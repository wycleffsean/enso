const std = @import("std");
const bytecode = @import("../../bytecode.zig");
const object = @import("../../object.zig");
pub const builder = @import("./ssa/builder.zig");
pub const format = @import("./ssa/format.zig");

pub const BlockId = builder.BlockId;
pub const ValueId = builder.ValueId;
pub const VariableId = builder.VariableId;

pub const Error = error{
    StackOverflow,
    StackUnderflow,
    UnsupportedOpcode,
    OutOfMemory,
} || builder.Error || bytecode.Cfg.Error;

const max_stack_slots = 256;

pub const RecordedInst = struct {
    block: BlockId,
    result: ?ValueId,
    op: Op,
};

pub const Binary = struct {
    op: bytecode.BinaryOperation,
    lhs: ValueId,
    rhs: ValueId,
};

pub const Unary = struct {
    op: bytecode.OpCode,
    value: ValueId,
};

pub const Compare = struct {
    op: bytecode.CompareOperation,
    lhs: ValueId,
    rhs: ValueId,
};

pub const Predicate = struct {
    op: bytecode.OpCode,
    invert: bool = false,
    lhs: ValueId,
    rhs: ValueId,
};

pub const StoreName = struct {
    name: object.Object,
    value: ValueId,
};

pub const StoreFast = struct {
    local: object.Object,
    value: ValueId,
};

pub const ReturnValue = struct {
    value: ValueId,
};

pub const Branch = struct {
    condition: ValueId,
    true_block: BlockId,
    false_block: BlockId,
};

pub const Call = struct {
    name: ValueId,
    receiver: ValueId,
    args_start: u32,
    args_len: u32,
};

pub const Values = struct {
    op: bytecode.OpCode,
    args_start: u32 = 0,
    args_len: u32 = 0,
};

pub const Effect = struct {
    op: bytecode.OpCode,
    args_start: u32 = 0,
    args_len: u32 = 0,
};

pub const Op = union(enum) {
    load_const: object.Object,
    load_name: object.Object,
    load_fast: object.Object,
    load_global: object.Object,
    load_build_class: void,
    store_name: StoreName,
    store_fast: StoreFast,
    binary_op: Binary,
    unary_op: Unary,
    compare_op: Compare,
    predicate_op: Predicate,
    value_op: Values,
    effect_op: Effect,
    call: Call,
    pop_top: ValueId,
    branch_if_false: Branch,
    branch_if_true: Branch,
    jump: BlockId,
    return_value: ReturnValue,
    return_const: object.Object,
    nop: void,
};

pub const SsaGraph = struct {
    allocator: std.mem.Allocator,
    cfg: bytecode.Cfg,
    builder: builder.Builder,
    insts: std.MultiArrayList(RecordedInst) = .empty,
    call_args: std.ArrayList(ValueId) = .empty,
    stack_variable_count: u32,
    name_variable_count: u32,

    pub fn deinit(self: *SsaGraph) void {
        self.call_args.deinit(self.allocator);
        self.insts.deinit(self.allocator);
        self.builder.deinit();
        self.cfg.deinit();
        self.* = undefined;
    }
};

pub const ExampleSsa = SsaGraph;
pub const ExampleOp = Op;

pub fn build(allocator: std.mem.Allocator, co: bytecode.CodeObject) Error!SsaGraph {
    var cfg = try bytecode.Cfg.buildFromCodeObject(allocator, co);
    const stack_variable_count = cfg.validateStackHeights() catch |err| {
        cfg.deinit();
        return err;
    };

    const name_variable_count: u32 = @intCast(co.names().len);
    const variable_count = stack_variable_count + name_variable_count + fastVariableCount(co);
    const ssa_builder = builder.Builder.init(allocator, &cfg, variable_count) catch |err| {
        cfg.deinit();
        return err;
    };

    var result = SsaGraph{
        .allocator = allocator,
        .cfg = cfg,
        .builder = ssa_builder,
        .stack_variable_count = stack_variable_count,
        .name_variable_count = name_variable_count,
    };
    errdefer result.deinit();

    var order = try reversePostOrder(allocator, &result.cfg);
    defer order.deinit(allocator);
    try lowerBlocks(&result, co, order.items);
    return result;
}

