const std = @import("std");
const bytecode = @import("bytecode.zig");
const object = @import("object.zig");
pub const builder = @import("ssa/builder.zig");
pub const format = @import("ssa/format.zig");

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

pub const StoreName = struct {
    name: object.Object,
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

pub const Op = union(enum) {
    load_const: object.Object,
    load_name: object.Object,
    store_name: StoreName,
    binary_op: Binary,
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
    errdefer cfg.deinit();
    const stack_variable_count = try cfg.validateStackHeights();

    const variable_count = stack_variable_count + @as(u32, @intCast(co.names().len));
    var ssa_builder = try builder.Builder.init(allocator, &cfg, variable_count);
    errdefer ssa_builder.deinit();

    var result = SsaGraph{
        .allocator = allocator,
        .cfg = cfg,
        .builder = ssa_builder,
        .stack_variable_count = stack_variable_count,
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
};

fn lowerInsn(out: *SsaGraph, co: bytecode.CodeObject, block: BlockId, stack: *BlockStack, insn: bytecode.Insn) Error!void {
    switch (insn) {
        .@"resume", .nop => try record(out, block, null, .{ .nop = {} }),
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
            const current = try out.builder.readVariable(variable, block);
            const value = if (current == out.builder.undefValue()) blk: {
                const loaded = try emitValue(out, block, .{ .load_name = name });
                try out.builder.writeVariable(variable, block, loaded);
                break :blk loaded;
            } else current;
            try stack.push(out, block, value);
        },
        .store_name => |namei| {
            const value = try stack.pop(out, block);
            try out.builder.writeVariable(nameVariable(out, namei), block, value);
            try record(out, block, null, .{ .store_name = .{ .name = co.names()[namei.index], .value = value } });
        },
        .copy => {
            const value = try stack.peek(out, block);
            try stack.push(out, block, value);
        },
        .pop_top => {
            const value = try stack.pop(out, block);
            try record(out, block, null, .{ .pop_top = value });
        },
        .binary_op => |op| {
            const rhs = try stack.pop(out, block);
            const lhs = try stack.pop(out, block);
            const value = try emitValue(out, block, .{ .binary_op = .{ .op = op, .lhs = lhs, .rhs = rhs } });
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
        .jump_backward, .jump_backward_no_interrupt => {
            const target = jumpTargetBlock(out, block) orelse return Error.UnsupportedOpcode;
            try record(out, block, null, .{ .jump = target });
        },
        .return_value => {
            const value = try stack.pop(out, block);
            try record(out, block, null, .{ .return_value = .{ .value = value } });
        },
        .return_const => try record(out, block, null, .{ .return_const = object.None }),
        else => return Error.UnsupportedOpcode,
    }
}

fn emitValue(out: *SsaGraph, block: BlockId, op: Op) Error!ValueId {
    const value = try out.builder.addInsnValue(block);
    try record(out, block, value, op);
    return value;
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
const test_utils = @import("test/utils.zig");

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
