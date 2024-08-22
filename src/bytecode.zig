const std = @import("std");
const parse = @import("parse.zig");
const intern = @import("bytecode/intern.zig");
const OpCode = @import("bytecode/opcodes.zig").OpCode;
const test_utils = @import("test/utils.zig");
const test_examples = test_utils.examples;
const AstNode = parse.AstNode;
const Parser = parse.Parser;
const testing = std.testing;

pub const Insn = union(OpCode) {
    push_null: void,
    return_value: void,
    load_const: intern.Index,
    load_name: intern.Index,
    return_const: void,
    @"resume": usize,
    call: usize,

    const Self = @This();

    // convenience function for tests
    fn init(comptime kind: OpCode, comptime value: test_utils.PyArgVal, intern_pool: *intern.StringInternPool) !Self {
        return switch (kind) {
            .@"resume" => .{ .@"resume" = value.integer },
            .push_null => .{ .push_null = value.void },
            .load_name => .{ .load_name = try intern_pool.put(value.string) },
            .load_const => .{ .load_const = try intern_pool.put(value.string) },
            .return_const => .{ .return_value = value.void },
            .return_value => .{ .return_value = value.void },
            .call => .{ .call = value.integer },
        };
    }
};

const Block = struct {
    parent: ?*const Block,
};