pub const SsaBuilder = struct {
    pub fn generate(allocator: std.mem.Allocator, co: bytecode.CodeObject) Error!SsaGraph {
        return build(allocator, co);
    }
};

fn reversePostOrder(allocator: std.mem.Allocator, cfg: *const bytecode.Cfg) !std.ArrayList(BlockId) {
    if (cfg.blocks.len == 0) return .empty;
    var order: std.ArrayList(BlockId) = try .initCapacity(allocator, cfg.blocks.len);
    errdefer order.deinit(allocator);

    const seen = try allocator.alloc(bool, cfg.blocks.len);
    defer allocator.free(seen);
    @memset(seen, false);

    appendPostOrder(cfg, &order, seen, 0);
    std.mem.reverse(BlockId, order.items);
    return order;
}

fn appendPostOrder(
    cfg: *const bytecode.Cfg,
    order: *std.ArrayList(BlockId),
    seen: []bool,
    block: BlockId,
) void {
    if (seen[block]) return;
    seen[block] = true;
    for (cfg.blockSuccessors(block)) |edge| {
        appendPostOrder(cfg, order, seen, edge.to);
    }
    order.appendAssumeCapacity(block);
}

fn lowerBlocks(out: *SsaGraph, co: bytecode.CodeObject, order: []const BlockId) Error!void {
    for (order) |block| {
        var stack = BlockStack{
            .depth = out.cfg.blockEntryStackHeight(block) orelse continue,
        };

        for (out.cfg.blockInsns(block)) |insn| {
            try lowerInsn(out, co, block, &stack, insn);
        }

        try out.builder.sealBlock(block);
    }
}

const BlockStack = struct {
    depth: u32,

    fn push(self: *BlockStack, out: *SsaGraph, block: BlockId, value: ValueId) Error!void {
        if (self.depth >= max_stack_slots) return Error.StackOverflow;
        try out.builder.writeVariable(stackVariable(self.depth), block, value);
        self.depth += 1;
    }

    fn pop(self: *BlockStack, out: *SsaGraph, block: BlockId) Error!ValueId {
        if (self.depth == 0) return Error.StackUnderflow;
        self.depth -= 1;
        return out.builder.readVariable(stackVariable(self.depth), block);
    }

    fn peek(self: *BlockStack, out: *SsaGraph, block: BlockId) Error!ValueId {
        if (self.depth == 0) return Error.StackUnderflow;
        return out.builder.readVariable(stackVariable(self.depth - 1), block);
    }

    fn peekFromTop(self: *BlockStack, out: *SsaGraph, block: BlockId, index: u32) Error!ValueId {
        if (index == 0 or index > self.depth) return Error.StackUnderflow;
        return out.builder.readVariable(stackVariable(self.depth - index), block);
    }

    fn writeFromTop(self: *BlockStack, out: *SsaGraph, block: BlockId, index: u32, value: ValueId) Error!void {
        if (index == 0 or index > self.depth) return Error.StackUnderflow;
        try out.builder.writeVariable(stackVariable(self.depth - index), block, value);
    }
};

