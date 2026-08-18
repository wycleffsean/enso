const std = @import("std");
const assert = std.debug.assert;
const CodeObject = @import("../bytecode.zig").CodeObject;
const TaggedValue = @import("../TaggedValue.zig");
const sys = @import("lib/sys.zig");
const testing = std.testing;
const test_utils = @import("../test/utils.zig");

const EnsoFrame = struct {
    prev: ?*EnsoFrame,
    co: *const CodeObject,
    stack_depth: u16 = undefined,
    locals: []TaggedValue,

    fn setLocal(self: *EnsoFrame, index: usize, value: TaggedValue) void {
        self.locals[index] = value;
    }

    fn getLocal(self: *EnsoFrame, index: usize) TaggedValue {
        return self.locals[index];
    }
};

pub const StackFrame = struct {
    allocator: std.mem.Allocator,
    // AFAICT - zig's memorypool internals will work well with a LIFO use case
    pool: std.heap.memory_pool.Extra(EnsoFrame, .{
        .growable = false,
    }),
    prev: ?*EnsoFrame = null,

    const Self = @This();

    const Error = error{
        OverflowError,
    } || std.mem.Allocator.Error;

    /// capacity - setting to null will use the value from sys.getrecursionlimit()
    ///   any other value is really only appropriate for testing
    pub fn init(allocator: std.mem.Allocator, capacity: ?usize) std.mem.Allocator.Error!Self {
        const cap = capacity orelse sys.getrecursionlimit();
        return .{
            .allocator = allocator,
            .pool = try .initCapacity(allocator, cap),
        };
    }

    pub fn deinit(self: *Self, base_allocator: std.mem.Allocator) void {
        self.pool.deinit(base_allocator);
        self.* = undefined;
    }

    pub fn push(self: *Self, co: *const CodeObject, nlocals: u16) Error!*EnsoFrame {
        var frame = self.pool.create(undefined) catch |err| switch (err) {
            error.OutOfMemory => return error.OverflowError,
        };
        const stack_depth = if (self.prev) |prev| prev.stack_depth + 1 else 0;
        frame.co = co;
        frame.locals = try self.allocator.alloc(TaggedValue, nlocals);
        frame.stack_depth = stack_depth;
        self.prev = frame;
        return frame;
    }

    pub fn pop(self: *Self) void {
        const frame = self.prev.?;
        self.prev = frame.prev;
        self.allocator.free(frame.locals);
        self.pool.destroy(frame);
    }
};

test "stackframe: overflow" {
    const harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    var sf: StackFrame = try .init(testing.allocator, 1);
    defer sf.deinit(testing.allocator);
    const co = try harness.buildCodeObjects("");

    _ = try sf.push(&co, 0);
    try testing.expectError(StackFrame.Error.OverflowError, sf.push(&co, 0));
}

test "stackframe: set/get local values" {
    const harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    var sf: StackFrame = try .init(testing.allocator, 1);
    defer sf.deinit(testing.allocator);
    const co = try harness.buildCodeObjects("");

    const frame = try sf.push(&co, 1000);
    defer sf.pop();

    frame.setLocal(0, .none);
    frame.setLocal(999, .none);
    _ = frame.getLocal(0);
    _ = frame.getLocal(999);
}
