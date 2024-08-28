const std = @import("std");
const testing = std.testing;
const lex = @import("../lex.zig");
const test_examples = @import("../test/utils.zig").examples;

fn lexBuffer(buffer: []const u8) !void {
    var lexer = lex.Lexer{ .buffer = buffer };
    for (0..100000) |_| {
        _ = lexer.next() catch |err| {
            // std.debug.print("{s}\n", .{lex.test_err_message});
            return err;
        };
        // std.debug.print("tok: {any}\n", .{tok});
    }
    try testing.expect(false);
}

test "lex: example fixtures" {
    inline for (test_examples) |example| {
        if (!example.test_lex) continue;
        try testing.expectError(lex.Lexer.Error.eof, lexBuffer(example.source()));
        comptime {
            // this one takes some time :/
            if (example.test_lex_comptime) {
                @setEvalBranchQuota(1000000);
                try testing.expectError(lex.Lexer.Error.eof, lexBuffer(example.source()));
            }
        }
    }
}