fn lowerInsn(out: *SsaGraph, co: bytecode.CodeObject, block: BlockId, stack: *BlockStack, insn: bytecode.Insn) Error!void {
    switch (insn) {
        .@"resume", .nop, .setup_annotations => try record(out, block, null, .{ .nop = {} }),
        .push_null => {
            const value = try emitValue(out, block, .{ .load_const = object.None });
            try stack.push(out, block, value);
        },
        .load_const => |consti| {
            const value = try emitValue(out, block, .{ .load_const = co.consts()[consti.index] });
            try stack.push(out, block, value);
        },
        .load_name => |namei| {
            const name = co.names()[namei.index];
            const variable = nameVariable(out, namei);
            const current = try currentVariableValue(out, variable, block);
            const value = if (current == out.builder.undefValue()) blk: {
                const loaded = try emitValue(out, block, .{ .load_name = name });
                try out.builder.writeVariable(variable, block, loaded);
                break :blk loaded;
            } else current;
            try stack.push(out, block, value);
        },
        .load_global => |name| {
            const value = try emitValue(out, block, .{ .load_global = name });
            try stack.push(out, block, value);
        },
        .load_build_class => {
            const value = try emitValue(out, block, .{ .load_build_class = {} });
            try stack.push(out, block, value);
        },
        .load_fast => |local| {
            const variable = try fastVariable(out, local);
            const current = try currentVariableValue(out, variable, block);
            const value = if (current == out.builder.undefValue()) blk: {
                const loaded = try emitValue(out, block, .{ .load_fast = local });
                try out.builder.writeVariable(variable, block, loaded);
                break :blk loaded;
            } else current;
            try stack.push(out, block, value);
        },
        .load_fast_and_clear => |local| {
            const variable = try fastVariable(out, local);
            const value = try currentVariableValue(out, variable, block);
            try stack.push(out, block, value);
            try out.builder.writeVariable(variable, block, out.builder.undefValue());
            try record(out, block, null, .{ .effect_op = .{ .op = .load_fast_and_clear } });
        },
        .store_name => |namei| {
            const value = try stack.pop(out, block);
            try out.builder.writeVariable(nameVariable(out, namei), block, value);
            try record(out, block, null, .{ .store_name = .{ .name = co.names()[namei.index], .value = value } });
        },
        .store_fast => |local| {
            const value = try stack.pop(out, block);
            try out.builder.writeVariable(try fastVariable(out, local), block, value);
            try record(out, block, null, .{ .store_fast = .{ .local = local, .value = value } });
        },
        .copy => {
            const value = try stack.peek(out, block);
            try stack.push(out, block, value);
        },
        .swap => |index| {
            const top = try stack.peekFromTop(out, block, 1);
            const other = try stack.peekFromTop(out, block, @intCast(index));
            try stack.writeFromTop(out, block, 1, other);
            try stack.writeFromTop(out, block, @intCast(index), top);
        },
        .pop_top => {
            const value = try stack.pop(out, block);
            try record(out, block, null, .{ .pop_top = value });
        },
        .end_for => {
            const value = try stack.pop(out, block);
            try record(out, block, null, .{ .effect_op = try effectWithArgs(out, .end_for, &.{value}) });
        },
        .end_send => {
            const value = try stack.peekFromTop(out, block, 2);
            try stack.writeFromTop(out, block, 2, try stack.pop(out, block));
            try record(out, block, null, .{ .effect_op = try effectWithArgs(out, .end_send, &.{value}) });
        },
        .binary_op => |op| {
            const rhs = try stack.pop(out, block);
            const lhs = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .binary_op = .{ .op = op, .lhs = lhs, .rhs = rhs } });
            try stack.push(out, block, value);
        },
        .unary_negative, .unary_not, .unary_invert, .get_iter, .get_yield_from_iter, .get_awaitable, .call_intrinsic_1 => {
            const arg = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .unary_op = .{ .op = std.meta.activeTag(insn), .value = arg } });
            try stack.push(out, block, value);
        },
        .compare_op => |op| {
            const rhs = try stack.pop(out, block);
            const lhs = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .compare_op = .{ .op = op, .lhs = lhs, .rhs = rhs } });
            try stack.push(out, block, value);
        },
        .is_op => |invert| {
            const rhs = try stack.pop(out, block);
            const lhs = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .predicate_op = .{ .op = .is_op, .invert = invert, .lhs = lhs, .rhs = rhs } });
            try stack.push(out, block, value);
        },
        .contains_op => |invert| {
            const rhs = try stack.pop(out, block);
            const lhs = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .predicate_op = .{ .op = .contains_op, .invert = invert, .lhs = lhs, .rhs = rhs } });
            try stack.push(out, block, value);
        },
        .build_tuple => |count| try lowerValueFromStack(out, block, stack, .build_tuple, count),
        .build_list => |count| try lowerValueFromStack(out, block, stack, .build_list, count),
        .build_set => |count| try lowerValueFromStack(out, block, stack, .build_set, count),
        .build_map => |count| try lowerValueFromStack(out, block, stack, .build_map, count * 2),
        .build_const_key_map => |count| try lowerValueFromStack(out, block, stack, .build_const_key_map, count + 1),
        .load_attr => {
            const owner = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .value_op = try valueWithArgs(out, .load_attr, &.{owner}) });
            try stack.push(out, block, value);
        },
        .import_name => {
            const fromlist = try stack.pop(out, block);
            const level = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .value_op = try valueWithArgs(out, .import_name, &.{ level, fromlist }) });
            try stack.push(out, block, value);
        },
        .import_from => {
            const module = try stack.peek(out, block);
            const value = try emitValue(out, block, .{ .value_op = try valueWithArgs(out, .import_from, &.{module}) });
            try stack.push(out, block, value);
        },
        .make_function => {
            const code = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .value_op = try valueWithArgs(out, .make_function, &.{code}) });
            try stack.push(out, block, value);
        },
        .call => |argc| {
            const args_start: u32 = @intCast(out.call_args.items.len);
            var remaining = argc;
            while (remaining > 0) : (remaining -= 1) {
                try out.call_args.append(out.allocator, try stack.pop(out, block));
            }
            std.mem.reverse(ValueId, out.call_args.items[args_start..]);
            const name_value = try stack.pop(out, block);
            const receiver = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .call = .{
                .name = name_value,
                .receiver = receiver,
                .args_start = args_start,
                .args_len = @intCast(argc),
            } });
            try stack.push(out, block, value);
        },
        .store_subscr => try lowerEffectFromStack(out, block, stack, .store_subscr, 3),
        .list_append => try lowerEffectFromStack(out, block, stack, .list_append, 1),
        .set_add => try lowerEffectFromStack(out, block, stack, .set_add, 1),
        .map_add => try lowerEffectFromStack(out, block, stack, .map_add, 2),
        .list_extend => try lowerEffectFromStack(out, block, stack, .list_extend, 1),
        .set_update => try lowerEffectFromStack(out, block, stack, .set_update, 1),
        .dict_update => try lowerEffectFromStack(out, block, stack, .dict_update, 1),
        .cleanup_throw => try record(out, block, null, .{ .effect_op = .{ .op = .cleanup_throw } }),
        .reraise => |extra| try lowerEffectFromStack(out, block, stack, .reraise, 1 + extra),
        .pop_jump_if_false => {
            const condition = try stack.pop(out, block);
            const false_block = branchTargetBlock(out, block) orelse return Error.UnsupportedOpcode;
            const true_block = fallthroughBlock(out, block) orelse false_block;
            try record(out, block, null, .{ .branch_if_false = .{
                .condition = condition,
                .true_block = true_block,
                .false_block = false_block,
            } });
        },
        .pop_jump_if_true => {
            const condition = try stack.pop(out, block);
            const true_block = branchTargetBlock(out, block) orelse return Error.UnsupportedOpcode;
            const false_block = fallthroughBlock(out, block) orelse true_block;
            try record(out, block, null, .{ .branch_if_true = .{
                .condition = condition,
                .true_block = true_block,
                .false_block = false_block,
            } });
        },
        .for_iter => {
            const iterator = try stack.peek(out, block);
            const next = try emitValue(out, block, .{ .value_op = try valueWithArgs(out, .for_iter, &.{iterator}) });
            try stack.push(out, block, next);
            const done_block = branchTargetBlock(out, block) orelse return Error.UnsupportedOpcode;
            const body_block = fallthroughBlock(out, block) orelse done_block;
            try record(out, block, null, .{ .branch_if_false = .{
                .condition = next,
                .true_block = body_block,
                .false_block = done_block,
            } });
        },
        .send => {
            const receiver = try stack.peek(out, block);
            const value = try emitValue(out, block, .{ .value_op = try valueWithArgs(out, .send, &.{receiver}) });
            try stack.push(out, block, value);
            const done_block = branchTargetBlock(out, block) orelse return Error.UnsupportedOpcode;
            const resume_block = fallthroughBlock(out, block) orelse done_block;
            try record(out, block, null, .{ .branch_if_false = .{
                .condition = value,
                .true_block = resume_block,
                .false_block = done_block,
            } });
        },
        .jump_backward, .jump_backward_no_interrupt => {
            const target = jumpTargetBlock(out, block) orelse return Error.UnsupportedOpcode;
            try record(out, block, null, .{ .jump = target });
        },
        .yield_value => {
            const value = try stack.pop(out, block);
            try record(out, block, null, .{ .effect_op = try effectWithArgs(out, .yield_value, &.{value}) });
        },
        .return_value => {
            const value = try stack.pop(out, block);
            try record(out, block, null, .{ .return_value = .{ .value = value } });
        },
        .return_const => try record(out, block, null, .{ .return_const = object.None }),
        .return_generator => try record(out, block, null, .{ .return_const = object.None }),
    }
}

