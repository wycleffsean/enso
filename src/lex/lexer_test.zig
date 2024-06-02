const std = @import("std");
const testing = std.testing;
const lex = @import("../lex.zig");

const test_grammar = @embedFile("../test/test_grammar.py");

fn lexBuffer(buffer: []const u8) !void {
    var lexer = lex.Lexer{ .buffer = buffer };
    for (0..100000) |_| {
        _ = lexer.next() catch |err| {
            std.debug.print("{s}\n", .{lex.test_err_message});
            return err;
        };
        // std.debug.print("tok: {any}\n", .{tok});
    }
    try testing.expect(false);
}

test "lex: pyfile" {
    try testing.expectError(lex.Lexer.Error.eof, lexBuffer(test_grammar));
}
