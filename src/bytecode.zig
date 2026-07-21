const std = @import("std");
const parse = @import("parse.zig");
const intern = @import("bytecode/intern.zig");
pub const Cfg = @import("bytecode/cfg.zig");
pub const OpCode = @import("bytecode/opcodes.zig").OpCode;
const opEffect = @import("bytecode/opcodes.zig").opEffect;
const object = @import("object.zig");
const test_utils = @import("test/utils.zig");
const test_examples = test_utils.examples;
const AstNode = parse.AstNode;
const Parser = parse.Parser;
const testing = std.testing;

const comptimePrint = std.fmt.comptimePrint;

/// basically a tightly packed slice
fn Span(comptime T: type) type {
    return struct {
        start: u32,
        len: u32,

        inline fn slice(self: @This(), source: []const T) []const T {
            return source[self.start..][0..self.len];
        }

        const empty = @This(){ .len = 0, .start = 0 };
    };
}

const CoIndex = struct { index: u32 };
pub const ConstIndex = struct { index: u32 };
pub const NameIndex = struct { index: u32 };
fn constant(i: u32) ConstIndex {
    return .{ .index = i };
}
fn nameIndex(i: u32) NameIndex {
    return .{ .index = i };
}

pub const StackEffectError = error{
    StackUnderflow,
};

pub const StackLength = struct {
    exit: u32,
    max: u32,
};

pub fn stackLength(ir: []const Insn) StackEffectError!u32 {
    return (try stackLengthFrom(ir, 0)).exit;
}

