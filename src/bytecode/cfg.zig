const std = @import("std");
const bytecode = @import("../bytecode.zig");
const testing = std.testing;

pub const Error = error{
    BadJumpTarget,
} || std.mem.Allocator.Error;

/// basically a tightly packed slice
/// TODO: delete and just bytecode.Span
fn Span(comptime IndexType: type, comptime ItemType: type) type {
    return struct {
        start: IndexType,
        len: IndexType,

        fn slice(self: @This(), source: []const ItemType) []const ItemType {
            return source[self.start..][0..self.len];
        }

        const empty = @This(){ .len = 0, .start = 0 };
    };
}

pub const EdgeKind = enum {
    fallthrough,
    jump,
    @"return",
};

pub const Edge = struct {
    /// TODO: we currently record this but don't do anything with it. Might be best to drop it
    kind: EdgeKind,
    from: BlockIndex,
    to: BlockIndex,
};

pub const InsnIndex = u32;
pub const BlockIndex = u32;
pub const LinkIndex = u32;
pub const InsnSpan = Span(InsnIndex, bytecode.Insn);
pub const LinkSpan = Span(LinkIndex, Edge);

pub const BasicBlock = struct {
    instructions: InsnSpan,
    predecessors: LinkSpan,
    successors: LinkSpan,

    const empty: BasicBlock = .{
        .instructions = .empty,
        .predecessors = .empty,
        .successors = .empty,
    };
};

const Self = @This();

allocator: std.mem.Allocator,
instructions: []const bytecode.Insn,
blocks: std.MultiArrayList(BasicBlock) = .empty,
edges: std.ArrayList(Edge) = .empty,
links: std.ArrayList(Edge) = .empty,

pub fn init(allocator: std.mem.Allocator, instructions: []const bytecode.Insn) Self {
    return .{
        .allocator = allocator,
        .instructions = instructions,
    };
}

pub fn deinit(self: *Self) void {
    self.blocks.deinit(self.allocator);
    self.edges.deinit(self.allocator);
    self.links.deinit(self.allocator);
    self.* = undefined;
}

pub fn blockInsns(self: *const Self, block: BlockIndex) []const bytecode.Insn {
    return self.blocks.items(.instructions)[block].slice(self.instructions);
}

pub fn blockPredecessors(self: *const Self, block: BlockIndex) []const Edge {
    return self.blocks.items(.predecessors)[block].slice(self.links.items);
}

pub fn blockSuccessors(self: *const Self, block: BlockIndex) []const Edge {
    return self.blocks.items(.successors)[block].slice(self.links.items);
}

/// determines if we are at a terminal
/// if so builds edges
/// the edges are the instruction index
fn maybeTerminate(self: *Self, terminal_index: u32, insn: bytecode.Insn) Error!bool {
    switch (insn) {
        // TODO: can we figure out jump ops thru metaprogramming?
        .for_iter,
        .pop_jump_if_false,
        .pop_jump_if_true,
        => |jump| {
            const jump_index = try checkedJumpTarget(terminal_index + 1, jump.delta, self.instructions.len);
            const fallthrough = terminal_index + 1;

            try self.edges.ensureUnusedCapacity(self.allocator, 2);
            if (fallthrough < self.instructions.len) {
                self.edges.appendAssumeCapacity(.{ .kind = .fallthrough, .from = terminal_index, .to = fallthrough });
            }
            if (jump_index != fallthrough) {
                self.edges.appendAssumeCapacity(.{ .kind = .jump, .from = terminal_index, .to = jump_index });
            }
        },
        .jump_backward,
        .jump_backward_no_interrupt,
        => |jump| {
            const jump_index = try checkedJumpTarget(terminal_index, jump.delta, self.instructions.len);
            try self.edges.append(self.allocator, .{ .kind = .jump, .from = terminal_index, .to = jump_index });
        },
        .return_value,
        .return_const,
        .return_generator,
        => {
            return true;
        },
        else => {
            return false;
        },
    }
    return true;
}

