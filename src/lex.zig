const std = @import("std");
const bufferedReader = std.io.bufferedReader;
const StreamSource = std.io.StreamSource;

const testing = std.testing;
const fixedBufferStream = std.io.fixedBufferStream;

const LineLength = u32;
const ColLength = u32;

const TokenTag = enum {
    EOF,
    LPAREN,
    RPAREN,
    SYMBOL,
    //STRING,
    COLON,
    COMMA,
    PLUS,
    MINUS,
    ASTERISK,
    SOLIDUS,
    LESS,
    GREATER,
    EQUAL,
    BANG,
    LSBRACKET,
    RSBRACKET,
    LCBRACKET,
    RCBRACKET,
    //INTEGER,
};

const Location = struct { line: LineLength, col: ColLength };

const Token = union(TokenTag) {
    EOF: Location,
    LPAREN: Location,
    RPAREN: Location,
    SYMBOL: struct { name: []const u8, begin: Location, end: Location },
    COLON: Location,
    COMMA: Location,
    PLUS: Location,
    MINUS: Location,
    ASTERISK: Location,
    SOLIDUS: Location,
    LESS: Location,
    GREATER: Location,
    EQUAL: Location,
    BANG: Location,
    LSBRACKET: Location,
    RSBRACKET: Location,
    LCBRACKET: Location,
    RCBRACKET: Location,
};

