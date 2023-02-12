const std = @import("std");
const parse = @import("parse.zig");
const intern = @import("ir/intern.zig");
const AstNode = parse.AstNode;
const Parser = parse.Parser;
const testing = std.testing;

const InsnType = enum {
    push_integer,
    push_symbol,
    decl_var,
    decl_fn,
    assign,
    sum,
    product,
    division,
    call,
};

pub const Insn = union(InsnType) {
    push_integer: struct { value: usize },
    push_symbol: struct { value: intern.Index },
    decl_var: struct { symbol: intern.Index },
    decl_fn: struct { symbol: intern.Index },
    assign: void,
    sum: void,
    product: void,
    division: void,
    call: void,
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
                try self.buildStack(group.value);
            },
            .name => |_| {
                try self.stack.append(ast);
            },
            .var_decl => |_| {
                try self.stack.append(ast);
            },
            .fn_decl => |fn_decl| {
                try self.stack.append(ast);
                for (fn_decl.statement.items) |expr| {
                    try self.buildStack(expr);
                }
            },
            .call => |call| {
                try self.stack.append(call.ref);
                try self.stack.append(ast);
            },
        }
    }

    fn generateInsn(self: *Self, ast_node: *const AstNode) Error!Insn {
        var insn: Insn = blk: {
            switch (ast_node.*) {
                .integer => break :blk Insn{ .push_integer = .{ .value = ast_node.integer.value } },
                .name => break :blk Insn{ .push_symbol = .{ .value = try self.intern_pool.put(ast_node.name.value) } },
                .var_decl => break :blk Insn{ .decl_var = .{ .symbol = try self.intern_pool.put(ast_node.var_decl.name) } },
                .sum => break :blk Insn{ .sum = {} },
                .product => break :blk Insn{ .product = {} },
                .division => break :blk Insn{ .division = {} },
                .group => break :blk try self.generateInsn(ast_node.group.value),
                .assignment => break :blk Insn{ .assign = {} },
                .fn_decl => break :blk Insn{ .decl_fn = .{ .symbol = try self.intern_pool.put(ast_node.fn_decl.name) } },
                .call => break :blk Insn{ .call = {} },
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
    arena: *std.heap.ArenaAllocator,
    irgen: IrGen,
    ir: std.ArrayList(Insn),
    intern_pool: *intern.StringInternPool,
};

fn testSetup(code: []const u8) !TestContext {
    // this is a strange thing to do but prevents segfault :/
    var arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var parser = Parser.init(arena.allocator(), code);
    const ast = try parser.parseStatement();

    var intern_pool = try testing.allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(arena.allocator());
    var irgen = IrGen.init(testing.allocator, arena, intern_pool, ast);
    var ir = try irgen.generate();
    return TestContext{
        .arena = arena,
        .irgen = irgen,
        .ir = ir,
        .intern_pool = intern_pool,
    };
}

fn testTeardown(ctx: *TestContext) void {
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

test "ir sum" {
    var ctx = try testSetup("1 + 2");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_integer = .{ .value = 1 } },
        Insn{ .push_integer = .{ .value = 2 } },
        Insn{ .sum = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
}

test "ir product" {
    var ctx = try testSetup("1 * 2");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_integer = .{ .value = 1 } },
        Insn{ .push_integer = .{ .value = 2 } },
        Insn{ .product = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
}

test "ir division" {
    var ctx = try testSetup("1 / 2");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_integer = .{ .value = 1 } },
        Insn{ .push_integer = .{ .value = 2 } },
        Insn{ .division = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
}

test "ir group" {
    {
        var ctx = try testSetup("(1 + 2) * 3");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .push_integer = .{ .value = 1 } },
            Insn{ .push_integer = .{ .value = 2 } },
            Insn{ .sum = {} },
            Insn{ .push_integer = .{ .value = 3 } },
            Insn{ .product = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
    }
    { // ungrouped
        var ctx = try testSetup("1 + 2 * 3");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .push_integer = .{ .value = 1 } },
            Insn{ .push_integer = .{ .value = 2 } },
            Insn{ .push_integer = .{ .value = 3 } },
            Insn{ .product = {} },
            Insn{ .sum = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
    }
}

test "declare variable" {
    var ctx = try testSetup("var a");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .decl_var = .{ .symbol = 0 } },
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
            Insn{ .assign = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
    }
    { // declare and assign
        var ctx = try testSetup("var a = 1");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .decl_var = .{ .symbol = 0 } }, // does decl_var also push the symbol onto the stack?
            Insn{ .push_integer = .{ .value = 1 } },
            Insn{ .assign = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
    }
    {
        var ctx = try testSetup("a = b+c*9");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .push_symbol = .{ .value = 0 } },
            Insn{ .push_symbol = .{ .value = 1 } },
            Insn{ .push_symbol = .{ .value = 2 } },
            Insn{ .push_integer = .{ .value = 9 } },
            Insn{ .product = {} },
            Insn{ .sum = {} },
            Insn{ .assign = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
    }
}
test "declare function" {
    const fn_decl =
        \\fn myFunction():
        \\	var a = 1
        \\	a * 3
    ;
    var ctx = try testSetup(fn_decl);
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .decl_fn = .{ .symbol = 0 } },
        Insn{ .decl_var = .{ .symbol = 1 } },
        Insn{ .push_integer = .{ .value = 1 } },
        Insn{ .assign = {} },
        Insn{ .push_symbol = .{ .value = 1 } },
        Insn{ .push_integer = .{ .value = 3 } },
        Insn{ .product = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
}

test "call function" {
    var ctx = try testSetup("myFunction()");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_symbol = .{ .value = 0 } },
        Insn{ .call = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir.items);
}
