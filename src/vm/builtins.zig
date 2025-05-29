const std = @import("std");
const VM = @import("../vm.zig").VM;
const object = @import("../object.zig");
const Object = object.Object;
const Callable = object.Callable;
const intern = @import("../bytecode/intern.zig");

const Self = @This();
// const BuiltinsMap = std.AutoArrayHashMapUnmanaged(intern.Index, Callable);

fn builtinPrint(vm: *VM, args: []Object) object.CallResult {
    for (args) |obj| {
        vm.stdout.writeAll(vm.getString(obj)) catch unreachable;
    }
    return .{ .object = object.None };
}

const Item = struct { []const u8, Callable };

const Builtins = [_]Item{
    .{ "print", builtinPrint },
};

// builtins_buf: [Builtins.len]BuiltinsMap.Entry = undefined,
// builtins: BuiltinsMap,

pub fn fetchBuiltinFunction(funcname: []const u8) VM.Error!Callable {
    for (Builtins) |builtin| {
        const name, const func = builtin;
        if (std.mem.eql(u8, funcname, name)) return func;
    }
    return VM.Error.NameError;
}
