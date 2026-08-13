//! Representative passes, written to show what the API feels like in use.
//!
//! Every one of them follows the same shape:
//!
//!     var ins = ir.InsertionSet{};
//!     for (block.values.items, 0..) |v, i| { ... ins.insertAt(...) ... }
//!     try ins.execute(proc, block);
//!
//! No pass mutates a value list while iterating it. No pass maintains a use
//! list. No pass touches a phi operand array. No pass contains a line of
//! exit-specific fixup code.

const std = @import("std");
const ir = @import("ir.zig");
const osr = @import("osr.zig");
const ValueId = ir.ValueId;
const BlockId = ir.BlockId;

// ===========================================================================
// Specialization: tier 1 -> tier 2
// ===========================================================================

/// Rewrites `py_binary_op(add, a, b)` given static types.
///
/// Three outcomes, in order of preference, and the ordering is the whole
/// argument for having a static type source at all:
///
///   1. Both operands are integer constants -> fold. No guard, no exit, no
///      overflow check. `1 + 2` never needs any of this machinery.
///
///   2. Both statically `int` -> `add_ovf_i64` terminator with a cold overflow
///      block that calls into big-int. **This is not an exit.** The result phis
///      back in as `tagged`; the CFG stays self-contained; no frame state, no
///      baseline transfer. Most of what the design doc called "speculation
///      failure" is actually this, and it is an order of magnitude less
///      machinery than OSR.
///
///   3. Types unknown (an `Any` boundary, or a value that came through `eval`)
///      -> emit `is_type` guards plus a `check` with a real exit, *or* leave the
///      tier-1 op alone. Which one depends on the compiler flag: under
///      `--strict-types` the guard is a hard error path; otherwise it is an
///      exit to baseline.
pub fn specializeBinaryOps(proc: *ir.Procedure, mode: SpecMode) !void {
    var bi: u32 = 0;
    while (bi < proc.blocks.items.len) : (bi += 1) {
        const block = BlockId.from(bi);
        var ins = ir.InsertionSet{};
        defer ins.deinit(proc.gpa);

        // Snapshot: specialization can append blocks, and it can replace a
        // non-terminator with a terminator, which splits this block.
        const values = try proc.gpa.dupe(ValueId, proc.blocks.items[bi].values.items);
        defer proc.gpa.free(values);

        for (values, 0..) |v, i| {
            if (proc.opcodeOf(v) != .py_binary_op) continue;
            const pay = proc.extraData(ir.PyBinOp, proc.values.items(.lhs)[v.idx()]);
            if (@as(ir.PyBinKind, @enumFromInt(pay.kind)) != .add) continue;

            const a = proc.resolve(pay.a);
            const b = proc.resolve(pay.b);

            // (1) constant fold
            if (proc.opcodeOf(a) == .const_int and proc.opcodeOf(b) == .const_int) {
                const x = constIntOf(proc, a);
                const y = constIntOf(proc, b);
                if (@addWithOverflow(x, y)[1] == 0) {
                    // In-place mutation keeps the ValueId, so nothing else in
                    // the graph has to be updated at all.
                    proc.replaceWithConstInt(v, x + y);
                    continue;
                }
                // Overflowing constant fold: emit a big-int constant instead.
                // (Elided: interning into the constant pool.)
            }

            // (2) statically int + int
            const ta = proc.py_types.items[a.idx()];
            const tb = proc.py_types.items[b.idx()];
            if (ta == .int and tb == .int) {
                try specializeIntAdd(proc, block, v, a, b, @intCast(i), &ins);
                continue;
            }

            // (3) unknown: guard, or leave generic
            if (mode == .guard_unknown) {
                try insertTypeGuard(proc, v, a, .int, @intCast(i), &ins);
                try insertTypeGuard(proc, v, b, .int, @intCast(i), &ins);
                try specializeIntAdd(proc, block, v, a, b, @intCast(i), &ins);
            }
        }
        try ins.execute(proc, block);
    }
}

pub const SpecMode = enum {
    /// Only specialize what the type source proved. Leaves `Any` boundaries as
    /// generic tier-1 calls. Correct everywhere, no exits needed.
    proven_only,
    /// Speculate at `Any` boundaries, inserting guards and exits.
    guard_unknown,
};

fn constIntOf(proc: *const ir.Procedure, v: ValueId) i64 {
    const lo: u64 = proc.values.items(.lhs)[v.idx()];
    const hi: u64 = proc.values.items(.rhs)[v.idx()];
    return @bitCast(lo | (hi << 32));
}

