//! Bytecode -> tier-1 SSA IR.
//!
//! This is the only pass that knows Python bytecode exists. It does two things
//! at once, which is the whole point of doing lowering before SSA rather than
//! after:
//!
//!   * It maintains a *compile-time symbolic* evaluation stack of ValueIds, so
//!     the Python stack machine evaporates. POP_TOP, SWAP, COPY, DUP_TOP and
//!     friends produce zero IR: they are stack bookkeeping, not semantics.
//!
//!   * It runs Braun et al. SSA construction on the fly (readLocal /
//!     writeLocal), so LOAD_FAST / STORE_FAST also produce zero IR.
//!
//! It emits *only* tier-1 `py_*` opcodes. It never emits `add_i64` and never
//! emits a `check`. Specialization is a separate pass over the SSA graph. This
//! separation means the lowering pass is written once and never rewritten as
//! the optimizer gets smarter.
//!
//! Phis are constructed in Upsilon form: `addPhiOperands` places an
//! `upsilon(v -> phi)` in each predecessor instead of appending to an operand
//! array on the phi. Braun's algorithm is unchanged in structure; only the
//! representation of "phi operand" differs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const ValueId = ir.ValueId;
const BlockId = ir.BlockId;

pub const Builder = struct {
    proc: *ir.Procedure,
    gpa: Allocator,

    nlocals: u16,
    /// currentDef, flattened: `defs[block * nlocals + local]`. Dense because
    /// nlocals is known from the code object and blocks are dense.
    defs: std.ArrayListUnmanaged(ValueId) = .{},

    /// Phis created for a not-yet-sealed block, awaiting operands.
    incomplete: std.ArrayListUnmanaged(Incomplete) = .{},
    /// phi -> the upsilons that write it. Construction-only; the whole point of
    /// Upsilon form is that nothing *outside* construction needs this.
    upsilons_of: std.AutoHashMapUnmanaged(ValueId, std.ArrayListUnmanaged(ValueId)) = .{},
    /// value -> upsilons that read it. Only used to drive trivial-phi removal.
    read_by: std.AutoHashMapUnmanaged(ValueId, std.ArrayListUnmanaged(ValueId)) = .{},

    /// Compile-time Python evaluation stack. Holds ValueIds, not runtime values.
    stack: std.ArrayListUnmanaged(ValueId) = .{},

    current: BlockId = .none,
    /// Bytecode offset of the instruction being lowered. Every value gets it as
    /// `origin`, and it is what `state_mark` records.
    pc: u32 = 0,

    const Incomplete = struct { block: BlockId, local: ir.LocalIdx, phi: ValueId };

    pub fn init(proc: *ir.Procedure, nlocals: u16) Builder {
        return .{ .proc = proc, .gpa = proc.gpa, .nlocals = nlocals };
    }

    pub fn deinit(b: *Builder) void {
        b.defs.deinit(b.gpa);
        b.incomplete.deinit(b.gpa);
        var it = b.upsilons_of.valueIterator();
        while (it.next()) |l| l.deinit(b.gpa);
        b.upsilons_of.deinit(b.gpa);
        var it2 = b.read_by.valueIterator();
        while (it2.next()) |l| l.deinit(b.gpa);
        b.read_by.deinit(b.gpa);
        b.stack.deinit(b.gpa);
    }

    // -----------------------------------------------------------------------
    // blocks
    // -----------------------------------------------------------------------

    pub fn newBlock(b: *Builder) !BlockId {
        const id = try b.proc.addBlock();
        try b.defs.appendNTimes(b.gpa, .none, b.nlocals);
        std.debug.assert(b.defs.items.len == b.proc.blocks.items.len * b.nlocals);
        return id;
    }

    /// Call once all predecessors of `block` are known. For a reducible CFG in
    /// reverse postorder this is immediate for every block except loop headers,
    /// which are created unsealed and sealed when the backedge is emitted.
    pub fn sealBlock(b: *Builder, block: BlockId) !void {
        var i: usize = 0;
        while (i < b.incomplete.items.len) {
            const inc = b.incomplete.items[i];
            if (inc.block != block) {
                i += 1;
                continue;
            }
            _ = b.incomplete.swapRemove(i);
            try b.addPhiOperands(inc.local, inc.phi, block);
        }
        b.proc.blocks.items[block.idx()].sealed = true;
    }

    pub fn switchTo(b: *Builder, block: BlockId) void {
        b.current = block;
    }

    // -----------------------------------------------------------------------
    // emit
    // -----------------------------------------------------------------------

    fn emit(b: *Builder, v: ir.Value) !ValueId {
        var val = v;
        val.origin = b.pc;
        const id = try b.proc.addValue(val);
        try b.proc.appendToBlock(b.current, id);
        return id;
    }

    /// Placed in a specific block rather than the current one. Upsilons need
    /// this: they live in the predecessor, which is usually not current.
    fn emitIn(b: *Builder, block: BlockId, v: ir.Value) !ValueId {
        var val = v;
        val.origin = b.pc;
        const id = try b.proc.addValue(val);
        try b.proc.appendToBlock(block, id);
        return id;
    }

    /// Called at the start of each bytecode instruction. This is what delimits
    /// the regions a guard may exit to, and it is the traceback / line marker.
    pub fn beginInstruction(b: *Builder, offset: u32) !void {
        b.pc = offset;
        _ = try b.emit(.{ .op = .state_mark, .repr = .none, .origin = offset, .lhs = offset, .rhs = 0 });
    }

    // -----------------------------------------------------------------------
    // symbolic stack: these emit nothing
    // -----------------------------------------------------------------------

    pub fn push(b: *Builder, v: ValueId) !void {
        try b.stack.append(b.gpa, v);
    }
    pub fn pop(b: *Builder) ValueId {
        return b.stack.pop();
    }
    pub fn peek(b: *Builder, depth: usize) ValueId {
        return b.stack.items[b.stack.items.len - 1 - depth];
    }
    /// POP_TOP, but note the decref: stack discipline is free, refcounting is
    /// not. This is the one place where "stack ops produce no IR" is a lie, and
    /// it is why refcount ops are first-class IR opcodes.
    pub fn popTop(b: *Builder) !void {
        const v = b.pop();
        if (b.proc.reprOf(v) == .object) {
            _ = try b.emit(.{ .op = .decref, .repr = .none, .origin = b.pc, .lhs = @intFromEnum(v), .rhs = 0 });
        }
    }
    pub fn swap(b: *Builder, i: usize) void {
        const n = b.stack.items.len;
        std.mem.swap(ValueId, &b.stack.items[n - 1], &b.stack.items[n - i]);
    }

    // -----------------------------------------------------------------------
    // Braun SSA construction
    // -----------------------------------------------------------------------

    inline fn defSlot(b: *Builder, block: BlockId, local: ir.LocalIdx) *ValueId {
        return &b.defs.items[block.idx() * b.nlocals + local];
    }

    pub fn writeLocal(b: *Builder, local: ir.LocalIdx, v: ValueId) !void {
        b.defSlot(b.current, local).* = v;
        // Record the abstract state change for OSR. Zero machine code; this is
        // the incremental exit state that osr.zig reads instead of us building
        // a dense FrameState per guard.
        _ = try b.emit(.{
            .op = .mov_hint,
            .repr = .none,
            .origin = b.pc,
            .lhs = @intFromEnum(v),
            .rhs = local,
        });
    }

    pub fn readLocal(b: *Builder, local: ir.LocalIdx) !ValueId {
        return b.readLocalIn(b.current, local);
    }

    fn readLocalIn(b: *Builder, block: BlockId, local: ir.LocalIdx) !ValueId {
        const slot = b.defSlot(block, local);
        if (slot.* != .none) return slot.*;
        return b.readLocalRecursive(block, local);
    }

    fn readLocalRecursive(b: *Builder, block: BlockId, local: ir.LocalIdx) !ValueId {
        const blk = &b.proc.blocks.items[block.idx()];
        var result: ValueId = undefined;

        if (!blk.sealed) {
            // Loop header we have not finished discovering. Speculatively place
            // an operand-less phi; sealBlock fills in the upsilons later.
            result = try b.emitPhi(block);
            try b.incomplete.append(b.gpa, .{ .block = block, .local = local, .phi = result });
        } else if (blk.preds.items.len == 1) {
            result = try b.readLocalIn(blk.preds.items[0], local);
        } else {
            // Break potential cycles before recursing.
            const phi = try b.emitPhi(block);
            b.defSlot(block, local).* = phi;
            try b.addPhiOperands(local, phi, block);
            result = phi;
        }
        b.defSlot(block, local).* = result;
        return result;
    }

    fn emitPhi(b: *Builder, block: BlockId) !ValueId {
        const id = try b.proc.addValue(.{
            .op = .phi,
            .repr = .object, // tier 1: everything is a boxed reference
            .origin = b.pc,
            .lhs = 0,
            .rhs = 0,
        });
        // Phis go at the very top of the block.
        const blk = &b.proc.blocks.items[block.idx()];
        try blk.values.insert(b.gpa, 0, id);
        try b.upsilons_of.put(b.gpa, id, .{});
        return id;
    }

    fn addPhiOperands(b: *Builder, local: ir.LocalIdx, phi: ValueId, block: BlockId) !void {
        // Copy predecessors: readLocalIn can create blocks/values.
        var preds = std.ArrayListUnmanaged(BlockId){};
        defer preds.deinit(b.gpa);
        try preds.appendSlice(b.gpa, b.proc.blocks.items[block.idx()].preds.items);

        for (preds.items) |pred| {
            const v = try b.readLocalIn(pred, local);
            try b.addUpsilon(pred, v, phi);
        }
    }

    fn addUpsilon(b: *Builder, pred: BlockId, v: ValueId, phi: ValueId) !void {
        const u = try b.emitIn(pred, .{
            .op = .upsilon,
            .repr = .none,
            .origin = b.pc,
            .lhs = @intFromEnum(v),
            .rhs = @intFromEnum(phi),
        });
        const gop = try b.upsilons_of.getOrPut(b.gpa, phi);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(b.gpa, u);

        const gop2 = try b.read_by.getOrPut(b.gpa, v);
        if (!gop2.found_existing) gop2.value_ptr.* = .{};
        try gop2.value_ptr.append(b.gpa, u);
    }

    /// A local that is read with no reaching definition is not "undefined" as
    /// in C -- in Python it is `UnboundLocalError`. Braun's undef case is
    /// therefore a *runtime check*, which is a nice illustration of why the
    /// lowering pass has to know Python semantics and later passes do not.
    pub fn emitUnboundCheck(b: *Builder, local: ir.LocalIdx) !ValueId {
        const off = try b.proc.addExtra(struct { helper: u32, nargs: u32 }, .{
            .helper = @intFromEnum(RuntimeHelper.raise_unbound_local),
            .nargs = 0,
        });
        _ = local;
        return b.emit(.{ .op = .call_runtime, .repr = .object, .origin = b.pc, .lhs = 0, .rhs = off });
    }

    // -----------------------------------------------------------------------
    // trivial phi removal
    // -----------------------------------------------------------------------

    /// Braun removes trivial phis on the fly. A worklist sweep after
    /// construction reaches the same fixpoint with much less code, and
    /// `replaceWithIdentity` makes each removal O(1). Do the simple thing.
    pub fn removeTrivialPhis(b: *Builder) !void {
        var work = std.ArrayListUnmanaged(ValueId){};
        defer work.deinit(b.gpa);
        var it = b.upsilons_of.keyIterator();
        while (it.next()) |k| try work.append(b.gpa, k.*);

        while (work.pop()) |phi| {
            if (b.proc.opcodeOf(phi) != .phi) continue; // already collapsed
            const ups = b.upsilons_of.get(phi) orelse continue;

            var same: ValueId = .none;
            var trivial = true;
            for (ups.items) |u| {
                if (b.proc.opcodeOf(u) == .nop) continue;
                const src = b.proc.resolve(ValueId.from(b.proc.values.items(.lhs)[u.idx()]));
                if (src == same or src == phi) continue;
                if (same != .none) {
                    trivial = false;
                    break;
                }
                same = src;
            }
            if (!trivial or same == .none) continue;

            // Anything that read this phi may now itself be trivial.
            if (b.read_by.get(phi)) |readers| {
                for (readers.items) |u| {
                    const target = ValueId.from(b.proc.values.items(.rhs)[u.idx()]);
                    if (target != phi) try work.append(b.gpa, target);
                }
            }
            b.proc.replaceWithIdentity(phi, same);
            for (ups.items) |u| b.proc.deleteValue(u);
        }
    }
};

