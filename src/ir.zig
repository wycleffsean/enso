const std = @import("std");
const parse = @import("./parse.zig");
const intern = @import("./ir/intern.zig");
const AstNode = parse.AstNode;
const Parser = parse.Parser;
const testing = std.testing;

const InsnType = enum {
    push_integer,
    sum,
};

pub const Insn = union(InsnType) {
    push_integer: struct { value: usize },
    sum: void,
};

pub const IrGen = struct {
    ast: *const AstNode,
    list: std.ArrayList(Insn),
    stack: std.ArrayList(*const AstNode),

    const Self = @This();

    const Error = error{} || std.mem.Allocator.Error;

    // storing the arena on the struct leads to a segfault for some reason
    pub fn init(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, ast: *const AstNode) Self {
        var list = std.ArrayList(Insn).init(allocator);
        var stack = std.ArrayList(*const AstNode).init(arena.allocator());
        return .{
            .ast = ast,
            .list = list,
            .stack = stack,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
    }

    pub fn generate(self: *Self) Error!std.ArrayList(Insn) {
        try self.buildStack(self.ast);
        for (self.stack.items) |ast_node| {
            var insn: Insn = blk: {
                switch (ast_node.*) {
                    .integer => break :blk Insn{ .push_integer = .{ .value = ast_node.integer.value } },
                    .sum => break :blk Insn{ .sum = .{} },
                    else => unreachable,
                }
            };
            try self.list.append(insn);
        }
        return self.list;
    }

    fn buildStack(self: *Self, ast: *const AstNode) Error!void {
        switch (ast.*) {
            .sum, .product, .division, .assignment => |node| {
                // @call(.{ .always_tail }, buildStack, .{self, ast
                try self.buildStack(node.lhs);
                try self.buildStack(node.rhs);
                try self.stack.append(ast);
            },
            .integer => |_| {
                try self.stack.append(ast);
            },
            .group => |group| {
                try self.stack.append(group.value);
            },
            .name => |_| {
                try self.stack.append(ast);
            },
            .variable_declaration => |_| {
                try self.stack.append(ast);
            },
        }
    }

    fn pushInteger(node: *const AstNode) Insn {
        std.debug.assert(node.* != AstNode.integer);
        return Insn{ .push_integer = .{ .value = node.integer.value } };
    }
};

test {
    _ = intern;
}

test "push integer" {
    var parser = Parser.init(testing.allocator, "1");
    defer parser.deinit();
    const ast = try parser.parse();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var irgen = IrGen.init(testing.allocator, &arena, ast);
    defer irgen.deinit();
    var ir = try irgen.generate();
    defer ir.deinit();
    var push = Insn{ .push_integer = .{ .value = 1 } };
    var expected: [1]Insn = .{push};
    try testing.expectEqualSlices(Insn, expected[0..], ir.items);
}

test "push sum" {
    var parser = Parser.init(testing.allocator, "1 + 2");
    defer parser.deinit();
    const ast = try parser.parse();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var irgen = IrGen.init(testing.allocator, &arena, ast);
    defer irgen.deinit();
    var ir = try irgen.generate();
    defer ir.deinit();
    var pusha = Insn{ .push_integer = .{ .value = 1 } };
    var pushb = Insn{ .push_integer = .{ .value = 2 } };
    var sum = Insn{ .sum = .{} };
    var expected: [3]Insn = .{ pusha, pushb, sum };
    try testing.expectEqualSlices(Insn, expected[0..], ir.items);
}
