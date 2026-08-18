const std = @import("std");
const ir = @import("../../ir.zig");

const ValueId = ir.ValueId;
const BlockId = ir.BlockId;

proc: *ir.Procedure,
allocator: std.mem.Allocator,
nlocals: u16,
defs: std.ArrayList(ValueId) = .empty,
incomplete: std.ArrayList(Incomplete) = .empty,
upsilons_of: std.AutoHashMapUnmanaged(ValueId, std.ArrayList(ValueId)) = .empty,
read_by: std.AutoHashMapUnmanaged(ValueId, std.ArrayList(ValueId)) = .empty,
stack: std.ArrayList(ValueId) = .empty,
current: BlockId = .none,
pc: u32 = 0,

const Builder = @This();

const Incomplete = struct { bid: BlockId, local: ir.LocalIdx, phi: ValueId };

pub fn init(proc: *ir.Procedure, nlocals: u16) Builder {
    return .{ .proc = proc, .allocator = proc.allocator, .nlocals = nlocals };
}

pub fn deinit(b: *Builder) void {
    b.defs.deinit(b.allocator);
    b.incomplete.deinit(b.allocator);
    var it = b.upsilons_of.valueIterator();
    while (it.next()) |l| l.deinit(b.allocator);
    b.upsilons_of.deinit(b.allocator);
    var it2 = b.read_by.valueIterator();
    while (it2.next()) |l| l.deinit(b.allocator);
    b.read_by.deinit(b.allocator);
    b.stack.deinit(b.allocator);
}

pub fn newBlock(b: *Builder) !BlockId {
    const id = try b.proc.addBlock();
    try b.defs.appendNTimes(b.allocator, .none, b.nlocals);
    std.debug.assert(b.defs.items.len == b.proc.blocks.items.len * b.nlocals);
    return id;
}

pub fn sealBlock(b: *Builder, bid: BlockId) !void {
    var i: usize = 0;
    while (i < b.incomplete.items.len) {
        const inc = b.incomplete.items[i];
        if (inc.bid != bid) {
            i += 1;
            continue;
        }
        _ = b.incomplete.swapRemove(i);
        try b.addPhiOperands(inc.local, inc.phi, bid);
    }
    b.proc.blocks.items[bid.idx()].sealed = true;
}

pub fn switchTo(b: *Builder, block: BlockId) void {
    b.current = block;
}

pub fn emit(b: *Builder, v: ir.Value) !ValueId {
    var val = v;
    val.origin = b.pc;
    return try b.proc.addValue(b.current, val);
}

fn emitIn(b: *Builder, bid: BlockId, v: ir.Value) !ValueId {
    var val = v;
    val.origin = b.pc;
    return try b.proc.addValue(bid, val);
}

/// Like emitIn but inserts before the block's terminator (if any),
/// so that upsilons don't appear after a jump/branch/ret.
fn emitBeforeTerminator(b: *Builder, bid: BlockId, v: ir.Value) !ValueId {
    var val = v;
    val.origin = b.pc;
    const id = ir.ValueId.from(@intCast(b.proc.values.len));
    try b.proc.values.append(b.proc.allocator, val);
    const blk = &b.proc.blocks.items[bid.idx()];
    // Insert before terminator if the last value is one.
    const insert_pos = if (blk.values.items.len > 0 and
        b.proc.values.items(.op)[blk.values.items[blk.values.items.len - 1].idx()].isTerminator())
        blk.values.items.len - 1
    else
        blk.values.items.len;
    try blk.values.insert(b.proc.allocator, insert_pos, id);
    return id;
}

pub fn push(b: *Builder, v: ValueId) !void {
    try b.stack.append(b.allocator, v);
}
pub fn pop(b: *Builder) ValueId {
    return b.stack.pop().?;
}
pub fn peek(b: *Builder, depth: usize) ValueId {
    return b.stack.items[b.stack.items.len - 1 - depth];
}