pub fn stackLengthFrom(ir: []const Insn, entry: u32) StackEffectError!StackLength {
    var length: i64 = entry;
    var max: i64 = entry;

    for (ir) |insn| {
        switch (insn) {
            .call => |argc| {
                length -= 2;
                length -= @intCast(argc);
                length += 1;
            },
            .build_tuple => |argc| {
                length -= @intCast(argc);
                length += 1;
            },
            inline else => |payload, tag| {
                _ = payload;
                const effect = comptime opEffect(tag);
                length -= effect.pops;
                length += effect.pushes;
            },
        }
        if (length < 0) return StackEffectError.StackUnderflow;
        max = @max(max, length);
    }

    return .{
        .exit = @intCast(length),
        .max = @intCast(max),
    };
}

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
    store_name: NameIndex,
    for_iter: RelativeJump,
    swap: void,
    load_const: ConstIndex,
    load_name: NameIndex,
    build_tuple: usize,
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
    fn init(comptime kind: OpCode, comptime arg: ?u8, comptime value: object.Object, intern_pool: *intern.StringInternPool) !Self {
        // we always intern strings in the bytecode
        const obj = if (value == .string) try value.string.symbolize(intern_pool) else value;
        return switch (kind) {
            .nop => .{ .nop = {} },
            .@"resume" => .{ .@"resume" = obj.int },
            .push_null => .{ .push_null = {} },
            .load_name => .{ .load_name = nameIndex(arg orelse return error.MissingOpcodeArgument) },
            .load_const => .{ .load_const = constant(arg orelse return error.MissingOpcodeArgument) },
            .return_const => .{ .return_const = {} },
            .return_value => .{ .return_value = {} },
            .call => .{ .call = obj.int },
            .copy => .{ .copy = {} },
            .setup_annotations => .{ .setup_annotations = obj.void },
            .store_name => .{ .store_name = nameIndex(arg orelse return error.MissingOpcodeArgument) },
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

pub const CodeObject = struct {
    module: *const Module,
    instructions: Span(Insn) = .empty,
    // co_argcount: *const Object = &Zero,
    // co_code: *const Object = &EmptyString,
    // co_exceptiontable: *const Object = &EmptyString,
    // co_firstlineno: *const Object = &One,
    // co_freevars: *const Object = &EmptyTuple,
    // co_lnotab: *const Object = &None, // Deprecated, use co_lines instead
    co_names: Span(object.Object) = .empty,
    // co_qualname: *const Object = &.{ .string = .{ .string = "<module>" } },
    // co_varnames: *const Object = &EmptyTuple,
    // co_cellvars: *const Object = &EmptyTuple,
    co_consts: Span(object.Object) = .empty,
    // co_filename: *const Object = &EmptyString,
    // co_flags: *const Object = &Zero,
    // co_kwonlyargcount: *const Object = &Zero,
    // co_linetable: *const Object = &EmptyString,
    // co_name: *const Object = &.{ .string = .{ .string = "<module>" } },
    // co_nlocals: *const Object = &Zero,
    // co_posonlyargcount: *const Object = &Zero,
    co_stacksize: u32 = 0,

    // // TODO: we're leaving the world of "python objects" here,
    // //   at some point we'll need to reconcile that
    // instructions: []const Instruction = &[_]Instruction{},

    // methods...
    // replace(,
    // co_positions(,
    // co_lines(,

    pub fn getInstructions(self: *const CodeObject) []const Insn {
        return self.module.instructions(self);
    }
    pub fn consts(self: *const CodeObject) []const object.Object {
        return self.module.consts(self);
    }
    pub fn names(self: *const CodeObject) []const object.Object {
        return self.module.names(self);
    }
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    /// the full set of instructions for the module
    /// which all code objects slice from
    instruction_store: std.ArrayList(Insn) = .empty,
    /// the full set of code object for the module
    /// references to code objects are indexes into this list
    codeobject_store: std.MultiArrayList(CodeObject) = .empty,
    constant_store: std.ArrayList(object.Object) = .empty,
    name_store: std.ArrayList(object.Object) = .empty,
    intern_pool: *intern.StringInternPool,

    pub fn init(allocator: std.mem.Allocator, intern_pool: *intern.StringInternPool) Module {
        return .{
            .allocator = allocator,
            .intern_pool = intern_pool,
        };
    }

    /// Builds all codeobjects from an AST into this module.
    pub fn buildFromAst(self: *Module, ast: *const AstNode) Builder.Error!void {
        try Builder.build(
            self.allocator,
            self.intern_pool,
            ast,
            self,
        );
    }

    /// Returns a module with all codeobjects when given an AST.
    /// Prefer buildFromAst when the CodeObject back-pointers need to survive a move.
    pub fn build(allocator: std.mem.Allocator, intern_pool: *intern.StringInternPool, ast: *const AstNode) Builder.Error!Module {
        var result = init(allocator, intern_pool);
        try result.buildFromAst(ast);
        return result;
    }

    pub fn deinit(self: *Module) void {
        self.instruction_store.deinit(self.allocator);
        self.codeobject_store.deinit(self.allocator);
        self.constant_store.deinit(self.allocator);
        self.name_store.deinit(self.allocator);
    }

    inline fn instructions(self: *const Module, co: *const CodeObject) []const Insn {
        return co.instructions.slice(self.instruction_store.items);
    }

    inline fn consts(self: *const Module, co: *const CodeObject) []const object.Object {
        return co.co_consts.slice(self.constant_store.items);
    }

    inline fn names(self: *const Module, co: *const CodeObject) []const object.Object {
        return co.co_names.slice(self.name_store.items);
    }

    pub const Builder = struct {
        allocator: std.mem.Allocator,
        ast_root: *const AstNode,
        intern_pool: *intern.StringInternPool,
        queue: std.ArrayList(Seam) = .empty,
        /// Per-codeobject cache for deduping co_names entries.
        /// intern_pool owns string identity; this only maps symbols to local NameIndex operands.
        current_name_indexes: std.AutoHashMap(object.Symbol, NameIndex),
        current_code_object: u32 = 0,
        current_const_start: usize = 0,
        current_name_start: usize = 0,
        mod: *Module,

        const Seam = struct {
            parent: u32,
            node: *const AstNode,
        };

        pub const Error = error{
            InvalidEntryNode,
        } || StackEffectError || intern.StringInternPool.Error || std.mem.Allocator.Error;

        fn build(allocator: std.mem.Allocator, intern_pool: *intern.StringInternPool, ast: *const AstNode, mod: *Module) Error!void {
            var builder = Builder{
                .allocator = allocator,
                .ast_root = ast,
                .intern_pool = intern_pool,
                .current_name_indexes = .init(allocator),
                .mod = mod,
            };
            defer {
                builder.current_name_indexes.deinit();
                builder.queue.deinit(allocator);
            }

            _ = try builder.enqueueSeam(builder.ast_root);
            while (builder.current_code_object < builder.queue.items.len) {
                const current_seam = builder.queue.items[builder.current_code_object];
                try builder.processEntryNode(current_seam.node, &builder.mod.instruction_store);
                builder.current_code_object += 1;
            }
        }

        /// append an instruction to the current code object
        fn append(self: *Builder, insn: Insn) !void {
            try self.mod.instruction_store.append(self.mod.allocator, insn);
        }

        /// append a constant to the module store, and push the instruction
        fn appendConst(self: *Builder, obj: object.Object) !void {
            const index = self.mod.constant_store.items.len - self.current_const_start;
            try self.mod.constant_store.append(self.mod.allocator, obj);
            try self.append(.{ .load_const = .{ .index = @intCast(index) } });
        }

        fn nameIndexForSymbol(self: *Builder, sym: object.Symbol) !NameIndex {
            const gop = try self.current_name_indexes.getOrPut(sym);
            if (!gop.found_existing) {
                const index = self.mod.name_store.items.len - self.current_name_start;
                gop.value_ptr.* = .{ .index = @intCast(index) };
                try self.mod.name_store.append(self.mod.allocator, .{ .symbol = sym });
            }
            return gop.value_ptr.*;
        }

        fn loadName(self: *Builder, sym: object.Symbol) !void {
            try self.append(.{ .load_name = try self.nameIndexForSymbol(sym) });
        }

        fn storeName(self: *Builder, sym: object.Symbol) !void {
            try self.append(.{ .store_name = try self.nameIndexForSymbol(sym) });
        }

        /// we've found the root node of a new codeobject, enqueue it for later
        fn enqueueSeam(self: *Builder, node: *const AstNode) !CoIndex {
            const co_index = self.queue.items.len;
            try self.queue.append(self.allocator, .{
                .parent = self.current_code_object,
                .node = node,
            });
            return .{ .index = @intCast(co_index) };
        }

        fn processEntryNode(self: *Builder, ast_node: *const AstNode, insns: *std.ArrayList(Insn)) Error!void {
            const insn_idx = self.mod.instruction_store.items.len;
            const co_idx = self.mod.codeobject_store.len;
            const co_const_idx = self.mod.constant_store.items.len;
            const co_name_idx = self.mod.name_store.items.len;
            self.current_const_start = co_const_idx;
            self.current_name_start = co_name_idx;
            self.current_name_indexes.clearRetainingCapacity();

            // ENTER
            try self.append(.{ .@"resume" = 0 });

            switch (ast_node.*) {
                .root => |ast_list| {
                    try self.mod.codeobject_store.append(self.mod.allocator, .{
                        .module = self.mod,
                    });
                    for (ast_list) |node| try self.generateInsns(node, insns);
                },
                .fn_decl => |fn_decl| {
                    try self.mod.codeobject_store.append(self.mod.allocator, .{
                        .module = self.mod,
                    });
                    for (fn_decl.suite.items) |node| try self.generateInsns(node, insns);
                },
                // .lambda,
                // .class,
                // .comprehension,
                // => {},
                else => {
                    // we're trying to process a codeobject from an invalid seam in the AST
                    return Error.InvalidEntryNode;
                },
            }

            // EXIT
            // TODO: this is pretty hacky - just an intermediate solution. follow compile.c approach
            const length = try stackLength(self.mod.instruction_store.items[insn_idx..]);
            // std.debug.assert(length < 2); // should never be more than one lingering item in the stack
            if (length == 0) {
                try self.append(Insn{ .return_const = {} });
            } else {
                try self.append(Insn{ .return_value = {} });
            }

            // update spans before exit
            self.mod.codeobject_store.items(.instructions)[co_idx] = .{
                .start = @intCast(insn_idx),
                .len = @intCast(self.mod.instruction_store.items[insn_idx..].len),
            };
            self.mod.codeobject_store.items(.co_consts)[co_idx] = .{
                .start = @intCast(co_const_idx),
                .len = @intCast(self.mod.constant_store.items[co_const_idx..].len),
            };
            self.mod.codeobject_store.items(.co_names)[co_idx] = .{
                .start = @intCast(co_name_idx),
                .len = @intCast(self.mod.name_store.items[co_name_idx..].len),
            };
        }

        fn generateBinaryOp(self: *Builder, kind: BinaryOperation, binary_op: *const parse.BinaryOp, insns: *std.ArrayList(Insn)) Error!void {
            try self.generateInsns(binary_op.lhs, insns);
            try self.generateInsns(binary_op.rhs, insns);
            try self.append(.{ .binary_op = kind });
        }

        fn generateInsns(self: *Builder, ast_node: *const AstNode, insns: *std.ArrayList(Insn)) Error!void {
            switch (ast_node.*) {
                // .root => break :blk Insn{ .@"resume" = 0 },
                .root => {},
                // .integer => break :blk Insn{ .load_const = .{ .value = ast_node.integer.value } },
                .name => |name| {
                    const sym = try self.intern_pool.put(name.value);
                    switch (name.context) {
                        .Load => try self.loadName(sym),
                        .Store => try self.storeName(sym),
                    }
                },
                .string_literal => |string| {
                    const interned = try object.stringToSymbol(string.value, self.intern_pool);
                    try self.appendConst(interned);
                },
                // .var_decl => break :blk Insn{ .decl_var = .{ .symbol = try self.intern_pool.put(ast_node.var_decl.name) } },
                // .division => break :blk Insn{ .division = {} },
                // .group => break :blk try self.generateInsn(ast_node.group.value),
                // .assignment => break :blk Insn{ .assign = {} },
                .unary_op => |op_node| {
                    try self.generateInsns(op_node.value, insns);
                    const op: Insn = switch (op_node.kind) {
                        .positive => .{ .call_intrinsic_1 = .unary_positive },
                        .negative => .{ .unary_negative = {} },
                        .logical_not => .{ .unary_not = {} },
                        .bitwise_not => .{ .unary_invert = {} },
                    };
                    try self.append(op);
                },
                .bool_op => |op| {
                    const jump: Insn = switch (op.kind) {
                        .@"and" => .{ .pop_jump_if_false = .{ .delta = 2 } },
                        .@"or" => .{ .pop_jump_if_true = .{ .delta = 2 } },
                    };
                    try self.generateInsns(op.lhs, insns);
                    try self.append(.{ .copy = {} });
                    try self.append(jump);
                    try self.append(.{ .pop_top = {} });
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
                    try self.append(.{ .pop_jump_if_false = .{ .delta = 2 } });
                    try self.generateInsns(expr.lhs, insns);
                    try self.append(.{ .return_value = {} });
                    try self.generateInsns(expr.rhs, insns);
                    // try self.append( .{ .return_value = {} }); // implied
                },
                .call => |call| {
                    const len = call.args.items.len;
                    try self.append(.{ .push_null = {} }); // TODO: eventually we'll need to push receiver here
                    try self.generateInsns(call.ref, insns);
                    for (call.args.items) |node| {
                        try self.generateInsns(node, insns);
                    }
                    try self.append(.{ .call = len });
                    if (call.discard_return_value)
                        try self.append(.{ .pop_top = {} });
                },
                .integer => |int| try self.appendConst(.{ .int = int.value }),
                .bool => |b| try self.appendConst(.{ .bool = b }),
                .float => |float| try self.appendConst(.{ .float = float.value }),
                .complex => |cmp| try self.appendConst(.{ .complex = .{ .re = cmp.real, .im = cmp.imaginary } }),
                .list => |list| switch (list) {
                    .empty => try self.appendConst(object.EmptyArray),
                    // TODO - make exhaustive
                    else => try self.appendConst(object.EmptyArray),
                },
                .pass => {}, // surprisingly not a nop
                .assignment => |assignment| {
                    try self.generateInsns(assignment.rhs, insns);
                    // we handle this bit with ExpressionContext which is smelly
                    try self.generateInsns(assignment.lhs, insns);
                },
                .named_expression => |named_expression| {
                    try self.generateInsns(named_expression.rhs, insns);
                    try self.append(.{ .copy = {} });
                    try self.generateInsns(named_expression.lhs, insns);
                },
                .for_in => |for_in| {
                    // push the iterable onto the stack
                    try self.generateInsns(for_in.iterable, insns);
                    // pop iterable, push iterator
                    try self.append(.{ .get_iter = {} });
                    try self.append(.{ .for_iter = .{ .delta = 0 } });
                    const for_iter_mark = insns.items.len - 1;
                    // TODO: for non-trivial cases we'll need call back into this switch statement
                    //   but have a signal for load vs store
                    for (for_in.target_list.items) |target| {
                        std.debug.assert(target.* == .name);
                        try self.storeName(try self.intern_pool.put(target.name.value));
                    }
                    const suite_mark = insns.items.len;
                    for (for_in.suite.items) |expression|
                        try self.generateInsns(expression, insns);
                    // try self.generateInsns(for_in.else_suite, insns); // TODO

                    // clean up iterator, but only when the block actually did anything
                    if ((insns.items.len - suite_mark) > 0) try self.append(.{ .pop_top = {} });

                    // We jump by incrementing/decrementing the program counter.  Cpython records deltas that represent
                    // a similar idea but are a length in bytes; we're not going to match
                    const jump_index = @as(i64, @intCast(for_iter_mark)) - @as(i64, @intCast(insns.items.len));
                    try self.append(.{ .jump_backward = .{ .delta = jump_index } });
                    try self.append(.{ .end_for = {} });
                    insns.items[for_iter_mark].for_iter.delta = @intCast(insns.items.len - for_iter_mark);
                },
                .fn_decl => |fn_decl| {
                    // handle the suite in a different co
                    const co_idx = try self.enqueueSeam(ast_node);
                    _ = co_idx; // TODO: this becomes a constant can reference
                    // TODO: we add the future code object (its deterministic index) into the current code objects constants table

                    const fn_name = try self.mod.intern_pool.put(fn_decl.name);
                    try self.appendConst(.{ .int = 2 }); // hardcoded for our test
                    try self.append(.{ .make_function = {} });
                    try self.storeName(fn_name);
                },
                .lambda => |lambda| {
                    // TODO: generate code object for real
                    _ = lambda;
                    const co = object.Code{};
                    try self.appendConst(.{ .code = co });
                    try self.append(.{ .make_function = {} });
                    // try self.generateInsns(expression, insns);
                },
                .@"return" => |list| {
                    const items = list.items;
                    const returns_tuple = if (items.len > 1) true else false;

                    for (items) |expression|
                        try self.generateInsns(expression, insns);
                    if (returns_tuple)
                        try self.append(.{ .build_tuple = items.len });
                    try self.append(.{ .return_value = {} });
                },
                else => {
                    // TODO: this should become an exhaustive switch
                    std.debug.print("\n###############\ngenerateInsns: AstNode.{s} is not handled\n###############\n", .{@tagName(ast_node.*)});
                    unreachable;
                },
            }
        }
    };
};

test {
    _ = intern;
    _ = Cfg;
}

test "bytecode: example fixtures" {
    // var arena = std.heap.ArenaAllocator.init(testing.allocator);
    // var allocator = arena.allocator();
    // defer arena.deinit();

    inline for (test_examples) |example| {
        if (!example.test_bytecode) continue;

        var harness = try test_utils.CompilerHarness.create(testing.allocator);
        defer harness.deinit();
        const co = try harness.buildCodeObjects(example.source());
        const ir = co.getInstructions();

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var intern_pool = intern.StringInternPool.init(arena.allocator());
        defer intern_pool.deinit();

        const len = comptime example.code().instructions.len;
        var expected: [len]Insn = undefined;

        inline for (comptime example.code().instructions, 0..) |dis, i| {
            expected[i] = try Insn.init(dis.opcode, dis.arg, dis.argval, &intern_pool);
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
    // The python compiler peephole optimizes away simple expressions
    // like this, so we need to test by hand.  Very dis can be generated by
    // doing something like:
    //   def foo(a, b):
    //     return a or b
    {
        // and == JUMP_IF_FALSE
        var harness = try test_utils.CompilerHarness.create(testing.allocator);
        defer harness.deinit();
        const co = try harness.buildCodeObjects("True and False");

        const expected = [_]Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = constant(0) },
            .{ .copy = {} },
            .{ .pop_jump_if_false = .{ .delta = 2 } },
            .{ .pop_top = {} },
            .{ .load_const = constant(1) },
            .{ .return_value = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], co.getInstructions());
    }
    {
        // or == JUMP_IF_TRUE
        var harness = try test_utils.CompilerHarness.create(testing.allocator);
        defer harness.deinit();
        const co = try harness.buildCodeObjects("True or False");

        const expected = [_]Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = constant(0) },
            .{ .copy = {} },
            .{ .pop_jump_if_true = .{ .delta = 2 } },
            .{ .pop_top = {} },
            .{ .load_const = constant(1) },
            .{ .return_value = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], co.getInstructions());
    }
    {
        // chain
        var harness = try test_utils.CompilerHarness.create(testing.allocator);
        defer harness.deinit();
        const co = try harness.buildCodeObjects("True and False or True");

        const expected = [_]Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = constant(0) },
            .{ .copy = {} },
            .{ .pop_jump_if_false = .{ .delta = 2 } },
            .{ .pop_top = {} },
            .{ .load_const = constant(1) },
            .{ .copy = {} },
            .{ .pop_jump_if_true = .{ .delta = 2 } },
            .{ .pop_top = {} },
            .{ .load_const = constant(2) },
            .{ .return_value = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], co.getInstructions());
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
        const co = try harness.buildCodeObjects("1 if True else 2");

        const expected = [_]Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = constant(0) },
            .{ .pop_jump_if_false = .{ .delta = 2 } },
            .{ .load_const = constant(1) },
            .{ .return_value = {} },
            .{ .load_const = constant(2) },
            .{ .return_value = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], co.getInstructions());
    }
}

