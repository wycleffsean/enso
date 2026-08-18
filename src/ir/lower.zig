const std = @import("std");
const ir = @import("../ir.zig");
const bytecode = @import("../bytecode.zig");
const cfg = @import("../bytecode/cfg.zig");
const terminatesBlock = cfg.terminatesBlock;
const Builder = @import("lower/Builder.zig");

const testing = std.testing;
const test_utils = @import("../test/utils.zig");

const BlockId = ir.BlockId;

pub fn lowerCodeObject(allocator: std.mem.Allocator, co: bytecode.CodeObject) !ir.Procedure {
    var proc: ir.Procedure = .{ .allocator = allocator };
    // nlocals: count of fast local slots (params + body-assigned locals).
    // Use at least 1 so module-level code objects with no locals don't zero-size the defs table.
    const nlocals: u16 = @max(1, @as(u16, @intCast(co.co_nlocals)));
    var b: Builder = .init(&proc, nlocals);
    defer b.deinit();

    var graph = try cfg.buildFromCodeObject(allocator, co);
    defer graph.deinit();

    // Pass 1: allocate all BlockIds so terminators can reference successor blocks
    // by stable ID before those blocks' instructions are lowered
    for (0..graph.blocks.len) |_| _ = try b.newBlock();

    // Pass 2: lower each block's instructions, including its terminator
    for (0..graph.blocks.len) |bid| {
        const block_id: ir.BlockId = .from(@intCast(bid));
        const insns = graph.blockInsns(@intCast(bid));
        const preds = graph.blockPredecessors(@intCast(bid));
        const succs = graph.blockSuccessors(@intCast(bid));
        try lowerBlock(&b, block_id, insns, preds, succs);
    }

    return proc;
}

fn lowerBlock(
    b: *Builder,
    bid: ir.BlockId,
    insns: []const bytecode.Insn,
    predecessors: []const cfg.Edge,
    successors: []const cfg.Edge,
) !void {
    var block = &b.proc.blocks.items[bid.idx()];
    try block.addPredecessors(b.proc, predecessors);
    b.switchTo(bid);
    var has_terminator = false;
    for (insns) |insn| {
        if (terminatesBlock(insn)) {
            try lowerTerminator(b, insn, successors);
            has_terminator = true;
        } else {
            try lowerInsn(b, insn);
        }
    }
    // A block without an explicit terminator falls through to its single successor.
    // Emit an explicit jump so the IR graph is always complete.
    if (!has_terminator and successors.len > 0) {
        const target: ir.BlockId = .from(successors[0].to);
        _ = try b.emit(.{ .op = .jump, .repr = .none, .lhs = @intFromEnum(target), .rhs = 0 });
    }
    try b.sealBlock(bid);
}

