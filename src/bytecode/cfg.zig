const std = @import("std");
const bytecode = @import("../bytecode.zig");
const testing = std.testing;
const test_utils = @import("../test/utils.zig");

const Error = error{
    BadJumpTarget,
} | std.mem.Allocator.Error;

/// basically a tightly packed slice
fn Span(IndexType: type, ItemType: type) type {
    return struct {
        start: IndexType,
        len: IndexType,

        fn slice(self: *@This(), source: []ItemType) []ItemType {
            return source[self.start..][0..self.len];
        }

        const empty = @This(){ .len = 0, .start = 0 };
    };
}

const EdgeKind = enum {
    fallthrough,
    jump,
    @"return",
};

const Edge = struct {
    /// TODO: we currently record this but don't do anything with it. Might be best to drop it
    kind: EdgeKind,
    from: BlockIndex,
    to: BlockIndex,
};

const InsnIndex = u32;
const BlockIndex = u32;
const InsnSpan = Span(InsnIndex, bytecode.Insn);
const BlockSpan = Span(BlockIndex, Edge);

const BasicBlock = struct {
    instructions: Span(InsnIndex),
    predecessors: Span(BlockIndex),
    successors: Span(BlockIndex),

    const empty: BasicBlock = .{
        .instructions = .empty,
        .predecessors = .empty,
        .successors = .empty,
    };
};

const Self = @This();

allocator: std.mem.Allocator,
instructions: []bytecode.Insn,
blocks: std.MultiArrayList(BasicBlock) = .empty,
edges: std.ArrayList(Edge) = .empty,
links: std.ArrayList(BlockIndex) = .empty,

fn init(allocator: std.mem.Allocator, instructions: []bytecode.Insn) Self {
    return .{
        .allocator = allocator,
        .instructions = instructions,
    };
}

fn deinit(self: *Self) void {
    self.blocks.deinit(self.allocator);
    self.edges.deinit(self.allocator);
    self.links.deinit(self.allocator);
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
            const jump_index: i64 = @as(i64, @intCast(terminal_index + 1)) + jump.delta;
            if (jump_index < 0 or jump_index >= self.instructions.len) return Error.BadJumpTarget;
            // fallthru
            try self.edges.ensureUnusedCapacity(self.allocator, 2);
            self.edges.appendAssumeCapacity(.{ .kind = .fallthrough, .from = terminal_index, .to = terminal_index + 1 });
            self.edges.appendAssumeCapacity(.{ .kind = .jump, .from = terminal_index, .to = jump_index });
        },
        // .jump_backward,
        // .jump_backward_no_interrupt,
        // => |jump| {
        //     // no fallthru
        // },
        // .return_value,
        // .return_const,
        // .return_generator,
        // => |jump| {
        //     // no fallthru
        //     // we can skip return edges
        //     return true;
        // },
        else => {
            return false;
        },
    }
    return true;
}

pub fn build(allocator: std.mem.Allocator, instructions: []bytecode.Insn) Error!Self {
    var self = init(allocator, instructions);
    errdefer self.deinit();
    defer self.edges.deinit(self.allocator);

    if (instructions.len == 0) return self;

    var insn_to_block: std.ArrayList(BlockIndex) = try .initCapacity(allocator, instructions.len);
    defer insn_to_block.deinit(allocator);
    var current_block: BasicBlock = .empty;

    for (instructions, 0..) |insn, index| {
        insn_to_block.appendAssumeCapacity(self.blocks.items.len);

        if (try maybeTerminate(index, insn)) {
            // we build our basic blocks here
            current_block.instructions.len = index - current_block.instructions.start;
            try self.blocks.append(allocator, current_block);
            current_block.instructions.start = index + 1;
        }
    }

    // all of the edges we created are indexed to the instruction
    // but we need them pointing at the block containing the instruction
    for (self.edges.items) |*edge| {
        edge.to = insn_to_block[edge.to];
        edge.from = insn_to_block[edge.from];
    }

    try self.links.ensureTotalCapacity(self.allocator, self.edges.len * 2);

    // we loop O(blocks*(2*edges)) - not optimal but probably fine :/
    for (self.blocks.slice(), 0..) |*block, block_index| {
        block.succ.from = self.links.len;
        for (self.edges.items) |succ_edge| {
            if (succ_edge.to != block_index) continue;
            self.links.appendAssumeCapacity(succ_edge);
        }
        block.succ.to = self.links.len;

        block.pred.from = self.links.len;
        for (self.edges.items) |pred_edge| {
            if (pred_edge.from != block_index) continue;
            self.links.appendAssumeCapacity(pred_edge);
        }
        block.pred.to = self.links.len;
    }

    return self;
}

test "bytecode/cfg" {
    const harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
}
