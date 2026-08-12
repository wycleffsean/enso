const std = @import("std");
const assert = std.debug.assert;
const CodeObject = @import("../bytecode.zig").CodeObject;
const sys = @import("lib/sys.zig");
const testing = std.testing;
const test_utils = @import("../test/utils.zig");

const TaggedValue = struct {
    bits: u64,

    const TagBits = 4;
    const PayloadBits = 64 - TagBits;
    const TagShift = PayloadBits;
    const PayloadMask = (@as(u64, 1) << TagShift) - 1;
    const TagMask = ((@as(u64, 1) << TagBits) - 1) << TagShift;

    const Tag = enum(u4) {
        pointer = 0x0,
        integer = 0xE,
        boolean = 0xF,
        none = 0xD,
    };

    const none: TaggedValue = .{ .bits = @as(u64, @intFromEnum(Tag.none)) << TagShift };

    /// Ensure the high bits we're using aren't utilized
    /// by pointers on the system
    fn addressSpaceCheck() bool {
        var x: u8 = 0;
        const addr = @intFromPtr(&x);
        return (addr >> TagShift) == 0;
    }

    inline fn tag(value: TaggedValue) Tag {
        return @enumFromInt((value.bits & TagMask) >> TagShift);
    }

    inline fn setTag(bits: u60, kind: Tag) u64 {
        return (@as(u64, @intFromEnum(kind)) << TagShift) | bits;
    }

    inline fn is(value: TaggedValue, kind: Tag) bool {
        return value.tag() == kind;
    }

    fn pointer(ptr: *void) TaggedValue {
        const raw = @intFromPtr(ptr);
        assert((raw >> TagShift) == 0);

        return .{ .bits = raw | @as(u64, @intFromEnum(Tag.pointer)) << TagShift };
    }

    fn asPointer(value: TaggedValue) *void {
        assert(value.is(.pointer));

        return @ptrFromInt(value.bits & ((@as(u64, 1) << TagShift) - 1));
    }

    fn integer(int: i60) TaggedValue {
        return .{ .bits = setTag(@bitCast(int), .integer) };
    }

    fn asInteger(value: TaggedValue) i60 {
        assert(value.is(.integer));

        const payload: u60 = @intCast(value.bits & PayloadMask);
        return @bitCast(payload);
    }
};

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

test "values: address space" {
    try testing.expect(TaggedValue.addressSpaceCheck());
}

test "values: none" {
    const v: TaggedValue = .none;
    try testing.expect(v.is(.none));
}

test "values: pointers" {
    var x: u8 = 99;
    const value = TaggedValue.pointer(@ptrCast(&x));
    try testing.expect(value.is(.pointer));

    const ptr: *u8 = @ptrCast(value.asPointer());
    try testing.expectEqual(&x, ptr);
}

test "values: integers" {
    const max: TaggedValue = .integer(std.math.maxInt(i60));
    const min = TaggedValue.integer(std.math.minInt(i60));
    const one: TaggedValue = .integer(1);
    const neg_one = TaggedValue.integer(-1);
    const zero = TaggedValue.integer(0);

    try testing.expectEqual(576460752303423486, max.asInteger() + neg_one.asInteger());
    try testing.expectEqual(std.math.maxInt(i60), max.asInteger());
    try testing.expectEqual(std.math.minInt(i60), min.asInteger());
    try testing.expectEqual(1, one.asInteger());
    try testing.expectEqual(0, zero.asInteger());
    try testing.expectEqual(-1, neg_one.asInteger());
}

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
