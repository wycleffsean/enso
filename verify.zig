//! Verifier. Write this before writing any pass.
//!
//! The exit-ordering check below is the one that matters most. Without it, a
//! pass that hoists a guard above a store produces code that is correct until
//! the guard fires, at which point baseline resumes with a stale frame and redoes
//! a side effect. That failure is nondeterministic, data-dependent, and
//! effectively undebuggable. With the check, it is a compile-time assertion.

const std = @import("std");
const ir = @import("ir.zig");
const osr = @import("osr.zig");
const passes = @import("passes.zig");
const ValueId = ir.ValueId;
const BlockId = ir.BlockId;

pub const Error = error{
    TerminatorNotLast,
    MissingTerminator,
    MultipleTerminators,
    OperandDoesNotDominateUse,
    UpsilonTargetNotPhi,
    UpsilonDoesNotReachPhi,
    ExitStateStale,
    OverflowResultUsedOnFailingPath,
    OutOfMemory,
};

pub fn verify(proc: *ir.Procedure) Error!void {
    // Recompute dominators from scratch. Do *not* maintain them incrementally:
    // incremental dominance is a research problem and every pass that gets it
    // subtly wrong produces the same undebuggable class of bug as above.
    const doms = try computeDominators(proc);
    defer proc.gpa.free(doms);

    var block_of = try proc.gpa.alloc(BlockId, proc.values.len);
    defer proc.gpa.free(block_of);
    var pos_of = try proc.gpa.alloc(u32, proc.values.len);
    defer proc.gpa.free(pos_of);
    @memset(block_of, .none);

    for (proc.blocks.items, 0..) |blk, bi| {
        for (blk.values.items, 0..) |v, i| {
            block_of[v.idx()] = BlockId.from(@intCast(bi));
            pos_of[v.idx()] = @intCast(i);
        }
    }

    for (proc.blocks.items, 0..) |blk, bi| {
        const block = BlockId.from(@intCast(bi));
        if (blk.values.items.len == 0) return error.MissingTerminator;

        // exactly one terminator, and it is last
        for (blk.values.items, 0..) |v, i| {
            const is_term = proc.effectsFor(v).terminator;
            if (is_term and i != blk.values.items.len - 1) return error.TerminatorNotLast;
            if (!is_term and i == blk.values.items.len - 1) return error.MissingTerminator;
        }

        for (blk.values.items) |v| {
            // operands dominate uses -- except phis, whose inputs arrive via
            // upsilons in predecessors and therefore do not dominate the phi.
            if (proc.opcodeOf(v) != .phi and proc.opcodeOf(v) != .upsilon) {
                var buf: [16]ValueId = undefined;
                for (passes.operandsOf(proc, v, &buf)) |raw| {
                    const o = proc.resolve(raw);
                    if (o == .none) continue;
                    const ob = block_of[o.idx()];
                    if (ob == .none) return error.OperandDoesNotDominateUse;
                    if (ob == block) {
                        if (pos_of[o.idx()] >= pos_of[v.idx()]) {
                            // Legal only for a terminator-defined value read in
                            // a successor, which is not this case.
                            return error.OperandDoesNotDominateUse;
                        }
                    } else if (!dominates(doms, ob, block)) {
                        return error.OperandDoesNotDominateUse;
                    }
                }
            }

            // Upsilon form legality: the target is a phi, and this block must be
            // able to *reach* the phi's block. Note this is weaker than
            // dominance -- that is the tradeoff Upsilon form makes, and it is
            // why this check has to exist explicitly.
            if (proc.opcodeOf(v) == .upsilon) {
                const phi = ValueId.from(proc.values.items(.rhs)[v.idx()]);
                if (proc.opcodeOf(phi) != .phi) return error.UpsilonTargetNotPhi;
                if (!reaches(proc, block, block_of[phi.idx()])) return error.UpsilonDoesNotReachPhi;
            }

            // The exit-ordering invariant.
            if (proc.effectsFor(v).can_exit and !proc.exit_ok.isSet(v.idx())) {
                return error.ExitStateStale;
            }
        }
    }
}

