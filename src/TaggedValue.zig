const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const math = std.math;

/// high bit "tagged" values, for densely encoding pointers
/// integers, and other immediate values in the same bits
pub const TaggedValue = @This();

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

pub const None: TaggedValue = .{ .bits = @as(u64, @intFromEnum(Tag.none)) << TagShift };

pub fn format(self: *const TaggedValue, writer: *std.Io.Writer) !void {
    switch (self.tag()) {
        .pointer => try writer.writeAll("<pointer>"),
        .integer => try writer.print("{d}", .{self.asInteger()}),
        .boolean => try writer.writeAll("(True or False - fixme"),
        .none => try writer.writeAll("None"),
    }
}

/// Ensure the high bits we're using aren't utilized
/// by pointers on the system
fn addressSpaceCheck() bool {
    var x: u8 = 0;
    const addr = @intFromPtr(&x);
    return (addr >> TagShift) == 0;
}

pub inline fn highWord(value: TaggedValue) u32 {
    return @truncate(value.bits >> 32);
}

pub inline fn lowWord(value: TaggedValue) u32 {
    return @as(u32, @truncate(value.bits));
}

pub inline fn assemble(high: u32, low: u32) TaggedValue {
    return .{
        .bits = @as(u64, high) << 32 | @as(u64, low),
    };
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

pub fn fromPointer(ptr: *const anyopaque) TaggedValue {
    const raw = @intFromPtr(ptr);
    assert((raw >> TagShift) == 0);
    return .{ .bits = raw | @as(u64, @intFromEnum(Tag.pointer)) << TagShift };
}

pub fn asPointer(value: TaggedValue) *anyopaque {
    assert(value.is(.pointer));
    return @ptrFromInt(value.bits & ((@as(u64, 1) << TagShift) - 1));
}

pub inline fn isPointer(value: TaggedValue) bool {
    return value.is(.pointer);
}

pub fn integer(int: i60) TaggedValue {
    return .{ .bits = setTag(@bitCast(int), .integer) };
}

pub inline fn isInteger(value: TaggedValue) bool {
    return value.is(.integer);
}

/// Decode an integer payload without asserting — only safe after `isInteger()`.
pub inline fn asIntegerUnchecked(value: TaggedValue) i60 {
    const payload: u60 = @intCast(value.bits & PayloadMask);
    return @bitCast(payload);
}

fn asInteger(value: TaggedValue) i60 {
    assert(value.is(.integer));

    const payload: u60 = @intCast(value.bits & PayloadMask);
    return @bitCast(payload);
}

test "values: address space" {
    try testing.expect(TaggedValue.addressSpaceCheck());
}

test "values: none" {
    const v: TaggedValue = .None;
    try testing.expect(v.is(.none));
}

test "values: pointers" {
    var x: u8 = 99;
    const value = TaggedValue.fromPointer(@ptrCast(&x));
    try testing.expect(value.is(.pointer));

    const ptr: *u8 = @ptrCast(value.asPointer());
    try testing.expectEqual(&x, ptr);
}

test "values: integers" {
    const max: TaggedValue = .integer(math.maxInt(i60));
    const min = TaggedValue.integer(math.minInt(i60));
    const one: TaggedValue = .integer(1);
    const neg_one = TaggedValue.integer(-1);
    const zero = TaggedValue.integer(0);

    try testing.expectEqual(576460752303423486, max.asInteger() + neg_one.asInteger());
    try testing.expectEqual(math.maxInt(i60), max.asInteger());
    try testing.expectEqual(math.minInt(i60), min.asInteger());
    try testing.expectEqual(1, one.asInteger());
    try testing.expectEqual(0, zero.asInteger());
    try testing.expectEqual(-1, neg_one.asInteger());
}

test "values: encoding/decoding" {
    const min = math.minInt(u60);
    const value = TaggedValue.integer(min);
    const lhs = value.highWord();
    const rhs = value.lowWord();
    const new_value = TaggedValue.assemble(lhs, rhs);

    try testing.expectEqual(min, new_value.asInteger());
}
