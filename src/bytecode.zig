const std = @import("std");
const parse = @import("parse.zig");
const intern = @import("intern.zig");
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

        pub inline fn slice(self: @This(), source: []const T) []const T {
            return source[self.start..][0..self.len];
        }

        const empty = @This(){ .len = 0, .start = 0 };
    };
}

const CoIndex = struct { index: u32 };
pub const ConstIndex = struct { index: u32 };
fn constant(i: u32) ConstIndex {
    return .{ .index = i };
}

pub const StackEffectError = error{
    StackUnderflow,
};

pub const StackLength = struct {
    exit: u32,
    max: u32,
};

// pub fn stackLength(ir: []const Insn) StackEffectError!u32 {
//     return (try stackLengthFrom(ir, 0)).exit;
// }

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
            .build_list => |argc| {
                length -= @intCast(argc);
                length += 1;
            },
            .build_set => |argc| {
                length -= @intCast(argc);
                length += 1;
            },
            .build_map => |argc| {
                length -= @intCast(argc * 2);
                length += 1;
            },
            .build_const_key_map => |argc| {
                length -= @intCast(argc + 1);
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
pub const BinaryOperation = enum(u4) {
    add = 0,
    bit_and = 1,
    floor_div = 2,
    lshift = 3,
    mat_mult = 4,
    mult = 5,
    mod = 6,
    bit_or = 7,
    pow = 8,
    rshift = 9,
    sub = 10,
    div = 11,
    bit_xor = 12,
    inplace_add = 13,
};

pub const CompareOperation = enum(u8) {
    lt,
    leq,
    eq,
    neq,
    gt,
    geq,
    identity,
    not_identity,
};

pub const CallIntrinsic1Kind = enum(u8) {
    stopiteration_error = 3,
    unary_positive = 5,
    list_to_tuple = 6,
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
    store_name: object.Symbol,
    for_iter: RelativeJump,
    swap: usize,
    load_const: ConstIndex,
    load_name: object.Symbol,
    build_tuple: usize,
    build_list: usize,
    build_set: usize,
    build_map: usize,
    load_attr: object.Symbol,
    compare_op: CompareOperation,
    import_name: void,
    import_from: void,
    pop_jump_if_false: RelativeJump,
    pop_jump_if_true: RelativeJump,
    load_global: object.Object,
    is_op: bool,
    contains_op: bool,
    reraise: usize,
    copy: void,
    return_const: void,
    binary_op: BinaryOperation,
    send: RelativeJump,
    load_fast: object.Object,
    store_fast: object.Object,
    get_awaitable: usize,
    make_function: void,
    jump_backward_no_interrupt: RelativeJump,
    jump_backward: RelativeJump,
    jump_forward: RelativeJump,
    load_fast_and_clear: object.Object,
    list_append: usize,
    set_add: usize,
    map_add: usize,
    yield_value: usize,
    @"resume": usize,
    build_const_key_map: usize,
    list_extend: usize,
    set_update: usize,
    dict_update: usize,
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

    /// convenience function for tests
    fn normalize_for_test(comptime dis: object.Instruction, intern_pool: *intern.StringInternPool) !Self {
        const kind = dis.opcode;
        const arg = dis.arg;
        const value = dis.argval;
        // we always intern strings in the bytecode
        const obj = if (value == .string) try value.string.symbolize(intern_pool) else value;
        return switch (kind) {
            .nop => .{ .nop = {} },
            .@"resume" => .{ .@"resume" = obj.int },
            .push_null => .{ .push_null = {} },
            .load_name => .{ .load_name = obj.symbol },
            .load_const => .{ .load_const = constant(arg orelse return error.MissingOpcodeArgument) },
            .return_const => .{ .return_const = {} },
            .return_value => .{ .return_value = {} },
            .call => .{ .call = obj.int },
            .copy => .{ .copy = {} },
            .load_fast => .{ .load_fast = .{ .int = arg orelse return error.MissingOpcodeArgument } },
            .store_fast => .{ .store_fast = .{ .int = arg orelse return error.MissingOpcodeArgument } },
            .load_fast_and_clear => .{ .load_fast_and_clear = .{ .int = arg orelse return error.MissingOpcodeArgument } },
            .setup_annotations => .{ .setup_annotations = obj.void },
            .store_name => .{ .store_name = obj.symbol },
            .binary_op => .{ .binary_op = @enumFromInt(arg.?) },
            .compare_op => .{ .compare_op = try compareOperation(dis) },
            .contains_op => .{ .contains_op = (arg orelse return error.MissingOpcodeArgument) != 0 },
            // TODO...
            .build_tuple => .{ .build_tuple = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .build_list => .{ .build_list = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .build_set => .{ .build_set = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .build_map => .{ .build_map = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .get_iter => .{ .get_iter = {} },
            .get_yield_from_iter => .{ .get_yield_from_iter = {} },
            .get_awaitable => .{ .get_awaitable = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .for_iter => .{ .for_iter = .{ .delta = value.int } },
            .pop_top => .{ .pop_top = {} },
            .jump_backward => .{ .jump_backward = .{ .delta = value.int } },
            .unary_not => .{ .unary_not = {} },
            .unary_negative => .{ .unary_negative = {} },
            .unary_invert => .{ .unary_invert = {} },
            .call_intrinsic_1 => .{ .call_intrinsic_1 = @enumFromInt(arg orelse return error.MissingOpcodeArgument) },
            .pop_jump_if_false => .{ .pop_jump_if_false = .{ .delta = value.int } },
            .pop_jump_if_true => .{ .pop_jump_if_true = .{ .delta = value.int } },
            .is_op => .{ .is_op = (arg orelse return error.MissingOpcodeArgument) != 0 },
            .end_for => .{ .end_for = {} },
            .make_function => .{ .make_function = {} },
            .swap => .{ .swap = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .list_append => .{ .list_append = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .set_add => .{ .set_add = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .map_add => .{ .map_add = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .build_const_key_map => .{ .build_const_key_map = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .list_extend => .{ .list_extend = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .set_update => .{ .set_update = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .dict_update => .{ .dict_update = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .send => .{ .send = .{ .delta = value.int } },
            .yield_value => .{ .yield_value = @intCast(arg orelse return error.MissingOpcodeArgument) },
            .cleanup_throw => .{ .cleanup_throw = {} },
            .end_send => .{ .end_send = {} },
            .return_generator => .{ .return_generator = {} },
            .reraise => .{ .reraise = @intCast(arg orelse return error.MissingOpcodeArgument) },
            else => {
                comptime {
                    @compileError(comptimePrint("uh-oh - we don't handle this opcode yet! - {s} ({})", .{ @tagName(kind), @intFromEnum(kind) }));
                }
            },
        };
    }

    fn compareOperation(comptime dis: object.Instruction) !CompareOperation {
        if (dis.argrepr) |repr| {
            if (comptime std.mem.eql(u8, repr, "<")) return .lt;
            if (comptime std.mem.eql(u8, repr, "<=")) return .leq;
            if (comptime std.mem.eql(u8, repr, "==")) return .eq;
            if (comptime std.mem.eql(u8, repr, "!=")) return .neq;
            if (comptime std.mem.eql(u8, repr, ">")) return .gt;
            if (comptime std.mem.eql(u8, repr, ">=")) return .geq;
        }
        return switch (dis.arg orelse return error.MissingOpcodeArgument) {
            2 => .lt,
            26 => .leq,
            40 => .eq,
            55 => .neq,
            68 => .gt,
            92 => .geq,
            else => error.UnexpectedOpcodeArgument,
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
    co_argcount: u32 = 0, // number of positional parameters (fast locals 0..co_argcount-1)
    co_nlocals: u32 = 0, // count of fast local slots for this code object
    // co_qualname: *const Object = &.{ .string = .{ .string = "<module>" } },
    // co_varnames: *const Object = &EmptyTuple,
    // co_cellvars: *const Object = &EmptyTuple,
    co_consts: Span(object.Object) = .empty,
    // co_names: when userspace asks for code.co_names, iterate load_name/store_name instructions
    //   and collect unique symbols; resolve each via module.intern_pool.get(sym) to get the string.
    // co_filename: *const Object = &EmptyString,
    // co_flags: *const Object = &Zero,
    // co_kwonlyargcount: *const Object = &Zero,
    // co_linetable: *const Object = &EmptyString,
    co_name: []const u8 = "<co>", //*const object.Object = &.{ .string = .{ .string = "<module>" } },
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
    }

    inline fn instructions(self: *const Module, co: *const CodeObject) []const Insn {
        return co.instructions.slice(self.instruction_store.items);
    }

    inline fn consts(self: *const Module, co: *const CodeObject) []const object.Object {
        return co.co_consts.slice(self.constant_store.items);
    }

    pub const Builder = struct {
        allocator: std.mem.Allocator,
        ast_root: *const AstNode,
        intern_pool: *intern.StringInternPool,
        queue: std.ArrayList(Seam) = .empty,
        current_code_object: u32 = 0,
        current_const_start: usize = 0,
        loop_continue_targets: std.ArrayList(usize) = .empty,
        current_fast_symbols: std.ArrayList(object.Symbol) = .empty,
        /// Maps fast symbol → slot index within the current code object's locals.
        current_fast_indexes: std.AutoHashMap(object.Symbol, u32) = undefined,
        deferred_fast_cleanups: std.ArrayList(object.Symbol) = .empty,
        /// True when generating inside a function body (where locals use fast slots).
        in_function_scope: bool = false,
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
                .current_fast_indexes = .init(allocator),
                .mod = mod,
            };
            defer {
                builder.deferred_fast_cleanups.deinit(allocator);
                builder.current_fast_symbols.deinit(allocator);
                builder.current_fast_indexes.deinit();
                builder.loop_continue_targets.deinit(allocator);
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
            for (self.mod.constant_store.items[self.current_const_start..], 0..) |existing, index| {
                if (objectEql(existing, obj)) {
                    try self.append(.{ .load_const = .{ .index = @intCast(index) } });
                    return;
                }
            }
            const index = self.mod.constant_store.items.len - self.current_const_start;
            try self.mod.constant_store.append(self.mod.allocator, obj);
            try self.append(.{ .load_const = .{ .index = @intCast(index) } });
        }

        fn appendFreshConst(self: *Builder, obj: object.Object) !void {
            const index = self.mod.constant_store.items.len - self.current_const_start;
            try self.mod.constant_store.append(self.mod.allocator, obj);
            try self.append(.{ .load_const = .{ .index = @intCast(index) } });
        }

        fn objectEql(lhs: object.Object, rhs: object.Object) bool {
            return switch (lhs) {
                .none => rhs == .none,
                .bool => |l| rhs == .bool and l == rhs.bool,
                .int => |l| rhs == .int and l == rhs.int,
                .float => |l| rhs == .float and l == rhs.float,
                .complex => |l| rhs == .complex and l.re == rhs.complex.re and l.im == rhs.complex.im,
                .string => |l| rhs == .string and std.mem.eql(u8, l.string, rhs.string.string),
                .symbol => |l| rhs == .symbol and l == rhs.symbol,
                .array => false,
                .tuple => false,
                .code => false,
                .codeobject => |l| rhs == .codeobject and l == rhs.codeobject,
            };
        }

        fn loadName(self: *Builder, sym: object.Symbol) !void {
            try self.append(.{ .load_name = sym });
        }

        fn storeName(self: *Builder, sym: object.Symbol) !void {
            try self.append(.{ .store_name = sym });
        }

        fn isFastSymbol(self: *const Builder, sym: object.Symbol) bool {
            return self.current_fast_indexes.contains(sym);
        }

        /// Register sym as a fast local (if not already) and return its slot index.
        fn fastIndexForSymbol(self: *Builder, sym: object.Symbol) !u32 {
            const gop = try self.current_fast_indexes.getOrPut(sym);
            if (!gop.found_existing) {
                const idx: u32 = @intCast(self.current_fast_symbols.items.len);
                gop.value_ptr.* = idx;
                try self.current_fast_symbols.append(self.allocator, sym);
            }
            return gop.value_ptr.*;
        }

        fn loadFast(self: *Builder, sym: object.Symbol) !void {
            const idx = try self.fastIndexForSymbol(sym);
            try self.append(.{ .load_fast = .{ .int = @intCast(idx) } });
        }

        fn storeFast(self: *Builder, sym: object.Symbol) !void {
            const idx = try self.fastIndexForSymbol(sym);
            try self.append(.{ .store_fast = .{ .int = @intCast(idx) } });
        }

        fn appendTupleConst(self: *Builder, values: []const object.Object) !void {
            const owned = try self.allocator.alloc(object.Object, values.len);
            @memcpy(owned, values);
            try self.appendConst(.{ .tuple = owned });
        }

        fn constObjectFromAst(self: *Builder, ast_node: *const AstNode) !?object.Object {
            return switch (ast_node.*) {
                .integer => |int| .{ .int = int.value },
                .bool => |b| .{ .bool = b },
                .float => |float| .{ .float = float.value },
                .complex => |cmp| .{ .complex = .{ .re = cmp.real, .im = cmp.imaginary } },
                .string_literal => |string| try object.stringToSymbol(string.value, self.intern_pool),
                else => null,
            };
        }

        fn appendDeferredFastCleanups(self: *Builder) !void {
            for (self.deferred_fast_cleanups.items) |sym| {
                try self.append(.{ .swap = 2 });
                try self.append(.{ .pop_top = {} });
                try self.append(.{ .swap = 2 });
                try self.storeFast(sym);
                try self.append(.{ .reraise = 0 });
            }
        }

        fn forwardJumpDelta(self: *const Builder, jump_index: usize, target_index: usize) object.ObjectInt {
            _ = self;
            return @as(object.ObjectInt, @intCast(target_index)) - @as(object.ObjectInt, @intCast(jump_index + 1));
        }

        fn backwardJumpDelta(self: *const Builder, jump_index: usize, target_index: usize) object.ObjectInt {
            _ = self;
            return @as(object.ObjectInt, @intCast(target_index)) - @as(object.ObjectInt, @intCast(jump_index));
        }

        fn patchConditionalJump(self: *Builder, jump_index: usize, target_index: usize) void {
            const delta = self.forwardJumpDelta(jump_index, target_index);
            switch (self.mod.instruction_store.items[jump_index]) {
                .pop_jump_if_false => self.mod.instruction_store.items[jump_index].pop_jump_if_false.delta = delta,
                .pop_jump_if_true => self.mod.instruction_store.items[jump_index].pop_jump_if_true.delta = delta,
                .jump_forward => self.mod.instruction_store.items[jump_index].jump_forward.delta = delta,
                else => unreachable,
            }
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
            self.current_const_start = co_const_idx;
            self.current_fast_symbols.clearRetainingCapacity();
            self.current_fast_indexes.clearRetainingCapacity();
            self.in_function_scope = false;
            self.deferred_fast_cleanups.clearRetainingCapacity();

            // ENTER
            try self.append(.{ .@"resume" = 0 });

            const flow = switch (ast_node.*) {
                .root => |stmt_list| blk: {
                    try self.mod.codeobject_store.append(self.mod.allocator, .{
                        .module = self.mod,
                    });
                    break :blk try self.generateStatements(stmt_list, insns);
                },
                .fn_decl => |fn_decl| blk: {
                    try self.mod.codeobject_store.append(self.mod.allocator, .{
                        .module = self.mod,
                    });
                    self.in_function_scope = true;
                    // Register positional parameters as fast locals in slot order.
                    for (fn_decl.parameters.arguments.items) |param| {
                        if (param.identifier.* == .name) {
                            const sym = try self.intern_pool.put(param.identifier.name.value);
                            _ = try self.fastIndexForSymbol(sym);
                        }
                    }
                    self.mod.codeobject_store.items(.co_argcount)[co_idx] =
                        @intCast(fn_decl.parameters.arguments.items.len);
                    break :blk try self.generateStatements(fn_decl.suite.items, insns);
                },
                .comprehension => |comprehension| blk: {
                    try self.mod.codeobject_store.append(self.mod.allocator, .{
                        .module = self.mod,
                    });
                    try self.generateGeneratorCodeObject(comprehension, insns);
                    break :blk Flow.terminates;
                },
                // .lambda,
                // .class,
                // => {},
                else => {
                    // we're trying to process a codeobject from an invalid seam in the AST
                    return Error.InvalidEntryNode;
                },
            };

            // EXIT
            if (flow.falls_through) {
                try self.append(Insn{ .return_const = {} });
            }
            try self.appendDeferredFastCleanups();

            // update spans before exit
            self.mod.codeobject_store.items(.instructions)[co_idx] = .{
                .start = @intCast(insn_idx),
                .len = @intCast(self.mod.instruction_store.items[insn_idx..].len),
            };
            self.mod.codeobject_store.items(.co_consts)[co_idx] = .{
                .start = @intCast(co_const_idx),
                .len = @intCast(self.mod.constant_store.items[co_const_idx..].len),
            };
            self.mod.codeobject_store.items(.co_nlocals)[co_idx] =
                @intCast(self.current_fast_symbols.items.len);
        }

        const Flow = struct {
            falls_through: bool = true,
            const terminates: Flow = .{ .falls_through = false };
            const continues: Flow = .{ .falls_through = true };
        };

        fn generateStatements(self: *Builder, statements: []const parse.StatementNode, insns: *std.ArrayList(Insn)) Error!Flow {
            var flow = Flow.continues;

            for (statements) |stmt| {
                if (!flow.falls_through) break;
                flow = try self.generateStatement(stmt, insns);
            }
            return flow;
        }

        fn generateStatement(self: *Builder, stmt: parse.StatementNode, insns: *std.ArrayList(Insn)) Error!Flow {
            switch (stmt) {
                .expr => |expr| {
                    try self.generateInsns(expr, insns);
                    if (exprLeavesValue(expr)) try self.append(.{ .pop_top = {} });
                    return Flow.continues;
                },
                .node => |node| switch (node.*) {
                    .@"return" => {
                        try self.generateInsns(node, insns);
                        return Flow.terminates;
                    },
                    .if_stmt => |if_stmt| {
                        return try self.generateIfStatement(if_stmt, insns);
                    },
                    .while_stmt => |while_stmt| {
                        return try self.generateWhileStatement(while_stmt, insns);
                    },
                    .continue_stmt => {
                        try self.generateInsns(node, insns);
                        return Flow.terminates;
                    },
                    .break_stmt => {
                        try self.generateInsns(node, insns);
                        return Flow.terminates;
                    },
                    .raise_stmt => {
                        try self.generateInsns(node, insns);
                        return Flow.terminates;
                    },
                    else => {
                        try self.generateInsns(node, insns);
                        return Flow.continues;
                    },
                },
            }
        }

        fn exprLeavesValue(ast_node: *const AstNode) bool {
            return switch (ast_node.*) {
                .assignment => false,
                .augmented_assignment => false,
                .annotated_assignment => false,
                .yield => false,
                else => true,
            };
        }

        fn generateBinaryOp(self: *Builder, kind: BinaryOperation, binary_op: *const parse.BinaryOp, insns: *std.ArrayList(Insn)) Error!void {
            try self.generateInsns(binary_op.lhs, insns);
            try self.generateInsns(binary_op.rhs, insns);
            try self.append(.{ .binary_op = kind });
        }

        fn generateComparison(self: *Builder, comparison: parse.Comparison, insns: *std.ArrayList(Insn)) Error!void {
            try self.generateInsns(comparison.lhs, insns);
            try self.generateInsns(comparison.rhs, insns);
            switch (comparison.kind) {
                .identity => {
                    try self.append(.{ .is_op = false });
                    return;
                },
                .not_identity => {
                    try self.append(.{ .is_op = true });
                    return;
                },
                else => {},
            }
            const op: CompareOperation = switch (comparison.kind) {
                .lt => .lt,
                .gt => .gt,
                .eq => .eq,
                .leq => .leq,
                .geq => .geq,
                .neq => .neq,
                .identity => .identity,
                .not_identity => .not_identity,
            };
            try self.append(.{ .compare_op = op });
        }

        fn generateMembership(self: *Builder, membership: parse.BinaryOp, invert: bool, insns: *std.ArrayList(Insn)) Error!void {
            try self.generateInsns(membership.lhs, insns);
            try self.generateInsns(membership.rhs, insns);
            try self.append(.{ .contains_op = invert });
        }

        fn generateAssignment(self: *Builder, assignment: parse.BinaryOp, keep_value: bool, insns: *std.ArrayList(Insn)) Error!void {
            if (assignment.rhs.* == .assignment) {
                try self.generateAssignment(assignment.rhs.assignment, true, insns);
            } else {
                try self.generateInsns(assignment.rhs, insns);
            }
            if (keep_value) try self.append(.{ .copy = {} });
            try self.generateInsns(assignment.lhs, insns);
        }

        fn generateListDisplay(self: *Builder, list: anytype, insns: *std.ArrayList(Insn)) Error!void {
            switch (list) {
                .empty => try self.append(.{ .build_list = 0 }),
                .list => |items| {
                    if (try self.generateConstListExtend(items.items, insns)) return;

                    var built = false;
                    var pending: usize = 0;
                    for (items.items) |item| {
                        if (item.unpack) {
                            if (!built) {
                                try self.append(.{ .build_list = pending });
                                built = true;
                            }
                            try self.generateInsns(item.value, insns);
                            try self.append(.{ .list_extend = 1 });
                        } else {
                            if (built) {
                                try self.generateInsns(item.value, insns);
                                try self.append(.{ .list_append = 1 });
                            } else {
                                try self.generateInsns(item.value, insns);
                                pending += 1;
                            }
                        }
                    }
                    if (!built) try self.append(.{ .build_list = pending });
                },
                .comprehension => |comprehension| try self.generateListComprehension(comprehension, insns),
            }
        }

        fn generateSetDisplay(self: *Builder, set: anytype, insns: *std.ArrayList(Insn)) Error!void {
            switch (set) {
                .set => |items| {
                    var built = false;
                    var pending: usize = 0;
                    for (items.items) |item| {
                        if (item.unpack) {
                            if (!built) {
                                try self.append(.{ .build_set = pending });
                                built = true;
                            }
                            try self.generateInsns(item.value, insns);
                            try self.append(.{ .set_update = 1 });
                        } else {
                            if (built) {
                                try self.generateInsns(item.value, insns);
                                try self.append(.{ .set_add = 1 });
                            } else {
                                try self.generateInsns(item.value, insns);
                                pending += 1;
                            }
                        }
                    }
                    if (!built) try self.append(.{ .build_set = pending });
                },
                .comprehension => |comprehension| try self.generateSetComprehension(comprehension, insns),
            }
        }

        fn generateDictionaryDisplay(self: *Builder, dictionary: anytype, insns: *std.ArrayList(Insn)) Error!void {
            switch (dictionary) {
                .empty => try self.append(.{ .build_map = 0 }),
                .dictionary => |items| {
                    var built = false;
                    var index: usize = 0;
                    while (index < items.items.len) {
                        if (items.items[index].key == null) {
                            if (!built) {
                                try self.append(.{ .build_map = 0 });
                                built = true;
                            }
                            try self.generateInsns(items.items[index].value, insns);
                            try self.append(.{ .dict_update = 1 });
                            index += 1;
                            continue;
                        }

                        const start = index;
                        while (index < items.items.len and items.items[index].key != null) : (index += 1) {}
                        const len = index - start;

                        if (!built and try self.canBuildConstKeyMap(items.items[start..index])) {
                            var keys = try std.ArrayList(object.Object).initCapacity(self.allocator, len);
                            defer keys.deinit(self.allocator);
                            for (items.items[start..index]) |item| {
                                keys.appendAssumeCapacity((try self.constObjectFromAst(item.key.?)).?);
                                try self.generateInsns(item.value, insns);
                            }
                            try self.appendTupleConst(keys.items);
                            try self.append(.{ .build_const_key_map = len });
                            built = true;
                        } else if (!built) {
                            for (items.items[start..index]) |item| {
                                try self.generateInsns(item.key.?, insns);
                                try self.generateInsns(item.value, insns);
                            }
                            try self.append(.{ .build_map = len });
                            built = true;
                        } else {
                            for (items.items[start..index]) |item| {
                                try self.generateInsns(item.key.?, insns);
                                try self.generateInsns(item.value, insns);
                                try self.append(.{ .map_add = 1 });
                            }
                        }
                    }
                    if (!built) try self.append(.{ .build_map = 0 });
                },
                .comprehension => |comprehension| try self.generateDictionaryComprehension(comprehension, insns),
            }
        }

        fn canBuildConstKeyMap(self: *Builder, items: anytype) !bool {
            if (items.len < 2) return false;
            for (items) |item| {
                const key = try self.constObjectFromAst(item.key.?);
                if (key == null) return false;
            }
            return true;
        }

        fn generateConstListExtend(self: *Builder, items: anytype, insns: *std.ArrayList(Insn)) Error!bool {
            if (items.len < 3) return false;
            var constants = try std.ArrayList(object.Object).initCapacity(self.allocator, items.len);
            defer constants.deinit(self.allocator);
            for (items) |item| {
                if (item.unpack) return false;
                const value = try self.constObjectFromAst(item.value) orelse return false;
                constants.appendAssumeCapacity(value);
            }
            _ = insns;
            try self.append(.{ .build_list = 0 });
            try self.appendTupleConst(constants.items);
            try self.append(.{ .list_extend = 1 });
            return true;
        }

        fn generateComprehensionHeader(self: *Builder, comprehension: anytype, comptime build_tag: OpCode, insns: *std.ArrayList(Insn)) Error!object.Symbol {
            if (comprehension.for_expressions.items.len != 1) return Error.InvalidEntryNode;
            const comp_for = comprehension.for_expressions.items[0];
            if (comp_for.predicate_expression != null) return Error.InvalidEntryNode;
            if (comp_for.target_list.items.len != 1) return Error.InvalidEntryNode;
            const target = comp_for.target_list.items[0];
            if (target.* != .name) return Error.InvalidEntryNode;
            const sym = try self.intern_pool.put(target.name.value);

            try self.generateInsns(comp_for.iterator, insns);
            try self.append(.{ .get_iter = {} });
            try self.append(.{ .load_fast_and_clear = .{ .int = 0 } });
            try self.append(.{ .swap = 2 });
            try self.append(switch (build_tag) {
                .build_list => .{ .build_list = 0 },
                .build_set => .{ .build_set = 0 },
                .build_map => .{ .build_map = 0 },
                else => unreachable,
            });
            try self.append(.{ .swap = 2 });
            return sym;
        }

        fn beginComprehensionLoop(self: *Builder, sym: object.Symbol, insns: *std.ArrayList(Insn)) !usize {
            try self.append(.{ .for_iter = .{ .delta = 0 } });
            const for_iter_mark = insns.items.len - 1;
            try self.storeFast(sym);
            try self.current_fast_symbols.append(self.allocator, sym);
            // Comprehension body expressions use fast slots for the loop variable,
            // so treat the body as a fast scope regardless of the enclosing scope.
            self.in_function_scope = true;
            return for_iter_mark;
        }

        fn finishComprehensionLoop(self: *Builder, sym: object.Symbol, saved_in_function_scope: bool, for_iter_mark: usize, body_index: usize, insns: *std.ArrayList(Insn)) !void {
            self.in_function_scope = saved_in_function_scope;
            _ = self.current_fast_symbols.pop();
            try self.append(.{ .jump_backward = .{ .delta = self.backwardJumpDelta(insns.items.len, for_iter_mark) } });
            try self.append(.{ .end_for = {} });
            insns.items[for_iter_mark].for_iter.delta = @intCast(insns.items.len - for_iter_mark);
            try self.append(.{ .swap = 2 });
            try self.storeFast(sym);
            try self.deferred_fast_cleanups.append(self.allocator, sym);
            _ = body_index;
        }

        fn generateListComprehension(self: *Builder, comprehension: anytype, insns: *std.ArrayList(Insn)) Error!void {
            const sym = try self.generateComprehensionHeader(comprehension, .build_list, insns);
            const saved = self.in_function_scope;
            const for_iter_mark = try self.beginComprehensionLoop(sym, insns);
            const body_index = insns.items.len;
            try self.generateInsns(comprehension.expression, insns);
            try self.append(.{ .list_append = 2 });
            try self.finishComprehensionLoop(sym, saved, for_iter_mark, body_index, insns);
        }

        fn generateSetComprehension(self: *Builder, comprehension: anytype, insns: *std.ArrayList(Insn)) Error!void {
            const sym = try self.generateComprehensionHeader(comprehension, .build_set, insns);
            const saved = self.in_function_scope;
            const for_iter_mark = try self.beginComprehensionLoop(sym, insns);
            const body_index = insns.items.len;
            try self.generateInsns(comprehension.expression, insns);
            try self.append(.{ .set_add = 2 });
            try self.finishComprehensionLoop(sym, saved, for_iter_mark, body_index, insns);
        }

        fn generateDictionaryComprehension(self: *Builder, comprehension: anytype, insns: *std.ArrayList(Insn)) Error!void {
            const sym = try self.generateComprehensionHeader(comprehension, .build_map, insns);
            const saved = self.in_function_scope;
            const for_iter_mark = try self.beginComprehensionLoop(sym, insns);
            const body_index = insns.items.len;
            try self.generateInsns(comprehension.expression.key orelse return Error.InvalidEntryNode, insns);
            try self.generateInsns(comprehension.expression.value, insns);
            try self.append(.{ .map_add = 2 });
            try self.finishComprehensionLoop(sym, saved, for_iter_mark, body_index, insns);
        }

        fn generateGeneratorExpression(self: *Builder, comprehension: anytype, insns: *std.ArrayList(Insn)) Error!void {
            if (comprehension.for_expressions.items.len == 0) return Error.InvalidEntryNode;
            const seam = try self.allocator.create(AstNode);
            seam.* = .{ .comprehension = comprehension };
            const co_idx = try self.enqueueSeam(seam);
            try self.appendConst(.{ .codeobject = co_idx.index });
            try self.append(.{ .make_function = {} });

            const first_for = comprehension.for_expressions.items[0];
            try self.generateInsns(first_for.iterator, insns);
            try self.append(.{ .get_iter = {} });
            try self.append(.{ .call = 0 });
        }

        fn generateYieldExpression(self: *Builder, yield: anytype, insns: *std.ArrayList(Insn)) Error!void {
            switch (yield) {
                .expression => |expression| {
                    try self.generateInsns(expression, insns);
                    try self.append(.{ .get_yield_from_iter = {} });
                    try self.appendConst(object.None);
                    const send_index = insns.items.len;
                    try self.append(.{ .send = .{ .delta = 3 } });
                    try self.append(.{ .yield_value = 2 });
                    try self.append(.{ .@"resume" = 2 });
                    try self.append(.{ .jump_backward_no_interrupt = .{ .delta = self.backwardJumpDelta(insns.items.len, send_index) } });
                    try self.append(.{ .end_send = {} });
                    try self.append(.{ .pop_top = {} });
                },
                .list => |items| {
                    if (items.items.len == 1 and !items.items[0].unpack) {
                        try self.generateInsns(items.items[0].value, insns);
                    } else {
                        var built = false;
                        var pending: usize = 0;
                        for (items.items) |item| {
                            if (item.unpack) {
                                if (!built) {
                                    try self.append(.{ .build_list = pending });
                                    built = true;
                                }
                                try self.generateInsns(item.value, insns);
                                try self.append(.{ .list_extend = 1 });
                            } else if (built) {
                                try self.generateInsns(item.value, insns);
                                try self.append(.{ .list_append = 1 });
                            } else {
                                try self.generateInsns(item.value, insns);
                                pending += 1;
                            }
                        }
                        if (!built) try self.append(.{ .build_list = pending });
                        try self.append(.{ .call_intrinsic_1 = .list_to_tuple });
                    }
                    try self.append(.{ .yield_value = 1 });
                    try self.append(.{ .@"resume" = 1 });
                    try self.append(.{ .pop_top = {} });
                },
            }
        }

        fn generateAwaitExpression(self: *Builder, ast_node: *const AstNode, insns: *std.ArrayList(Insn)) Error!void {
            try self.generateInsns(ast_node, insns);
            try self.append(.{ .get_awaitable = 0 });
            try self.appendConst(object.None);
            const send_index = insns.items.len;
            try self.append(.{ .send = .{ .delta = 3 } });
            try self.append(.{ .yield_value = 2 });
            try self.append(.{ .@"resume" = 3 });
            try self.append(.{ .jump_backward_no_interrupt = .{ .delta = self.backwardJumpDelta(insns.items.len, send_index) } });
            try self.append(.{ .end_send = {} });
        }

        fn generateGeneratorCodeObject(self: *Builder, comprehension: anytype, insns: *std.ArrayList(Insn)) Error!void {
            if (comprehension.for_expressions.items.len == 0) return Error.InvalidEntryNode;
            try self.append(.{ .return_generator = {} });
            try self.append(.{ .pop_top = {} });

            const dot_zero = try self.intern_pool.put(".0");
            try self.current_fast_symbols.append(self.allocator, dot_zero);
            try self.loadFast(dot_zero);

            const first_for = comprehension.for_expressions.items[0];
            if (first_for.target_list.items.len != 1) return Error.InvalidEntryNode;
            const first_target = first_for.target_list.items[0];
            if (first_target.* != .name) return Error.InvalidEntryNode;
            const first_sym = try self.intern_pool.put(first_target.name.value);

            try self.append(.{ .for_iter = .{ .delta = 0 } });
            const first_for_iter = insns.items.len - 1;
            try self.current_fast_symbols.append(self.allocator, first_sym);
            try self.storeFast(first_sym);

            if (comprehension.for_expressions.items.len != 2) return Error.InvalidEntryNode;
            const second_for = comprehension.for_expressions.items[1];
            if (second_for.target_list.items.len != 1) return Error.InvalidEntryNode;
            const second_target = second_for.target_list.items[0];
            if (second_target.* != .name) return Error.InvalidEntryNode;
            const second_sym = try self.intern_pool.put(second_target.name.value);

            try self.generateInsns(second_for.iterator, insns);
            try self.append(.{ .get_iter = {} });
            try self.append(.{ .for_iter = .{ .delta = 0 } });
            const second_for_iter = insns.items.len - 1;
            try self.current_fast_symbols.append(self.allocator, second_sym);
            try self.storeFast(second_sym);
            try self.generateInsns(comprehension.expression, insns);
            try self.append(.{ .yield_value = 1 });
            try self.append(.{ .@"resume" = 1 });
            try self.append(.{ .pop_top = {} });
            try self.append(.{ .jump_backward = .{ .delta = self.backwardJumpDelta(insns.items.len, second_for_iter) } });
            try self.append(.{ .end_for = {} });
            try self.append(.{ .jump_backward = .{ .delta = self.backwardJumpDelta(insns.items.len, first_for_iter) } });
            try self.append(.{ .end_for = {} });
            try self.append(.{ .return_const = {} });
            insns.items[first_for_iter].for_iter.delta = @intCast(insns.items.len - first_for_iter);
            insns.items[second_for_iter].for_iter.delta = @intCast((second_for_iter + 1 + 0) - second_for_iter);
            try self.append(.{ .call_intrinsic_1 = .stopiteration_error });
            try self.append(.{ .reraise = 1 });
        }

        fn generateIfStatement(self: *Builder, if_stmt: anytype, insns: *std.ArrayList(Insn)) Error!Flow {
            try self.generateInsns(if_stmt.predicate, insns);
            try self.append(.{ .pop_jump_if_false = .{ .delta = 0 } });
            const false_jump_index = insns.items.len - 1;

            const then_flow = try self.generateStatements(if_stmt.suite.items, insns);
            if (if_stmt.else_suite) |else_suite| {
                // The "then" suite is its own basic block, so if it falls
                // through into what follows it needs an explicit jump past
                // the "else" suite rather than relying on fallthrough (which
                // would incorrectly run the else suite too). We deliberately
                // don't collapse this into a single shared exit jump the way
                // CPython's peephole optimizer does: that's a bytecode-level
                // optimization that only makes later SSA/CFG passes redo
                // work we'd have to undo first.
                var then_exit_jump_index: ?usize = null;
                if (then_flow.falls_through) {
                    try self.append(.{ .jump_forward = .{ .delta = 0 } });
                    then_exit_jump_index = insns.items.len - 1;
                }

                self.patchConditionalJump(false_jump_index, insns.items.len);
                const else_flow = try self.generateStatements(else_suite.items, insns);

                if (then_exit_jump_index) |jump_index| {
                    self.patchConditionalJump(jump_index, insns.items.len);
                }

                return .{ .falls_through = then_flow.falls_through or else_flow.falls_through };
            }

            // TODO: this matches CPython's fixture shape for a final module-level
            // if body, but statement-boundary aware lowering should decide this
            // from the enclosing statement list instead.
            if (then_flow.falls_through) try self.append(.{ .return_const = {} });
            self.patchConditionalJump(false_jump_index, insns.items.len);
            return Flow.continues;
        }

        fn generateWhileStatement(self: *Builder, while_stmt: anytype, insns: *std.ArrayList(Insn)) Error!Flow {
            const initial_condition_index = insns.items.len;
            try self.generateInsns(while_stmt.predicate, insns);
            try self.append(.{ .pop_jump_if_false = .{ .delta = 0 } });
            const initial_false_jump_index = insns.items.len - 1;

            const body_index = insns.items.len;
            try self.loop_continue_targets.append(self.allocator, initial_condition_index);
            const body_flow = try self.generateStatements(while_stmt.suite.items, insns);
            _ = body_flow;
            _ = self.loop_continue_targets.pop();

            try self.generateInsns(while_stmt.predicate, insns);
            try self.append(.{ .pop_jump_if_false = .{ .delta = 1 } });
            const tail_false_jump_index = insns.items.len - 1;
            try self.append(.{ .jump_backward = .{ .delta = self.backwardJumpDelta(insns.items.len, body_index) } });

            const loop_exit_index = insns.items.len;
            self.patchConditionalJump(tail_false_jump_index, loop_exit_index);
            try self.append(.{ .return_const = {} });

            const initial_exit_index = insns.items.len;
            self.patchConditionalJump(initial_false_jump_index, initial_exit_index);
            try self.append(.{ .return_const = {} });

            return Flow.terminates;
        }

        fn generateInsns(self: *Builder, ast_node: *const AstNode, insns: *std.ArrayList(Insn)) Error!void {
            switch (ast_node.*) {
                // .root => break :blk Insn{ .@"resume" = 0 },
                .root => {},
                // .integer => break :blk Insn{ .load_const = .{ .value = ast_node.integer.value } },
                .name => |name| {
                    const sym = try self.intern_pool.put(name.value);
                    if (self.in_function_scope) {
                        switch (name.context) {
                            // In function scope every local is a fast slot.
                            // store auto-registers the symbol; load looks it up.
                            .Store => try self.storeFast(sym),
                            .Load => if (self.isFastSymbol(sym))
                                try self.loadFast(sym)
                            else
                                try self.loadName(sym), // global/builtin reference
                        }
                    } else {
                        switch (name.context) {
                            .Load => try self.loadName(sym),
                            .Store => try self.storeName(sym),
                        }
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
                .comparison => |comparison| try self.generateComparison(comparison, insns),
                .membership => |membership| try self.generateMembership(membership, false, insns),
                .not_membership => |membership| try self.generateMembership(membership, true, insns),
                .group => |group| try self.generateInsns(group.value, insns),
                .conditional => |*expr| {
                    try self.generateInsns(expr.predicate, insns);
                    try self.append(.{ .pop_jump_if_false = .{ .delta = 2 } });
                    try self.generateInsns(expr.lhs, insns);
                    try self.append(.{ .return_value = {} });
                    try self.generateInsns(expr.rhs, insns);
                    // try self.append( .{ .return_value = {} }); // implied
                },
                .field_access => |field_access| {
                    try self.generateInsns(field_access.lhs, insns);
                    const attr_name = field_access.rhs.name.value;
                    const sym = try self.intern_pool.put(attr_name);
                    try self.append(.{ .load_attr = sym });
                },
                .call => |call| {
                    const len = call.args.items.len;
                    try self.append(.{ .push_null = {} }); // TODO: eventually we'll need to push receiver here
                    try self.generateInsns(call.ref, insns);
                    for (call.args.items) |node| {
                        try self.generateInsns(node, insns);
                    }
                    try self.append(.{ .call = len });
                },
                .integer => |int| try self.appendConst(.{ .int = int.value }),
                .bool => |b| try self.appendConst(.{ .bool = b }),
                .float => |float| try self.appendConst(.{ .float = float.value }),
                .complex => |cmp| try self.appendConst(.{ .complex = .{ .re = cmp.real, .im = cmp.imaginary } }),
                .ellipsis => try self.appendConst(object.None),
                .tuple => |items| {
                    for (items.items) |item| try self.generateInsns(item, insns);
                    try self.append(.{ .build_tuple = items.items.len });
                },
                .list => |list| try self.generateListDisplay(list, insns),
                .set => |set| try self.generateSetDisplay(set, insns),
                .dictionary => |dictionary| try self.generateDictionaryDisplay(dictionary, insns),
                .comprehension => |comprehension| try self.generateGeneratorExpression(comprehension, insns),
                .starred => |starred| try self.generateInsns(starred.value, insns),
                .subscript => |subscript| {
                    _ = subscript.rhs;
                    try self.generateInsns(subscript.lhs, insns);
                },
                .slice => try self.appendConst(object.None),
                .pass => {}, // surprisingly not a nop
                .assignment => |assignment| {
                    try self.generateAssignment(assignment, false, insns);
                },
                .augmented_assignment => |assignment| {
                    std.debug.assert(assignment.lhs.* == .name);
                    const sym = try self.intern_pool.put(assignment.lhs.name.value);
                    try self.loadName(sym);
                    try self.generateInsns(assignment.rhs, insns);
                    const op: BinaryOperation = switch (assignment.kind) {
                        .add => .inplace_add,
                        .sub => .sub,
                        .mult => .mult,
                        .mat_mult => .mat_mult,
                        .div => .div,
                        .floor_div => .floor_div,
                        .mod => .mod,
                        .pow => .pow,
                    };
                    try self.append(.{ .binary_op = op });
                    try self.storeName(sym);
                },
                .annotated_assignment => |assignment| {
                    if (assignment.value) |value| {
                        try self.generateInsns(value, insns);
                        try self.generateInsns(assignment.lhs, insns);
                    }
                },
                .named_expression => |named_expression| {
                    try self.generateInsns(named_expression.rhs, insns);
                    try self.append(.{ .copy = {} });
                    try self.generateInsns(named_expression.lhs, insns);
                },
                .yield => |yield| try self.generateYieldExpression(yield, insns),
                .await => |await| try self.generateAwaitExpression(await, insns),
                .if_stmt => |if_stmt| {
                    _ = try self.generateIfStatement(if_stmt, insns);
                },
                .while_stmt => |while_stmt| {
                    _ = try self.generateWhileStatement(while_stmt, insns);
                },
                .try_stmt => |try_stmt| {
                    _ = try self.generateStatements(try_stmt.suite.items, insns);
                    for (try_stmt.except_handlers.items) |handler| {
                        _ = try self.generateStatements(handler.suite.items, insns);
                    }
                    if (try_stmt.else_suite) |suite| _ = try self.generateStatements(suite.items, insns);
                    if (try_stmt.finally_suite) |suite| _ = try self.generateStatements(suite.items, insns);
                },
                .with_stmt => |with_stmt| {
                    _ = try self.generateStatements(with_stmt.suite.items, insns);
                },
                .del_stmt => {},
                .continue_stmt => {
                    const target = self.loop_continue_targets.getLast();
                    try self.append(.{ .jump_backward = .{ .delta = self.backwardJumpDelta(insns.items.len, target) } });
                },
                .break_stmt => {},
                .raise_stmt => {},
                .assert_stmt => {},
                .import => {},
                .class => {},
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
                    // TODO: there is a flow state we need to consider here
                    _ = try self.generateStatements(for_in.suite.items, insns);
                    // try self.generateInsns(for_in.else_suite, insns); // TODO

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

                    const fn_name = try self.mod.intern_pool.put(fn_decl.name);
                    try self.appendConst(.{ .codeobject = co_idx.index });
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
        comptime @setEvalBranchQuota(10000);
        if (!example.test_bytecode) continue;

        var harness = try test_utils.CompilerHarness.create(testing.allocator);
        defer harness.deinit();
        const co = try harness.buildCodeObjects(example.source());
        const ir = co.getInstructions();
        const actual = if (example.normalize_bytecode)
            try test_utils.optimizeBytecodeForPythonFixture(testing.allocator, co)
        else
            ir;
        defer if (example.normalize_bytecode) testing.allocator.free(actual);

        const len = comptime example.code().instructions.len;
        var expected: [len]Insn = undefined;

        inline for (comptime example.code().instructions, 0..) |dis, i| {
            expected[i] = try Insn.normalize_for_test(dis, &harness.intern_pool);
            // we cheat and rewrite the delta values since we calculate them
            // differently.  Of course this is a hack and will only update the
            // deltas if they appear on the same line which is good enough
            if (i <= actual.len) {
                switch (expected[i]) {
                    .for_iter => {
                        if (actual[i] == .for_iter) expected[i].for_iter.delta = actual[i].for_iter.delta;
                    },
                    .pop_jump_if_false => {
                        if (actual[i] == .pop_jump_if_false) expected[i].pop_jump_if_false.delta = actual[i].pop_jump_if_false.delta;
                    },
                    .pop_jump_if_true => {
                        if (actual[i] == .pop_jump_if_true) expected[i].pop_jump_if_true.delta = actual[i].pop_jump_if_true.delta;
                    },
                    .jump_backward => {
                        if (actual[i] == .jump_backward) expected[i].jump_backward.delta = actual[i].jump_backward.delta;
                    },
                    else => {},
                }
            }
        }

        testing.expectEqualSlices(Insn, expected[0..], actual) catch |err| {
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
            .{ .pop_top = {} },
            .{ .return_const = {} },
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
            .{ .pop_top = {} },
            .{ .return_const = {} },
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
            .{ .load_const = constant(0) },
            .{ .pop_top = {} },
            .{ .return_const = {} },
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
            .{ .pop_top = {} },
            .{ .return_const = {} },
        };

        try testing.expectEqualSlices(Insn, expected[0..], co.getInstructions());
    }
}

test "bytecode: if/else statement emits jump_forward past else suite" {
    // def ex(cond):
    //     if cond:
    //         x = 10
    //     else:
    //         x = 20
    //     return x + 1
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    const source =
        "def ex(cond):\n" ++
        "\tif cond:\n" ++
        "\t\tx = 10\n" ++
        "\telse:\n" ++
        "\t\tx = 20\n" ++
        "\treturn x + 1\n";
    _ = try harness.buildCodeObjects(source);
    const fn_co = harness.module.codeobject_store.get(1);

    const expected = [_]Insn{
        .{ .@"resume" = 0 },
        .{ .load_fast = .{ .int = 0 } }, // cond
        .{ .pop_jump_if_false = .{ .delta = 3 } },
        .{ .load_const = constant(0) }, // 10
        .{ .store_fast = .{ .int = 1 } }, // x
        .{ .jump_forward = .{ .delta = 2 } },
        .{ .load_const = constant(1) }, // 20
        .{ .store_fast = .{ .int = 1 } }, // x
        .{ .load_fast = .{ .int = 1 } }, // x
        .{ .load_const = constant(2) }, // 1
        .{ .binary_op = .add },
        .{ .return_value = {} },
    };

    try testing.expectEqualSlices(Insn, expected[0..], fn_co.getInstructions());

    // The CFG should see the "then" suite as its own block that jumps past
    // the "else" suite, rather than inferring only three blocks.
    var cfg = try Cfg.build(testing.allocator, fn_co.getInstructions());
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 4), cfg.blocks.len);
}

test "bytecode: if/elif/else statement chains jump_forward per branch" {
    // def ex(cond, other):
    //     if cond:
    //         x = 10
    //     elif other:
    //         x = 20
    //     else:
    //         x = 30
    //     return x
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    const source =
        "def ex(cond, other):\n" ++
        "\tif cond:\n" ++
        "\t\tx = 10\n" ++
        "\telif other:\n" ++
        "\t\tx = 20\n" ++
        "\telse:\n" ++
        "\t\tx = 30\n" ++
        "\treturn x\n";
    _ = try harness.buildCodeObjects(source);
    const fn_co = harness.module.codeobject_store.get(1);

    var jump_forward_count: usize = 0;
    for (fn_co.getInstructions()) |insn| {
        if (insn == .jump_forward) jump_forward_count += 1;
    }
    // one jump past the elif/else chain, and one past the elif's own else
    try testing.expectEqual(@as(usize, 2), jump_forward_count);

    var cfg = try Cfg.build(testing.allocator, fn_co.getInstructions());
    defer cfg.deinit();
    // entry, if-then, elif-condition, elif-then, else, exit
    try testing.expectEqual(@as(usize, 6), cfg.blocks.len);
}

test "bytecode: if/else statement skips jump_forward when then suite terminates" {
    // def ex(cond):
    //     if cond:
    //         return 1
    //     else:
    //         x = 2
    //     return x
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    const source =
        "def ex(cond):\n" ++
        "\tif cond:\n" ++
        "\t\treturn 1\n" ++
        "\telse:\n" ++
        "\t\tx = 2\n" ++
        "\treturn x\n";
    _ = try harness.buildCodeObjects(source);
    const fn_co = harness.module.codeobject_store.get(1);

    for (fn_co.getInstructions()) |insn| {
        try testing.expect(insn != .jump_forward);
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

    const sym_a = mod.intern_pool.getIndex("a").?;
    const sym_b = mod.intern_pool.getIndex("b").?;
    const sym_add = mod.intern_pool.getIndex("add").?;

    const expected_main = [_]Insn{
        .{ .@"resume" = 0 },
        .{ .load_const = constant(0) },
        .{ .store_name = sym_a },
        .{ .load_const = constant(1) },
        .{ .store_name = sym_b },
        .{ .load_const = constant(2) },
        .{ .make_function = {} },
        .{ .store_name = sym_add },
        .{ .push_null = {} },
        .{ .load_name = sym_add },
        .{ .load_name = sym_a },
        .{ .load_name = sym_b },
        .{ .call = 2 },
        .{ .pop_top = {} },
        .{ .return_const = {} },
    };

    try testing.expectEqualSlices(Insn, expected_main[0..], main_co.getInstructions());
    try testing.expectEqual(object.Object{ .codeobject = 1 }, main_co.consts()[2]);

    const expected_fn = [_]Insn{
        .{ .@"resume" = 0 },
        .{ .load_fast = .{ .int = 0 } }, // x
        .{ .load_fast = .{ .int = 1 } }, // y
        .{ .binary_op = .add },
        .{ .return_value = {} },
    };

    try testing.expectEqualSlices(Insn, expected_fn[0..], fn_co.getInstructions());
}