fn emitValue(out: *SsaGraph, block: BlockId, op: Op) Error!ValueId {
    const value = try out.builder.addInsnValue(block);
    try record(out, block, value, op);
    return value;
}

fn lowerValueFromStack(out: *SsaGraph, block: BlockId, stack: *BlockStack, op: bytecode.OpCode, pop_count: usize) Error!void {
    const values = try popValues(out, block, stack, pop_count);
    const value = try emitValue(out, block, .{ .value_op = .{
        .op = op,
        .args_start = values.start,
        .args_len = values.len,
    } });
    try stack.push(out, block, value);
}

fn lowerEffectFromStack(out: *SsaGraph, block: BlockId, stack: *BlockStack, op: bytecode.OpCode, pop_count: usize) Error!void {
    const values = try popValues(out, block, stack, pop_count);
    try record(out, block, null, .{ .effect_op = .{
        .op = op,
        .args_start = values.start,
        .args_len = values.len,
    } });
}

fn valueWithArgs(out: *SsaGraph, op: bytecode.OpCode, values: []const ValueId) Error!Values {
    const span = try appendValues(out, values);
    return .{ .op = op, .args_start = span.start, .args_len = span.len };
}

fn effectWithArgs(out: *SsaGraph, op: bytecode.OpCode, values: []const ValueId) Error!Effect {
    const span = try appendValues(out, values);
    return .{ .op = op, .args_start = span.start, .args_len = span.len };
}

