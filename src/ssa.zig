const std = @import("std");
const object = @import("object.zig");
const bytecode = @import("bytecode.zig");
const opcodes = @import("bytecode/opcodes.zig");
const OpCode = opcodes.OpCode;
const opEffect = opcodes.opEffect;

// testing
const testing = std.testing;
const test_utils = @import("./test/utils.zig");

const InsnIndex = u32;
const BlockIndex = u32;

const BinaryOperation = struct {
    op: bytecode.BinaryOperation,
    lhs: InsnIndex,
    rhs: InsnIndex,
};

// const SsaInsn = union(OpCode) {
const SsaInsn = union(enum) {
    // pop_top: void,
    // push_null: void,
    // end_for: void,
    // end_send: void,
    nop: void,
    // unary_negative: void,
    // unary_not: void,
    // unary_invert: void,
    // cleanup_throw: void,
    // store_subscr: void,
    // get_iter: void,
    // get_yield_from_iter: void,
    // load_build_class: void,
    // return_generator: void,
    // return_value: void,
    // setup_annotations: void,
    // store_name: object.Object,
    // for_iter: void,
    // swap: void,
    load_const: object.Object,
    load_name: object.Object,
    // build_tuple: void,
    // build_list: void,
    // build_set: void,
    // build_map: void,
    // load_attr: void,
    // compare_op: void,
    // import_name: void,
    // import_from: void,
    // pop_jump_if_false: void,
    // pop_jump_if_true: void,
    // load_global: object.Object,
    // is_op: void,
    // contains_op: void,
    // reraise: void,
    // copy: void,
    // return_const: void,
    binary_op: BinaryOperation,
    // send: void,
    // load_fast: object.Object,
    // store_fast: object.Object,
    // get_awaitable: void,
    // make_function: void,
    // jump_backward_no_interrupt: void,
    // jump_backward: void,
    // load_fast_and_clear: void,
    // list_append: void,
    // set_add: void,
    // map_add: void,
    // yield_value: void,
    // @"resume": usize,
    // build_const_key_map: void,
    // list_extend: void,
    // set_update: void,
    // dict_update: void,
    call: struct { name: InsnIndex, receiver: InsnIndex, args: []InsnIndex },
    // call_intrinsic_1: void,
};

const SsaNode = struct {
    insn: SsaInsn,
};

pub const SsaGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.MultiArrayList(SsaNode),

    const Self = @This();

    fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .nodes = .empty,
        };
    }

    fn deinit(self: *Self) void {
        self.nodes.deinit(self.allocator);
    }

    fn addNode(self: *Self, node: SsaNode) !InsnIndex {
        const idx: InsnIndex = @intCast(self.nodes.len);
        try self.nodes.append(self.allocator, node);
        return idx;
    }

    // pub fn format(self: Self, writer: *std.io.Writer) !void {}
};

const Value = SsaNode;

