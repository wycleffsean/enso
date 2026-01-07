const std = @import("std");
const intern = @import("bytecode/intern.zig");
const Exception = @import("exception.zig");

pub const ObjectInt = i64;
pub const ObjectFloat = f64;
pub const ObjectComplex = std.math.Complex(ObjectFloat);

pub const Object = union(enum) {
    none: void,
    bool: bool,
    int: ObjectInt,
    float: ObjectFloat,
    complex: ObjectComplex,
    array: []Object,
    tuple: []const Object,
    string: String,
    symbol: Symbol, // symbols are just interned strings
    // callabe: Callable, // TODO: these are real objects that _have_ a callable
    code: Code,

    const Self = @This();

    pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .none => try writer.print("None", .{}),
            .bool => |b| try writer.print("{s}", .{if (b) "True" else "False"}),
            .string => |str| try writer.print("'{s}'", .{str.string}),
            .int => |number| try writer.print("{d}", .{number}),
            .float => |number| try writer.print("{d}", .{number}),
            .complex => |cnum| try writer.print("({d}+{d}j)", .{ cnum.re, cnum.im }),
            // TODO - we have no reference to the pool so we can't retrieve the string
            .symbol => |sym| try writer.print("<<unprintable:{d}>>", .{sym}),
            .array => |arr| try writer.print("{any}", .{arr}),
            .tuple => |t| try writer.print("{any}", .{t}),
            .code => try writer.print("<code object>", .{}),
        }
    }
};

const max_digits = blk: {
    const math = std.math;
    const max_signed: ObjectInt = math.maxInt(ObjectInt);
    // log10_int requires unsigned
    const U = std.meta.Int(.unsigned, @bitSizeOf(ObjectInt));
    const max_u: U = @intCast(max_signed);
    break :blk @as(u6, math.log10_int(max_u) + 1);
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
        .float => |float| std.fmt.bufPrint(buffer[0..], "{d:19}", .{float}) catch unreachable,
        .complex => |cnum| std.fmt.bufPrint(buffer[0..], "({d}+{d}j)", .{ cnum.re, cnum.im }) catch unreachable,
        .array => std.fmt.bufPrint(buffer[0..], "<<array>>", .{}) catch unreachable,
        .tuple => std.fmt.bufPrint(buffer[0..], "<<tuple>>", .{}) catch unreachable,
        .code => std.fmt.bufPrint(buffer[0..], "<<code>>", .{}) catch unreachable,
    };
}

pub const None = Object{ .none = {} };
pub const False = Object{ .bool = false };
pub const True = Object{ .bool = true };
pub const Zero = Object{ .int = 0 };
pub const One = Object{ .int = 1 };
pub const Symbol = intern.Index;
pub const EmptyArray = Object{ .array = &[_]Object{} };
pub const EmptyTuple = Object{ .tuple = &[_]Object{} };
pub const EmptyString = Object{ .string = .{ .string = "" } };

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

pub const Code = struct {
    co_argcount: *const Object = &Zero,
    co_code: *const Object = &EmptyString,
    co_exceptiontable: *const Object = &EmptyString,
    co_firstlineno: *const Object = &One,
    co_freevars: *const Object = &EmptyTuple,
    co_lnotab: *const Object = &None, // Deprecated, use co_lines instead
    co_names: *const Object = &EmptyTuple,
    co_qualname: *const Object = &.{ .string = .{ .string = "<module>" } },
    co_varnames: *const Object = &EmptyTuple,
    co_cellvars: *const Object = &EmptyTuple,
    co_consts: *const Object = &EmptyTuple,
    co_filename: *const Object = &EmptyString,
    co_flags: *const Object = &Zero,
    co_kwonlyargcount: *const Object = &Zero,
    co_linetable: *const Object = &EmptyString,
    co_name: *const Object = &.{ .string = .{ .string = "<module>" } },
    co_nlocals: *const Object = &Zero,
    co_posonlyargcount: *const Object = &Zero,
    co_stacksize: *const Object = &One,

    // TODO: we're leaving the world of "python objects" here,
    //   at some point we'll need to reconcile that
    instructions: []const Instruction = &[_]Instruction{},

    // methods...
    // replace(,
    // co_positions(,
    // co_lines(,
};

// Not "objects", but children of them
const OpCode = @import("./bytecode/opcodes.zig").OpCode;
pub const Instruction = struct {
    opcode: OpCode,
    arg: ?u8,
    argval: Object,
    argrepr: ?[]const u8 = null,
    offset: u16,
    starts_line: ?u16,
    is_jump_target: bool,
    // TODO: positions
};
