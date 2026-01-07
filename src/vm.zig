const std = @import("std");
const bytecode = @import("bytecode.zig");
const builtins = @import("vm/builtins.zig");
const OpCode = @import("bytecode/opcodes.zig").OpCode;
const object = @import("object.zig");
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

pub fn VM(WriterType: type) type {
    return struct {
        const Self = @This();
        const Callable = object.Callable(Self);
        const Builtins = builtins.Builtins(Self);

        stack: [stack_depth]Object = undefined,
        sp: u8 = 0,
        intern_pool: *intern.StringInternPool,
        stdout: WriterType,

        pub fn init(intern_pool: *intern.StringInternPool, stdout: WriterType) Self {
            return .{ .intern_pool = intern_pool, .stdout = stdout };
        }

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
}

const TestContext = struct {
    ir: []const bytecode.Insn,
    intern_pool: *intern.StringInternPool,
};

fn testSetup(code: []const u8, buffer: []u8) !TestContext {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const allocator = fba.allocator();

    var parser = Parser.init(allocator, code);
    const ast = try parser.parse();

    const intern_pool = try allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(allocator);

    var irgen = bytecode.IrGen.init(allocator, intern_pool, ast);
    const ir = try irgen.generate(allocator);
    return .{ .ir = ir, .intern_pool = intern_pool };
}

fn testTeardown(ctx: *TestContext) void {
    _ = ctx;
}

fn testExample(comptime example: test_utils.Example) !void {
    var buffer: [std.heap.page_size_min * 8]u8 = undefined;
    var ctx = try testSetup(example.source(), &buffer);
    defer testTeardown(&ctx);

    var stdout: std.ArrayList(u8) = .{};
    defer stdout.deinit(testing.allocator);
    const stdout_writer = stdout.writer(testing.allocator);

    var vm = VM(@TypeOf(stdout_writer)).init(ctx.intern_pool, stdout_writer);
    try vm.eval(ctx.ir);

    testing.expectEqualStrings(example.stdout(), stdout.items) catch |err| {
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
