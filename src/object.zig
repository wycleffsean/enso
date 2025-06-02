const std = @import("std");
const intern = @import("bytecode/intern.zig");
const Exception = @import("exception.zig");

pub const ObjectInt = i64;
pub const ObjectFloat = f64;

pub const Object = union(enum) {
    none: void,
    bool: bool,
    int: ObjectInt,
    float: ObjectFloat,
    complex: std.math.Complex(ObjectFloat),
    string: String,
    symbol: Symbol, // symbols are just interned strings
    // callabe: Callable, // TODO: these are real objects that _have_ a callable

    const Self = @This();

    pub fn format(value: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        switch (value) {
            .none => try writer.print("None", .{}),
            .bool => |b| try writer.print("{s}", .{if (b) "True" else "False"}),
            .string => |str| try writer.print("'{s}'", .{str.string}),
            .int => |number| try writer.print("{d}", .{number}),
            .float => |number| try writer.print("{d}", .{number}),
            .complex => |cnum| try writer.print("({d}+{d}j)", .{ cnum.re, cnum.im }),
            // TODO - we have no reference to the pool so we can't retrieve the string
            .symbol => |sym| try writer.print("<<unprintable:{d}>>", .{sym}),
        }
    }
};

const max_digits = blk: {
    const math = std.math;
    const max = math.maxInt(ObjectInt);
    const ln_max = math.log(f32, math.e, max);
    break :blk @as(u6, @intFromFloat(@as(f64, math.floor(ln_max / math.ln10)))) + 1;
};

// __str__ - a temporary solution
//   we mark this inline so that we can get the string of integers
//   with just a stack allocation.  inline so that it survives
//   for the lifetime of the caller
pub inline fn dStr(comptime VMType: type, vm: *VMType, receiver: *const Object) []const u8 {
    var buffer: [max_digits]u8 = undefined;
    return switch (receiver.*) {
        .none => "None",
        .bool => |b| if (b) "True" else "False",
        .string => |str| str.string,
        .symbol => |sym| vm.intern_pool.get(sym),
        .int => |int| std.fmt.bufPrint(buffer[0..], "{d}", .{int}) catch unreachable,
        .float => |float| std.fmt.bufPrint(buffer[0..], "{d:19.5}", .{float}) catch unreachable,
        .complex => |cnum| std.fmt.bufPrint(buffer[0..], "({d}+{d}j)", .{ cnum.re, cnum.im }) catch unreachable,
    };
}

pub const None = Object{ .none = {} };
pub const False = Object{ .bool = false };
pub const True = Object{ .bool = true };
pub const Symbol = intern.Index;

pub fn stringToSymbol(string: []const u8, intern_pool: *intern.StringInternPool) !Object {
    return .{ .symbol = try intern_pool.put(string) };
}

pub const String = struct {
    string: []const u8,

    const Self = @This();

    pub fn symbolize(self: *const Self, intern_pool: *intern.StringInternPool) !Object {
        return stringToSymbol(self.string, intern_pool);
    }
};

pub const CallResult = union(enum) {
    object: Object,
    exception: Exception,

    pub const fail = @This(){ .exception = Exception{} };
};
// TODO: callables will _really_ look like this
//   fn(receiver, *args, **kwargs) !Object
// we have our own exceptions that are distinct
// from zig.  If we can enforce that callables
// don't return zig errors that would be great
pub fn Callable(VMType: type) type {
    return *const fn (*VMType, []Object) CallResult;
}
