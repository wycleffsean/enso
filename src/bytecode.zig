const std = @import("std");
const parse = @import("parse.zig");
const intern = @import("bytecode/intern.zig");
const OpCode = @import("bytecode/opcodes.zig").OpCode;
const object = @import("object.zig");
const test_utils = @import("test/utils.zig");
const test_examples = test_utils.examples;
const AstNode = parse.AstNode;
const Parser = parse.Parser;
const testing = std.testing;

const comptimePrint = std.fmt.comptimePrint;

const RelativeJump = struct { delta: object.ObjectInt };

pub const Insn = union(OpCode) {
    pop_top: void,
    push_null: void,
    end_for: void,
    nop: void,
    store_subscr: void,
    get_iter: void,
    load_build_class: void,
    return_value: void,
    setup_annotations: void,
    store_name: object.Object,
    for_iter: RelativeJump,
    swap: void,
    load_const: object.Object,
    load_name: object.Object,
    build_list: void,
    load_attr: void,
    compare_op: void,
    import_name: void,
    import_from: void,
    pop_jump_if_false: void,
    return_const: void,
    make_function: void,
    jump_backward: RelativeJump,
    @"resume": usize,
    list_extend: void,
    call: usize,
    call_intrinsic_1: void,

    const Self = @This();

    // convenience function for tests
    fn init(comptime kind: OpCode, comptime value: object.Object, intern_pool: *intern.StringInternPool) !Self {
        // we always intern strings in the bytecode
        const obj = if (value == .string) try value.string.symbolize(intern_pool) else value;
        return switch (kind) {
            .nop => .{ .nop = {} },
            .@"resume" => .{ .@"resume" = obj.int },
            .push_null => .{ .push_null = {} },
            .load_name => .{ .load_name = obj },
            .load_const => .{ .load_const = obj },
            .return_const => .{ .return_value = {} },
            .return_value => .{ .return_value = {} },
            .call => .{ .call = obj.int },
            .setup_annotations => .{ .setup_annotations = obj.void },
            .store_name => .{ .store_name = obj },
            // TODO...
            .build_list => .{ .build_list = {} },
            .list_extend => .{ .list_extend = {} },
            .get_iter => .{ .get_iter = {} },
            .for_iter => .{ .for_iter = .{ .delta = value.int } },
            .pop_top => .{ .pop_top = {} },
            .jump_backward => .{ .jump_backward = .{ .delta = value.int } },
            .end_for => .{ .end_for = {} },
            else => {
                comptime {
                    @compileError(comptimePrint("uh-oh - we don't handle this opcode yet! - {s} ({})", .{ @tagName(kind), @intFromEnum(kind) }));
                }
            },
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
        allocator: std.mem.Allocator,
        intern_pool: *intern.StringInternPool,
        ast: *const AstNode,
    ) Self {
        const stack = std.ArrayList(StackItem).init(allocator);
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
            .integer, .float, .complex, .name, .var_decl, .string_literal, .for_in => {
                try self.stack.append(.{ .ast_node = ast });
            },
            .fn_decl => |fn_decl| {
                try self.stack.append(.{ .block = Block{ .parent = block } });
                // this is sketchy, but we need the stable pointer to the block
                const fn_block = &self.stack.items[self.stack.items.len - 1].block;
                try self.stack.append(.{ .ast_node = ast });
                for (fn_decl.suite.items) |expr| {
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

    fn generateInsns(self: *Self, ast_node: *const AstNode, insns: *std.ArrayList(Insn)) Error!void {
        switch (ast_node.*) {
            // .root => break :blk Insn{ .@"resume" = 0 },
            // .integer => break :blk Insn{ .load_const = .{ .value = ast_node.integer.value } },
            .name => |name| try insns.append(.{ .load_name = try object.stringToSymbol(name.value, self.intern_pool) }),
            .string_literal => |string| try insns.append(.{ .load_const = try object.stringToSymbol(string.value, self.intern_pool) }),
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
                try insns.append(.{ .call = len });
            },
            .integer => |int| try insns.append(.{ .load_const = .{ .int = int.value } }),
            .float => |float| try insns.append(.{ .load_const = .{ .float = float.value } }),
            .complex => |cmp| try insns.append(.{ .load_const = .{ .complex = .{ .re = cmp.real, .im = cmp.imaginary } } }),
            .array_literal => try insns.append(.{ .load_const = object.EmptyArray }),
            .pass => {}, // surprisingly not a nop
            .for_in => |for_in| {
                // push the iterable onto the stack
                try self.generateInsns(for_in.iterable, insns);
                // pop iterable, push iterator
                try insns.append(.{ .get_iter = {} });
                try insns.append(.{ .for_iter = .{ .delta = 0 } });
                const for_iter_mark = insns.items.len - 1;
                // TODO: for non-trivial cases we'll need call back into this switch statement
                //   but have a signal for load vs store
                for (for_in.target_list.items) |target| {
                    std.debug.assert(target.* == .name);
                    try insns.append(.{ .store_name = try object.stringToSymbol(target.name.value, self.intern_pool) });
                }
                for (for_in.suite.items) |expression|
                    try self.generateInsns(expression, insns);
                // try self.generateInsns(for_in.else_suite, insns); // TODO

                // We jump by incrementing/decrementing the program counter.  Cpython records deltas that represent
                // a similar idea but are a length in bytes; we're not going to match
                const jump_index = @as(i64, @intCast(for_iter_mark)) - @as(i64, @intCast(insns.items.len));
                try insns.append(.{ .jump_backward = .{ .delta = jump_index } });
                try insns.append(.{ .end_for = {} });
                insns.items[for_iter_mark].for_iter.delta = @intCast(insns.items.len - for_iter_mark);
            },
            else => {
                // TODO: this should become an exhaustive switch
                std.debug.print("\n###############\ngenerateInsn: AstNode.{s} is not handled\n###############\n", .{@tagName(ast_node.*)});
                unreachable;
            },
        }
    }

    pub fn generate(self: *Self, allocator: std.mem.Allocator) Error![]Insn {
        var insns = std.ArrayList(Insn).init(allocator);
        const root_block = Block{ .parent = null };
        var current_block: *const Block = &root_block;
        try self.buildStack(self.ast, current_block);
        for (self.stack.items) |item| {
            switch (item) {
                .ast_node => |ast_node| {
                    try self.generateInsns(ast_node, &insns);
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
    const allocator = arena.allocator();

    var parser = Parser.init(allocator, code);
    const ast = try parser.parse();

    const intern_pool = try testing.allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(allocator);
    var irgen = IrGen.init(allocator, intern_pool, ast);
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
            // we cheat and rewrite the delta values since we calculate them
            // differently
            switch (expected[i]) {
                .for_iter => expected[i].for_iter.delta = ctx.ir[i].for_iter.delta,
                .jump_backward => expected[i].jump_backward.delta = ctx.ir[i].jump_backward.delta,
                else => {},
            }
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
