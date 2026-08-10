const std = @import("std");
const CodeObject = @import("../bytecode.zig").CodeObject;
const sys = @import("lib/sys.zig");
const testing = std.testing;
const test_utils = @import("../test/utils.zig");

const EnsoFrame = extern struct {
    prev: ?*EnsoFrame,
    co: *const CodeObject,
    stack_depth: u16 = undefined,
    nlocals: u16 = undefined,
};

pub const StackFrame = struct {
    // AFAICT - zig's memorypool internals will work well with a LIFO use case
    pool: std.heap.memory_pool.Extra(EnsoFrame, .{
        .growable = false,
    }),
    prev: ?*EnsoFrame = null,

    const Self = @This();

    const Error = error{
        OverflowError,
    };

    /// capacity - setting to null will use the value from sys.getrecursionlimit()
    ///   any other value is really only appropriate for testing
    pub fn init(base_allocator: std.mem.Allocator, capacity: ?usize) std.mem.Allocator.Error!Self {
        const cap = capacity orelse sys.getrecursionlimit();
        return .{
            .pool = try .initCapacity(base_allocator, cap),
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
        frame.nlocals = nlocals;
        frame.stack_depth = stack_depth;
        self.prev = frame;
        return frame;
    }

    pub fn pop(self: *Self) void {
        const frame = self.prev.?;
        self.prev = frame.prev;
        self.pool.destroy(frame);
    }
};

test "overflow" {
    const harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    var sf: StackFrame = try .init(testing.allocator, 1);
    defer sf.deinit(testing.allocator);
    const co = try harness.buildCodeObjects("");

    _ = try sf.push(&co, 0);
    try testing.expectError(StackFrame.Error.OverflowError, sf.push(&co, 0));
}
