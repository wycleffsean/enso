const std = @import("std");
const testing = std.testing;
const Parser = @import("../parse.zig").Parser;

const test_grammar = @embedFile("../test/test_grammar.py");

test "parse pyfile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, test_grammar);
    _ = try parser.parse();
}
