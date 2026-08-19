const std = @import("std");
const VM = @import("../vm.zig").VM;
const Error = @import("../vm.zig").Error;
const object = @import("../object.zig");
const Object = object.Object;
const Callable = object.Callable;
const intern = @import("../intern.zig");

pub const Builtins = struct {
    const Self = @This();
    // const BuiltinsMap = std.AutoArrayHashMapUnmanaged(intern.Index, Callable);

    fn builtinPrint(vm: *VM, args: []Object) object.CallResult {
        for (args) |obj| {
            vm.stdout.writeAll(object.dStr(VM, vm, &obj)) catch unreachable;
        }
        return .{ .object = object.None };
    }

    fn builtinAbs(vm: *VM, args: []Object) object.CallResult {
        _ = vm;
        const arg = args[0];
        switch (arg) {
            .int => |int| {
                return .{ .object = Object{ .int = @intCast(@abs(int)) } };
            },
            .float => |int| {
                return .{ .object = Object{ .float = @abs(int) } };
            },
            .complex => |c| {
                return .{ .object = Object{ .float = @abs(c.magnitude()) } };
            },
            else => return .fail,
        }
    }

    const Item = struct { []const u8, Callable };

    const builtins = [_]Item{
        .{ "abs", builtinAbs },
        .{ "print", builtinPrint },
    };

    // builtins_buf: [Builtins.len]BuiltinsMap.Entry = undefined,
    // builtins: BuiltinsMap,

    pub fn fetchBuiltinFunction(funcname: []const u8) Error!Callable {
        for (builtins) |builtin| {
            const name, const func = builtin;
            if (std.mem.eql(u8, funcname, name)) return func;
        }
        return Error.NameError;
    }
};