/// Emit the terminating instruction for a block.
/// `successors` are the CFG edges out of this block, in the order the CFG built them
/// (fallthrough first, then jump — matching pop_jump_if_false semantics).
fn lowerTerminator(b: *Builder, insn: bytecode.Insn, successors: []const cfg.Edge) !void {
    switch (insn) {
        .pop_jump_if_false, .pop_jump_if_true => {
            // successors[0] = fallthrough (then), successors[1] = jump (else)
            // For pop_jump_if_false: condition is true → fallthrough (then), false → jump (else)
            const cond_val = b.pop();
            const truthy = try b.emit(.{ .op = .py_truthy, .repr = .i1, .lhs = cond_val.idx(), .rhs = 0 });
            const then_bid: ir.BlockId = if (successors.len > 0) .from(successors[0].to) else .none;
            const else_bid: ir.BlockId = if (successors.len > 1) .from(successors[1].to) else .none;
            _ = try b.proc.addBranch(b.current, .{
                .predicate = truthy.idx(),
                .extra = .{ .then = then_bid, .@"else" = else_bid },
            });
        },
        .jump_forward, .jump_backward, .jump_backward_no_interrupt => {
            const target: ir.BlockId = if (successors.len > 0) .from(successors[0].to) else .none;
            _ = try b.emit(.{ .op = .jump, .repr = .none, .lhs = @intFromEnum(target), .rhs = 0 });
        },
        .return_value => {
            const val = b.pop();
            _ = try b.emit(.{ .op = .ret, .repr = .none, .lhs = val.idx(), .rhs = 0 });
        },
        .return_const => {
            _ = try b.emit(.{ .op = .ret, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        else => {
            // Non-branching terminals (return_generator, for_iter, send) — stub
            _ = try b.emit(.{ .op = .ret, .repr = .none, .lhs = 0, .rhs = 0 });
        },
    }
}

fn lowerInsn(b: *Builder, insn: bytecode.Insn) !void {
    switch (insn) {
        .@"resume", .nop => {
            _ = try b.emit(.{ .op = .nop, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        .push_null => {
            const v = try b.emit(.{ .op = .const_obj, .repr = .object, .lhs = 0, .rhs = 0 });
            try b.push(v);
        },
        .load_const => {
            const v = try b.emit(.{ .op = .const_obj, .repr = .object, .lhs = 0, .rhs = 0 });
            try b.push(v);
        },
        .load_name => {
            // Global/builtin lookup — stub until runtime lookup is implemented.
            const v = try b.emit(.{ .op = .const_obj, .repr = .object, .lhs = 0, .rhs = 0 });
            try b.push(v);
        },
        .load_fast => |obj| {
            const local_idx: ir.LocalIdx = @intCast(obj.int);
            const v = try b.readLocal(local_idx);
            try b.push(v);
        },
        .store_name => {
            // Global store — stub until runtime is implemented.
            _ = b.pop();
        },
        .store_fast => |obj| {
            const local_idx: ir.LocalIdx = @intCast(obj.int);
            const v = b.pop();
            try b.writeLocal(local_idx, v);
        },
        .binary_op => {
            const rhs = b.pop();
            const lhs = b.pop();
            const v = try b.emit(.{ .op = .py_binary_op, .repr = .object, .lhs = lhs.idx(), .rhs = rhs.idx() });
            try b.push(v);
        },
        .call => |argc| {
            // pop argc args, then callable, then null (from push_null)
            var i: usize = 0;
            while (i < argc) : (i += 1) _ = b.pop();
            const callable = b.pop();
            _ = b.pop(); // null pushed by push_null below callable
            const v = try b.emit(.{ .op = .py_call, .repr = .object, .lhs = callable.idx(), .rhs = 0 });
            try b.push(v);
        },
        .pop_top => {
            _ = b.pop();
        },
        else => {
            // TODO: delete me, this switch should be exhaustive
            std.debug.print("lowerInsn: unhandled '{s}'\n", .{@tagName(insn)});
            return error.UnhandledInstruction;
        },
    }
}

test "ir/lower: none" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("");
    defer proc.deinit();
    try testing.expectEqualSlices(ir.OpCode, ([_]ir.OpCode{ .nop, .ret })[0..], proc.values.items(.op));
}

test "ir/lower: hello_world" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("print('hello world')");
    defer proc.deinit();
    try testing.expectEqualSlices(
        ir.OpCode,
        ([_]ir.OpCode{
            .nop, // resume
            .const_obj, // push_null
            .const_obj, // load_name(print)
            .const_obj, // load_const('hello world')
            .py_call, // call(1)
            .ret, // return_const
        })[0..],
        proc.values.items(.op),
    );
}

fn assertSuccession(p: *const ir.Procedure, pred: BlockId, succ: BlockId) !void {
    var buf: [8]ir.BlockId = undefined;
    const successors = p.successors(pred, &buf);
    try testing.expect(successors.len > 0);
    for (successors) |successor| if (successor == succ) return;
    return error.TestExpectedSuccessor;
}

fn assertContainsPhi(p: *const ir.Procedure, bid: BlockId) !void {
    var has_phi = false;
    for (p.blocks.items[bid.idx()].values.items) |vid| {
        has_phi = has_phi or p.values.items(.op)[vid.idx()] == .phi;
    }
    try testing.expect(has_phi);
}

test "ir/lower: branching" {
    // def ex(cond):
    //     if cond:   ← entry block: load cond, py_truthy, branch → then(1) / else(2)
    //         x = 10 ← then block: store_fast, jump → exit(3)
    //     else:
    //         x = 20 ← else block: store_fast, jump → exit(3)
    //     return x+1 ← exit block: load x (phi), binary_op, ret
    const code =
        \\ def ex(cond):
        \\     if cond:
        \\         x = 10
        \\     else:
        \\         x = 20
        \\     return x + 1
    ;

    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const root_co = try harness.buildCodeObjects(code);
    const co = root_co.module.codeobject_store.get(1);
    var proc = try lowerCodeObject(arena.allocator(), co);
    defer proc.deinit();

    const entryb: BlockId = .from(0);
    const thenb: BlockId = .from(1);
    const elseb: BlockId = .from(2);
    const exitb: BlockId = .from(3);

    try testing.expectEqual(4, proc.blocks.items.len);

    try assertSuccession(&proc, entryb, thenb);
    try assertSuccession(&proc, entryb, elseb);
    try assertSuccession(&proc, thenb, exitb);
    try assertSuccession(&proc, elseb, exitb);

    try assertContainsPhi(&proc, exitb);
}
