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
    var b: Builder = .init(&proc, @intCast(co.co_stacksize));
    defer b.deinit();

    var graph = try cfg.buildFromCodeObject(allocator, co);
    defer graph.deinit();

    for (0..graph.blocks.len) |bid| {
        const insns = graph.blockInsns(@intCast(bid));
        const preds = graph.blockPredecessors(@intCast(bid));
        try lowerBlock(&b, insns, preds);
    }

    return proc;
}

fn lowerBlock(b: *Builder, insns: []const bytecode.Insn, predecessors: []const cfg.Edge) !void {
    _ = predecessors;
    const entry = try b.newBlock();
    try b.sealBlock(entry);
    b.switchTo(entry);
    for (insns) |insn| if (!terminatesBlock(insn)) try lowerInsn(b, insn);
}

fn lowerInsn(b: *Builder, insn: bytecode.Insn) !void {
    switch (insn) {
        .@"resume", .nop => {
            _ = try b.emit(.{ .op = .nop, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        .return_const => |val| {
            _ = val;
            _ = try b.emit(.{ .op = .ret, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        .return_value => {},
        .push_null => {
            _ = try b.emit(.{ .op = .const_obj, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        .load_const => {
            _ = try b.emit(.{ .op = .const_obj, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        .store_name => {},
        .load_name => {
            _ = try b.emit(.{ .op = .const_obj, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        .binary_op => {},
        .call => {
            _ = try b.emit(.{ .op = .py_call, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        .pop_top => {},
        .pop_jump_if_false => {},
        else => {
            // TODO: delete me, this switch should be exhaustive
            std.debug.print("lowerInsn: unhandled '{s}'\n", .{@tagName(insn)});
            return error.UnhandledInstruction;
        },
    }
}

// test "ir/lower: none" {
//     var harness = try test_utils.CompilerHarness.create(testing.allocator);
//     defer harness.deinit();

//     const proc = try harness.lower("");
//     try testing.expectEqualSlices(ir.OpCode, ([2]ir.OpCode{ .nop, .ret })[0..], proc.values.items(.op));
// }

// test "ir/lower: hello_world" {
//     var harness = try test_utils.CompilerHarness.create(testing.allocator);
//     defer harness.deinit();

//     const proc = try harness.lower("print('hello world')");
//     try testing.expectEqualSlices(
//         ir.OpCode,
//         ([_]ir.OpCode{
//             .nop,
//             .const_obj,
//             .const_obj,
//             .const_obj,
//             .py_call,
//             .ret,
//         })[0..],
//         proc.values.items(.op),
//     );
// }

fn assertSuccession(p: *const ir.Procedure, pred: BlockId, succ: BlockId) !void {
    var buf: [8]ir.BlockId = undefined;
    const successors = p.successors(pred, &buf);
    var result = false;
    for (successors) |successor| result |= successor == succ;
    try testing.expect(result);
}

test "ir/lower: branching" {
    // 1           0 RESUME                   0

    // 2           2 LOAD_FAST                0 (cond)
    //             4 POP_JUMP_IF_FALSE        7 (to 20)

    // 3           6 LOAD_CONST               1 (10)
    //             8 STORE_FAST               1 (x)

    // 6          10 LOAD_FAST                1 (x)
    //            12 LOAD_CONST               3 (1)
    //            14 BINARY_OP                0 (+)
    //            18 RETURN_VALUE

    // 5     >>   20 LOAD_CONST               2 (20)
    //            22 STORE_FAST               1 (x)

    // 6          24 LOAD_FAST                1 (x)
    //            26 LOAD_CONST               3 (1)
    //            28 BINARY_OP                0 (+)
    //            32 RETURN_VALUE
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

    // TODO: this is lame, it hides memory leaks for now
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const root_co = try harness.buildCodeObjects(code);
    const co = root_co.module.codeobject_store.get(1);
    var proc = try lowerCodeObject(arena.allocator(), co);
    defer proc.deinit();

    // const entryb: BlockId = .from(0);
    // const thenb: BlockId = .from(1);
    // const elseb: BlockId = .from(2);
    // const exitb: BlockId = .from(3);

    // try testing.expectEqual(4, proc.blocks.items.len);

    // try assertSuccession(&proc, entryb, thenb);
    // try assertSuccession(&proc, entryb, elseb);
    // try assertSuccession(&proc, thenb, exitb);
    // try assertSuccession(&proc, elseb, exitb);

    // try testing.expectEqualSlices(
    //     ir.OpCode,
    //     ([_]ir.OpCode{
    //         .nop,
    //         .arg,
    //         .py_truthy,
    //         .branch,
    //         // .const_int,
    //         // .jump,
    //         // .const_int,
    //         // .const_int,
    //         // .py_binary_op,
    //         .ret,
    //     })[0..],
    //     proc.values.items(.op),
    // );
}
