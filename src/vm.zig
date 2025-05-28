const std = @import("std");
const bytecode = @import("bytecode.zig");
const OpCode = @import("bytecode/opcodes.zig").OpCode;
const object = @import("object.zig");
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

const VM = struct {
    stack: [stack_depth]Object = undefined,
    sp: u8 = 0,
    intern_pool: *intern.StringInternPool,
    stdout: std.ArrayList(u8).Writer,

    const Self = @This();

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

    fn getString(self: *const Self, obj: object.Object) []const u8 {
        assert(obj == .symbol or obj == .string);
        return switch (obj) {
            .string => |str| str.string,
            .symbol => |sym| self.intern_pool.get(sym),
            else => unreachable,
        };
    }

    fn call(self: *Self, arity: usize) !void {
        // TODO: this is not compatible with python 3.7+, where a method may
        // have unlimited arguments.  We need to reconcile comptime with unlimited
        // memory allocation
        //https://stackoverflow.com/a/48051450
        var args_buf: [255]Object = undefined;
        for (0..arity) |i| {
            args_buf[i] = self.pop();
        }
        const funcname = self.pop();
        const receiver = self.pop();
        _ = receiver; // TODO: handle receivers
        if (std.mem.eql(u8, self.getString(funcname), "print")) {
            assert(arity == 1);
            // TODO: this should be a pipe one day, and so the writer interface
            // should not have allocation errors
            self.stdout.writeAll(self.getString(args_buf[0])) catch unreachable;
        }
    }
};

const TestContext = struct {
    ir: []const bytecode.Insn,
    intern_pool: *intern.StringInternPool,
};

fn testSetup(code: []const u8, buffer: []u8) !TestContext {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const allocator = fba.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);

    var parser = Parser.init(allocator, code);
    const ast = try parser.parse();

    const intern_pool = try allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(allocator);

    var irgen = bytecode.IrGen.init(&arena, intern_pool, ast);
    const ir = try irgen.generate(allocator);
    return .{ .ir = ir, .intern_pool = intern_pool };
}

fn testTeardown(ctx: *TestContext) void {
    _ = ctx;
}

fn testExample(source: []const u8, expected_stdout: []const u8) !void {
    var buffer: [std.mem.page_size * 8]u8 = undefined;
    var ctx = try testSetup(source, &buffer);
    defer testTeardown(&ctx);

    var stdout = std.ArrayList(u8).init(testing.allocator);
    defer stdout.deinit();

    var vm = VM{ .intern_pool = ctx.intern_pool, .stdout = stdout.writer() };
    try vm.eval(ctx.ir);

    try testing.expectEqualStrings(expected_stdout, stdout.items);
}

test "parse: example fixtures" {
    inline for (test_examples) |example| {
        if (!example.test_vm) continue;
        if (example.test_vm_comptime) {
            comptime {
                try testExample(example.source());
            }
        }
        {
            try testExample(example.source(), example.stdout());
        }
    }
}