const ValueSpan = struct {
    start: u32,
    len: u32,
};

fn popValues(out: *SsaGraph, block: BlockId, stack: *BlockStack, count: usize) Error!ValueSpan {
    const start: u32 = @intCast(out.call_args.items.len);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        try out.call_args.append(out.allocator, try stack.pop(out, block));
    }
    const items = out.call_args.items[start..];
    std.mem.reverse(ValueId, items);
    return .{ .start = start, .len = @intCast(count) };
}

fn appendValues(out: *SsaGraph, values: []const ValueId) Error!ValueSpan {
    const start: u32 = @intCast(out.call_args.items.len);
    try out.call_args.appendSlice(out.allocator, values);
    return .{ .start = start, .len = @intCast(values.len) };
}

fn record(out: *SsaGraph, block: BlockId, result: ?ValueId, op: Op) Error!void {
    try out.insts.append(out.allocator, .{
        .block = block,
        .result = result,
        .op = op,
    });
}

fn stackVariable(slot: u32) VariableId {
    return slot;
}

fn nameVariable(out: *const SsaGraph, namei: bytecode.NameIndex) VariableId {
    return out.stack_variable_count + namei.index;
}

fn fastVariable(out: *const SsaGraph, local: object.Object) Error!VariableId {
    return out.stack_variable_count + out.name_variable_count + try localIndex(local);
}

