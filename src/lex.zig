const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;
const ascii = std.ascii;
const fixedBufferStream = std.io.fixedBufferStream;

var test_logger_buf: [std.mem.page_size / 4]u8 = undefined;
var test_err_message: []u8 = undefined;

const TestLogger = struct {
    fn err(self: *const TestLogger, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        test_err_message = std.fmt.bufPrint(&test_logger_buf, fmt, args) catch unreachable;
    }
};

const log = if (builtin.is_test)
    TestLogger{}
else
    std.log.scoped(.lex);

const LineLength = u32;
const ColLength = u32;
pub const IndentLength = u32;

const TokenTag = enum {
    eof,
    name,
    integer,
    //STRING,
    docstring,
    dot,
    colon,
    comma,
    pipe,
    plus,
    minus,
    asterisk,
    solidus,
    less,
    greater,
    assign,
    bang,
    lparen,
    rparen,
    lsbracket,
    rsbracket,
    lcbracket,
    rcbracket,
    var_kw,
    def_kw,
};

const Location = struct { indent: IndentLength = 0, line: LineLength, col: ColLength };
const Bare = struct { loc: Location };
const Identifier = struct {
    value: []const u8,
    loc: Location,

    pub fn format(self: Identifier, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt; // actual_fmt i.e. any, or whatever
        try std.fmt.formatBuf(self.value, options, writer);
    }
};

pub const Token = union(TokenTag) {
    eof: Bare,
    lparen: Bare,
    rparen: Bare,
    name: Identifier,
    integer: Identifier,
    docstring: Identifier,
    dot: Bare,
    colon: Bare,
    comma: Bare,
    pipe: Bare,
    plus: Bare,
    minus: Bare,
    asterisk: Bare,
    solidus: Bare,
    less: Bare,
    greater: Bare,
    assign: Bare,
    bang: Bare,
    lsbracket: Bare,
    rsbracket: Bare,
    lcbracket: Bare,
    rcbracket: Bare,
    var_kw: Bare,
    def_kw: Bare,

    // this is really smelly
    pub inline fn getLocation(self: *const Token) Location {
        return switch (self.*) {
            .eof => self.eof.loc,
            .lparen => self.lparen.loc,
            .rparen => self.rparen.loc,
            .name => self.name.loc,
            .integer => self.integer.loc,
            .docstring => self.docstring.loc,
            .dot => self.dot.loc,
            .colon => self.colon.loc,
            .comma => self.comma.loc,
            .pipe => self.pipe.loc,
            .plus => self.plus.loc,
            .minus => self.minus.loc,
            .asterisk => self.asterisk.loc,
            .solidus => self.solidus.loc,
            .less => self.less.loc,
            .greater => self.greater.loc,
            .assign => self.assign.loc,
            .bang => self.bang.loc,
            .lsbracket => self.lsbracket.loc,
            .rsbracket => self.rsbracket.loc,
            .lcbracket => self.lcbracket.loc,
            .rcbracket => self.rcbracket.loc,
            .var_kw => self.var_kw.loc,
            .def_kw => self.def_kw.loc,
        };
    }

    // pub fn format(value: Token, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {

    // }

};

