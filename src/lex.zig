const std = @import("std");
const builtin = @import("builtin");
const test_examples = @import("test/utils.zig").examples;

const testing = std.testing;
const ascii = std.ascii;
const fixedBufferStream = std.io.fixedBufferStream;

// https://docs.python.org/3/reference/lexical_analysis.html#identifiers

var test_logger_buf: [std.heap.page_size_min / 4]u8 = undefined;
pub var test_err_message: []u8 = undefined;

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

pub const TokenTag = enum {
    eof,
    lparen,
    rparen,
    name,
    at,
    integer,
    float,
    imaginary,
    string,
    dot,
    colon,
    comma,
    pipe,
    plus,
    minus,
    asterisk,
    double_asterisk,
    solidus,
    double_solidus,
    percent,
    assign,
    equality,
    walrus,
    bang,
    neq,
    ampersand,
    caret,
    tilde,
    labracket,
    leq,
    rabracket,
    geq,
    double_labracket,
    double_rabracket,
    lsbracket,
    rsbracket,
    lcbracket,
    rcbracket,
    false_kw,
    await_kw,
    else_kw,
    import_kw,
    pass_kw,
    none_kw,
    break_kw,
    except_kw,
    in_kw,
    raise_kw,
    true_kw,
    class_kw,
    finally_kw,
    is_kw,
    return_kw,
    and_kw,
    continue_kw,
    for_kw,
    lambda_kw,
    try_kw,
    as_kw,
    def_kw,
    from_kw,
    nonlocal_kw,
    while_kw,
    assert_kw,
    del_kw,
    global_kw,
    not_kw,
    with_kw,
    async_kw,
    elif_kw,
    if_kw,
    or_kw,
    yield_kw,
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
    at: Identifier,
    integer: Identifier,
    float: Identifier,
    imaginary: Identifier,
    string: Identifier,
    dot: Bare,
    colon: Bare,
    comma: Bare,
    pipe: Bare,
    plus: Bare,
    minus: Bare,
    asterisk: Bare,
    double_asterisk: Bare,
    solidus: Bare,
    double_solidus: Bare,
    percent: Bare,
    assign: Bare,
    equality: Bare,
    walrus: Bare,
    bang: Bare,
    neq: Bare,
    ampersand: Bare,
    caret: Bare,
    tilde: Bare,
    labracket: Bare,
    leq: Bare,
    rabracket: Bare,
    geq: Bare,
    double_labracket: Bare,
    double_rabracket: Bare,
    lsbracket: Bare,
    rsbracket: Bare,
    lcbracket: Bare,
    rcbracket: Bare,
    false_kw: Bare,
    await_kw: Bare,
    else_kw: Bare,
    import_kw: Bare,
    pass_kw: Bare,
    none_kw: Bare,
    break_kw: Bare,
    except_kw: Bare,
    in_kw: Bare,
    raise_kw: Bare,
    true_kw: Bare,
    class_kw: Bare,
    finally_kw: Bare,
    is_kw: Bare,
    return_kw: Bare,
    and_kw: Bare,
    continue_kw: Bare,
    for_kw: Bare,
    lambda_kw: Bare,
    try_kw: Bare,
    as_kw: Bare,
    def_kw: Bare,
    from_kw: Bare,
    nonlocal_kw: Bare,
    while_kw: Bare,
    assert_kw: Bare,
    del_kw: Bare,
    global_kw: Bare,
    not_kw: Bare,
    with_kw: Bare,
    async_kw: Bare,
    elif_kw: Bare,
    if_kw: Bare,
    or_kw: Bare,
    yield_kw: Bare,

    pub inline fn getLocation(self: *const Token) Location {
        return switch (self.*) {
            inline else => |item| item.loc,
        };
    }

    // pub fn format(value: Token, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {

    // }

};

