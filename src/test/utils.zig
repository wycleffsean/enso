const std = @import("std");
const dis_examples = @import("disassembled_examples");
const object = @import("../object.zig");

const parse = @import("../parse.zig");
const intern = @import("../bytecode/intern.zig");
const bytecode = @import("../bytecode.zig");
const ssa = @import("../ssa.zig");
pub const CompilerHarness = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    intern_pool: intern.StringInternPool,
    module: bytecode.Module,

    const Self = @This();
    const ParseError = parse.Parser.Error;
    const ParseOrIRGenError = ParseError || bytecode.Module.Builder.Error;

    pub fn create(base_allocator: std.mem.Allocator) !*Self {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        var ptr = try arena.allocator().create(Self);
        ptr.arena = arena;
        ptr.allocator = ptr.arena.allocator();
        ptr.intern_pool = intern.StringInternPool.init(ptr.allocator);
        return ptr;
    }

    pub fn deinit(self: *Self) void {
        self.intern_pool.deinit();
        self.arena.deinit();
    }

    pub fn doParse(self: *Self, code: []const u8) ParseError!*const parse.AstNode {
        var parser = parse.Parser.init(self.allocator, code);
        return parser.parse() catch |err| {
            parse.highlightSource("<<test>>", code, parser.peeked);
            return err;
        };
    }

    pub fn buildCodeObjects(self: *Self, code: []const u8) ParseOrIRGenError!bytecode.CodeObject {
        const ast = try self.doParse(code);
        self.module = try bytecode.Module.build(
            self.allocator,
            &self.intern_pool,
            ast,
        );
        return self.module.codeobject_store.get(0);
    }

    pub fn doSsa(self: *Self, code: []const u8) ParseOrIRGenError!ssa.SsaGraph {
        const co = try self.buildCodeObjects(code);
        return ssa.SsaBuilder.generate(self.allocator, co);
    }
};

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
        .name = "langref_6_2_2_1_string_literal_concatenation",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_5_list_displays",
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
        .name = "langref_6_2_8_generator_expressions",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_9_yield_expressions",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_3_4_calls",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_4_await_expression",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_10_comparisons",
        // the python compiler folds over these operations when using constants
        // so at this time we won't get the same results
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
