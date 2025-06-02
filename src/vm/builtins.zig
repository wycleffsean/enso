const std = @import("std");
const Error = @import("../vm.zig").Error;
const object = @import("../object.zig");
const Object = object.Object;
const intern = @import("../bytecode/intern.zig");

pub fn Builtins(VMType: type) type {
    return struct {
        const Self = @This();
        const Callable = object.Callable(VMType);
        // const BuiltinsMap = std.AutoArrayHashMapUnmanaged(intern.Index, Callable);

        fn builtinPrint(vm: *VMType, args: []Object) object.CallResult {
            for (args) |obj| {
                vm.stdout.writeAll(object.dStr(VMType, vm, &obj)) catch unreachable;
            }
            return .{ .object = object.None };
        }

        fn builtinAbs(vm: *VMType, args: []Object) object.CallResult {
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
}
