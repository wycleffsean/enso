const std = @import("std");
const dis_examples = @import("./disassembled_examples.zig");

const Example = struct {
    name: []const u8,
    test_lex: bool = true,
    test_parse: bool = true,
    test_dis: bool = false,

    const Self = @This();

    pub fn path(self: *const Self) []const u8 {
        return dis_examples.examples.get(self.name).?.path;
    }

    pub fn source(self: *const Self) []const u8 {
        return dis_examples.examples.get(self.name).?.source;
    }

    pub fn instructions(self: *const Self) []const dis_examples.Instruction {
        return dis_examples.examples.get(self.name).?.instructions;
    }
};

pub const examples = [_]Example{
    .{
        .name = "hello_world",
        .test_parse = false,
    },
};

test "lexing examples" {
    inline for (examples) |example| {
        _ = example.path();
        _ = example.source();
        _ = example.instructions();
    }
}
