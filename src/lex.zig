const std = @import("std");

const testing = std.testing;
const fixedBufferStream = std.io.fixedBufferStream;

const LineLength = u32;
const ColLength = u32;

const TokenTag = enum {
    eof,
    name,
    integer,
    //STRING,
    colon,
    comma,
    pipe,
    plus,
    minus,
    asterisk,
    solidus,
    less,
    greater,
    equal,
    bang,
    lparen,
    rparen,
    lsbracket,
    rsbracket,
    lcbracket,
    rcbracket,
};

const Location = struct { line: LineLength, col: ColLength };

pub const Token = union(TokenTag) {
    eof: Location,
    lparen: Location,
    rparen: Location,
    name: struct { value: []const u8, loc: Location },
    integer: struct { value: []const u8, loc: Location },
    colon: Location,
    comma: Location,
    pipe: Location,
    plus: Location,
    minus: Location,
    asterisk: Location,
    solidus: Location,
    less: Location,
    greater: Location,
    equal: Location,
    bang: Location,
    lsbracket: Location,
    rsbracket: Location,
    lcbracket: Location,
    rcbracket: Location,
};

pub const Lexer = struct {
    buffer: []const u8,
    index: usize = 0,
    curr: ?u8 = null,
    prior: ?u8 = null,
    col: ColLength = 0,
    line: LineLength = 1, // 1 indexed, latent increment col = 0 # 1 indexed, immediate increment
    //indent: u32 = 0, // 0 indexed, immediate increment
    const Self = @This();

    pub const Error = error{
        BadToken,
        eof,
    };

    fn peek(self: *Self) Error!u8 {
        if (self.curr) |curr| {
            return curr;
        }

        if (self.index >= self.buffer.len) {
            return Error.eof;
        }

        const byte = self.buffer[self.index];
        self.curr = byte;
        return byte;
    }

    fn is(val: ?u8, comptime lit: u8) bool {
        if (val) |value| {
            return value == lit;
        }
        return false;
    }

    fn take(self: *Self) Error!u8 {
        var byte = try self.peek();
        self.index += 1;
        if (is(self.prior, '\n')) {
            self.line += 1;
            self.col = 0;
        } else {
            self.col += 1;
        }
        self.prior = self.curr;
        self.curr = null;
        return byte;
    }

    fn location(self: Self) Location {
        return .{ .line = self.line, .col = self.col };
    }

    fn readWhileAlpha(self: *Self) Error!void {
        while (true) {
            const byte = self.peek() catch return;
            switch (byte) {
                'A'...'Z', 'a'...'z' => {
                    _ = try self.take();
                },
                else => return,
            }
        }
    }

    fn readWhileNumeric(self: *Self) Error!void {
        while (true) {
            const byte = self.peek() catch return;
            switch (byte) {
                '0'...'9' => {
                    _ = try self.take();
                },
                else => return,
            }
        }
    }

    pub fn next(self: *Self) Error!Token {
        const byte = self.take() catch return Token{ .eof = self.location() };
        switch (byte) {
            // whitespace
            '\n', '\t', ' ' => return self.next(),
            // brackets and operators
            '(' => return Token{ .lparen = self.location() },
            ')' => return Token{ .rparen = self.location() },
            ':' => return Token{ .colon = self.location() },
            ',' => return Token{ .comma = self.location() },
            '|' => return Token{ .pipe = self.location() },
            '+' => return Token{ .plus = self.location() },
            '-' => return Token{ .minus = self.location() },
            '*' => return Token{ .asterisk = self.location() },
            '/' => return Token{ .solidus = self.location() },
            '<' => return Token{ .less = self.location() },
            '>' => return Token{ .greater = self.location() },
            '=' => return Token{ .equal = self.location() },
            '!' => return Token{ .bang = self.location() },
            '[' => return Token{ .lsbracket = self.location() },
            ']' => return Token{ .rsbracket = self.location() },
            '{' => return Token{ .lcbracket = self.location() },
            '}' => return Token{ .rcbracket = self.location() },
            'A'...'Z', 'a'...'z' => {
                const loc = self.location();
                const start = self.index - 1;
                try self.readWhileAlpha();
                return Token{ .name = .{ .value = self.buffer[start..self.index], .loc = loc } };
            },
            '1'...'9' => {
                const loc = self.location();
                const start = self.index - 1;
                try self.readWhileNumeric();
                return Token{ .integer = .{ .value = self.buffer[start..self.index], .loc = loc } };
            },
            else => return Error.BadToken,
        }
    }
};

