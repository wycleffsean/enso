const std = @import("std");
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const bytecode = @import("bytecode.zig");
const eval = @import("eval.zig");
const gen = @import("gen.zig");
const testing = std.testing;
const dis_examples = @import("test/disassembled_examples.zig");

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

    _ = dis_examples.basic;

    _ = lex;
    _ = parse;
    _ = bytecode;
    _ = eval;
    _ = gen;
    _ = @import("lex/lexer_test.zig");
    _ = @import("parse/grammar_test.zig");
}