fn localIndex(local: object.Object) Error!u32 {
    return switch (local) {
        .int => |index| if (index >= 0) @intCast(index) else Error.UnsupportedOpcode,
        else => Error.UnsupportedOpcode,
    };
}

fn fastVariableCount(co: bytecode.CodeObject) u32 {
    var count: u32 = 0;
    for (co.getInstructions()) |insn| {
        const local: ?object.Object = switch (insn) {
            .load_fast, .store_fast, .load_fast_and_clear => |value| value,
            else => null,
        };
        if (local) |value| {
            const index = localIndex(value) catch continue;
            count = @max(count, index + 1);
        }
    }
    return count;
}

fn currentVariableValue(out: *SsaGraph, variable: VariableId, block: BlockId) Error!ValueId {
    if (try out.builder.currentDefinition(variable, block)) |value| return value;
    if (out.cfg.blockPredecessors(block).len == 0) return out.builder.undefValue();
    return out.builder.readVariable(variable, block);
}

fn jumpTargetBlock(out: *const SsaGraph, block: BlockId) ?BlockId {
    for (out.cfg.blockSuccessors(block)) |edge| {
        if (edge.kind == .jump) return edge.to;
    }
    return null;
}

fn branchTargetBlock(out: *const SsaGraph, block: BlockId) ?BlockId {
    return jumpTargetBlock(out, block) orelse fallthroughBlock(out, block);
}

fn fallthroughBlock(out: *const SsaGraph, block: BlockId) ?BlockId {
    for (out.cfg.blockSuccessors(block)) |edge| {
        if (edge.kind == .fallthrough) return edge.to;
    }
    return null;
}

const testing = std.testing;
const test_utils = @import("../../test/utils.zig");

test "ssa: codeobject lowering uses const and name tables" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    const co = try harness.buildCodeObjects("a = 1\nprint(a + 2)");
    var graph = try build(testing.allocator, co);
    defer graph.deinit();

    try testing.expect(graph.stack_variable_count > 0);
    try testing.expectEqual(@as(usize, 2), co.names().len);
    try testing.expect(graph.insts.len > 0);
}

test "ssa: cfg stack validation exposes block entry heights" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    const co = try harness.buildCodeObjects("1 if True else 2");
    var cfg = try bytecode.Cfg.build(testing.allocator, co.getInstructions());
    defer cfg.deinit();
    _ = try cfg.validateStackHeights();

    try testing.expectEqual(@as(?u32, 0), cfg.blockEntryStackHeight(0));
    for (0..cfg.blocks.len) |block_usize| {
        const block: BlockId = @intCast(block_usize);
        try testing.expect(cfg.blockEntryStackHeight(block) != null);
        try testing.expect(cfg.blockExitStackHeight(block) != null);
    }
}

fn testExample(comptime example: test_utils.Example) !void {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    const co = harness.buildCodeObjects(example.source()) catch |err| {
        std.debug.print("\n----- failing buildCodeObjects: {s} ------\n\n", .{example.path()});
        return err;
    };

    var graph = build(testing.allocator, co) catch |err| {
        std.debug.print("\n----- failing ssa: {s} ------\n\n", .{example.path()});
        return err;
    };
    defer graph.deinit();

    try testing.expect(graph.cfg.blocks.len > 0 or co.getInstructions().len == 0);
}

test "ssa: example fixtures" {
    inline for (test_utils.examples) |example| {
        comptime @setEvalBranchQuota(10000);
        try testExample(example);
    }
}