// TODO: this is not a great implementation - should be using nested labeled switches, and it should be stateful
pub const Lexer = struct {
    buffer: []const u8,
    index: usize = 0,
    curr: ?u8 = null,
    prior: ?u8 = null,
    col: ColLength = 0,
    line: LineLength = 1, // 1 indexed, latent increment col = 0 # 1 indexed, immediate increment
    indent: u32 = 0, // 0 indexed, immediate increment
    complete: bool = false,
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
        const byte = self.peek() orelse return Error.eof;
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
        var spaces: u32 = 0;
        while (true) {
            switch (self.peek() orelse return) {
                '\t' => {
                    self.indent += 1;
                    spaces = 0;
                    _ = try self.take();
                },
                ' ' => {
                    spaces += 1;
                    _ = try self.take();
                    if (spaces == 4) {
                        self.indent += 1;
                        spaces = 0;
                    }
                },
                else => return,
            }
        }
    }

    fn location(self: *Self) Location {
        return .{ .indent = self.indent, .line = self.line, .col = self.col };
    }

    fn bare(self: *Self) Bare {
        return .{ .loc = self.location() };
    }

    fn readUntilLineEnd(self: *Self) Error!void {
        const rest_of_line = std.mem.sliceTo(self.buffer[self.index..], '\n');
        // it's tempting to just skip the cursor forward to the line end
        // but we need the bookkeeping stuff take() does
        for (0..rest_of_line.len) |_| _ = try self.take();
    }

    fn readWhileIdentifier(self: *Self) Error!void {
        while (true) {
            const byte = self.peek() orelse return;
            if (ascii.isAlphanumeric(byte) or byte == '_') _ = try self.take() else return;
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

    fn readWhileZero(self: *Self) Error!void {
        while (true) {
            const byte = self.peek() orelse return;
            switch (byte) {
                '0' => {
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

    // whitespace or colon!!
    fn matchExactTerminatedByWhitspace(self: *Self, comptime needle: []const u8) bool {
        if (!self.matchExact(needle)) return false;
        if (self.peek()) |byte| {
            switch (byte) {
                '\n', '\t', ' ', ':' => {},
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

    const KeywordTuple = struct { TokenTag, []const u8 };
    const keywords = [_]KeywordTuple{
        .{ .false_kw, "False" },
        .{ .await_kw, "await" },
        .{ .else_kw, "else" },
        .{ .import_kw, "import" },
        .{ .pass_kw, "pass" },
        .{ .none_kw, "None" },
        .{ .break_kw, "break" },
        .{ .except_kw, "except" },
        .{ .in_kw, "in" },
        .{ .raise_kw, "raise" },
        .{ .true_kw, "True" },
        .{ .class_kw, "class" },
        .{ .finally_kw, "finally" },
        .{ .is_kw, "is" },
        .{ .return_kw, "return" },
        .{ .and_kw, "and" },
        .{ .continue_kw, "continue" },
        .{ .for_kw, "for" },
        .{ .lambda_kw, "lambda" },
        .{ .try_kw, "try" },
        .{ .def_kw, "def" },
        .{ .from_kw, "from" },
        .{ .nonlocal_kw, "nonlocal" },
        .{ .while_kw, "while" },
        .{ .assert_kw, "assert" },
        .{ .async_kw, "async" },
        .{ .as_kw, "as" },
        .{ .del_kw, "del" },
        .{ .global_kw, "global" },
        .{ .not_kw, "not" },
        .{ .with_kw, "with" },
        .{ .elif_kw, "elif" },
        .{ .if_kw, "if" },
        .{ .or_kw, "or" },
        .{ .yield_kw, "yield" },
    };

    fn readKeyword(self: *Self) ?Token {
        inline for (keywords) |kw| {
            if (self.matchKeyword(kw[0], kw[1])) |token| return token;
        }
        return null;
    }

    inline fn readFloat(self: *Self, start: usize, loc: Location) Error!Token {
        const dot = try self.take();
        std.debug.assert(dot == '.');
        try self.readWhileNumeric();
        if (self.peek()) |val| {
            if (val == 'j') return self.readImaginary(start, loc);
        }
        return Token{ .float = .{ .value = self.buffer[start..self.index], .loc = loc } };
    }

    inline fn readImaginary(self: *Self, start: usize, loc: Location) Error!Token {
        const j = try self.take();
        std.debug.assert(j == 'j');
        return Token{ .imaginary = .{ .value = self.buffer[start..self.index], .loc = loc } };
    }

    pub fn next(self: *Self) Error!Token {
        const byte = self.take() catch |err| {
            // we give a nice sentinel before throwing; if we don't throw
            // then consumers could get stuck in an infinite loop while(lex.next())
            defer self.complete = true;
            if (self.complete) return err else return Token{ .eof = self.bare() };
        };
        switch (byte) {
            // whitespace
            '\n' => {
                // TODO: create end of statement
                try self.takeIndents();
                return self.next();
            },
            '\t', ' ' => return self.next(),
            // brackets and operators
            '(' => return Token{ .lparen = self.bare() },
            ')' => return Token{ .rparen = self.bare() },
            '.' => return Token{ .dot = self.bare() },
            ':' => {
                if (self.peek()) |val| {
                    if (val == '=') {
                        _ = self.take() catch unreachable;
                        return Token{ .walrus = self.bare() };
                    }
                }
                return Token{ .colon = self.bare() };
            },
            ',' => return Token{ .comma = self.bare() },
            '|' => return Token{ .pipe = self.bare() },
            '+' => return Token{ .plus = self.bare() },
            '-' => return Token{ .minus = self.bare() },
            '*' => {
                if (self.peek()) |val| {
                    if (val == '*') {
                        _ = self.take() catch unreachable;
                        return Token{ .double_asterisk = self.bare() };
                    }
                }
                return Token{ .asterisk = self.bare() };
            },
            '/' => {
                if (self.peek()) |val| {
                    if (val == '/') {
                        _ = self.take() catch unreachable;
                        return Token{ .double_solidus = self.bare() };
                    }
                }
                return Token{ .solidus = self.bare() };
            },
            '%' => return Token{ .percent = self.bare() },
            '=' => {
                if (self.peek()) |val| {
                    if (val == '=') {
                        _ = self.take() catch unreachable;
                        return Token{ .equality = self.bare() };
                    }
                }
                return Token{ .assign = self.bare() };
            },
            '!' => {
                if (self.peek()) |val| {
                    if (val == '=') {
                        _ = self.take() catch unreachable;
                        return Token{ .neq = self.bare() };
                    }
                }
                return Token{ .bang = self.bare() };
            },
            '&' => return Token{ .ampersand = self.bare() },
            '^' => return Token{ .caret = self.bare() },
            '~' => return Token{ .tilde = self.bare() },
            '<' => {
                if (self.peek()) |val| {
                    switch (val) {
                        '<' => {
                            _ = self.take() catch unreachable;
                            return Token{ .double_labracket = self.bare() };
                        },
                        '=' => {
                            _ = self.take() catch unreachable;
                            return Token{ .leq = self.bare() };
                        },
                        else => {},
                    }
                }
                return Token{ .labracket = self.bare() };
            },
            '>' => {
                if (self.peek()) |val| {
                    switch (val) {
                        '>' => {
                            _ = self.take() catch unreachable;
                            return Token{ .double_rabracket = self.bare() };
                        },
                        '=' => {
                            _ = self.take() catch unreachable;
                            return Token{ .geq = self.bare() };
                        },
                        else => {},
                    }
                }
                return Token{ .rabracket = self.bare() };
            },
            '[' => return Token{ .lsbracket = self.bare() },
            ']' => return Token{ .rsbracket = self.bare() },
            '{' => return Token{ .lcbracket = self.bare() },
            '}' => return Token{ .rcbracket = self.bare() },
            '"' => {
                const docstringSentinel = "\"\"\"";
                if (self.matchExact(docstringSentinel)) return self.nextDocstring(docstringSentinel);
                return self.nextString('"');
            },
            '\'' => {
                const docstringSentinel = "'''";
                if (self.matchExact(docstringSentinel)) return self.nextDocstring(docstringSentinel);
                return self.nextString('\'');
            },
            'A'...'Z', 'a'...'z', '_' => {
                if (self.readKeyword()) |kw| {
                    return kw;
                }
                const loc = self.location();
                const start = self.index - 1;
                try self.readWhileIdentifier();
                return Token{ .name = .{ .value = self.buffer[start..self.index], .loc = loc } };
            },
            '@' => {
                const loc = self.location();
                const start = self.index - 1;
                try self.readWhileIdentifier();
                return Token{ .at = .{ .value = self.buffer[start..self.index], .loc = loc } };
            },
            '0' => {
                const loc = self.location();
                const start = self.index - 1;
                try self.readWhileZero();
                if (self.peek()) |val| {
                    if (val == '.') {
                        return self.readFloat(start, loc);
                    } else if (val == 'j') {
                        return self.readImaginary(start, loc);
                    } else if (ascii.isDigit(val)) {
                        log.err("SyntaxError: leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers", .{});
                        return Error.SyntaxError;
                    }
                }
                return Token{ .integer = .{ .value = self.buffer[self.index - 1 .. self.index], .loc = self.location() } };
            },
            '1'...'9' => {
                const loc = self.location();
                const start = self.index - 1;
                try self.readWhileNumeric();
                if (self.peek()) |val| {
                    if (val == '.') {
                        return self.readFloat(start, loc);
                    } else if (val == 'j') {
                        return self.readImaginary(start, loc);
                    }
                }
                return Token{ .integer = .{ .value = self.buffer[start..self.index], .loc = loc } };
            },
            '#' => {
                // comments aren't tokenized, we just advance
                try self.readUntilLineEnd();
                return self.next();
            },
            '\\' => {
                // TODO: prevent end of statement
                return self.next();
            },
            ';' => {
                // TODO: create end of statement
                return self.next();
            },
            else => {
                const rest_of_line = std.mem.sliceTo(self.buffer[self.index - 1 ..], '\n');
                log.err("BadToken: '{s}' (line {d})", .{ rest_of_line, self.location().line });
                return Error.BadToken;
            },
        }
    }

    // TODO: we support escaping quote characters, but the escapes will end up in the resulting
    // string.  So far the lexer only pulls slices out of an existent buffer avoiding any need
    // to allocate memory.  In a future revision we could allocPrint into the intern pool directly
    pub fn nextString(self: *Self, comptime sentinel: u8) Error!Token {
        const start = self.index;
        const loc = self.location();
        var escaped = false;

        while (true) {
            const byte = self.take() catch {
                log.err("SyntaxError: unterminated string literal (detected at line {d})", .{self.location().line});
                return Error.SyntaxError;
            };
            if (escaped) {
                escaped = false;
            } else {
                switch (byte) {
                    sentinel => {
                        return Token{ .string = .{ .value = self.buffer[start .. self.index - 1], .loc = loc } };
                    },
                    '\\' => {
                        escaped = true;
                    },
                    else => {},
                }
            }
        }
    }

    pub fn nextDocstring(self: *Self, comptime sentinel: []const u8) Error!Token {
        const start = self.index;
        const loc = self.location();
        while (true) {
            const byte = self.peek() orelse {
                log.err("SyntaxError: unterminated triple-quoted string literal (detected at line {d})", .{self.location().line});
                return Error.SyntaxError;
            };
            switch (byte) {
                sentinel[0] => {
                    if (self.matchExact(sentinel)) {
                        return Token{ .string = .{ .value = self.buffer[start .. self.index - 3], .loc = loc } };
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

test "lex: peek" {
    var lex = Lexer{ .buffer = "F" };
    try testing.expectEqual(lex.curr, null);
    try testing.expectEqual(lex.col, 0);
    const x = lex.peek();
    try testing.expectEqual(x, 'F');
    try testing.expectEqual(lex.curr, 'F');
    try testing.expectEqual(lex.col, 0);
}

test "lex: take" {
    var lex = Lexer{ .buffer = "F" };
    try testing.expectEqual(lex.col, 0);
    try testing.expectEqual(lex.take(), 'F');
    try testing.expectEqual(lex.curr, null);
    try testing.expectEqual(lex.prior, 'F');
    try testing.expectEqual(lex.col, 1);
}

test "lex: indents" {
    // taken from py lexer, with comment -> # TODO: a bit wrong :/
    var lex = Lexer{ .buffer = "\t+\n\t\t+\n\t\t\t+\n" };
    try testing.expectEqual(lex.next(), Token{ .plus = .{ .loc = .{ .indent = 0, .line = 1, .col = 2 } } });
    try testing.expectEqual(lex.next(), Token{ .plus = .{ .loc = .{ .indent = 2, .line = 2, .col = 2 } } });
    try testing.expectEqual(lex.next(), Token{ .plus = .{ .loc = .{ .indent = 3, .line = 3, .col = 3 } } });
    try testing.expectEqual(lex.next(), Token{ .eof = .{ .loc = .{ .indent = 0, .line = 3, .col = 4 } } });
}

test "lex: space indents" {
    var lex = Lexer{ .buffer = "+\n    +\n        +\n" };
    try testing.expectEqual(lex.next(), Token{ .plus = .{ .loc = .{ .indent = 0, .line = 1, .col = 1 } } });
    try testing.expectEqual(lex.next(), Token{ .plus = .{ .loc = .{ .indent = 1, .line = 2, .col = 4 } } });
    try testing.expectEqual(lex.next(), Token{ .plus = .{ .loc = .{ .indent = 2, .line = 3, .col = 8 } } });
    try testing.expectEqual(lex.next(), Token{ .eof = .{ .loc = .{ .indent = 0, .line = 3, .col = 9 } } });
}

test "lex: parens" {
    var lex = Lexer{ .buffer = "()" };
    try testing.expectEqual(lex.next(), Token{ .lparen = .{ .loc = .{ .line = 1, .col = 1 } } });
    try testing.expectEqual(lex.next(), Token{ .rparen = .{ .loc = .{ .line = 1, .col = 2 } } });
}

test "lex: operators" {
    var lex = Lexer{ .buffer = ":,+-*<>/=![]{}|%&^~:=**<<>>//== <= >= !=" };
    try testing.expectEqual(Token{ .colon = .{ .loc = .{ .line = 1, .col = 1 } } }, lex.next());
    try testing.expectEqual(Token{ .comma = .{ .loc = .{ .line = 1, .col = 2 } } }, lex.next());
    try testing.expectEqual(Token{ .plus = .{ .loc = .{ .line = 1, .col = 3 } } }, lex.next());
    try testing.expectEqual(Token{ .minus = .{ .loc = .{ .line = 1, .col = 4 } } }, lex.next());
    try testing.expectEqual(Token{ .asterisk = .{ .loc = .{ .line = 1, .col = 5 } } }, lex.next());
    try testing.expectEqual(Token{ .labracket = .{ .loc = .{ .line = 1, .col = 6 } } }, lex.next());
    try testing.expectEqual(Token{ .rabracket = .{ .loc = .{ .line = 1, .col = 7 } } }, lex.next());
    try testing.expectEqual(Token{ .solidus = .{ .loc = .{ .line = 1, .col = 8 } } }, lex.next());
    try testing.expectEqual(Token{ .assign = .{ .loc = .{ .line = 1, .col = 9 } } }, lex.next());
    try testing.expectEqual(Token{ .bang = .{ .loc = .{ .line = 1, .col = 10 } } }, lex.next());
    try testing.expectEqual(Token{ .lsbracket = .{ .loc = .{ .line = 1, .col = 11 } } }, lex.next());
    try testing.expectEqual(Token{ .rsbracket = .{ .loc = .{ .line = 1, .col = 12 } } }, lex.next());
    try testing.expectEqual(Token{ .lcbracket = .{ .loc = .{ .line = 1, .col = 13 } } }, lex.next());
    try testing.expectEqual(Token{ .rcbracket = .{ .loc = .{ .line = 1, .col = 14 } } }, lex.next());
    try testing.expectEqual(Token{ .pipe = .{ .loc = .{ .line = 1, .col = 15 } } }, lex.next());
    try testing.expectEqual(Token{ .percent = .{ .loc = .{ .line = 1, .col = 16 } } }, lex.next());
    try testing.expectEqual(Token{ .ampersand = .{ .loc = .{ .line = 1, .col = 17 } } }, lex.next());
    try testing.expectEqual(Token{ .caret = .{ .loc = .{ .line = 1, .col = 18 } } }, lex.next());
    try testing.expectEqual(Token{ .tilde = .{ .loc = .{ .line = 1, .col = 19 } } }, lex.next());
    // TODO: fix location of these two character operators
    // the col count is the last character but should be the first
    try testing.expectEqual(Token{ .walrus = .{ .loc = .{ .line = 1, .col = 21 } } }, lex.next());
    try testing.expectEqual(Token{ .double_asterisk = .{ .loc = .{ .line = 1, .col = 23 } } }, lex.next());
    try testing.expectEqual(Token{ .double_labracket = .{ .loc = .{ .line = 1, .col = 25 } } }, lex.next());
    try testing.expectEqual(Token{ .double_rabracket = .{ .loc = .{ .line = 1, .col = 27 } } }, lex.next());
    try testing.expectEqual(Token{ .double_solidus = .{ .loc = .{ .line = 1, .col = 29 } } }, lex.next());
    try testing.expectEqual(Token{ .equality = .{ .loc = .{ .line = 1, .col = 31 } } }, lex.next());
    try testing.expectEqual(Token{ .leq = .{ .loc = .{ .line = 1, .col = 34 } } }, lex.next());
    try testing.expectEqual(Token{ .geq = .{ .loc = .{ .line = 1, .col = 37 } } }, lex.next());
    try testing.expectEqual(Token{ .neq = .{ .loc = .{ .line = 1, .col = 40 } } }, lex.next());
    try testing.expectEqual(Token{ .eof = .{ .loc = .{ .line = 1, .col = 40 } } }, lex.next());
}

test "lex: whitespace ignored" {
    var lex = Lexer{ .buffer = " \t\n" };
    try testing.expectEqual(lex.next(), Token{ .eof = .{ .loc = .{ .line = 1, .col = 3 } } });
}

test "lex: name" {
    {
        var lex = Lexer{ .buffer = "thing " };
        const value = "thing";
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.name.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.name.loc);
    }
    {
        var lex = Lexer{ .buffer = "d02" };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, "d02", next.name.value);
    }
}

test "lex: at" {
    var lex = Lexer{ .buffer = "@thing " };
    const value = "@thing";
    const next = try lex.next();
    try testing.expectEqualSlices(u8, value, next.at.value);
    try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.at.loc);
}

fn expectErrorMessage(message: []const u8) !void {
    // For reasons I never figured out, if this buffer is not empty after tests run then
    // we get this printed in the test runner report (but the test still passes):
    //   run enso_tests: error: 'test.parse pyfile' failed: SyntaxError: unterminated triple-quoted string literal (detected at line 2)
    // if you comment out the test that sets the buffer to that value (which is a string literal
    // expectation in these tests), then the error printed is the value the prior test left it in e.g.:
    //   run enso_tests: error: leading zeros in decimal integer literals are not permitted;...
    defer {
        test_logger_buf = undefined;
    }
    return testing.expectEqualStrings(message, test_err_message);
}

test "lex: integer" {
    {
        const value = "987654321";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.integer.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.integer.loc);
    }
    {
        const value = "0";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.integer.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.integer.loc);
    }
    {
        const value = "000";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, "0", next.integer.value);
        try testing.expectEqual(Location{ .line = 1, .col = 3 }, next.integer.loc);
    }
    {
        const value = "0123";
        var lex = Lexer{ .buffer = value };
        try testing.expectError(Lexer.Error.SyntaxError, lex.next());
        try expectErrorMessage("SyntaxError: leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers");
    }
}

test "lex: float" {
    {
        const value = "2.718";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.float.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.float.loc);
    }
    {
        const value = "0.707";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.float.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.float.loc);
    }
}

test "lex: imaginary" {
    {
        const value = "0j";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.imaginary.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.imaginary.loc);
    }
    {
        const value = "1j";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.imaginary.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.imaginary.loc);
    }
    {
        const value = "0.1j";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.imaginary.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.imaginary.loc);
    }
    {
        const value = "3.1j";
        var lex = Lexer{ .buffer = value };
        const next = try lex.next();
        try testing.expectEqualSlices(u8, value, next.imaginary.value);
        try testing.expectEqual(Location{ .line = 1, .col = 1 }, next.imaginary.loc);
    }
}

// keywords
// https://docs.python.org/3/library/keyword.html
// https://docs.python.org/3/reference/lexical_analysis.html#keywords

fn testKeyword(tag: TokenTag, kw: []const u8) !void {
    var buf: [50]u8 = undefined;
    {
        var lex = Lexer{ .buffer = kw };
        const next = try lex.next();
        try testing.expect(next == tag);
    }
    {
        const str = std.fmt.bufPrint(&buf, "{s}:", .{kw}) catch unreachable;
        var lex = Lexer{ .buffer = str };
        const next = try lex.next();
        try testing.expect(next == tag);
    }
    {
        const str = std.fmt.bufPrint(&buf, "{s} ", .{kw}) catch unreachable;
        var lex = Lexer{ .buffer = str };
        const next = try lex.next();
        try testing.expect(next == tag);
    }
    {
        const str = std.fmt.bufPrint(&buf, "{s}\t", .{kw}) catch unreachable;
        var lex = Lexer{ .buffer = str };
        const next = try lex.next();
        try testing.expect(next == tag);
    }
    {
        const str = std.fmt.bufPrint(&buf, "{s}s", .{kw}) catch unreachable;
        var lex = Lexer{ .buffer = str };
        const next = try lex.next();
        try testing.expect(next != tag);
    }
}

test "lex: keywords" {
    try testKeyword(.false_kw, "False");
    try testKeyword(.await_kw, "await");
    try testKeyword(.else_kw, "else");
    try testKeyword(.import_kw, "import");
    try testKeyword(.pass_kw, "pass");
    try testKeyword(.none_kw, "None");
    try testKeyword(.break_kw, "break");
    try testKeyword(.except_kw, "except");
    try testKeyword(.in_kw, "in");
    try testKeyword(.raise_kw, "raise");
    try testKeyword(.true_kw, "True");
    try testKeyword(.class_kw, "class");
    try testKeyword(.finally_kw, "finally");
    try testKeyword(.is_kw, "is");
    try testKeyword(.return_kw, "return");
    try testKeyword(.and_kw, "and");
    try testKeyword(.continue_kw, "continue");
    try testKeyword(.for_kw, "for");
    try testKeyword(.lambda_kw, "lambda");
    try testKeyword(.try_kw, "try");
    try testKeyword(.as_kw, "as");
    try testKeyword(.def_kw, "def");
    try testKeyword(.from_kw, "from");
    try testKeyword(.nonlocal_kw, "nonlocal");
    try testKeyword(.while_kw, "while");
    try testKeyword(.assert_kw, "assert");
    try testKeyword(.del_kw, "del");
    try testKeyword(.global_kw, "global");
    try testKeyword(.not_kw, "not");
    try testKeyword(.with_kw, "with");
    try testKeyword(.async_kw, "async");
    try testKeyword(.elif_kw, "elif");
    try testKeyword(.if_kw, "if");
    try testKeyword(.or_kw, "or");
    try testKeyword(.yield_kw, "yield");
}

test "lex: strings" {
    {
        var lex = Lexer{ .buffer = "'string'" };
        const next = try lex.next();
        try testing.expect(next == .string);
        try testing.expectEqualSlices(u8, "string", next.string.value);
    }
    {
        var lex = Lexer{ .buffer = "'escaped\\' string'" };
        const next = try lex.next();
        try testing.expect(next == .string);
        try testing.expectEqualSlices(u8, "escaped\\' string", next.string.value);
    }
    {
        var lex = Lexer{ .buffer = "\"string\"" };
        const next = try lex.next();
        try testing.expect(next == .string);
        try testing.expectEqualSlices(u8, "string", next.string.value);
    }
    {
        var lex = Lexer{ .buffer = "\"escaped\\\" string\"" };
        const next = try lex.next();
        try testing.expect(next == .string);
        try testing.expectEqualSlices(u8, "escaped\\\" string", next.string.value);
    }
}

test "lex: triple quote" {
    {
        const doc =
            \\"""The quick
            \\brown fox jumps over the lazy dog
            \\"""
        ;
        var lex = Lexer{ .buffer = doc };
        const next = try lex.next();
        try testing.expect(next == .string);
        try testing.expectEqualSlices(u8, "The quick\nbrown fox jumps over the lazy dog\n", next.string.value);
    }
    {
        const doc =
            \\"""The quick
            \\brown fox jumps over the lazy dog
        ;
        var lex = Lexer{ .buffer = doc };
        try testing.expectError(Lexer.Error.SyntaxError, lex.next());
        try expectErrorMessage("SyntaxError: unterminated triple-quoted string literal (detected at line 2)");
    }
    {
        const doc =
            \\'''The quick
            \\brown fox jumps over the lazy dog
            \\'''
        ;
        var lex = Lexer{ .buffer = doc };
        const next = try lex.next();
        try testing.expect(next == .string);
        try testing.expectEqualSlices(u8, "The quick\nbrown fox jumps over the lazy dog\n", next.string.value);
    }
    {
        const doc =
            \\'''The quick
            \\brown fox jumps over the lazy dog
        ;
        var lex = Lexer{ .buffer = doc };
        try testing.expectError(Lexer.Error.SyntaxError, lex.next());
        try expectErrorMessage("SyntaxError: unterminated triple-quoted string literal (detected at line 2)");
    }
}

test "lex: comments" {
    {
        var lex = Lexer{ .buffer = "#" };
        try testing.expect(try lex.next() == .eof);
    }
    {
        const doc =
            \\1 # this is a comment
            \\"the quick brown fox jumps over the lazy dog"
        ;
        var lex = Lexer{ .buffer = doc };
        try testing.expect(try lex.next() == .integer);
        try testing.expect(try lex.next() == .string);
        try testing.expect(try lex.next() == .eof);
    }
}

test "lex: example fixtures" {
    inline for (test_examples) |example| {
        if (!example.test_lex) continue;

        var lex = Lexer{ .buffer = example.source() };
        while (try lex.next() != .eof) continue;
    }
}