//pub fn lexer(stream: *StreamSource) Lexer {
//    return .{ .reader = bufferedReader(stream.reader()).reader() };
//}

//fn testStream(buf: []const u8) StreamSource {
//    return StreamSource{ .const_buffer = fixedBufferStream(buf[0..]) };
//}

test "peek" {
    var lex = Lexer{ .buffer = "F" };
    try testing.expectEqual(lex.curr, null);
    try testing.expectEqual(lex.col, 0);
    const x = lex.peek();
    try testing.expectEqual(x, 'F');
    try testing.expectEqual(lex.curr, 'F');
    try testing.expectEqual(lex.col, 0);
}

test "take" {
    var lex = Lexer{ .buffer = "F" };
    try testing.expectEqual(lex.col, 0);
    try testing.expectEqual(lex.take(), 'F');
    try testing.expectEqual(lex.curr, null);
    try testing.expectEqual(lex.prior, 'F');
    try testing.expectEqual(lex.col, 1);
}

test "parens" {
    var lex = Lexer{ .buffer = "()" };
    try testing.expectEqual(lex.next(), .{ .lparen = .{ .line = 1, .col = 1 } });
    try testing.expectEqual(lex.next(), .{ .rparen = .{ .line = 1, .col = 2 } });
}

test "operators" {
    var lex = Lexer{ .buffer = ":,+-*/<>=![]{}|" };
    try testing.expectEqual(lex.next(), .{ .colon = .{ .line = 1, .col = 1 } });
    try testing.expectEqual(lex.next(), .{ .comma = .{ .line = 1, .col = 2 } });
    try testing.expectEqual(lex.next(), .{ .plus = .{ .line = 1, .col = 3 } });
    try testing.expectEqual(lex.next(), .{ .minus = .{ .line = 1, .col = 4 } });
    try testing.expectEqual(lex.next(), .{ .asterisk = .{ .line = 1, .col = 5 } });
    try testing.expectEqual(lex.next(), .{ .solidus = .{ .line = 1, .col = 6 } });
    try testing.expectEqual(lex.next(), .{ .less = .{ .line = 1, .col = 7 } });
    try testing.expectEqual(lex.next(), .{ .greater = .{ .line = 1, .col = 8 } });
    try testing.expectEqual(lex.next(), .{ .equal = .{ .line = 1, .col = 9 } });
    try testing.expectEqual(lex.next(), .{ .bang = .{ .line = 1, .col = 10 } });
    try testing.expectEqual(lex.next(), .{ .lsbracket = .{ .line = 1, .col = 11 } });
    try testing.expectEqual(lex.next(), .{ .rsbracket = .{ .line = 1, .col = 12 } });
    try testing.expectEqual(lex.next(), .{ .lcbracket = .{ .line = 1, .col = 13 } });
    try testing.expectEqual(lex.next(), .{ .rcbracket = .{ .line = 1, .col = 14 } });
    try testing.expectEqual(lex.next(), .{ .pipe = .{ .line = 1, .col = 15 } });
}

test "whitespace ignored" {
    var lex = Lexer{ .buffer = " \t\n" };
    try testing.expectEqual(lex.next(), .{ .eof = .{ .line = 1, .col = 3 } });
}

test "name" {
    var lex = Lexer{ .buffer = "thing " };
    var value = "thing";
    const next = try lex.next();
    try testing.expectEqualSlices(u8, value, next.name.value);
    try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.name.loc);
}

test "integer" {
    {
        var value = "987654321";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.integer.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.integer.loc);
    }
    {
        var value = "0123";
        var lex = Lexer{ .buffer = value };
        try testing.expectError(error.BadToken, lex.next());
    }
}
