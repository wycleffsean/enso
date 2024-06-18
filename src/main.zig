const std = @import("std");
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const bytecode = @import("bytecode.zig");
const eval = @import("eval.zig");
const gen = @import("gen.zig");
const vm = @import("vm.zig");
const testing = std.testing;
const test_utils = @import("test/utils.zig");

const ReferenceCapabilities = enum {
    isolated,
    value,
    reference,
    box,
    transition,
    tag,
};

const Allocation = enum {
    stack,
    heap,
};

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});
}

test {
    try testing.expect(true);
    // Broke after zig 0.9.1 :(
    // testing.refAllDecls(@This());

    _ = test_utils;

    _ = lex;
    _ = parse;
    _ = bytecode;
    _ = eval;
    _ = gen;
    _ = vm;
    _ = @import("lex/lexer_test.zig");
    _ = @import("parse/grammar_test.zig");
}