// ---------------------------------------------------------------------------

pub fn dominates(doms: []const BlockId, a: BlockId, b: BlockId) bool {
    var cur = b;
    while (true) {
        if (cur == a) return true;
        const next = doms[cur.idx()];
        if (next == cur or next == .none) return false;
        cur = next;
    }
}

/// Cooper/Harvey/Kennedy iterative dominators. Cheap enough to rerun after
/// every CFG change, which is exactly what we want.
pub fn computeDominators(proc: *ir.Procedure) ![]BlockId {
    const n = proc.blocks.items.len;
    const idom = try proc.gpa.alloc(BlockId, n);
    @memset(idom, .none);
    if (n == 0) return idom;

    const order = try reversePostorder(proc);
    defer proc.gpa.free(order);
    const rpo_num = try proc.gpa.alloc(u32, n);
    defer proc.gpa.free(rpo_num);
    for (order, 0..) |b, i| rpo_num[b.idx()] = @intCast(i);

    idom[proc.entry.idx()] = proc.entry;
    var changed = true;
    while (changed) {
        changed = false;
        for (order) |b| {
            if (b == proc.entry) continue;
            var new_idom: BlockId = .none;
            for (proc.blocks.items[b.idx()].preds.items) |p| {
                if (idom[p.idx()] == .none) continue;
                new_idom = if (new_idom == .none) p else intersect(idom, rpo_num, p, new_idom);
            }
            if (new_idom != .none and idom[b.idx()] != new_idom) {
                idom[b.idx()] = new_idom;
                changed = true;
            }
        }
    }
    return idom;
}

fn intersect(idom: []const BlockId, rpo: []const u32, a_in: BlockId, b_in: BlockId) BlockId {
    var a = a_in;
    var b = b_in;
    while (a != b) {
        while (rpo[a.idx()] > rpo[b.idx()]) a = idom[a.idx()];
        while (rpo[b.idx()] > rpo[a.idx()]) b = idom[b.idx()];
    }
    return a;
}

pub fn reversePostorder(proc: *ir.Procedure) ![]BlockId {
    const n = proc.blocks.items.len;
    var visited = try std.DynamicBitSetUnmanaged.initEmpty(proc.gpa, n);
    defer visited.deinit(proc.gpa);
    var out = std.ArrayListUnmanaged(BlockId){};
    try postorder(proc, proc.entry, &visited, &out);
    std.mem.reverse(BlockId, out.items);
    return out.toOwnedSlice(proc.gpa);
}

fn postorder(
    proc: *ir.Procedure,
    b: BlockId,
    visited: *std.DynamicBitSetUnmanaged,
    out: *std.ArrayListUnmanaged(BlockId),
) !void {
    if (visited.isSet(b.idx())) return;
    visited.set(b.idx());
    var buf: [8]BlockId = undefined;
    for (proc.successors(b, &buf)) |s| try postorder(proc, s, visited, out);
    try out.append(proc.gpa, b);
}

fn reaches(proc: *ir.Procedure, from: BlockId, to: BlockId) bool {
    if (from == to) return true;
    var seen = std.DynamicBitSetUnmanaged.initEmpty(proc.gpa, proc.blocks.items.len) catch return true;
    defer seen.deinit(proc.gpa);
    var stack = std.ArrayListUnmanaged(BlockId){};
    defer stack.deinit(proc.gpa);
    stack.append(proc.gpa, from) catch return true;
    while (stack.pop()) |b| {
        if (b == to) return true;
        if (seen.isSet(b.idx())) continue;
        seen.set(b.idx());
        var buf: [8]BlockId = undefined;
        for (proc.successors(b, &buf)) |s| stack.append(proc.gpa, s) catch return true;
    }
    return false;
}