/// Builds the checked-add-with-bigint-fallback shape. Notice that this is
/// entirely ordinary CFG and SSA work -- one new block, one phi, no exit table
/// involvement whatsoever.
///
///     bb_cur:   %s = add_ovf_i64 %a, %b -> [bb_fast, bb_slow]
///     bb_slow:  %big = call_runtime bigint_add(%a, %b); jump bb_fast
///     bb_fast:  %r = phi          ; upsilon(%s) in bb_cur, upsilon(%big) in bb_slow
fn specializeIntAdd(
    proc: *ir.Procedure,
    block: BlockId,
    old: ValueId,
    a: ValueId,
    b: ValueId,
    index: u32,
    ins: *ir.InsertionSet,
) !void {
    _ = index;
    const fast = try proc.addBlock();
    const slow = try proc.addBlock();

    const ovf_extra = try proc.addExtra(ir.OvfOp, .{
        .a = a,
        .b = b,
        .normal = fast,
        .overflow = slow,
    });
    const sum = try proc.addValue(.{
        .op = .add_ovf_i64,
        .repr = .i64,
        .origin = proc.values.items(.origin)[old.idx()],
        .lhs = ovf_extra,
        .rhs = 0,
    });

    // Slow path: big int. Allocates, can raise MemoryError, and that is all
    // ordinary effect metadata -- no exit involved.
    const helper_extra = try proc.addExtra(struct { helper: u32, nargs: u32 }, .{ .helper = 0, .nargs = 2 });
    try proc.addExtraSlice(&.{ a, b });
    const big = try proc.addValue(.{
        .op = .call_runtime,
        .repr = .object,
        .origin = proc.values.items(.origin)[old.idx()],
        .lhs = 0,
        .rhs = helper_extra,
    });
    try proc.appendToBlock(slow, big);
    const jmp = try proc.addValue(.{ .op = .jump, .repr = .none, .origin = 0, .lhs = @intFromEnum(fast), .rhs = 0 });
    try proc.appendToBlock(slow, jmp);

    // Join. Upsilon form means adding these two edges touches no operand array.
    const phi = try proc.addValue(.{ .op = .phi, .repr = .tagged, .origin = 0, .lhs = 0, .rhs = 0 });
    try proc.appendToBlock(fast, phi);
    const boxed = try proc.addValue(.{ .op = .box_i64, .repr = .tagged, .origin = 0, .lhs = @intFromEnum(sum), .rhs = 0 });
    _ = boxed; // in a real impl, upsilon(boxed -> phi) lives in `block`
    try proc.blocks.items[fast.idx()].preds.append(proc.gpa, block);
    try proc.blocks.items[fast.idx()].preds.append(proc.gpa, slow);
    try proc.blocks.items[slow.idx()].preds.append(proc.gpa, block);

    // Everything downstream of `old` now reads the phi. O(1).
    proc.values.items(.repr)[old.idx()] = .tagged;
    proc.replaceWithIdentity(old, phi);
    try ins.insertAt(proc.gpa, 0, sum); // terminator placement handled by the
    // block splitter, elided here
}

/// `is_type` is deliberately an ordinary pure predicate rather than a fused
/// speculative op, because then CSE, GVN and range analysis eliminate redundant
/// guards with no guard-specific machinery at all. `check` consumes it.
fn insertTypeGuard(
    proc: *ir.Procedure,
    at: ValueId,
    obj: ValueId,
    ty: ir.PyTypeId,
    index: u32,
    ins: *ir.InsertionSet,
) !void {
    const pred = try proc.addValue(.{
        .op = .is_type,
        .repr = .i1,
        .origin = proc.values.items(.origin)[at.idx()],
        .lhs = @intFromEnum(obj),
        .rhs = @intFromEnum(ty),
    });
    // Exit id is `.none` for now; osr.materialize fills in the descriptor and
    // the stackmap operands just before MIR lowering, from the mov_hint stream.
    const payload = try proc.addExtra(ir.CheckPayload, .{ .exit = .none, .nargs = 0 });
    const chk = try proc.addValue(.{
        .op = .check,
        .repr = .none,
        .origin = proc.values.items(.origin)[at.idx()],
        .lhs = @intFromEnum(pred),
        .rhs = payload,
    });
    try ins.insertAt(proc.gpa, index, pred);
    try ins.insertAt(proc.gpa, index, chk);
}

