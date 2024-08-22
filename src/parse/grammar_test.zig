const std = @import("std");
const testing = std.testing;
const Parser = @import("../parse.zig").Parser;
const lex = @import("../lex.zig");

const test_grammar = @embedFile("../test/examples/test_grammar.py");

test "parse: full python grammar" {
    if (true) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, test_grammar);
    _ = try parser.parse();
}