const SsaBackend = struct {
    ssa_graph: SsaGraph,

    const Self = @This();
    const StackValue = InsnIndex; // TODO: this is an artifact of this being a generic interface, delete later

    fn init(allocator: std.mem.Allocator) Self {
        return .{
            // lifetime of ssa_graph exceeds build process so the caller deinits
            .ssa_graph = .init(allocator),
        };
    }

    fn emit(self: *Self, insn: SsaInsn) InsnIndex {
        const node: SsaNode = .{ .insn = insn };
        const idx = self.ssa_graph.addNode(node) catch unreachable;
        return idx;
    }

    fn call(self: *Self, name: InsnIndex, receiver: InsnIndex, args: []InsnIndex) StackValue {
        return self.emit(.{ .call = .{
            .name = name,
            .receiver = receiver,
            .args = args,
        } });
    }
    fn loadConst(self: *Self, consti: object.Object) StackValue {
        return self.emit(.{ .load_const = consti });
    }
    fn loadName(self: *Self, namei: object.Object) StackValue {
        return self.emit(.{ .load_name = namei });
    }
    fn popTop(self: *Self, value: StackValue) void {
        _ = value;
        _ = self;
    }
    fn @"resume"(self: *Self, context: usize) void {
        _ = context;
        _ = self;
    }
    fn returnConst(self: *Self) void {
        _ = self;
    }

    fn pushNull(self: *Self) StackValue {
        return self.emit(.{ .load_const = object.None });
    }
    fn endFor(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn endSend(self: *Self) void {
        _ = self;
    }
    fn nop(self: *Self) void {
        _ = self;
    }
    fn unaryNegative(self: *Self, value: StackValue) StackValue {
        _ = value;
        return self.emit(.{ .nop = {} });
    }
    fn unaryNot(self: *Self, value: StackValue) StackValue {
        _ = value;
        return self.emit(.{ .nop = {} });
    }
    fn unaryInvert(self: *Self, value: StackValue) StackValue {
        _ = value;
        return self.emit(.{ .nop = {} });
    }
    fn cleanupThrow(self: *Self) void {
        _ = self;
    }
    fn storeSubscr(self: *Self, values: []StackValue) void {
        _ = self;
        _ = values;
    }
    fn getIter(self: *Self, value: StackValue) StackValue {
        _ = value;
        return self.emit(.{ .nop = {} });
    }
    fn getYieldFromIter(self: *Self, value: StackValue) StackValue {
        _ = value;
        return self.emit(.{ .nop = {} });
    }
    fn loadBuildClass(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn returnGenerator(self: *Self) void {
        _ = self;
    }
    fn returnValue(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn setupAnnotations(self: *Self) void {
        _ = self;
    }
    fn storeName(self: *Self, namei: object.Object, value: StackValue) void {
        _ = namei;
        _ = self;
        _ = value;
    }
    fn forIter(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn swap(self: *Self) void {
        _ = self;
    }
    fn buildTuple(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn buildList(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn buildSet(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn buildMap(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn loadAttr(self: *Self) void {
        _ = self;
    }
    fn compareOp(self: *Self, left: StackValue, right: StackValue) StackValue {
        _ = left;
        _ = right;
        return self.emit(.{ .nop = {} });
    }
    fn importName(self: *Self, left: StackValue, right: StackValue) StackValue {
        _ = left;
        _ = right;
        return self.emit(.{ .nop = {} });
    }
    fn importFrom(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn popJumpIfFalse(self: *Self, delta: bytecode.RelativeJump, value: StackValue) void {
        _ = delta;
        _ = self;
        _ = value;
    }
    fn popJumpIfTrue(self: *Self, delta: bytecode.RelativeJump, value: StackValue) void {
        _ = delta;
        _ = self;
        _ = value;
    }
    fn loadGlobal(self: *Self, namei: object.Object) void {
        _ = namei;
        _ = self;
    }
    fn isOp(self: *Self, left: StackValue, right: StackValue) StackValue {
        _ = left;
        _ = right;
        return self.emit(.{ .nop = {} });
    }
    fn containsOp(self: *Self, left: StackValue, right: StackValue) StackValue {
        _ = left;
        _ = right;
        return self.emit(.{ .nop = {} });
    }
    fn reraise(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn copy(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn binaryOp(self: *Self, oparg: bytecode.BinaryOperation, left: StackValue, right: StackValue) StackValue {
        return self.emit(.{ .binary_op = .{ .op = oparg, .lhs = left, .rhs = right } });
    }
    fn send(self: *Self) void {
        _ = self;
    }
    fn loadFast(self: *Self, var_num: object.Object) StackValue {
        _ = var_num;
        return self.emit(.{ .nop = {} });
    }
    fn storeFast(self: *Self, var_num: object.Object, value: StackValue) void {
        _ = var_num;
        _ = self;
        _ = value;
    }
    fn getAwaitable(self: *Self, value: StackValue) StackValue {
        _ = value;
        return self.emit(.{ .nop = {} });
    }
    fn makeFunction(self: *Self) void {
        _ = self;
    }
    fn jumpBackwardNoInterrupt(self: *Self, delta: bytecode.RelativeJump) void {
        _ = delta;
        _ = self;
    }
    fn jumpBackward(self: *Self, delta: bytecode.RelativeJump) void {
        _ = delta;
        _ = self;
    }
    fn loadFastAndClear(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn listAppend(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn setAdd(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn mapAdd(self: *Self, left: StackValue, right: StackValue) void {
        _ = self;
        _ = left;
        _ = right;
    }
    fn yieldValue(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn buildConstKeyMap(self: *Self) StackValue {
        return self.emit(.{ .nop = {} });
    }
    fn listExtend(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn setUpdate(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn dictUpdate(self: *Self, value: StackValue) void {
        _ = self;
        _ = value;
    }
    fn callIntrinsic1(self: *Self, oparg: bytecode.CallIntrinsic1Kind, value: StackValue) StackValue {
        _ = oparg;
        _ = value;
        return self.emit(.{ .nop = {} });
    }
};

fn Stack(comptime T: type) type {
    return struct {
        buf: []T,
        len: usize = 0,

        const Self = @This();

        fn push(self: *Self, v: T) void {
            self.buf[self.len] = v;
            self.len += 1;
        }

        fn pop(self: *Self) T {
            std.debug.assert(self.len > 0);
            self.len -= 1;
            return self.buf[self.len];
        }

        fn popSlice(self: *Self, n: usize) []T {
            std.debug.assert(self.len >= n);
            const start = self.len - n;
            self.len = start;
            return self.buf[start .. start + n];
        }
    };
}

const StackMachine = struct {
    const StackMachineValue = InsnIndex;
    const BackendType = SsaBackend; // TODO: artifact of this being a generic interface, delete if possible
    backend: *BackendType,
    stack_buf: [1024]StackMachineValue = undefined,
    stack: Stack(StackMachineValue),

    const Self = @This();

    pub fn init(backend: *BackendType) Self {
        var self: Self = undefined;
        self.backend = backend;
        self.stack = .{ .buf = &self.stack_buf };
        return self;
    }

    pub fn eval(self: *Self, insns: []const bytecode.Insn) void {
        for (insns) |insn| {
            self.step(insn);
        }
    }

    fn requireHandlerReturnVoid(comptime handler_name: []const u8, comptime tag: anytype) void {
        const FnT = @TypeOf(@field(BackendType, handler_name));
        const info = @typeInfo(FnT);
        if (info != .@"fn") {
            @compileError("handler '" ++ handler_name ++ "' for opcode " ++ @tagName(tag) ++ " is not a function");
        }
        const ret = info.@"fn".return_type orelse void;
        if (ret != void) {
            @compileError("opcode " ++ @tagName(tag) ++ " pushes 0, but handler '" ++ handler_name ++ "' returns " ++ @typeName(ret));
        }
    }

    fn requireHandlerReturnValue(comptime handler_name: []const u8, comptime tag: anytype, comptime ValueType: type) void {
        const FnT = @TypeOf(@field(BackendType, handler_name));
        const info = @typeInfo(FnT);
        if (info != .@"fn") {
            @compileError("handler '" ++ handler_name ++ "' for opcode " ++ @tagName(tag) ++ " is not a function");
        }
        const ret = info.@"fn".return_type orelse void;
        if (ret == void or ret != ValueType) {
            @compileError("opcode " ++ @tagName(tag) ++ " pushes 1, but handler '" ++ handler_name ++ "' returns " ++ @typeName(ret) ++ " (expected " ++ @typeName(ValueType) ++ ")");
        }
    }

    pub fn step(self: *Self, insn: bytecode.Insn) void {
        switch (insn) {
            .for_iter => {},
            .call => |argc| {
                const args = self.stack.popSlice(argc);
                const name = self.stack.pop();
                const receiver = self.stack.pop();
                const result = self.backend.call(name, receiver, args);
                self.stack.push(result);
            },
            inline else => |oparg, tag| {
                const effect = comptime opEffect(tag);
                const op_fn = @field(BackendType, effect.handler);
                const no_oparg = @TypeOf(oparg) == void;

                comptime {
                    if (effect.pushes == 0) requireHandlerReturnVoid(effect.handler, tag);
                    if (effect.pushes == 1) requireHandlerReturnValue(effect.handler, tag, StackMachineValue);
                    if (effect.pushes > 1) @compileError("opcode " ++ @tagName(tag) ++ " pushes > 1 not supported yet");
                }

                // std.debug.print("tag: {any}\n", .{tag});

                if (no_oparg and effect.pushes == 0) {
                    _ = switch (effect.pops) {
                        0 => op_fn(self.backend),
                        1 => op_fn(self.backend, self.stack.pop()),
                        2 => op_fn(self.backend, self.stack.pop(), self.stack.pop()),
                        else => op_fn(self.backend, self.stack.popSlice(effect.pops)),
                    };
                } else if (no_oparg and effect.pushes > 0) {
                    const result = switch (effect.pops) {
                        0 => op_fn(self.backend),
                        1 => op_fn(self.backend, self.stack.pop()),
                        2 => op_fn(self.backend, self.stack.pop(), self.stack.pop()),
                        else => op_fn(self.backend, self.stack.popSlice(effect.pops)),
                    };
                    self.stack.push(result);
                } else if (effect.pushes == 0) {
                    switch (effect.pops) {
                        0 => op_fn(self.backend, oparg),
                        1 => op_fn(self.backend, oparg, self.stack.pop()),
                        2 => op_fn(self.backend, oparg, self.stack.pop(), self.stack.pop()),
                        else => op_fn(self.backend, oparg, self.stack.popSlice(effect.pops)),
                    }
                } else if (effect.pushes > 0) {
                    const result = switch (effect.pops) {
                        0 => op_fn(self.backend, oparg),
                        1 => op_fn(self.backend, oparg, self.stack.pop()),
                        2 => blk: {
                            // we "pop" backward because the items come out of the stack backward :P
                            const rhs = self.stack.pop();
                            const lhs = self.stack.pop();
                            break :blk op_fn(self.backend, oparg, lhs, rhs);
                        },
                        else => op_fn(self.backend, oparg, self.stack.popSlice(effect.pops)),
                    };
                    self.stack.push(result);
                }
            },
        }
    }
};

pub const SsaBuilder = struct {
    allocator: std.mem.Allocator,
    backend: SsaBackend,
    stack_machine: StackMachine,
    const Self = @This();

    pub fn generate(allocator: std.mem.Allocator, ir: []bytecode.Insn) !SsaGraph {
        var self: Self = undefined;
        self.init(allocator);

        self.stack_machine.eval(ir);

        return self.backend.ssa_graph;
    }

    fn init(self: *Self, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.backend = .init(self.allocator);
        self.stack_machine = .init(&self.backend);
        std.debug.assert(&self.backend == self.stack_machine.backend);
    }
};

fn expectEqualSsaInsn(expected: SsaInsn, actual: SsaInsn) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));

    switch (expected) {
        .call => |e| {
            const a = actual.call;
            try testing.expectEqual(e.name, a.name);
            try testing.expectEqual(e.receiver, a.receiver);
            try testing.expectEqualSlices(InsnIndex, e.args, a.args);
        },
        inline else => |e, tag| {
            try testing.expectEqual(e, @field(actual, @tagName(tag)));
        },
    }
}

fn expectEqualSsa(expected: []const SsaInsn, actual: SsaGraph) !void {
    const actual_insns = actual.nodes.items(.insn);
    for (expected, actual_insns, 0..) |e, a, i| {
        expectEqualSsaInsn(e, a) catch |err| {
            std.debug.print("SSA instruction mismatch at index {d}\n", .{i});
            return err;
        };
    }
    try testing.expectEqual(expected.len, actual_insns.len);
}

test "ssa: destackify bytecode" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    {
        const ssa_graph = try harness.doSsa("1 + 2");

        try expectEqualSsa(
            &[_]SsaInsn{
                .{ .load_const = .{ .int = 1 } },
                .{ .load_const = .{ .int = 2 } },
                .{ .binary_op = .{ .op = .add, .lhs = 0, .rhs = 1 } },
            },
            ssa_graph,
        );
    }
    {
        const ssa_graph = try harness.doSsa("print(11 + 22)");

        var args = [_]InsnIndex{4};
        try expectEqualSsa(
            &[_]SsaInsn{
                .{ .load_const = .{ .none = {} } }, // 0: receiver
                .{ .load_name = .{ .symbol = 0 } }, // 1
                .{ .load_const = .{ .int = 11 } }, // 2
                .{ .load_const = .{ .int = 22 } }, // 2
                .{ .binary_op = .{ .op = .add, .lhs = 2, .rhs = 3 } }, // 4
                .{ .call = .{ .name = 1, .receiver = 0, .args = &args } },
            },
            ssa_graph,
        );
    }
}
