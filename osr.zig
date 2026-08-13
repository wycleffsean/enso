//! OSR exit state.
//!
//! The key claim being implemented: **exit state is a property of a program
//! point, not a field on a guard.** So we do not store a dense FrameState per
//! `check`. Instead the lowering pass leaves a stream of `mov_hint` and
//! `state_mark` values (zero machine code), and this file derives:
//!
//!   * `exit_ok`: is the abstract state valid here at all?
//!   * a dense, interned `ExitDescriptor`, on demand, right before MIR lowering.
//!
//! Why not dense-per-guard from the start: a loop with 40 guards over a
//! 25-slot frame is 1000 slot entries per copy, multiplied again by every
//! inlined frame. And correctness: with the state living *in* the instruction
//! stream, "can I move this check?" reduces to ordinary effect reasoning
//! against the hints, instead of a manual audit in every pass.
//!
//! Slot numbering is flat: `[0, nlocals)` are locals, `[nlocals, nslots)` are
//! evaluation-stack positions from the bottom up.

const std = @import("std");
const ir = @import("ir.zig");
const ValueId = ir.ValueId;
const BlockId = ir.BlockId;

pub const Availability = struct {
    nlocals: u16,
    nslots: u16,
    /// Current source of each abstract slot. `.none` means dead / optimized out.
    slots: []ValueId,
    /// Bytecode offset a guard here would resume at.
    pc: u32 = 0,

    pub fn clone(a: Availability, gpa: std.mem.Allocator) !Availability {
        return .{
            .nlocals = a.nlocals,
            .nslots = a.nslots,
            .slots = try gpa.dupe(ValueId, a.slots),
            .pc = a.pc,
        };
    }
};

/// Computes `proc.exit_ok`.
///
/// The rule: after a `state_mark` the abstract state matches the bytecode
/// position exactly, so an exit is legal. After any value that writes the world
/// or can reenter Python, an exit is *illegal* until the next `state_mark`,
/// because resuming baseline at the old offset would redo the side effect.
///
/// This is the invariant that stops a pass from hoisting a guard above a store
/// and silently miscompiling. Run it after every pass that reorders anything,
/// and let the verifier assert it.
pub fn computeExitOk(proc: *ir.Procedure) !void {
    proc.exit_ok.deinit(proc.gpa);
    proc.exit_ok = try std.DynamicBitSetUnmanaged.initEmpty(proc.gpa, proc.values.len);

    for (proc.blocks.items) |blk| {
        // Conservative block entry: not ok until a state_mark is seen. Lowering
        // emits one at the top of every bytecode instruction, so in practice
        // this costs nothing.
        var ok = false;
        for (blk.values.items) |v| {
            const op = proc.opcodeOf(v);
            if (op == .state_mark) {
                ok = true;
                continue;
            }
            const e = ir.effectsOf(op);
            if (e.can_exit and ok) proc.exit_ok.set(v.idx());
            if (e.writes_world or e.can_call_python) ok = false;
        }
    }
}

/// Walks a block forward, maintaining `avail`, and calls `cb.at(value, avail)`
/// for every value that can exit. Callers use this to materialize descriptors
/// or to answer "what is live for exit purposes here?" for liveness.
///
/// Block-entry availability must be supplied by the caller. For straight-line
/// lowering output, meeting predecessors is unnecessary because the lowering
/// pass emits a hint for every slot it touches; a full solver is only needed
/// after aggressive code motion, at which point this becomes an ordinary
/// forward dataflow problem with `.none` as the meet-to-dead element.
pub fn walkBlock(
    proc: *const ir.Procedure,
    block: BlockId,
    avail: *Availability,
    ctx: anytype,
) !void {
    const blk = proc.blocks.items[block.idx()];
    for (blk.values.items) |v| {
        switch (proc.opcodeOf(v)) {
            .state_mark => avail.pc = proc.values.items(.lhs)[v.idx()],
            .mov_hint => {
                const src = ValueId.from(proc.values.items(.lhs)[v.idx()]);
                const slot = proc.values.items(.rhs)[v.idx()];
                avail.slots[slot] = proc.resolve(src);
            },
            else => {
                if (proc.effectsFor(v).can_exit) try ctx.at(v, avail);
            },
        }
    }
}