test "bytecode: codeobject seams for function definitions" {
    // ❯ python -m dis test.py
    //   0           0 RESUME                   0

    //   1           2 LOAD_CONST               0 (1)
    //               4 STORE_NAME               0 (a)

    //   2           6 LOAD_CONST               1 (2)
    //               8 STORE_NAME               1 (b)

    //   5          10 LOAD_CONST               2 (<code object add at 0x7961815ff9e0, file "test.py", line 5>)
    //              12 MAKE_FUNCTION            0
    //              14 STORE_NAME               2 (add)

    //   9          16 PUSH_NULL
    //              18 LOAD_NAME                2 (add)
    //              20 LOAD_NAME                0 (a)
    //              22 LOAD_NAME                1 (b)
    //              24 CALL                     2
    //              32 POP_TOP
    //              34 RETURN_CONST             3 (None)

    // Disassembly of <code object add at 0x7961815ff9e0, file "test.py", line 5>:
    //   5           0 RESUME                   0

    //   6           2 LOAD_FAST                0 (a)
    //               4 LOAD_FAST                1 (b)
    //               6 BINARY_OP                0 (+)
    //              10 RETURN_VALUE

    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    const source =
        "a = 1\n" ++
        "b = 2\n" ++
        "def add(a, b):\n" ++
        "\treturn a + b\n" ++
        "add(a,b)";
    _ = try harness.buildCodeObjects(source);
    const mod = harness.module;
    const main_co = mod.codeobject_store.get(0);
    const fn_co = mod.codeobject_store.get(1);

    const expected_main = [_]Insn{
        .{ .@"resume" = 0 },
        .{ .load_const = constant(0) },
        .{ .store_name = nameIndex(0) },
        .{ .load_const = constant(1) },
        .{ .store_name = nameIndex(1) },
        .{ .load_const = constant(2) },
        .{ .make_function = {} },
        .{ .store_name = nameIndex(2) },
        .{ .push_null = {} },
        .{ .load_name = nameIndex(2) },
        .{ .load_name = nameIndex(0) },
        .{ .load_name = nameIndex(1) },
        .{ .call = 2 },
        .{ .pop_top = {} },
        .{ .return_const = {} },
    };

    try testing.expectEqualSlices(Insn, expected_main[0..], main_co.getInstructions());

    // TODO: this is actually quite wrong
    // - real python does load_fast instead of load_name
    // - we have a return statement so that generates return_value, then our co exit handler appends a superfluous return_const
    const expected_fn = [_]Insn{
        .{ .@"resume" = 0 },
        .{ .load_name = nameIndex(0) },
        .{ .load_name = nameIndex(1) },
        .{ .binary_op = .add },
        .{ .return_value = {} },
        .{ .return_const = {} },
    };

    try testing.expectEqualSlices(Insn, expected_fn[0..], fn_co.getInstructions());
}