const StackItem = union(enum) {
    ast_node: *const AstNode,
    block: Block,
    block_end: Block,
    null: void,
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
        const stack = std.ArrayList(StackItem).init(arena.allocator());
        return .{
            .ast = ast,
            .intern_pool = intern_pool,
            .stack = stack,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
    }

    // This function iterates over the AST, flattens it out, and leaves markers for block/scope
    fn buildStack(self: *Self, ast: *const AstNode, block: *const Block) Error!void {
        switch (ast.*) {
            .root => |ast_list| {
                try self.stack.append(.{ .block = Block{ .parent = block } });
                for (ast_list) |node| {
                    try self.buildStack(node, block);
                }
                try self.stack.append(.{ .block_end = Block{ .parent = block } });
            },
            .sum, .product, .division, .assignment => |node| {
                // @call(.{ .always_tail }, buildStack, .{self, ast
                try self.buildStack(node.lhs, block);
                try self.buildStack(node.rhs, block);
                try self.stack.append(.{ .ast_node = ast });
            },
            .group => |group| {
                try self.buildStack(group.value, block);
            },
            .integer, .name, .var_decl, .string_literal => {
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
                try self.stack.append(.{ .null = {} }); // TODO: eventually we'll need to push receiver here
                try self.stack.append(.{ .ast_node = call.ref });
                for (call.args.items) |node| {
                    try self.buildStack(node, block);
                }
                try self.stack.append(.{ .ast_node = ast }); // i.e. push 'call'
            },
            else => {
                // TODO: this should become an exhaustive switch
                std.debug.print("\n###############\nbuildStack: AstNode.{s} is not handled\n###############\n", .{@tagName(ast.*)});
                unreachable;
            },
        }
    }

    fn generateInsn(self: *Self, ast_node: *const AstNode) Error!Insn {
        const insn: Insn = blk: {
            switch (ast_node.*) {
                // .root => break :blk Insn{ .@"resume" = 0 },
                // .integer => break :blk Insn{ .load_const = .{ .value = ast_node.integer.value } },
                .name => |name| break :blk Insn{ .load_name = try self.intern_pool.put(name.value) },
                .string_literal => |string| break :blk Insn{ .load_const = try self.intern_pool.put(string.value) },
                // .var_decl => break :blk Insn{ .decl_var = .{ .symbol = try self.intern_pool.put(ast_node.var_decl.name) } },
                // .sum => break :blk Insn{ .sum = {} },
                // .product => break :blk Insn{ .product = {} },
                // .division => break :blk Insn{ .division = {} },
                // .group => break :blk try self.generateInsn(ast_node.group.value),
                // .block_end => {
                // .assignment => break :blk Insn{ .assign = {} },
                // .fn_decl => break :blk Insn{ .decl_fn = .{ .symbol = try self.intern_pool.put(ast_node.fn_decl.name) } },
                .call => |call| {
                    const len = call.args.items.len;
                    break :blk Insn{ .call = len };
                },
                else => {
                    // TODO: this should become an exhaustive switch
                    std.debug.print("\n###############\ngenerateInsn: AstNode.{s} is not handled\n###############\n", .{@tagName(ast_node.*)});
                    unreachable;
                },
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
                    try insns.append(Insn{ .@"resume" = 0 });
                },
                .block_end => {
                    try insns.append(Insn{ .return_value = {} });
                },
                .null => {
                    try insns.append(Insn{ .push_null = {} });
                },
            }
        }
        // try insns.append(Insn{ .yield = {} });
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

    const intern_pool = try testing.allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(arena.allocator());
    var irgen = IrGen.init(arena, intern_pool, ast);
    const ir = try irgen.generate(testing.allocator);
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

// test "ir: push integer" {
//     var ctx = try testSetup("1");
//     defer testTeardown(&ctx);

//     var expected = [_]Insn{
//         Insn{ .push_integer = .{ .value = 1 } },
//         Insn{ .yield = {} },
//     };
//     try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
// }

// test "ir: sum" {
//     var ctx = try testSetup("1 + 2");
//     defer testTeardown(&ctx);

//     var expected = [_]Insn{
//         Insn{ .push_integer = .{ .value = 1 } },
//         Insn{ .push_integer = .{ .value = 2 } },
//         Insn{ .sum = {} },
//         Insn{ .yield = {} },
//     };
//     try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
// }

// test "ir: product" {
//     var ctx = try testSetup("1 * 2");
//     defer testTeardown(&ctx);

//     var expected = [_]Insn{
//         Insn{ .push_integer = .{ .value = 1 } },
//         Insn{ .push_integer = .{ .value = 2 } },
//         Insn{ .product = {} },
//         Insn{ .yield = {} },
//     };
//     try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
// }

// test "ir: division" {
//     var ctx = try testSetup("1 / 2");
//     defer testTeardown(&ctx);

//     var expected = [_]Insn{
//         Insn{ .push_integer = .{ .value = 1 } },
//         Insn{ .push_integer = .{ .value = 2 } },
//         Insn{ .division = {} },
//         Insn{ .yield = {} },
//     };
//     try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
// }

// test "ir: group" {
//     {
//         var ctx = try testSetup("(1 + 2) * 3");
//         defer testTeardown(&ctx);

//         var expected = [_]Insn{
//             Insn{ .push_integer = .{ .value = 1 } },
//             Insn{ .push_integer = .{ .value = 2 } },
//             Insn{ .sum = {} },
//             Insn{ .push_integer = .{ .value = 3 } },
//             Insn{ .product = {} },
//             Insn{ .yield = {} },
//         };
//         try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
//     }
//     { // ungrouped
//         var ctx = try testSetup("1 + 2 * 3");
//         defer testTeardown(&ctx);

//         var expected = [_]Insn{
//             Insn{ .push_integer = .{ .value = 1 } },
//             Insn{ .push_integer = .{ .value = 2 } },
//             Insn{ .push_integer = .{ .value = 3 } },
//             Insn{ .product = {} },
//             Insn{ .sum = {} },
//             Insn{ .yield = {} },
//         };
//         try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
//     }
// }

// test "ir: assignment" {
//     {
//         var ctx = try testSetup("a = 1");
//         defer testTeardown(&ctx);

//         var expected = [_]Insn{
//             Insn{ .push_symbol = .{ .value = 0 } },
//             Insn{ .push_integer = .{ .value = 1 } },
//             Insn{ .assign = {} },
//             Insn{ .yield = {} },
//         };
//         try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
//     }
//     {
//         var ctx = try testSetup("a = b+c*9");
//         defer testTeardown(&ctx);

//         var expected = [_]Insn{
//             Insn{ .push_symbol = .{ .value = 0 } },
//             Insn{ .push_symbol = .{ .value = 1 } },
//             Insn{ .push_symbol = .{ .value = 2 } },
//             Insn{ .push_integer = .{ .value = 9 } },
//             Insn{ .product = {} },
//             Insn{ .sum = {} },
//             Insn{ .assign = {} },
//             Insn{ .yield = {} },
//         };
//         try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
//     }
// }
// test "ir: declare function" {
//     if (true) return error.SkipZigTest;
//     {
//         const fn_decl =
//             \\fn myFunction():
//             \\	a = 1
//             \\	a * 3
//         ;
//         var ctx = try testSetup(fn_decl);
//         defer testTeardown(&ctx);

//         var expected = [_]Insn{
//             Insn{ .decl_fn = .{ .symbol = 0 } },
//             Insn{ .push_symbol = .{ .symbol = 1 } },
//             Insn{ .push_integer = .{ .value = 1 } },
//             Insn{ .assign = {} },
//             Insn{ .push_symbol = .{ .value = 1 } },
//             Insn{ .push_integer = .{ .value = 3 } },
//             Insn{ .product = {} },
//             Insn{ .yield = {} },
//             Insn{ .yield = {} },
//         };
//         try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
//     }
//     {
//         // declare function in parent scope
//         const fn_decl =
//             \\a = 9
//             \\
//             \\fn myFunction():
//             \\	b = 1
//             \\	a * b
//         ;
//         var ctx = try testSetup(fn_decl);
//         defer testTeardown(&ctx);

//         var expected = [_]Insn{
//             Insn{ .push_symbol = .{ .symbol = 0 } },
//             Insn{ .push_integer = .{ .value = 9 } },
//             Insn{ .assign = {} },
//             //
//             Insn{ .decl_fn = .{ .symbol = 1 } },
//             Insn{ .push_symbol = .{ .symbol = 2 } },
//             Insn{ .push_integer = .{ .value = 1 } },
//             Insn{ .assign = {} },
//             Insn{ .push_symbol = .{ .value = 0 } },
//             Insn{ .push_symbol = .{ .value = 2 } },
//             Insn{ .product = {} },
//             Insn{ .yield = {} },
//             //
//             Insn{ .yield = {} },
//         };
//         try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
//     }
// }

// test "ir: call function" {
//     var ctx = try testSetup("myFunction()");
//     defer testTeardown(&ctx);

//     var expected = [_]Insn{
//         Insn{ .push_symbol = .{ .value = 0 } },
//         Insn{ .call = {} },
//         Insn{ .yield = {} },
//     };
//     try testing.expectEqualSlices(Insn, expected[0..], ctx.ir);
// }

test "bytecode: example fixtures" {
    // var arena = std.heap.ArenaAllocator.init(testing.allocator);
    // var allocator = arena.allocator();
    // defer arena.deinit();

    inline for (test_examples) |example| {
        if (!example.test_bytecode) continue;
        var ctx = try testSetup(example.source());
        defer testTeardown(&ctx);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var intern_pool = intern.StringInternPool.init(arena.allocator());
        defer intern_pool.deinit();

        const len = comptime example.instructions().len;
        var expected: [len]Insn = undefined;

        inline for (comptime example.instructions(), 0..) |dis, i| {
            expected[i] = try Insn.init(dis.opcode, dis.argval, &intern_pool);
        }

        testing.expectEqualSlices(Insn, expected[0..], ctx.ir) catch |err| {
            std.debug.print("\n----- failing: {s} ------\n\n", .{example.path()});
            return err;
        };
        // if (!example.test_parse) continue;
        // var parser = Parser.init(allocator, example.source());
        // _ = parser.parse() catch |err| {
        //     highlightSource(example.path(), example.source(), parser.peek());
        //     return err;
        // };
    }
}