// Braun SSA construction
// see "Simple and Efficient Construction of Single Static Assignemnt Form"

inline fn defSlot(b: *Builder, block: BlockId, local: ir.LocalIdx) *ValueId {
    return &b.defs.items[block.idx() * b.nlocals + local];
}

pub fn writeLocal(b: *Builder, local: ir.LocalIdx, v: ValueId) !void {
    b.defSlot(b.current, local).* = v;
}

pub fn readLocal(b: *Builder, local: ir.LocalIdx) !ValueId {
    return b.readLocalIn(b.current, local);
}

fn readLocalIn(b: *Builder, block: BlockId, local: ir.LocalIdx) std.mem.Allocator.Error!ValueId {
    const slot = b.defSlot(block, local);
    if (slot.* != .none) return slot.*;
    return b.readLocalRecursive(block, local);
}

fn readLocalRecursive(b: *Builder, block: BlockId, local: ir.LocalIdx) !ValueId {
    const blk = &b.proc.blocks.items[block.idx()];
    var result: ValueId = undefined;

    if (!blk.sealed) {
        // Loop header we have not finished discovering. Speculatively place
        // an operand-less phi; sealBlock fills in the upsilons later
        result = try b.emitPhi(block);
        try b.incomplete.append(b.allocator, .{ .bid = block, .local = local, .phi = result });
    } else if (blk.preds.items.len == 0) {
        // Entry block or unreachable: no definition reaches here.
        // Emit a placeholder; a later pass can lower this to an UnboundLocalError check.
        result = try b.emitIn(block, .{ .op = .const_obj, .repr = .object, .origin = 0, .lhs = 0, .rhs = 0 });
    } else if (blk.preds.items.len == 1) {
        result = try b.readLocalIn(blk.preds.items[0], local);
    } else {
        // Break potential cycles
        const phi = try b.emitPhi(block);
        b.defSlot(block, local).* = phi;
        try b.addPhiOperands(local, phi, block);
        result = phi;
    }
    b.defSlot(block, local).* = result;
    return result;
}

fn emitPhi(b: *Builder, bid: BlockId) !ValueId {
    // Allocate the value ID and append to the value store directly —
    // do NOT use proc.addValue which also appends to block.values.
    // We then insert at position 0 so phis always precede all other instructions.
    const id = ir.ValueId.from(@intCast(b.proc.values.len));
    try b.proc.values.append(b.proc.allocator, .{
        .op = .phi,
        .repr = .object, // tier 1/baseline: everything is a boxed reference
        .origin = b.pc,
        .lhs = 0,
        .rhs = 0,
    });
    const blk = &b.proc.blocks.items[bid.idx()];
    try blk.values.insert(b.allocator, 0, id);
    try b.upsilons_of.put(b.allocator, id, .empty);
    return id;
}

fn addPhiOperands(b: *Builder, local: ir.LocalIdx, phi: ValueId, block: BlockId) !void {
    // Copy predecessors: readLocalIn can create blocks/values
    var preds: std.ArrayList(BlockId) = .empty;
    defer preds.deinit(b.allocator);
    try preds.appendSlice(b.allocator, b.proc.blocks.items[block.idx()].preds.items);

    for (preds.items) |pred| {
        const v = try b.readLocalIn(pred, local);
        try b.addUpsilon(pred, v, phi);
    }
}

fn addUpsilon(b: *Builder, pred: BlockId, v: ValueId, phi: ValueId) !void {
    const u = try b.emitBeforeTerminator(pred, .{
        .op = .upsilon,
        .repr = .none,
        .origin = b.pc,
        .lhs = @intFromEnum(v),
        .rhs = @intFromEnum(phi),
    });
    const gop = try b.upsilons_of.getOrPut(b.allocator, phi);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(b.allocator, u);

    const gop2 = try b.read_by.getOrPut(b.allocator, v);
    if (!gop2.found_existing) gop2.value_ptr.* = .empty;
    try gop2.value_ptr.append(b.allocator, u);
}
