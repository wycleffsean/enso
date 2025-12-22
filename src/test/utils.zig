const std = @import("std");
const dis_examples = @import("./disassembled_examples.zig");
const object = @import("../object.zig");

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

    pub fn code(comptime self: *const Self) *const object.Code {
        return self.dis().co;
    }

    pub fn stdout(comptime self: *const Self) []const u8 {
        return self.dis().captured_stdout;
    }
};

pub const examples = [_]Example{
    .{
        .name = "examples_none",
    },
    .{
        .name = "examples_hello_world",
    },
    .{
        .name = "examples_expressions",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "examples_builtin_functions",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_6_set_displays",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_7_dictionary_displays",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_11_boolean_operations",
        // the python compiler folds over these operations when using constants
        // so at this time we won't get the same results
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_13_conditional_expressions",
        // the python compiler folds over these operations when using constants
        // so at this time we won't get the same results
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_14_lambdas",
        .test_vm = false,
    },
    .{
        .name = "langref_8_7_function_definitions",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_8_3_for_statement",
        .test_vm = false,
    },
    // .{
    //     .name = "test_grammar",
    //     .test_parse = false,
    //     .test_bytecode = false,
    //     .test_vm = false,
    // },
};

test "lexing examples" {
    inline for (examples) |example| {
        _ = example.path();
        _ = example.source();
        _ = example.code().instructions;
    }
}
