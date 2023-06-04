const std = @import("std");
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const ir = @import("ir.zig");
const eval = @import("eval.zig");
const gen = @import("gen.zig");
const testing = std.testing;

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
    // Broke after zig 0.9.1 :(
    // testing.refAllDecls(@This());

    _ = lex;
    _ = parse;
    _ = ir;
    _ = eval;
    _ = gen;
}
