const std = @import("std");
const dis_examples = @import("./disassembled_examples.zig");

pub const PyArgVal = dis_examples.PyArgVal;

const Example = struct {
    name: []const u8,
    comptime test_lex: bool = true,
    comptime test_parse: bool = true,
    comptime test_bytecode: bool = true,
    comptime test_vm: bool = true,
    comptime test_vm_comptime: bool = false,

    const Self = @This();

    pub fn dis(comptime self: *const Self) dis_examples.Example {
        return dis_examples.examples.get(self.name).?;
    }

    pub fn path(comptime self: *const Self) []const u8 {
        return self.dis().path;
    }

    pub fn source(comptime self: *const Self) []const u8 {
        return self.dis().source;
    }

    pub fn instructions(comptime self: *const Self) []const dis_examples.Instruction {
        return self.dis().instructions;
    }
};

pub const examples = [_]Example{
    .{
        .name = "none",
    },
    .{
        .name = "hello_world",
    },
};

test "lexing examples" {
    inline for (examples) |example| {
        _ = example.path();
        _ = example.source();
        _ = example.instructions();
    }
}
