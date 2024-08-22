const std = @import("std");
const bytecode = @import("bytecode.zig");
const OpCode = @import("bytecode/opcodes.zig").OpCode;
const assert = std.debug.assert;
// for tests
const testing = std.testing;
const intern = @import("bytecode/intern.zig");
const Parser = @import("parse.zig").Parser;
const test_examples = @import("test/utils.zig").examples;

const PyObject = union(enum) {
    null: void,
    string: []const u8,

    const Self = @This();

    pub fn format(value: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        switch (value) {
            .null => try writer.print("None", .{}),
            .string => |str| try writer.print("'{s}'", .{str}),
        }
    }
};
const stack_depth = 1000;

const VM = struct {
    stack: [stack_depth]PyObject = undefined,
    sp: u8 = 0,
    intern_pool: *intern.StringInternPool,

    const Self = @This();

    fn push(self: *Self, object: PyObject) void {
        self.sp += 1;
        assert(self.sp < stack_depth);
        self.stack[self.sp] = object;
    }

    fn pop(self: *Self) PyObject {
        assert(self.sp >= 0);
        defer self.sp -= 1;
        // std.debug.print("pop: {d} {any}\n", .{ self.sp, self.stack[self.sp] });
        return self.stack[self.sp];
    }

    pub fn eval(self: *Self, insns: []const bytecode.Insn) !void {
        for (insns) |insn| {
            switch (insn) {
                .push_null => {
                    self.push(PyObject{ .null = {} });
                },
                .return_value => {},
                .load_const => |pyconst| {
                    self.push(PyObject{ .string = try self.intern_pool.get(pyconst) });
                },
                .load_name => |name| {
                    self.push(PyObject{ .string = try self.intern_pool.get(name) });
                },
                .return_const => {},
                .@"resume" => {},
                .call => |arity| try self.call(arity),
            }
        }
    }

    fn call(self: *Self, arity: usize) !void {
        // TODO: this is not compatible with python 3.7+, where a method may
        // have unlimited arguments.  We need to reconcile comptime with unlimited
        // memory allocation
        //https://stackoverflow.com/a/48051450
        var args_buf: [255]PyObject = undefined;
        for (0..arity) |i| {
            args_buf[i] = self.pop();
        }
        const funcname = self.pop();
        assert(funcname == .string);
        const receiver = self.pop();
        _ = receiver; // TODO: handle receivers
        if (std.mem.eql(u8, funcname.string, "print")) {
            assert(arity == 1);
            std.debug.print("{s}", .{args_buf[0].string});
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

test "parse: example fixtures" {
    inline for (test_examples) |example| {
        if (!example.test_vm) continue;
        if (example.test_vm_comptime) {
            comptime {
                var buffer: [std.mem.page_size * 8]u8 = undefined;
                var ctx = try testSetup(example.source(), &buffer);
                defer testTeardown(&ctx);

                var vm = VM{ .intern_pool = ctx.intern_pool };
                try vm.eval(ctx.ir);
            }
        } else {
            var buffer: [std.mem.page_size * 8]u8 = undefined;
            var ctx = try testSetup(example.source(), &buffer);
            defer testTeardown(&ctx);

            var vm = VM{ .intern_pool = ctx.intern_pool };
            try vm.eval(ctx.ir);
        }
    }
}