pub const RuntimeHelper = enum(u32) {
    raise_unbound_local,
    import_name,
    build_class,
    match_class,
    setup_annotations,
    format_value,
    // ... the long tail of rare CPython opcodes lives here, not in Opcode.
};

// ===========================================================================
// Worked example: the §14 program, lowered.
//
//   if cond: x = 10
//   else:    x = 20
//   return x + 1
//
// Shows that the lowering pass emits only tier-1 ops and that no phi operand
// array is ever touched.
// ===========================================================================

pub fn lowerExample(proc: *ir.Procedure, cond_arg_index: u32) !void {
    var b = Builder.init(proc, 1); // one local: x
    defer b.deinit();

    const entry = try b.newBlock();
    proc.entry = entry;
    b.switchTo(entry);
    try b.sealBlock(entry);

    try b.beginInstruction(0);
    const cond = try b.emit(.{ .op = .arg, .repr = .object, .origin = 0, .lhs = cond_arg_index, .rhs = 0 });
    // POP_JUMP_IF_FALSE has to call __bool__ in general: tier 1 is honest.
    const truthy = try b.emit(.{ .op = .py_truthy, .repr = .i1, .origin = 0, .lhs = @intFromEnum(cond), .rhs = 0 });

    const then_bb = try b.newBlock();
    const else_bb = try b.newBlock();
    const join_bb = try b.newBlock();

    const br_extra = try proc.addExtra(ir.Branch, .{ .then_ = then_bb, .else_ = else_bb });
    _ = try b.emit(.{ .op = .branch, .repr = .none, .origin = 0, .lhs = @intFromEnum(truthy), .rhs = br_extra });
    try proc.blocks.items[then_bb.idx()].preds.append(proc.gpa, entry);
    try proc.blocks.items[else_bb.idx()].preds.append(proc.gpa, entry);

    // then: x = 10
    b.switchTo(then_bb);
    try b.sealBlock(then_bb);
    try b.beginInstruction(4);
    const c10 = try b.emit(.{ .op = .const_int, .repr = .tagged, .origin = 4, .lhs = 10, .rhs = 0 });
    try b.writeLocal(0, c10);
    _ = try b.emit(.{ .op = .jump, .repr = .none, .origin = 4, .lhs = @intFromEnum(join_bb), .rhs = 0 });
    try proc.blocks.items[join_bb.idx()].preds.append(proc.gpa, then_bb);

    // else: x = 20
    b.switchTo(else_bb);
    try b.sealBlock(else_bb);
    try b.beginInstruction(10);
    const c20 = try b.emit(.{ .op = .const_int, .repr = .tagged, .origin = 10, .lhs = 20, .rhs = 0 });
    try b.writeLocal(0, c20);
    _ = try b.emit(.{ .op = .jump, .repr = .none, .origin = 10, .lhs = @intFromEnum(join_bb), .rhs = 0 });
    try proc.blocks.items[join_bb.idx()].preds.append(proc.gpa, else_bb);

    // join: return x + 1
    b.switchTo(join_bb);
    try b.sealBlock(join_bb); // both preds known -> phi gets its upsilons now
    try b.beginInstruction(16);
    const x = try b.readLocal(0); // creates the phi + two upsilons
    const one = try b.emit(.{ .op = .const_int, .repr = .tagged, .origin = 16, .lhs = 1, .rhs = 0 });
    const binop_extra = try proc.addExtra(ir.PyBinOp, .{
        .kind = @intFromEnum(ir.PyBinKind.add),
        .a = x,
        .b = one,
    });
    const sum = try b.emit(.{ .op = .py_binary_op, .repr = .object, .origin = 16, .lhs = binop_extra, .rhs = 0 });
    _ = try b.emit(.{ .op = .ret, .repr = .none, .origin = 18, .lhs = @intFromEnum(sum), .rhs = 0 });

    try b.removeTrivialPhis();
}
