const std = @import("std");
const parse = @import("parse.zig");
const intern = @import("bytecode/intern.zig");
pub const OpCode = @import("bytecode/opcodes.zig").OpCode;
const object = @import("object.zig");
const test_utils = @import("test/utils.zig");
const test_examples = test_utils.examples;
const AstNode = parse.AstNode;
const Parser = parse.Parser;
const testing = std.testing;

const comptimePrint = std.fmt.comptimePrint;

// TODO: this is only public because it's a struct with a fieldname
//   just make it an object.ObjectInt instead
pub const RelativeJump = struct { delta: object.ObjectInt };
pub const BinaryOperation = enum {
    add,
    sub,
    mult,
    div,
    floor_div,
    mod,
    pow,
    lshift,
    rshift,
    bit_or,
    bit_xor,
    bit_and,
    mat_mult,
};

pub const CallIntrinsic1Kind = enum {
    unary_positive,
};

pub const Insn = union(OpCode) {
    pop_top: void,
    push_null: void,
    end_for: void,
    end_send: void,
    nop: void,
    unary_negative: void,
    unary_not: void,
    unary_invert: void,
    cleanup_throw: void,
    store_subscr: void,
    get_iter: void,
    get_yield_from_iter: void,
    load_build_class: void,
    return_generator: void,
    return_value: void,
    setup_annotations: void,
    store_name: object.Object,
    for_iter: RelativeJump,
    swap: void,
    load_const: object.Object,
    load_name: object.Object,
    build_tuple: void,
    build_list: void,
    build_set: void,
    build_map: void,
    load_attr: void,
    compare_op: void,
    import_name: void,
    import_from: void,
    pop_jump_if_false: RelativeJump,
    pop_jump_if_true: RelativeJump,
    load_global: object.Object,
    is_op: void,
    contains_op: void,
    reraise: void,
    copy: void,
    return_const: void,
    binary_op: BinaryOperation,
    send: void,
    load_fast: object.Object,
    store_fast: object.Object,
    get_awaitable: void,
    make_function: void,
    jump_backward_no_interrupt: RelativeJump,
    jump_backward: RelativeJump,
    load_fast_and_clear: void,
    list_append: void,
    set_add: void,
    map_add: void,
    yield_value: void,
    @"resume": usize,
    build_const_key_map: void,
    list_extend: void,
    set_update: void,
    dict_update: void,
    call: usize,
    call_intrinsic_1: CallIntrinsic1Kind,

    const Self = @This();

    pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
        var op_buffer: [80]u8 = undefined;
        const op = std.ascii.upperString(&op_buffer, @tagName(self.*));

        try writer.print("{s}", .{op});
        switch (self.*) {
            inline else => |payload| {
                if (@TypeOf(payload) != void) {
                    try writer.print("{any}", .{payload});
                }
            },
        }
    }

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
            .copy => .{ .copy = {} },
            .setup_annotations => .{ .setup_annotations = obj.void },
            .store_name => .{ .store_name = obj },
            // TODO...
            .build_tuple => .{ .build_tuple = {} },
            .build_list => .{ .build_list = {} },
            .build_map => .{ .build_map = {} },
            .list_extend => .{ .list_extend = {} },
            .get_iter => .{ .get_iter = {} },
            .for_iter => .{ .for_iter = .{ .delta = value.int } },
            .pop_top => .{ .pop_top = {} },
            .jump_backward => .{ .jump_backward = .{ .delta = value.int } },
            .unary_not => .{ .unary_not = {} },
            .pop_jump_if_true => .{ .pop_jump_if_true = {} },
            .end_for => .{ .end_for = {} },
            .make_function => .{ .make_function = {} },
            .build_const_key_map => .{ .build_const_key_map = {} },
            .dict_update => .{ .dict_update = {} },
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
    stack: std.array_list.Managed(StackItem),
    intern_pool: *intern.StringInternPool,

    const Self = @This();

    pub const Error = error{} || intern.StringInternPool.Error || std.mem.Allocator.Error;

    // storing the arena on the struct leads to a segfault for some reason
    pub fn init(
        allocator: std.mem.Allocator,
        intern_pool: *intern.StringInternPool,
        ast: *const AstNode,
    ) Self {
        const stack = std.array_list.Managed(StackItem).init(allocator);
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
            .add, .sub, .mult, .div, .floor_div, .mod, .pow, .lshift, .rshift, .bit_or, .bit_xor, .bit_and, .mat_mult, .assignment => {
                // @call(.{ .always_tail }, buildStack, .{self, ast
                // try self.buildStack(node.lhs, block);
                // try self.buildStack(node.rhs, block);
                try self.stack.append(.{ .ast_node = ast });
            },
            .pass => {
                try self.stack.append(.{ .ast_node = ast });
            },
            .bool_op => {
                try self.stack.append(.{ .ast_node = ast });
            },
            .conditional => {
                try self.stack.append(.{ .ast_node = ast });
            },
            .named_expression => {
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
            .call => {
                try self.stack.append(.{ .ast_node = ast }); // i.e. push 'call'
            },
            else => {
                // TODO: this should become an exhaustive switch
                std.debug.print("\n###############\nbuildStack: AstNode.{s} is not handled\n###############\n", .{@tagName(ast.*)});
                unreachable;
            },
        }
    }

    fn generateBinaryOp(self: *Self, kind: BinaryOperation, binary_op: *const parse.BinaryOp, insns: *std.array_list.Managed(Insn)) Error!void {
        try self.generateInsns(binary_op.lhs, insns);
        try self.generateInsns(binary_op.rhs, insns);
        try insns.append(.{ .binary_op = kind });
    }

    fn generateInsns(self: *Self, ast_node: *const AstNode, insns: *std.array_list.Managed(Insn)) Error!void {
        switch (ast_node.*) {
            // .root => break :blk Insn{ .@"resume" = 0 },
            // .integer => break :blk Insn{ .load_const = .{ .value = ast_node.integer.value } },
            .name => |name| {
                switch (name.context) {
                    .Load => try insns.append(.{ .load_name = try object.stringToSymbol(name.value, self.intern_pool) }),
                    .Store => try insns.append(.{ .store_name = try object.stringToSymbol(name.value, self.intern_pool) }),
                }
            },
            .string_literal => |string| try insns.append(.{ .load_const = try object.stringToSymbol(string.value, self.intern_pool) }),
            // .var_decl => break :blk Insn{ .decl_var = .{ .symbol = try self.intern_pool.put(ast_node.var_decl.name) } },
            // .division => break :blk Insn{ .division = {} },
            // .group => break :blk try self.generateInsn(ast_node.group.value),
            // .block_end => {
            // .assignment => break :blk Insn{ .assign = {} },
            // .fn_decl => break :blk Insn{ .decl_fn = .{ .symbol = try self.intern_pool.put(ast_node.fn_decl.name) } },
            .unary_op => |op_node| {
                try self.generateInsns(op_node.value, insns);
                const op: Insn = switch (op_node.kind) {
                    .positive => .{ .call_intrinsic_1 = .unary_positive },
                    .negative => .{ .unary_negative = {} },
                    .logical_not => .{ .unary_not = {} },
                    .bitwise_not => .{ .unary_invert = {} },
                };
                try insns.append(op);
            },
            .bool_op => |op| {
                const jump: Insn = switch (op.kind) {
                    .@"and" => .{ .pop_jump_if_false = .{ .delta = 2 } },
                    .@"or" => .{ .pop_jump_if_true = .{ .delta = 2 } },
                };
                try self.generateInsns(op.lhs, insns);
                try insns.append(.{ .copy = {} });
                try insns.append(jump);
                try insns.append(.{ .pop_top = {} });
                try self.generateInsns(op.rhs, insns);
            },
            .add => |*op| try self.generateBinaryOp(.add, op, insns),
            .sub => |*op| try self.generateBinaryOp(.sub, op, insns),
            .mult => |*op| try self.generateBinaryOp(.mult, op, insns),
            .div => |*op| try self.generateBinaryOp(.div, op, insns),
            .floor_div => |*op| try self.generateBinaryOp(.floor_div, op, insns),
            .mod => |*op| try self.generateBinaryOp(.mod, op, insns),
            .pow => |*op| try self.generateBinaryOp(.pow, op, insns),
            .lshift => |*op| try self.generateBinaryOp(.lshift, op, insns),
            .rshift => |*op| try self.generateBinaryOp(.rshift, op, insns),
            .bit_or => |*op| try self.generateBinaryOp(.bit_or, op, insns),
            .bit_xor => |*op| try self.generateBinaryOp(.bit_xor, op, insns),
            .bit_and => |*op| try self.generateBinaryOp(.bit_and, op, insns),
            .mat_mult => |*op| try self.generateBinaryOp(.mat_mult, op, insns),
            .conditional => |*expr| {
                try self.generateInsns(expr.predicate, insns);
                try insns.append(.{ .pop_jump_if_false = .{ .delta = 2 } });
                try self.generateInsns(expr.lhs, insns);
                try insns.append(.{ .return_value = {} });
                try self.generateInsns(expr.rhs, insns);
                // try insns.append(.{ .return_value = {} }); // implied
            },
            .call => |call| {
                const len = call.args.items.len;
                try insns.append(.{ .push_null = {} }); // TODO: eventually we'll need to push receiver here
                try self.generateInsns(call.ref, insns);
                for (call.args.items) |node| {
                    try self.generateInsns(node, insns);
                }
                try insns.append(.{ .call = len });
                if (call.discard_return_value)
                    try insns.append(.{ .pop_top = {} });
            },
            .integer => |int| try insns.append(.{ .load_const = .{ .int = int.value } }),
            .bool => |b| try insns.append(.{ .load_const = .{ .bool = b } }),
            .float => |float| try insns.append(.{ .load_const = .{ .float = float.value } }),
            .complex => |cmp| try insns.append(.{ .load_const = .{ .complex = .{ .re = cmp.real, .im = cmp.imaginary } } }),
            .list => |list| switch (list) {
                .empty => try insns.append(.{ .load_const = object.EmptyArray }),
                // TODO - make exhaustive
                else => try insns.append(.{ .load_const = object.EmptyArray }),
            },
            .pass => {}, // surprisingly not a nop
            .assignment => |assignment| {
                try self.generateInsns(assignment.rhs, insns);
                // we handle this bit with ExpressionContext which is smelly
                try self.generateInsns(assignment.lhs, insns);
            },
            .named_expression => |named_expression| {
                try self.generateInsns(named_expression.rhs, insns);
                try insns.append(.{ .copy = {} });
                try self.generateInsns(named_expression.lhs, insns);
            },
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
                const suite_mark = insns.items.len;
                for (for_in.suite.items) |expression|
                    try self.generateInsns(expression, insns);
                // try self.generateInsns(for_in.else_suite, insns); // TODO

                // clean up iterator, but only when the block actually did anything
                if ((insns.items.len - suite_mark) > 0) try insns.append(.{ .pop_top = {} });

                // We jump by incrementing/decrementing the program counter.  Cpython records deltas that represent
                // a similar idea but are a length in bytes; we're not going to match
                const jump_index = @as(i64, @intCast(for_iter_mark)) - @as(i64, @intCast(insns.items.len));
                try insns.append(.{ .jump_backward = .{ .delta = jump_index } });
                try insns.append(.{ .end_for = {} });
                insns.items[for_iter_mark].for_iter.delta = @intCast(insns.items.len - for_iter_mark);
            },
            .fn_decl => |fn_decl| {
                _ = fn_decl;
            },
            .lambda => |lambda| {
                // TODO: generate code object for real
                _ = lambda;
                const co = object.Code{};
                try insns.append(.{ .load_const = .{ .code = co } });
                try insns.append(.{ .make_function = {} });
                // try self.generateInsns(expression, insns);
            },
            else => {
                // TODO: this should become an exhaustive switch
                std.debug.print("\n###############\ngenerateInsns: AstNode.{s} is not handled\n###############\n", .{@tagName(ast_node.*)});
                unreachable;
            },
        }
    }

    pub fn generate(self: *Self, allocator: std.mem.Allocator) Error![]Insn {
        var insns = std.array_list.Managed(Insn).init(allocator);
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

test {
    _ = intern;
}

test "bytecode: example fixtures" {
    // var arena = std.heap.ArenaAllocator.init(testing.allocator);
    // var allocator = arena.allocator();
    // defer arena.deinit();

    inline for (test_examples) |example| {
        if (!example.test_bytecode) continue;

        var harness = try test_utils.CompilerHarness.create(testing.allocator);
        defer harness.deinit();
        const ir = try harness.doIRGen(example.source());

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var intern_pool = intern.StringInternPool.init(arena.allocator());
        defer intern_pool.deinit();

        const len = comptime example.code().instructions.len;
        var expected: [len]Insn = undefined;

        inline for (comptime example.code().instructions, 0..) |dis, i| {
            expected[i] = try Insn.init(dis.opcode, dis.argval, &intern_pool);
            // we cheat and rewrite the delta values since we calculate them
            // differently.  Of course this is a hack and will only update the
            // deltas if they appear on the same line which is good enough
            if (i <= ir.len) {
                switch (expected[i]) {
                    .for_iter => {
                        if (ir[i] == .for_iter) expected[i].for_iter.delta = ir[i].for_iter.delta;
                    },
                    .jump_backward => {
                        if (ir[i] == .jump_backward) expected[i].jump_backward.delta = ir[i].jump_backward.delta;
                    },
                    // We also cheat with the code objects - an empty object is a match
                    .load_const => {
                        if (ir[i] == .load_const and ir[i].load_const == .code) expected[i].load_const.code = ir[i].load_const.code;
                    },
                    else => {},
                }
            }
        }

        testing.expectEqualSlices(Insn, expected[0..], ir) catch |err| {
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

test "bytecode: binary ops" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    // The python compiler peephole optimizes away simple expressions
    // like this, so we need to test by hand.  Very dis can be generated by
    // doing something like:
    //   def foo(a, b):
    //     return a or b
    {
        // and == JUMP_IF_FALSE
        const ir = try harness.doIRGen("True and False");

        const expected = [_]Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = object.Object{ .bool = true } },
            .{ .copy = {} },
            .{ .pop_jump_if_false = .{ .delta = 2 } },
            .{ .pop_top = {} },
            .{ .load_const = object.Object{ .bool = false } },
            .{ .return_value = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], ir);
    }
    {
        // or == JUMP_IF_TRUE
        const ir = try harness.doIRGen("True or False");

        const expected = [_]Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = object.Object{ .bool = true } },
            .{ .copy = {} },
            .{ .pop_jump_if_true = .{ .delta = 2 } },
            .{ .pop_top = {} },
            .{ .load_const = object.Object{ .bool = false } },
            .{ .return_value = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], ir);
    }
    {
        // chain
        const ir = try harness.doIRGen("True and False or True");

        const expected = [_]Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = object.Object{ .bool = true } },
            .{ .copy = {} },
            .{ .pop_jump_if_false = .{ .delta = 2 } },
            .{ .pop_top = {} },
            .{ .load_const = object.Object{ .bool = false } },
            .{ .copy = {} },
            .{ .pop_jump_if_true = .{ .delta = 2 } },
            .{ .pop_top = {} },
            .{ .load_const = object.Object{ .bool = true } },
            .{ .return_value = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], ir);
    }
}

test "bytecode: conditional expression" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    // The python compiler peephole optimizes away simple expressions
    // like this, so we need to test by hand.  Very dis can be generated by
    // doing something like:
    //   def foo(a):
    //     return 1 if a else 2
    {
        const ir = try harness.doIRGen("1 if True else 2");

        const expected = [_]Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = object.Object{ .bool = true } },
            .{ .pop_jump_if_false = .{ .delta = 2 } },
            .{ .load_const = object.Object{ .int = 1 } },
            .{ .return_value = {} },
            .{ .load_const = object.Object{ .int = 2 } },
            .{ .return_value = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], ir);
    }
}