pub fn build(allocator: std.mem.Allocator, instructions: []const bytecode.Insn) Error!Self {
    var self = init(allocator, instructions);
    errdefer self.deinit();

    if (instructions.len == 0) return self;

    var insn_to_block: std.ArrayList(BlockIndex) = try .initCapacity(allocator, instructions.len);
    defer insn_to_block.deinit(allocator);
    var current_block: BasicBlock = .empty;

    for (instructions, 0..) |insn, index_usize| {
        const index: InsnIndex = @intCast(index_usize);
        insn_to_block.appendAssumeCapacity(@intCast(self.blocks.len));

        if (try self.maybeTerminate(index, insn)) {
            current_block.instructions.len = index + 1 - current_block.instructions.start;
            try self.blocks.append(allocator, current_block);
            current_block = .empty;
            current_block.instructions.start = index + 1;
        }
    }

    // TODO: add the final block, but I'm not even certain this is necessary
    if (current_block.instructions.start < instructions.len) {
        current_block.instructions.len = @as(InsnIndex, @intCast(instructions.len)) - current_block.instructions.start;
        try self.blocks.append(allocator, current_block);
    }

    // all of the edges we created are indexed to the instruction
    // but we need them pointing at the block containing the instruction
    for (self.edges.items) |*edge| {
        edge.to = insn_to_block.items[edge.to];
        edge.from = insn_to_block.items[edge.from];
    }

    try self.links.ensureTotalCapacity(self.allocator, self.edges.items.len * 2);

    // we loop O(blocks*(2*edges)) - not optimal but probably fine :/
    for (0..self.blocks.len) |block_index_usize| {
        const block_index: BlockIndex = @intCast(block_index_usize);

        self.blocks.items(.successors)[block_index].start = @intCast(self.links.items.len);
        for (self.edges.items) |succ_edge| {
            if (succ_edge.from != block_index) continue;
            self.links.appendAssumeCapacity(succ_edge);
        }
        self.blocks.items(.successors)[block_index].len =
            @intCast(self.links.items.len - self.blocks.items(.successors)[block_index].start);

        self.blocks.items(.predecessors)[block_index].start = @intCast(self.links.items.len);
        for (self.edges.items) |pred_edge| {
            if (pred_edge.to != block_index) continue;
            self.links.appendAssumeCapacity(pred_edge);
        }
        self.blocks.items(.predecessors)[block_index].len =
            @intCast(self.links.items.len - self.blocks.items(.predecessors)[block_index].start);
    }

    return self;
}

fn checkedJumpTarget(base: u32, delta: i64, instructions_len: usize) Error!InsnIndex {
    const jump_index: i64 = @as(i64, @intCast(base)) + delta;
    if (jump_index < 0 or jump_index >= instructions_len) return Error.BadJumpTarget;
    return @intCast(jump_index);
}

fn expectEdges(expected: []const Edge, actual: []const Edge) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.from, got.from);
        try testing.expectEqual(want.to, got.to);
    }
}

test "bytecode/cfg empty" {
    var cfg = try build(testing.allocator, &.{});
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 0), cfg.blocks.len);
    try testing.expectEqual(@as(usize, 0), cfg.edges.items.len);
}

test "bytecode/cfg straight line bytecode has one block" {
    const instructions = [_]bytecode.Insn{
        .{ .@"resume" = 0 },
        .{ .load_const = .{ .int = 1 } },
        .{ .return_value = {} },
    };

    var cfg = try build(testing.allocator, &instructions);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.blocks.len);
    try testing.expectEqual(@as(usize, 0), cfg.edges.items.len);
    try testing.expectEqual(@as(usize, 3), cfg.blockInsns(0).len);
}

test "bytecode/cfg conditional branch records fallthrough and target edges" {
    const instructions = [_]bytecode.Insn{
        .{ .@"resume" = 0 },
        .{ .pop_jump_if_false = .{ .delta = 1 } },
        .{ .return_value = {} },
        .{ .return_const = {} },
    };

    var cfg = try build(testing.allocator, &instructions);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 3), cfg.blocks.len);
    try expectEdges(&.{
        .{ .kind = .fallthrough, .from = 0, .to = 1 },
        .{ .kind = .jump, .from = 0, .to = 2 },
    }, cfg.blockSuccessors(0));
    try expectEdges(&.{.{ .kind = .fallthrough, .from = 0, .to = 1 }}, cfg.blockPredecessors(1));
    try expectEdges(&.{.{ .kind = .jump, .from = 0, .to = 2 }}, cfg.blockPredecessors(2));
}

test "bytecode/cfg unconditional jump does not fall through" {
    const instructions = [_]bytecode.Insn{
        .{ .@"resume" = 0 },
        .{ .jump_backward = .{ .delta = -1 } },
        .{ .return_const = {} },
    };

    var cfg = try build(testing.allocator, &instructions);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 2), cfg.blocks.len);
    try expectEdges(&.{.{ .kind = .jump, .from = 0, .to = 0 }}, cfg.blockSuccessors(0));
    try expectEdges(&.{.{ .kind = .jump, .from = 0, .to = 0 }}, cfg.blockPredecessors(0));
    try testing.expectEqual(@as(usize, 0), cfg.blockPredecessors(1).len);
}

test "bytecode/cfg fallthrough and jump to same block is a single edge" {
    const instructions = [_]bytecode.Insn{
        .{ .@"resume" = 0 },
        .{ .pop_jump_if_false = .{ .delta = 0 } },
        .{ .return_const = {} },
    };

    var cfg = try build(testing.allocator, &instructions);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 2), cfg.blocks.len);
    try expectEdges(&.{.{ .kind = .fallthrough, .from = 0, .to = 1 }}, cfg.blockSuccessors(0));
    try expectEdges(&.{.{ .kind = .fallthrough, .from = 0, .to = 1 }}, cfg.blockPredecessors(1));
}

test "bytecode/cfg bad jump target" {
    const instructions = [_]bytecode.Insn{
        .{ .@"resume" = 0 },
        .{ .pop_jump_if_false = .{ .delta = 99 } },
        .{ .return_const = {} },
    };

    try testing.expectError(Error.BadJumpTarget, build(testing.allocator, &instructions));
}