const Lexer = struct {
    reader: std.io.BufferedReader(4096, StreamSource.Reader).Reader,
    curr: ?u8 = null,
    prior: ?u8 = null,
    col: ColLength = 0,
    line: LineLength = 1, // 1 indexed, latent increment col = 0 # 1 indexed, immediate increment
    indent: u32 = 0, // 0 indexed, immediate increment
    internbuf: [16384]u8 = undefined,
    const Self = @This();

    const Error = error{
        BadToken,
        EOF,
    };

    fn peek(self: *Self) Error!u8 {
        if (self.curr) |curr| {
            return curr;
        }

        const byte = self.reader.readByte() catch return Error.EOF;
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

    fn readChars(self: *Self, buf: []const u8) Error!void {
        var i: u8 = 1;
        while (i < buf.len) : (i += 1) {
            const byte = try self.peek();
            switch (byte) {
                'A'...'Z', 'a'...'z' => {
                    buf[i] = try self.take();
                },
                else => return,
            }
        }
    }

    pub fn next(self: *Self) Error!Token {
        const byte = self.take() catch return Token{ .EOF = self.location() };
        switch (byte) {
            // whitespace
            '\n', '\t', ' ' => return self.next(),
            // brackets and operators
            '(' => return Token{ .LPAREN = self.location() },
            ')' => return Token{ .RPAREN = self.location() },
            ':' => return Token{ .COLON = self.location() },
            ',' => return Token{ .COMMA = self.location() },
            '+' => return Token{ .PLUS = self.location() },
            '-' => return Token{ .MINUS = self.location() },
            '*' => return Token{ .ASTERISK = self.location() },
            '/' => return Token{ .SOLIDUS = self.location() },
            '<' => return Token{ .LESS = self.location() },
            '>' => return Token{ .GREATER = self.location() },
            '=' => return Token{ .EQUAL = self.location() },
            '!' => return Token{ .BANG = self.location() },
            '[' => return Token{ .LSBRACKET = self.location() },
            ']' => return Token{ .RSBRACKET = self.location() },
            '{' => return Token{ .LCBRACKET = self.location() },
            '}' => return Token{ .RCBRACKET = self.location() },
            'A'...'Z', 'a'...'z' => {
                const begin = self.location();
                var tok = Token{ .SYMBOL = .{ .name = undefined, .begin = begin, .end = self.location() } };
                tok.SYMBOL.name[0] = byte;
                try self.readChars(&tok.SYMBOL.name);
                return tok;
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
    const buf = "F";
    var stream = StreamSource{ .const_buffer = fixedBufferStream(buf[0..]) };
    var lex = Lexer{ .reader = bufferedReader(stream.reader()).reader() };
    try testing.expectEqual(lex.curr, null);
    try testing.expectEqual(lex.col, 0);
    const x = lex.peek();
    try testing.expectEqual(x, 'F');
    try testing.expectEqual(lex.curr, 'F');
    try testing.expectEqual(lex.col, 0);
}

test "take" {
    const buf = "F";
    var stream = StreamSource{ .const_buffer = fixedBufferStream(buf[0..]) };
    var lex = Lexer{ .reader = bufferedReader(stream.reader()).reader() };
    try testing.expectEqual(lex.col, 0);
    try testing.expectEqual(lex.take(), 'F');
    try testing.expectEqual(lex.curr, null);
    try testing.expectEqual(lex.prior, 'F');
    try testing.expectEqual(lex.col, 1);
}

test "parens" {
    const buf = "()";
    var stream = StreamSource{ .const_buffer = fixedBufferStream(buf[0..]) };
    var lex = Lexer{ .reader = bufferedReader(stream.reader()).reader() };
    try testing.expectEqual(lex.next(), .{ .LPAREN = .{ .line = 1, .col = 1 } });
    try testing.expectEqual(lex.next(), .{ .RPAREN = .{ .line = 1, .col = 2 } });
}

test "operators" {
    const buf = ":,+-*/<>=![]{}";
    var stream = StreamSource{ .const_buffer = fixedBufferStream(buf[0..]) };
    var lex = Lexer{ .reader = bufferedReader(stream.reader()).reader() };
    try testing.expectEqual(lex.next(), .{ .COLON = .{ .line = 1, .col = 1 } });
    try testing.expectEqual(lex.next(), .{ .COMMA = .{ .line = 1, .col = 2 } });
    try testing.expectEqual(lex.next(), .{ .PLUS = .{ .line = 1, .col = 3 } });
    try testing.expectEqual(lex.next(), .{ .MINUS = .{ .line = 1, .col = 4 } });
    try testing.expectEqual(lex.next(), .{ .ASTERISK = .{ .line = 1, .col = 5 } });
    try testing.expectEqual(lex.next(), .{ .SOLIDUS = .{ .line = 1, .col = 6 } });
    try testing.expectEqual(lex.next(), .{ .LESS = .{ .line = 1, .col = 7 } });
    try testing.expectEqual(lex.next(), .{ .GREATER = .{ .line = 1, .col = 8 } });
    try testing.expectEqual(lex.next(), .{ .EQUAL = .{ .line = 1, .col = 9 } });
    try testing.expectEqual(lex.next(), .{ .BANG = .{ .line = 1, .col = 10 } });
    try testing.expectEqual(lex.next(), .{ .LSBRACKET = .{ .line = 1, .col = 11 } });
    try testing.expectEqual(lex.next(), .{ .RSBRACKET = .{ .line = 1, .col = 12 } });
    try testing.expectEqual(lex.next(), .{ .LCBRACKET = .{ .line = 1, .col = 13 } });
    try testing.expectEqual(lex.next(), .{ .RCBRACKET = .{ .line = 1, .col = 14 } });
}

test "whitespace ignored" {
    const buf = " \t\n";
    var stream = StreamSource{ .const_buffer = fixedBufferStream(buf[0..]) };
    var lex = Lexer{ .reader = bufferedReader(stream.reader()).reader() };
    try testing.expectEqual(lex.next(), .{ .EOF = .{ .line = 1, .col = 3 } });
}

test "symbol" {
    const buf = "thing ";
    var stream = StreamSource{ .const_buffer = fixedBufferStream(buf[0..]) };
    var lex = Lexer{ .reader = bufferedReader(stream.reader()).reader() };
    // TODO
    var name = "thing";
    try testing.expectEqual(lex.next(), .{ .SYMBOL = .{ .name = name, .begin = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 5 } } });
}
