const std = @import("std");
const bytecode = @import("../bytecode.zig");
const testing = std.testing;

pub const Error = error{
    BadJumpTarget,
    StackHeightMismatch,
} || bytecode.StackEffectError || std.mem.Allocator.Error;

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
    entry_stack_height: ?u32 = null,
    exit_stack_height: ?u32 = null,

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

// TODO: we calculate successors in the SSA so this should just be dropped
//   We're only using the successors for testing
pub fn blockSuccessors(self: *const Self, block: BlockIndex) []const Edge {
    return self.blocks.items(.successors)[block].slice(self.links.items);
}

pub fn blockEntryStackHeight(self: *const Self, block: BlockIndex) ?u32 {
    return self.blocks.items(.entry_stack_height)[block];
}

pub fn blockExitStackHeight(self: *const Self, block: BlockIndex) ?u32 {
    return self.blocks.items(.exit_stack_height)[block];
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
            if (jump_index < self.instructions.len and jump_index != fallthrough) {
                self.edges.appendAssumeCapacity(.{ .kind = .jump, .from = terminal_index, .to = jump_index });
            }
        },
        .jump_backward,
        .jump_backward_no_interrupt,
        .jump_forward,
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

    const leaders = try allocator.alloc(bool, instructions.len);
    defer allocator.free(leaders);
    @memset(leaders, false);
    leaders[0] = true;

    for (instructions, 0..) |insn, index_usize| {
        const index: InsnIndex = @intCast(index_usize);
        const edges_start = self.edges.items.len;
        if (try self.maybeTerminate(index, insn) and index + 1 < instructions.len) {
            leaders[index + 1] = true;
        }
        for (self.edges.items[edges_start..]) |edge| {
            leaders[edge.to] = true;
        }
    }

    const insn_to_block = try allocator.alloc(BlockIndex, instructions.len);
    defer allocator.free(insn_to_block);

    var block_start: InsnIndex = 0;
    var next_block: BlockIndex = 0;
    for (instructions[1..], 1..) |_, index_usize| {
        const index: InsnIndex = @intCast(index_usize);
        if (!leaders[index]) continue;

        try self.blocks.append(allocator, .{
            .instructions = .{
                .start = block_start,
                .len = index - block_start,
            },
            .predecessors = .empty,
            .successors = .empty,
        });
        for (insn_to_block[block_start..index]) |*mapped| mapped.* = next_block;
        next_block += 1;
        block_start = index;
    }
    try self.blocks.append(allocator, .{
        .instructions = .{
            .start = block_start,
            .len = @as(InsnIndex, @intCast(instructions.len)) - block_start,
        },
        .predecessors = .empty,
        .successors = .empty,
    });
    for (insn_to_block[block_start..instructions.len]) |*mapped| mapped.* = next_block;

    for (0..self.blocks.len - 1) |block_usize| {
        const block: BlockIndex = @intCast(block_usize);
        const insns = self.blockInsns(block);
        if (insns.len == 0 or terminatesBlock(insns[insns.len - 1])) continue;
        const from = self.blocks.items(.instructions)[block].start + self.blocks.items(.instructions)[block].len - 1;
        const to = self.blocks.items(.instructions)[block + 1].start;
        try self.edges.append(self.allocator, .{ .kind = .fallthrough, .from = from, .to = to });
    }

    // all of the edges we created are indexed to the instruction
    // but we need them pointing at the block containing the instruction
    for (self.edges.items) |*edge| {
        edge.to = insn_to_block[edge.to];
        edge.from = insn_to_block[edge.from];
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

pub fn buildFromCodeObject(allocator: std.mem.Allocator, co: bytecode.CodeObject) Error!Self {
    return build(allocator, co.getInstructions());
}

pub fn validateStackHeights(self: *Self) Error!u32 {
    const entries = self.blocks.items(.entry_stack_height);
    const exits = self.blocks.items(.exit_stack_height);
    var max_stack_height: u32 = 0;

    @memset(entries, null);
    @memset(exits, null);
    if (self.blocks.len == 0) return max_stack_height;

    entries[0] = 0;
    var changed = true;
    while (changed) {
        changed = false;
        for (0..self.blocks.len) |block_usize| {
            const block: BlockIndex = @intCast(block_usize);
            const entry = entries[block] orelse continue;
            const stack = try bytecode.stackLengthFrom(self.blockInsns(block), entry);
            exits[block] = stack.exit;
            max_stack_height = @max(max_stack_height, stack.max);

            for (self.blockSuccessors(block)) |edge| {
                const edge_exit = try edgeStackHeight(self.blockInsns(block), stack.exit, edge);
                if (entries[edge.to]) |known| {
                    if (known != edge_exit) return Error.StackHeightMismatch;
                } else {
                    entries[edge.to] = edge_exit;
                    changed = true;
                }
            }
        }
    }
    return @max(max_stack_height, 1);
}

fn terminatesBlock(insn: bytecode.Insn) bool {
    return switch (insn) {
        .for_iter,
        .pop_jump_if_false,
        .pop_jump_if_true,
        .jump_backward,
        .jump_backward_no_interrupt,
        .jump_forward,
        .return_value,
        .return_const,
        .return_generator,
        .send,
        => true,
        else => false,
    };
}

fn edgeStackHeight(insns: []const bytecode.Insn, default_exit: u32, edge: Edge) Error!u32 {
    if (insns.len == 0 or edge.kind != .jump) return default_exit;
    return switch (insns[insns.len - 1]) {
        .for_iter => if (default_exit >= 2) default_exit - 2 else Error.StackHeightMismatch,
        else => default_exit,
    };
}

fn checkedJumpTarget(base: u32, delta: i64, instructions_len: usize) Error!InsnIndex {
    const jump_index: i64 = @as(i64, @intCast(base)) + delta;
    if (jump_index < 0 or jump_index > instructions_len) return Error.BadJumpTarget;
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
        .{ .load_const = .{ .index = 0 } },
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

test "bytecode/cfg if/else statement" {
    const instructions = [_]bytecode.Insn{
        .{ .@"resume" = 0 },
        .{ .load_name = .{ .index = 0 } },
        .{ .pop_jump_if_false = .{ .delta = 3 } },
        .{ .load_const = .{ .index = 0 } },
        .{ .store_name = .{ .index = 1 } },
        .{ .jump_forward = .{ .delta = 2 } },
        .{ .load_const = .{ .index = 1 } },
        .{ .store_name = .{ .index = 1 } },
        .{ .load_name = .{ .index = 1 } },
        .{ .load_const = .{ .index = 2 } },
        .{ .binary_op = .add },
        .{ .return_value = {} },
    };

    var cfg = try build(testing.allocator, &instructions);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 4), cfg.blocks.len);
    try expectEdges(&.{
        .{ .kind = .fallthrough, .from = 0, .to = 1 },
    }, cfg.blockPredecessors(1));
    try expectEdges(&.{
        .{ .kind = .jump, .from = 0, .to = 2 },
    }, cfg.blockPredecessors(2));
    try expectEdges(&.{
        .{ .kind = .jump, .from = 1, .to = 3 },
        .{ .kind = .fallthrough, .from = 2, .to = 3 },
    }, cfg.blockPredecessors(3));
}

test "bytecode/cfg bad jump target" {
    const instructions = [_]bytecode.Insn{
        .{ .@"resume" = 0 },
        .{ .pop_jump_if_false = .{ .delta = 99 } },
        .{ .return_const = {} },
    };

    try testing.expectError(Error.BadJumpTarget, build(testing.allocator, &instructions));
}