/// Turn the current availability into an interned descriptor and rewrite
/// `check`'s stackmap operands to match.
///
/// Note what this produces: the descriptor holds *operand indices*, and the
/// ValueIds go into the check's own variadic operand list. That is what makes
/// exits participate in liveness, DCE and replaceAllUses with zero
/// exit-specific code anywhere else -- an exit reference simply *is* a use.
pub fn materialize(
    proc: *ir.Procedure,
    check: ValueId,
    frames: []const FrameDesc,
) !void {
    std.debug.assert(proc.opcodeOf(check) == .check);

    var slots = std.ArrayListUnmanaged(ir.SlotSource){};
    defer slots.deinit(proc.gpa);
    var args = std.ArrayListUnmanaged(ValueId){};
    defer args.deinit(proc.gpa);
    var frame_states = std.ArrayListUnmanaged(ir.FrameState){};
    defer frame_states.deinit(proc.gpa);

    // Dedup identical values within one exit: a value used by five slots is one
    // operand, five slot sources pointing at it.
    var seen = std.AutoHashMapUnmanaged(ValueId, u22){};
    defer seen.deinit(proc.gpa);

    for (frames) |f| {
        const slots_off: u32 = @intCast(slots.items.len);
        for (f.slots) |src| {
            if (src == .none) {
                try slots.append(proc.gpa, .{ .kind = .dead, .repr = .none, .payload = 0 });
                continue;
            }
            const v = proc.resolve(src);
            const repr = proc.reprOf(v);
            // A constant needs no operand and no live register at the exit.
            if (proc.opcodeOf(v) == .const_int) {
                try slots.append(proc.gpa, .{
                    .kind = .constant,
                    .repr = repr,
                    .payload = @intCast(v.idx() & 0x3F_FFFF),
                });
                continue;
            }
            const gop = try seen.getOrPut(proc.gpa, v);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(args.items.len);
                try args.append(proc.gpa, v);
            }
            try slots.append(proc.gpa, .{
                .kind = .operand,
                // Carried so the exit stub knows whether to box. Unboxed slots
                // mean exit code can allocate, hence can GC, hence is not
                // "just moving bits".
                .repr = repr,
                .payload = gop.value_ptr.*,
            });
        }
        try frame_states.append(proc.gpa, .{
            .code = f.code,
            .resume_pc = f.resume_pc,
            .nlocals = f.nlocals,
            .nstack = @intCast(f.slots.len - f.nlocals),
            .slots_off = slots_off,
        });
    }

    const exit_id = try proc.exits.intern(proc.gpa, frame_states.items, slots.items);

    // Append a fresh operand region. `extra` is append-only; the old region is
    // abandoned, which is free under an arena.
    const off = try proc.addExtra(ir.CheckPayload, .{
        .exit = exit_id,
        .nargs = @intCast(args.items.len),
    });
    try proc.addExtraSlice(args.items);
    proc.values.items(.rhs)[check.idx()] = off;
}

/// One frame of the exit's frame stack. Outermost first. Once inlining exists,
/// an exit inside an inlined callee reconstructs several of these.
pub const FrameDesc = struct {
    code: ir.CodeId,
    resume_pc: u32,
    nlocals: u16,
    /// Locals then stack, flat.
    slots: []const ValueId,
};

/// Reads a check's stackmap operands. Every pass that walks operands must
/// include these, or exits will keep values that DCE thinks are dead (or worse,
/// drop values the exit needs).
pub fn checkOperands(proc: *const ir.Procedure, check: ValueId) []const u32 {
    const rhs = proc.values.items(.rhs)[check.idx()];
    const pay = proc.extraData(ir.CheckPayload, rhs);
    return proc.extraSlice(rhs + 2, pay.nargs);
}

// ===========================================================================
// Notes on the MIR contract, since this is where it bites.
// ===========================================================================
//
// MIR has no stackmap facility: there is no way to ask it where a pseudo-reg
// lives at a given instruction. Therefore exits are lowered to *explicit code*
// before MIR, not to metadata that survives register allocation:
//
//   check %c, Exit42, (%a, %b)
//     =>  MIR:  bf   L_exit42, c
//         ...
//         L_exit42:
//              mov  i64:frame_slot_0(fp), a     ; boxing calls inserted here
//              mov  i64:frame_slot_1(fp), b     ;   if repr.needsBoxing()
//              mov  i64:pc_index(fp), 46
//              jcall  baseline_entry            ; or: return a deopt sentinel
//
// Consequences, all of which are fine but should be deliberate:
//   * Nothing needs to survive MIR register allocation. Answering "should OSR
//     lowering happen before or after RA": before, necessarily.
//   * Exit-only values stay live in MIR, costing registers in the hot loop.
//     This is exactly what stackmaps exist to avoid and we do not have them.
//     Measure it early: a loop with ~10 guards and ~20 live slots.
//   * The mitigation is fewer guards per loop body (hoist them out, which you
//     want anyway), not inventing a stackmap layer.
//
// MIR does give two things worth using:
//   * `JCALL`/`JRET`: a no-arg, no-return, direct-jump calling convention with
//     values passed through variables bound to specific hard registers,
//     documented as being for fast switching between JITted code and
//     interpreters. That is the tier-transfer primitive. For v1, returning a
//     deopt sentinel to a driver loop is simpler and portable; switch later.
//   * `LADDR` + `JMPI` (or `MIR_SWITCH`): a jump table over bytecode offsets,
//     which is how baseline gets a per-offset entry point.
