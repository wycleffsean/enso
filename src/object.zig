const std = @import("std");
const intern = @import("bytecode/intern.zig");
const Exception = @import("exception.zig");

pub const Object = union(enum) {
    none: void,
    bool: bool,
    int: i64,
    float: f64,
    complex: std.math.Complex(f64),
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
            .symbol => try writer.print("<<unprintable>>", .{}),
        }
    }
};

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
};
// TODO: callables will _really_ look like this
//   fn(receiver, *args, **kwargs) !Object
// we have our own exceptions that are distinct
// from zig.  If we can enforce that callables
// don't return zig errors that would be great
pub fn Callable(VMType: type) type {
    return *const fn (*VMType, []Object) CallResult;
}
