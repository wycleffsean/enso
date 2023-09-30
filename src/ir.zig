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
    yield, // ie return
    noop, // ie ast root node
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
    yield: void,
    noop: void,
};

const Block = struct {
    parent: ?*const Block,
};

const StackItem = union(enum) {
    ast_node: *const AstNode,
    block: Block,
    block_end: Block,
};

pub const IrGen = struct {
    ast: *const AstNode,
    stack: std.ArrayList(StackItem),
    intern_pool: *intern.StringInternPool,

    const Self = @This();

    const Error = error{} || intern.StringInternPool.Error || std.mem.Allocator.Error;

    // storing the arena on the struct leads to a segfault for some reason
    pub fn init(
        arena: *std.heap.ArenaAllocator,
        intern_pool: *intern.StringInternPool,
        ast: *const AstNode,
    ) Self {
        var stack = std.ArrayList(StackItem).init(arena.allocator());
        return .{
            .ast = ast,
            .intern_pool = intern_pool,
            .stack = stack,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
    }

    fn buildStack(self: *Self, ast: *const AstNode, block: *const Block) Error!void {
        switch (ast.*) {
            .root => |ast_list| {
                for (ast_list) |node| {
                    try self.buildStack(node, block);
                }
            },
            .sum, .product, .division, .assignment => |node| {
                // @call(.{ .always_tail }, buildStack, .{self, ast
                try self.buildStack(node.lhs, block);
                try self.buildStack(node.rhs, block);
                try self.stack.append(.{ .ast_node = ast });
            },
            .integer => |_| {
                try self.stack.append(.{ .ast_node = ast });
            },
            .group => |group| {
                try self.buildStack(group.value, block);
            },
            .name => |_| {
                try self.stack.append(.{ .ast_node = ast });
            },
            .var_decl => |_| {
                try self.stack.append(.{ .ast_node = ast });
            },
            .fn_decl => |fn_decl| {
                try self.stack.append(.{ .block = Block{ .parent = block } });
                // this is sketchy, but we need the stable pointer to the block
                const fn_block = &self.stack.items[self.stack.items.len - 1].block;
                try self.stack.append(.{ .ast_node = ast });
                for (fn_decl.statement.items) |expr| {
                    try self.buildStack(expr, fn_block);
                }
                try self.stack.append(.{ .block_end = Block{ .parent = block } });
            },
            .call => |call| {
                try self.stack.append(.{ .ast_node = call.ref });
                try self.stack.append(.{ .ast_node = ast });
            },
        }
    }

    fn generateInsn(self: *Self, ast_node: *const AstNode) Error!Insn {
        var insn: Insn = blk: {
            switch (ast_node.*) {
                .root => break :blk Insn{ .noop = {} },
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

    pub fn generate(self: *Self, allocator: std.mem.Allocator) Error![]Insn {
        var insns = std.ArrayList(Insn).init(allocator);
        const root_block = Block{ .parent = null };
        var current_block: *const Block = &root_block;
        try self.buildStack(self.ast, current_block);
        for (self.stack.items) |item| {
            switch (item) {
                .ast_node => |ast_node| {
                    const insn = try self.generateInsn(ast_node);
                    try insns.append(insn);
                },
                .block => |*block| {
                    current_block = block;
                },
                .block_end => {
                    try insns.append(Insn{ .yield = {} });
                },
            }
        }
        try insns.append(Insn{ .yield = {} });
        return insns.toOwnedSlice();
    }
};

const TestContext = struct {
    arena: *std.heap.ArenaAllocator,
    irgen: IrGen,
    ir: []const Insn,
    intern_pool: *intern.StringInternPool,
};

fn testSetup(code: []const u8) !TestContext {
    // this is a strange thing to do but prevents segfault :/
    var arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var parser = Parser.init(arena.allocator(), code);
    const ast = try parser.parse();

    var intern_pool = try testing.allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(arena.allocator());
    var irgen = IrGen.init(arena, intern_pool, ast);
    var ir = try irgen.generate(testing.allocator);
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
    testing.allocator.free(ctx.ir);
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
        Insn{ .yield = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
}

test "ir sum" {
    var ctx = try testSetup("1 + 2");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_integer = .{ .value = 1 } },
        Insn{ .push_integer = .{ .value = 2 } },
        Insn{ .sum = {} },
        Insn{ .yield = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
}

test "ir product" {
    var ctx = try testSetup("1 * 2");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_integer = .{ .value = 1 } },
        Insn{ .push_integer = .{ .value = 2 } },
        Insn{ .product = {} },
        Insn{ .yield = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
}

test "ir division" {
    var ctx = try testSetup("1 / 2");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_integer = .{ .value = 1 } },
        Insn{ .push_integer = .{ .value = 2 } },
        Insn{ .division = {} },
        Insn{ .yield = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
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
            Insn{ .yield = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
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
            Insn{ .yield = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
    }
}

test "declare variable" {
    var ctx = try testSetup("var a");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .decl_var = .{ .symbol = 0 } },
        Insn{ .yield = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
}

test "assignment" {
    {
        var ctx = try testSetup("a = 1");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .push_symbol = .{ .value = 0 } },
            Insn{ .push_integer = .{ .value = 1 } },
            Insn{ .assign = {} },
            Insn{ .yield = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
    }
    { // declare and assign
        var ctx = try testSetup("var a = 1");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .decl_var = .{ .symbol = 0 } }, // does decl_var also push the symbol onto the stack?
            Insn{ .push_integer = .{ .value = 1 } },
            Insn{ .assign = {} },
            Insn{ .yield = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
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
            Insn{ .yield = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
    }
    {
        var ctx = try testSetup("var a = 1+2*3");
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .decl_var = .{ .symbol = 0 } }, // does decl_var also push the symbol onto the stack?
            Insn{ .push_integer = .{ .value = 1 } },
            Insn{ .push_integer = .{ .value = 2 } },
            Insn{ .push_integer = .{ .value = 3 } },
            Insn{ .product = {} },
            Insn{ .sum = {} },
            Insn{ .assign = {} },
            Insn{ .yield = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
    }
}
test "declare function" {
    if (true) return error.SkipZigTest;
    {
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
            Insn{ .yield = {} },
            Insn{ .yield = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
    }
    {
        // declare function in parent scope
        const fn_decl =
            \\var a = 9
            \\
            \\fn myFunction():
            \\	var b = 1
            \\	a * b
        ;
        var ctx = try testSetup(fn_decl);
        defer testTeardown(&ctx);

        var expected = [_]Insn{
            Insn{ .decl_var = .{ .symbol = 0 } },
            Insn{ .push_integer = .{ .value = 9 } },
            Insn{ .assign = {} },
            //
            Insn{ .decl_fn = .{ .symbol = 1 } },
            Insn{ .decl_var = .{ .symbol = 2 } },
            Insn{ .push_integer = .{ .value = 1 } },
            Insn{ .assign = {} },
            Insn{ .push_symbol = .{ .value = 0 } },
            Insn{ .push_symbol = .{ .value = 2 } },
            Insn{ .product = {} },
            Insn{ .yield = {} },
            //
            Insn{ .yield = {} },
        };
        try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
    }
}

test "call function" {
    var ctx = try testSetup("myFunction()");
    defer testTeardown(&ctx);

    var expected = [_]Insn{
        Insn{ .push_symbol = .{ .value = 0 } },
        Insn{ .call = {} },
        Insn{ .yield = {} },
    };
    try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
}