pub const Lexer = struct {
    buffer: []const u8,
    index: usize = 0,
    curr: ?u8 = null,
    prior: ?u8 = null,
    col: ColLength = 0,
    line: LineLength = 1, // 1 indexed, latent increment col = 0 # 1 indexed, immediate increment
    indent: u32 = 0, // 0 indexed, immediate increment
    const Self = @This();

    pub const Error = error{
        BadToken,
        SyntaxError,
        eof,
    };

    fn peek(self: *Self) ?u8 {
        if (self.curr) |curr| {
            return curr;
        }

        if (self.index >= self.buffer.len) {
            return null;
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
        var byte = self.peek() orelse return Error.eof;
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

    fn takeIndents(self: *Self) Error!void {
        self.indent = 0;
        while ((self.peek() orelse 0) == '\t') {
            self.indent += 1;
            _ = try self.take();
        }
    }

    fn location(self: *Self) Location {
        return .{ .indent = self.indent, .line = self.line, .col = self.col };
    }

    fn bare(self: *Self) Bare {
        return .{ .loc = self.location() };
    }

    fn readWhileAlpha(self: *Self) Error!void {
        while (true) {
            const byte = self.peek() orelse return;
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
            const byte = self.peek() orelse return;
            switch (byte) {
                '0'...'9' => {
                    _ = try self.take();
                },
                else => return,
            }
        }
    }

    fn matchExact(self: *Self, comptime needle: []const u8) bool {
        // backup one space because we already took the first value of the needle
        const start = self.index - 1;
        const end = start + needle.len;
        if (end > self.buffer.len) return false;
        if (std.mem.eql(u8, needle, self.buffer[start..end])) {
            comptime var i = needle.len - 1;
            inline while (i > 0) : (i -= 1) {
                _ = self.take() catch unreachable;
            }
            return true;
        }
        return false;
    }

    fn matchExactTerminatedByWhitspace(self: *Self, comptime needle: []const u8) bool {
        if (!self.matchExact(needle)) return false;
        if (self.peek()) |byte| {
            switch (byte) {
                '\n', '\t', ' ' => {},
                else => return false,
            }
        }
        return true;
    }

    fn matchKeyword(self: *Self, comptime tag: TokenTag, comptime needle: []const u8) ?Token {
        if (self.matchExactTerminatedByWhitspace(needle)) {
            return @unionInit(Token, @tagName(tag), self.bare());
        }
        return null;
    }

    fn readKeyword(self: *Self) ?Token {
        if (self.matchKeyword(.var_kw, "var") orelse self.matchKeyword(.def_kw, "def")) |token| {
            return token;
        }
        return null;
    }

    pub fn next(self: *Self) Error!Token {
        const byte = self.take() catch return Token{ .eof = self.bare() };
        switch (byte) {
            // whitespace
            '\n' => {
                try self.takeIndents();
                return self.next();
            },
            '\t', ' ' => return self.next(),
            // brackets and operators
            '(' => return Token{ .lparen = self.bare() },
            ')' => return Token{ .rparen = self.bare() },
            '.' => return Token{ .dot = self.bare() },
            ':' => return Token{ .colon = self.bare() },
            ',' => return Token{ .comma = self.bare() },
            '|' => return Token{ .pipe = self.bare() },
            '+' => return Token{ .plus = self.bare() },
            '-' => return Token{ .minus = self.bare() },
            '*' => return Token{ .asterisk = self.bare() },
            '/' => return Token{ .solidus = self.bare() },
            '<' => return Token{ .less = self.bare() },
            '>' => return Token{ .greater = self.bare() },
            '=' => return Token{ .assign = self.bare() },
            '!' => return Token{ .bang = self.bare() },
            '[' => return Token{ .lsbracket = self.bare() },
            ']' => return Token{ .rsbracket = self.bare() },
            '{' => return Token{ .lcbracket = self.bare() },
            '}' => return Token{ .rcbracket = self.bare() },
            '"' => {
                if (self.matchExact("\"\"\"")) return self.nextDocstring();
                log.err("BadToken: double quotes not supported yet", .{});
                return Error.BadToken;
            },
            'A'...'Z', 'a'...'z' => {
                if (self.readKeyword()) |kw| {
                    return kw;
                }
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
            else => {
                const rest_of_line = std.mem.sliceTo(self.buffer[self.index - 1 ..], '\n');
                log.err("BadToken: '{s}' (line {d})", .{ rest_of_line, self.location().line });
                return Error.BadToken;
            },
        }
    }

    pub fn nextDocstring(self: *Self) Error!Token {
        const start = self.index;
        const loc = self.location();
        while (true) {
            const byte = self.peek() orelse {
                log.err("SyntaxError: unterminated triple-quoted string literal (detected at line {d})", .{self.location().line});
                return Error.SyntaxError;
            };
            switch (byte) {
                '"' => {
                    if (self.matchExact("\"\"\"")) {
                        return Token{ .docstring = .{ .value = self.buffer[start .. self.index - 3], .loc = loc } };
                    } else {
                        _ = try self.take();
                    }
                },
                else => {
                    _ = try self.take();
                },
            }
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

test "indents" {
    // taken from py lexer, with comment -> # TODO: a bit wrong :/
    var lex = Lexer{ .buffer = "\t+\n\t\t+\n\t\t\t+\n" };
    try testing.expectEqual(lex.next(), .{ .plus = .{ .loc = .{ .indent = 0, .line = 1, .col = 2 } } });
    try testing.expectEqual(lex.next(), .{ .plus = .{ .loc = .{ .indent = 2, .line = 2, .col = 2 } } });
    try testing.expectEqual(lex.next(), .{ .plus = .{ .loc = .{ .indent = 3, .line = 3, .col = 3 } } });
    try testing.expectEqual(lex.next(), .{ .eof = .{ .loc = .{ .indent = 0, .line = 3, .col = 4 } } });
}

test "parens" {
    var lex = Lexer{ .buffer = "()" };
    try testing.expectEqual(lex.next(), .{ .lparen = .{ .loc = .{ .line = 1, .col = 1 } } });
    try testing.expectEqual(lex.next(), .{ .rparen = .{ .loc = .{ .line = 1, .col = 2 } } });
}

test "operators" {
    var lex = Lexer{ .buffer = ":,+-*/<>=![]{}|" };
    try testing.expectEqual(lex.next(), .{ .colon = .{ .loc = .{ .line = 1, .col = 1 } } });
    try testing.expectEqual(lex.next(), .{ .comma = .{ .loc = .{ .line = 1, .col = 2 } } });
    try testing.expectEqual(lex.next(), .{ .plus = .{ .loc = .{ .line = 1, .col = 3 } } });
    try testing.expectEqual(lex.next(), .{ .minus = .{ .loc = .{ .line = 1, .col = 4 } } });
    try testing.expectEqual(lex.next(), .{ .asterisk = .{ .loc = .{ .line = 1, .col = 5 } } });
    try testing.expectEqual(lex.next(), .{ .solidus = .{ .loc = .{ .line = 1, .col = 6 } } });
    try testing.expectEqual(lex.next(), .{ .less = .{ .loc = .{ .line = 1, .col = 7 } } });
    try testing.expectEqual(lex.next(), .{ .greater = .{ .loc = .{ .line = 1, .col = 8 } } });
    try testing.expectEqual(lex.next(), .{ .assign = .{ .loc = .{ .line = 1, .col = 9 } } });
    try testing.expectEqual(lex.next(), .{ .bang = .{ .loc = .{ .line = 1, .col = 10 } } });
    try testing.expectEqual(lex.next(), .{ .lsbracket = .{ .loc = .{ .line = 1, .col = 11 } } });
    try testing.expectEqual(lex.next(), .{ .rsbracket = .{ .loc = .{ .line = 1, .col = 12 } } });
    try testing.expectEqual(lex.next(), .{ .lcbracket = .{ .loc = .{ .line = 1, .col = 13 } } });
    try testing.expectEqual(lex.next(), .{ .rcbracket = .{ .loc = .{ .line = 1, .col = 14 } } });
    try testing.expectEqual(lex.next(), .{ .pipe = .{ .loc = .{ .line = 1, .col = 15 } } });
}

test "whitespace ignored" {
    var lex = Lexer{ .buffer = " \t\n" };
    try testing.expectEqual(lex.next(), .{ .eof = .{ .loc = .{ .line = 1, .col = 3 } } });
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

// keywords

test "var kw" {
    {
        var lex = Lexer{ .buffer = "var" };
        const next = try lex.next();
        try testing.expect(next == .var_kw);
    }
    {
        var lex = Lexer{ .buffer = "var " };
        const next = try lex.next();
        try testing.expect(next == .var_kw);
    }
    {
        var lex = Lexer{ .buffer = "var\t" };
        const next = try lex.next();
        try testing.expect(next == .var_kw);
    }
    {
        var lex = Lexer{ .buffer = "vars" };
        const next = try lex.next();
        try testing.expect(next != .var_kw);
    }
}

test "def kw" {
    {
        var lex = Lexer{ .buffer = "def" };
        const next = try lex.next();
        try testing.expect(next == .def_kw);
    }
    {
        var lex = Lexer{ .buffer = "def " };
        const next = try lex.next();
        try testing.expect(next == .def_kw);
    }
    {
        var lex = Lexer{ .buffer = "def\t" };
        const next = try lex.next();
        try testing.expect(next == .def_kw);
    }
    {
        var lex = Lexer{ .buffer = "defs" };
        const next = try lex.next();
        try testing.expect(next != .def_kw);
    }
}

test "triple quote" {
    {
        const doc =
            \\"""The quick
            \\brown fox jumps over the lazy dog
            \\"""
        ;
        var lex = Lexer{ .buffer = doc };
        const next = try lex.next();
        try testing.expect(next == .docstring);
        try testing.expectEqualSlices(u8, "The quick\nbrown fox jumps over the lazy dog\n", next.docstring.value);
    }
    {
        const doc =
            \\"""The quick
            \\brown fox jumps over the lazy dog
        ;
        var lex = Lexer{ .buffer = doc };
        try testing.expectError(Lexer.Error.SyntaxError, lex.next());
        try testing.expectEqualSlices(u8, "SyntaxError: unterminated triple-quoted string literal (detected at line 2)", test_err_message);
    }
}
