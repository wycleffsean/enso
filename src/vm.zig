const std = @import("std");
const bytecode = @import("bytecode.zig");
const Builtins = @import("vm/builtins.zig").Builtins;
const opcodes = @import("bytecode/opcodes.zig");
const OpCode = opcodes.OpCode;
const opEffect = opcodes.opEffect;
const object = @import("object.zig");
const Callable = object.Callable;
const fatalExit = @import("utils.zig").fatalExit;
const Object = object.Object;
const None = object.None;

const assert = std.debug.assert;
// for tests
const testing = std.testing;
const intern = @import("bytecode/intern.zig");
const Parser = @import("parse.zig").Parser;
const test_utils = @import("test/utils.zig");
const test_examples = test_utils.examples;

const stack_depth = 1000;

pub const Error = error{
    NameError,
    TypeError,
};

pub const VM = struct {
    const Self = @This();

    stack: [stack_depth]Object = undefined,
    sp: u8 = 0,
    intern_pool: *intern.StringInternPool,
    stdout: *std.Io.Writer,

    fn push(self: *Self, obj: Object) void {
        self.sp += 1;
        assert(self.sp < stack_depth);
        self.stack[self.sp] = obj;
    }

    fn pop(self: *Self) Object {
        assert(self.sp >= 0);
        defer self.sp -= 1;
        // std.debug.print("pop: {d} {any}\n", .{ self.sp, self.stack[self.sp] });
        return self.stack[self.sp];
    }

    pub fn eval(self: *Self, insns: []const bytecode.Insn) !void {
        // TODO: does a labeled switch earn us anything here?  I would guess no, but let's experiment
        for (insns) |insn| {
            switch (insn) {
                .push_null => {
                    self.push(None);
                },
                .return_value => {},
                .load_const => |obj| {
                    self.push(obj);
                },
                .load_name => |name| {
                    self.push(name);
                },
                .return_const => {},
                .@"resume" => {},
                .call => |arity| try self.call(arity),
                else => {
                    // @compileError("uh-oh - we don't handle this Instruction yet!"); // - "); ++ @tagName(insn));
                },
            }
        }
    }

    fn fetchMethod(self: *Self, receiver: Object, funcname: Object) Error!Callable {
        switch (receiver) {
            .none => {
                // special case - we lookup the module table
                // which can fall thru to the builtins

                return try Builtins.fetchBuiltinFunction(object.dStr(Self, self, &funcname));
            },
            else => unreachable,
        }
    }

    fn call(self: *Self, arity: usize) !void {
        // TODO: this is not compatible with python 3.7+, where a method may
        // have unlimited arguments.  We need to reconcile comptime with unlimited
        // memory allocation
        //https://stackoverflow.com/a/48051450
        var args_buf: [255]Object = undefined;
        assert(arity <= 255);
        for (0..arity) |i| {
            args_buf[i] = self.pop();
        }
        const funcname = self.pop();
        assert(funcname == .symbol);
        const receiver = self.pop();
        const callable = self.fetchMethod(receiver, funcname) catch |err| {
            switch (err) {
                error.NameError => fatalExit(1, "NameError: name '{f}' is not defined", .{funcname}),
                error.TypeError => fatalExit(1, "TypeError", .{}),
            }
        };
        // TODO - when there is an actual receiver we'll need to pass it as the first argument
        const res = callable(self, args_buf[0..arity]);
        switch (res) {
            .object => |obj| self.push(obj),
            .exception => {
                // TODO - handle exceptions for real
                fatalExit(1, "Unhandled Exception", .{});
            },
        }
    }
};

const Value = union(enum) {
    static: object.Object,
    dynamic: void,
};

