const std = @import("std");
const parse = @import("./parse.zig");
const intern = @import("./ir/intern.zig");
const AstNode = parse.AstNode;
const Parser = parse.Parser;
const testing = std.testing;

const InsnType = enum {
    push_integer,
    push_symbol,
    decl_var,
    assign,
    sum,
    product,
    division,
};

pub const Insn = union(InsnType) {
    push_integer: struct { value: usize },
    push_symbol: struct { value: intern.Index },
    decl_var: void,
    assign: struct { symbol: intern.Index },
    sum: void,
    product: void,
    division: void,
};

pub const IrGen = struct {
    ast: *const AstNode,
    list: std.ArrayList(Insn),
    stack: std.ArrayList(*const AstNode),
    intern_pool: *intern.StringInternPool,

    const Self = @This();

    const Error = error{} || intern.StringInternPool.Error || std.mem.Allocator.Error;

    // storing the arena on the struct leads to a segfault for some reason
    pub fn init(
        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        intern_pool: *intern.StringInternPool,
        ast: *const AstNode,
    ) Self {
        var list = std.ArrayList(Insn).init(allocator);
        var stack = std.ArrayList(*const AstNode).init(arena.allocator());
        return .{
            .ast = ast,
            .intern_pool = intern_pool,
            .list = list,
            .stack = stack,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
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
            .var_decl => |_| {
                try self.stack.append(ast);
            },
            else => unreachable, // TODO: remove
        }
    }

    fn generateInsn(self: *Self, ast_node: *const AstNode) Error!Insn {
        var insn: Insn = blk: {
            switch (ast_node.*) {
                .integer => break :blk Insn{ .push_integer = .{ .value = ast_node.integer.value } },
                .name => break :blk Insn{ .push_symbol = .{ .value = try self.intern_pool.put(ast_node.name.value) } },
                .var_decl => break :blk Insn{ .decl_var = {} },
                .sum => break :blk Insn{ .sum = .{} },
                .product => break :blk Insn{ .product = {} },
                .division => break :blk Insn{ .division = {} },
                .group => break :blk try self.generateInsn(ast_node.group.value),
                .assignment => break :blk Insn{ .assign = .{ .symbol = 0 } },
                else => unreachable, // TODO: remove
            }
        };
        return insn;
    }

    pub fn generate(self: *Self) Error!std.ArrayList(Insn) {
        try self.buildStack(self.ast);
        for (self.stack.items) |ast_node| {
            const insn = try self.generateInsn(ast_node);
            try self.list.append(insn);
        }
        return self.list;
    }
};

const TestContext = struct {
    parser: Parser,
    arena: *std.heap.ArenaAllocator,
    irgen: IrGen,
    ir: std.ArrayList(Insn),
    intern_pool: *intern.StringInternPool,
};

fn testSetup(code: []const u8) !TestContext {
    var parser = Parser.init(testing.allocator, code);
    const ast = try parser.parse();

    // this is a strange thing to do but prevents segfault :/
    var arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var intern_pool = try testing.allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(arena.allocator());
    var irgen = IrGen.init(testing.allocator, arena, intern_pool, ast);
    var ir = try irgen.generate();
    return TestContext{
        .parser = parser,
        .arena = arena,
        .irgen = irgen,
        .ir = ir,
        .intern_pool = intern_pool,
    };
}

fn testTeardown(ctx: *TestContext) void {
    ctx.parser.deinit();
    ctx.irgen.deinit();
    ctx.intern_pool.deinit();
    ctx.arena.deinit();
    ctx.ir.deinit();
    testing.allocator.destroy(ctx.intern_pool);
    testing.allocator.destroy(ctx.arena);
}

test {
    _ = intern;
}

test "push integer" {
    var ctx = try testSetup("1");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_integer = .{ .value = 1 } },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
}

test "push sum" {
    var ctx = try testSetup("1 + 2");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_integer = .{ .value = 1 } },
        Insn{ .push_integer = .{ .value = 2 } },
        Insn{ .sum = .{} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
}

test "assignment" {
    {
        var ctx = try testSetup("a = 1");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .push_symbol = .{ .value = 0 } },
            Insn{ .push_integer = .{ .value = 1 } },
            Insn{ .assign = .{ .symbol = 0 } },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
    }
    {
        var ctx = try testSetup("a = b");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .push_symbol = .{ .value = 0 } },
            Insn{ .push_symbol = .{ .value = 1 } },
            Insn{ .assign = .{ .symbol = 0 } },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
    }
}
