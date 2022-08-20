const std = @import("std");
const testing = std.testing;
const lex = @import("./lex.zig");
const Token = lex.Token;

const AstNodeTag = enum {
    INTEGER,
    SUM,
};

pub const AstNode = union(AstNodeTag) {
    INTEGER: struct { value: usize },
    SUM: struct { left: *AstNode, right: *AstNode },
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lex.Lexer,
    peeked: ?Token = null,
    //taken: ?Token = null,

    const Self = @This();

    const Error = error{
        BadNullDenotation,
        UnhandledPrecedence,
        UnexpectedToken,
    } || lex.Lexer.Error ||
        std.fmt.ParseIntError || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) Self {
        return .{ .allocator = allocator, .lexer = lex.Lexer{ .buffer = buffer } };
    }

    pub fn parse(self: *Self) Error!*AstNode {
        const node = try self.parseExpression(.LOWEST);
        return node;
    }

    const Precedence = enum {
        LOWEST,
        EQUALITY,
        LESSGREATER,
        SUM,
        PRODUCT,
        PREFIX,
        CALL,
    };

    inline fn precedenceMap(token: Token) Error!Precedence {
        switch (token) {
            .EOF => return .LOWEST,
            .INTEGER => return .LOWEST,
            .PLUS => return .SUM,
            else => return Error.UnhandledPrecedence, // TODO: remove
        }
    }

    const ParseFn = fn (*Self) Error!*AstNode;

    inline fn nullDenotation(token: Token) Error!ParseFn {
        switch (token) {
            .INTEGER => return parseInteger,
            else => return Error.BadNullDenotation,
        }
    }

    const InfixFn = fn (*Self, *AstNode) Error!*AstNode;
    inline fn leftDenotation(token: Token) Error!InfixFn {
        switch (token) {
            .PLUS => return parseSum,
            else => return Error.BadNullDenotation,
        }
    }

    fn peek(self: *Self) Error!Token {
        if (self.peeked) |peeked| {
            return peeked;
        } else {
            const peeked = try self.lexer.next();
            self.peeked = peeked;
            return peeked;
        }
    }

    fn take(self: *Self) Error!Token {
        const peeked = try self.peek();
        self.peeked = null;
        return peeked;
    }

    fn peekPrecedence(self: *Self) Error!Precedence {
        var peeked = self.peek() catch return .LOWEST;
        return try precedenceMap(peeked);
    }

    fn parseExpression(self: *Self, precedence: Precedence) Error!*AstNode {
        var token = try self.peek();
        const leftFn = try nullDenotation(token);
        var left = try leftFn(self);
        while (@enumToInt(precedence) < @enumToInt(try self.peekPrecedence())) {
            token = try self.peek();
            const infixFn = try leftDenotation(token);
            left = try infixFn(self, left);
        }
        return left;
    }

    fn parseInteger(self: *Self) Error!*AstNode {
        var int_token = try self.take();
        const val = try std.fmt.parseInt(usize, int_token.INTEGER.value, 10);
        var int_node = try self.allocator.create(AstNode);
        int_node.* = .{ .INTEGER = .{ .value = val } };
        return int_node;
    }

    fn parseSum(self: *Self, left: *AstNode) Error!*AstNode {
        const sum_token = try self.take(); // skip SUM token
        switch (sum_token) {
            .PLUS => {
                var right = try self.parseExpression(.SUM);
                var sum_node = try self.allocator.create(AstNode);
                sum_node.* = .{ .SUM = .{ .left = left, .right = right } };
                return sum_node;
            },
            else => return Error.UnexpectedToken,
        }
    }
};

test "infix sum" {
    var parser = Parser.init(testing.allocator, "1 + 2");
    var result = try parser.parse();
    defer testing.allocator.destroy(result);
    defer testing.allocator.destroy(result.SUM.left);
    defer testing.allocator.destroy(result.SUM.right);
    try testing.expect(result.* == AstNode.SUM);
    try testing.expect(result.SUM.left.* == AstNode.INTEGER);
    try testing.expectEqual(@intCast(usize, 1), result.SUM.left.INTEGER.value);
    try testing.expect(result.SUM.right.* == AstNode.INTEGER);
    try testing.expectEqual(@intCast(usize, 2), result.SUM.right.INTEGER.value);
}