fn Backend(comptime StackValue: type) type {
    return struct {
        const Self = @This();

        fn call(self: *Self, argc: usize) StackValue {
            _ = argc;
            _ = self;
            return .{ .static = object.None };
        }
        fn loadConst(self: *Self, consti: object.Object) StackValue {
            _ = self;
            return .{ .static = consti };
        }
        fn loadName(self: *Self, namei: object.Object) StackValue {
            _ = self;
            return .{ .static = namei };
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
            _ = self;
            return .{ .static = object.None };
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
            _ = self;
            _ = value;
            return .{ .static = object.None };
        }
        fn unaryNot(self: *Self, value: StackValue) StackValue {
            _ = self;
            _ = value;
            return .{ .static = object.None };
        }
        fn unaryInvert(self: *Self, value: StackValue) StackValue {
            _ = self;
            _ = value;
            return .{ .static = object.None };
        }
        fn cleanupThrow(self: *Self) void {
            _ = self;
        }
        fn storeSubscr(self: *Self, values: []StackValue) void {
            _ = self;
            _ = values;
        }
        fn getIter(self: *Self, value: StackValue) StackValue {
            _ = self;
            _ = value;
            return .{ .static = object.None };
        }
        fn getYieldFromIter(self: *Self, value: StackValue) StackValue {
            _ = self;
            _ = value;
            return .{ .static = object.None };
        }
        fn loadBuildClass(self: *Self) StackValue {
            _ = self;
            return .{ .static = object.None };
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
            _ = self;
            return .{ .static = object.None };
        }
        fn buildList(self: *Self) StackValue {
            _ = self;
            return .{ .static = object.None };
        }
        fn buildSet(self: *Self) StackValue {
            _ = self;
            return .{ .static = object.None };
        }
        fn buildMap(self: *Self) StackValue {
            _ = self;
            return .{ .static = object.None };
        }
        fn loadAttr(self: *Self) void {
            _ = self;
        }
        fn compareOp(self: *Self, left: StackValue, right: StackValue) StackValue {
            _ = self;
            _ = left;
            _ = right;
            return .{ .static = object.None };
        }
        fn importName(self: *Self, left: StackValue, right: StackValue) StackValue {
            _ = self;
            _ = left;
            _ = right;
            return .{ .static = object.None };
        }
        fn importFrom(self: *Self) StackValue {
            _ = self;
            return .{ .static = object.None };
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
            _ = self;
            _ = left;
            _ = right;
            return .{ .static = object.None };
        }
        fn containsOp(self: *Self, left: StackValue, right: StackValue) StackValue {
            _ = self;
            _ = left;
            _ = right;
            return .{ .static = object.None };
        }
        fn reraise(self: *Self, value: StackValue) void {
            _ = self;
            _ = value;
        }
        fn copy(self: *Self) StackValue {
            _ = self;
            return .{ .static = object.None };
        }
        fn binaryOp(self: *Self, oparg: bytecode.BinaryOperation, left: StackValue, right: StackValue) StackValue {
            _ = oparg;
            _ = self;
            _ = left;
            _ = right;
            return .{ .static = object.None };
        }
        fn send(self: *Self) void {
            _ = self;
        }
        fn loadFast(self: *Self, var_num: object.Object) StackValue {
            _ = var_num;
            _ = self;
            return .{ .static = object.None };
        }
        fn storeFast(self: *Self, var_num: object.Object, value: StackValue) void {
            _ = var_num;
            _ = self;
            _ = value;
        }
        fn getAwaitable(self: *Self, value: StackValue) StackValue {
            _ = self;
            _ = value;
            return .{ .static = object.None };
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
            _ = self;
            return .{ .static = object.None };
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
            _ = self;
            return .{ .static = object.None };
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
            _ = self;
            _ = value;
            return .{ .static = object.None };
        }
    };
}

const ValueBackend = Backend(Value);

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

const OpResult = union {
    none: void,
    some: Value,
};

fn LoweringVM(comptime BackendType: type) type {
    return struct {
        backend: BackendType,
        stack_buf: [1024]Value = undefined,
        stack: Stack(Value),

        const Self = @This();

        pub fn init(backend: BackendType) Self {
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
                inline else => |oparg, tag| {
                    const effect = comptime opEffect(tag);
                    const op_fn = @field(BackendType, effect.handler);
                    const no_oparg = @TypeOf(oparg) == void;

                    comptime {
                        if (effect.pushes == 0) requireHandlerReturnVoid(effect.handler, tag);
                        if (effect.pushes == 1) requireHandlerReturnValue(effect.handler, tag, Value);
                        if (effect.pushes > 1) @compileError("opcode " ++ @tagName(tag) ++ " pushes > 1 not supported yet");
                    }

                    if (no_oparg and effect.pushes == 0) {
                        _ = switch (effect.pops) {
                            0 => op_fn(&self.backend),
                            1 => op_fn(&self.backend, self.stack.pop()),
                            2 => op_fn(&self.backend, self.stack.pop(), self.stack.pop()),
                            else => op_fn(&self.backend, self.stack.popSlice(effect.pops)),
                        };
                    } else if (no_oparg and effect.pushes > 0) {
                        const result: Value = switch (effect.pops) {
                            0 => op_fn(&self.backend),
                            1 => op_fn(&self.backend, self.stack.pop()),
                            2 => op_fn(&self.backend, self.stack.pop(), self.stack.pop()),
                            else => op_fn(&self.backend, self.stack.popSlice(effect.pops)),
                        };
                        self.stack.push(result);
                    } else if (effect.pushes == 0) {
                        switch (effect.pops) {
                            0 => op_fn(&self.backend, oparg),
                            1 => op_fn(&self.backend, oparg, self.stack.pop()),
                            2 => op_fn(&self.backend, oparg, self.stack.pop(), self.stack.pop()),
                            else => op_fn(&self.backend, oparg, self.stack.popSlice(effect.pops)),
                        }
                    } else if (effect.pushes > 0) {
                        const result = switch (effect.pops) {
                            0 => op_fn(&self.backend, oparg),
                            1 => op_fn(&self.backend, oparg, self.stack.pop()),
                            2 => op_fn(&self.backend, oparg, self.stack.pop(), self.stack.pop()),
                            else => op_fn(&self.backend, oparg, self.stack.popSlice(effect.pops)),
                        };
                        self.stack.push(result);
                    }
                },
            }
        }
    };
}

fn testExample(comptime example: test_utils.Example) !void {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    const ir = try harness.doIRGen(example.source());

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();

    var vm = VM{ .intern_pool = &harness.intern_pool, .stdout = &stdout.writer };
    try vm.eval(ir);

    testing.expectEqualStrings(example.stdout(), stdout.written()) catch |err| {
        std.debug.print("\n----- failing: {s} ------\n\n", .{example.path()});
        return err;
    };
}

test "vm eval: example fixtures" {
    inline for (test_examples) |example| {
        if (!example.test_vm) continue;
        if (example.test_vm_comptime) {
            comptime {
                try testExample(example.source());
            }
        }
        {
            try testExample(example);
        }
    }
}

test "LoweringVM: stack evaluation" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    const ir = try harness.doIRGen("print('hello world')");

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();

    const backend: ValueBackend = .{};
    var vm: LoweringVM(ValueBackend) = .init(backend);
    vm.eval(ir);
}