// ===========================================================================
// Guard elimination
// ===========================================================================

/// Deletes any `check` whose predicate folded to a known-true constant. Under
/// `--strict-types` on fully annotated code this should remove essentially all
/// of them, which is the payoff for having the guards be ordinary values.
pub fn eliminateGuards(proc: *ir.Procedure, known_true: *const std.DynamicBitSetUnmanaged) void {
    for (proc.blocks.items) |blk| {
        for (blk.values.items) |v| {
            if (proc.opcodeOf(v) != .check) continue;
            const pred = proc.resolve(ValueId.from(proc.values.items(.lhs)[v.idx()]));
            if (known_true.isSet(pred.idx())) proc.deleteValue(v);
        }
    }
}

// ===========================================================================
// DCE
// ===========================================================================

/// Mark-and-sweep. The only subtlety, and it is the important one: a `check`'s
/// stackmap operands are *uses*, so values kept alive only by an exit survive.
/// Speculation genuinely weakens DCE and there is no way around it; the
/// mitigations are guard elimination first, then rematerialization (`.constant`
/// slot sources), then allocation sinking (`.materialize`).
pub fn dce(proc: *ir.Procedure) !void {
    var live = try std.DynamicBitSetUnmanaged.initEmpty(proc.gpa, proc.values.len);
    defer live.deinit(proc.gpa);
    var work = std.ArrayListUnmanaged(ValueId){};
    defer work.deinit(proc.gpa);

    // Roots: anything with an effect.
    for (proc.blocks.items) |blk| {
        for (blk.values.items) |v| {
            const e = proc.effectsFor(v);
            if (e.terminator or e.writes_world or e.can_exit or e.can_raise) {
                if (!live.isSet(v.idx())) {
                    live.set(v.idx());
                    try work.append(proc.gpa, v);
                }
            }
        }
    }

    while (work.pop()) |v| {
        var buf: [16]ValueId = undefined;
        for (operandsOf(proc, v, &buf)) |o| {
            const r = proc.resolve(o);
            if (r == .none or live.isSet(r.idx())) continue;
            live.set(r.idx());
            try work.append(proc.gpa, r);
        }
    }

    for (proc.blocks.items) |blk| {
        for (blk.values.items) |v| {
            if (live.isSet(v.idx())) continue;
            if (proc.effectsFor(v).terminator) continue;
            proc.deleteValue(v);
        }
    }
    proc.stripIdentitiesAndNops();
}

/// Single place where operand layout is decoded. Every pass calls this rather
/// than switching on opcode itself; adding an opcode means editing one function.
pub fn operandsOf(proc: *const ir.Procedure, v: ValueId, buf: *[16]ValueId) []const ValueId {
    const i = v.idx();
    const op = proc.opcodeOf(v);
    const lhs = proc.values.items(.lhs)[i];
    const rhs = proc.values.items(.rhs)[i];
    var n: usize = 0;
    switch (op) {
        .nop, .phi, .arg, .const_int, .const_f64, .const_obj, .jump, .state_mark, .unreachable_ => {},
        .identity, .decref, .incref, .box_i64, .box_f64, .unbox_i64, .unbox_f64, .is_type, .is_tagged_int, .py_truthy, .py_get_iter, .ret => {
            if (lhs != @intFromEnum(ValueId.none)) {
                buf[n] = ValueId.from(lhs);
                n += 1;
            }
        },
        .upsilon, .mov_hint => {
            buf[n] = ValueId.from(lhs);
            n += 1;
        },
        .branch => {
            buf[n] = ValueId.from(lhs);
            n += 1;
        },
        .add_ovf_i64, .sub_ovf_i64, .mul_ovf_i64 => {
            const d = proc.extraData(ir.OvfOp, lhs);
            buf[n] = d.a;
            buf[n + 1] = d.b;
            n += 2;
        },
        .py_binary_op => {
            const d = proc.extraData(ir.PyBinOp, lhs);
            buf[n] = d.a;
            buf[n + 1] = d.b;
            n += 2;
        },
        .check => {
            buf[n] = ValueId.from(lhs);
            n += 1;
            // The stackmap operands. Missing this line is how you silently drop
            // values an exit needs.
            for (osr.checkOperands(proc, v)) |raw| {
                if (n >= buf.len) break;
                buf[n] = ValueId.from(raw);
                n += 1;
            }
        },
        else => {
            if (rhs != 0) {} // opcode-specific layouts go here
        },
    }
    return buf[0..n];
}
