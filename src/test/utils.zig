const std = @import("std");
const dis_examples = @import("./disassembled_examples.zig");

pub const PyArgVal = dis_examples.PyArgVal;

pub const Example = struct {
    name: []const u8,
    test_lex: bool = true,
    test_lex_comptime: bool = false,
    test_parse: bool = true,
    test_bytecode: bool = true,
    test_vm: bool = true,
    test_vm_comptime: bool = false,

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

    pub fn stdout(comptime self: *const Self) []const u8 {
        return self.dis().captured_stdout;
    }
};

pub const examples = [_]Example{
    .{
        .name = "none",
    },
    .{
        .name = "hello_world",
    },
    .{
        .name = "test_grammar",
        .test_parse = false,
        .test_bytecode = false,
        .test_vm = false,
    },
};

test "lexing examples" {
    inline for (examples) |example| {
        _ = example.path();
        _ = example.source();
        _ = example.instructions();
    }
}
