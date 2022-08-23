const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const lex = @import("./lex.zig");
const Token = lex.Token;

const AstNodeTag = enum {
    integer,
    sum,
    product,
    division,
    group,
    name,
    variable_declaration,
    assignment,
};

const BinaryOp = struct { lhs: *AstNode, rhs: *AstNode };

pub const AstNode = union(AstNodeTag) {
    integer: struct { value: usize },
    sum: BinaryOp,
    product: BinaryOp,
    division: BinaryOp,
    group: struct { value: *AstNode },
    name: struct { value: []const u8 },
    variable_declaration: struct { name: []const u8 },
    assignment: BinaryOp,
};

pub const Parser = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    lexer: lex.Lexer,
    peeked: ?Token = null,
    //taken: ?Token = null,

    const Self = @This();

    const Error = error{
        BadNullDenotation,
        BadLeftDenotation,
        UnhandledPrecedence,
        UnexpectedToken,
    } || lex.Lexer.Error ||
        std.fmt.ParseIntError || std.mem.Allocator.Error;

    pub fn init(allocator: ?std.mem.Allocator, buffer: []const u8) Self {
        var base_allocator = allocator orelse std.heap.page_allocator; // TODO testing.allocator leaves us in an infinite spin loop for some reason
        base_allocator = std.heap.page_allocator;
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        return .{ .allocator = arena.allocator(), .arena = arena, .lexer = lex.Lexer{ .buffer = buffer } };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn parse(self: *Self) Error!*AstNode {
        const node = try self.parseExpression(.lowest);
        return node;
    }

    const Precedence = enum {
        lowest,
        equality,
        lessgreater,
        sum,
        product,
        prefix,
        call,
    };

    inline fn precedenceMap(token: Token) Error!Precedence {
        switch (token) {
            .eof => return .lowest,
            .integer => return .lowest,
            .plus => return .sum,
            .asterisk => return .product,
            .solidus => return .product,
            .rparen => return .lowest,
            .name => return .lowest,
            .var_kw => return .lowest,
            .assign => return .equality,
            else => return Error.UnhandledPrecedence, // TODO: remove
        }
    }

    const ParseFn = fn (*Self) Error!*AstNode;
    inline fn nullDenotation(token: Token) Error!ParseFn {
        switch (token) {
            .integer => return parseInteger,
            .lparen => return parseGroup,
            .name => return parseName,
            .var_kw => return parseVariableDeclaration,
            else => return Error.BadNullDenotation,
        }
    }

    const InfixFn = fn (*Self, *AstNode) Error!*AstNode;
    inline fn leftDenotation(token: Token) Error!InfixFn {
        switch (token) {
            .plus => return parsesum,
            .asterisk => return parseProduct,
            .solidus => return parseDivision,
            .assign => return parseAssignment,
            else => return Error.BadLeftDenotation,
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
        var peeked = self.peek() catch return .lowest;
        return try precedenceMap(peeked);
    }

    fn parseExpression(self: *Self, precedence: Precedence) Error!*AstNode {
        var token = try self.peek();
        const lhsFn = try nullDenotation(token);
        var lhs = try lhsFn(self);
        while (@enumToInt(precedence) < @enumToInt(try self.peekPrecedence())) {
            token = try self.peek();
            const infixFn = try leftDenotation(token);
            lhs = try infixFn(self, lhs);
        }
        return lhs;
    }

    fn parseInteger(self: *Self) Error!*AstNode {
        var int_token = try self.take();
        const val = try std.fmt.parseInt(usize, int_token.integer.value, 10);
        var int_node = try self.allocator.create(AstNode);
        int_node.* = .{ .integer = .{ .value = val } };
        return int_node;
    }

    fn parsesum(self: *Self, lhs: *AstNode) Error!*AstNode {
        const sum_token = try self.take(); // skip sum token
        switch (sum_token) {
            .plus => {
                var rhs = try self.parseExpression(.sum);
                var sum_node = try self.allocator.create(AstNode);
                sum_node.* = .{ .sum = .{ .lhs = lhs, .rhs = rhs } };
                return sum_node;
            },
            else => return Error.UnexpectedToken,
        }
    }

    fn parseProduct(self: *Self, lhs: *AstNode) Error!*AstNode {
        const product_token = try self.take(); // skip asterisk token
        assert(product_token == .asterisk);
        var rhs = try self.parseExpression(.product);
        var sum_node = try self.allocator.create(AstNode);
        sum_node.* = .{ .product = .{ .lhs = lhs, .rhs = rhs } };
        return sum_node;
    }

    fn parseDivision(self: *Self, lhs: *AstNode) Error!*AstNode {
        const solidus_token = try self.take(); // skip solidus token
        assert(solidus_token == .solidus);
        var rhs = try self.parseExpression(.product);
        var sum_node = try self.allocator.create(AstNode);
        sum_node.* = .{ .division = .{ .lhs = lhs, .rhs = rhs } };
        return sum_node;
    }

    fn parseGroup(self: *Self) Error!*AstNode {
        const lparen_token = try self.take(); // skip lparen token
        assert(lparen_token == .lparen);
        var rhs = try self.parseExpression(.lowest);
        var group_node = try self.allocator.create(AstNode);
        group_node.* = .{ .group = .{ .value = rhs } };
        const rparen_token = try self.take(); // skip rparen token
        // we raise here because this could be user error
        if (rparen_token != .rparen) return Error.UnexpectedToken;
        return group_node;
    }

    fn parseName(self: *Self) Error!*AstNode {
        const name_token = try self.take();
        assert(name_token == .name);
        var name_node = try self.allocator.create(AstNode);
        name_node.* = .{ .name = .{ .value = name_token.name.value } };
        return name_node;
    }

    fn parseVariableDeclaration(self: *Self) Error!*AstNode {
        const var_kw_token = try self.take(); // skip var_kw token
        assert(var_kw_token == .var_kw);
        const name_token = try self.take();
        if (name_token != .name) return Error.UnexpectedToken;
        var variable_declaration_node = try self.allocator.create(AstNode);
        variable_declaration_node.* = .{ .variable_declaration = .{ .name = name_token.name.value } };
        return variable_declaration_node;
    }

    fn parseAssignment(self: *Self, lhs: *AstNode) Error!*AstNode {
        const assign_token = try self.take(); // skip assign token
        assert(assign_token == .assign);
        var rhs = try self.parseExpression(.equality);
        var assignment_node = try self.allocator.create(AstNode);
        assignment_node.* = .{ .assignment = .{ .lhs = lhs, .rhs = rhs } };
        return assignment_node;
    }
};

// Test arithmetic

test "infix sum" {
    var parser = Parser.init(testing.allocator, "1 + 2");
    defer parser.deinit();
    var result = try parser.parse();
    try testing.expect(result.* == AstNode.sum);
    try testing.expect(result.sum.lhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 1), result.sum.lhs.integer.value);
    try testing.expect(result.sum.rhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 2), result.sum.rhs.integer.value);
}

test "infix product" {
    var parser = Parser.init(testing.allocator, "1 + 2 * 3");
    defer parser.deinit();
    var result = try parser.parse();
    try testing.expect(result.* == AstNode.sum);
    try testing.expect(result.sum.lhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 1), result.sum.lhs.integer.value);
    try testing.expect(result.sum.rhs.* == AstNode.product);
    try testing.expect(result.sum.rhs.product.lhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 2), result.sum.rhs.product.lhs.integer.value);
    try testing.expect(result.sum.rhs.product.rhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 3), result.sum.rhs.product.rhs.integer.value);
}

test "infix division" {
    var parser = Parser.init(testing.allocator, "1 + 2 / 3");
    defer parser.deinit();
    var result = try parser.parse();
    try testing.expect(result.* == AstNode.sum);
    try testing.expect(result.sum.lhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 1), result.sum.lhs.integer.value);
    try testing.expect(result.sum.rhs.* == AstNode.division);
    try testing.expect(result.sum.rhs.division.lhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 2), result.sum.rhs.division.lhs.integer.value);
    try testing.expect(result.sum.rhs.division.rhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 3), result.sum.rhs.division.rhs.integer.value);
}

test "group" {
    var parser = Parser.init(testing.allocator, "(1 + 2) / 3");
    defer parser.deinit();
    var result = try parser.parse();

    try testing.expect(result.* == .division);
    try testing.expect(result.division.lhs.* == .group);
    try testing.expect(result.division.lhs.group.value.* == .sum);
    try testing.expect(result.division.lhs.group.value.sum.lhs.* == .integer);
    try testing.expectEqual(@intCast(usize, 1), result.division.lhs.group.value.sum.lhs.integer.value);
    try testing.expect(result.division.lhs.group.value.sum.rhs.* == .integer);
    try testing.expectEqual(@intCast(usize, 2), result.division.lhs.group.value.sum.rhs.integer.value);
    try testing.expect(result.division.rhs.* == .integer);
    try testing.expectEqual(@intCast(usize, 3), result.division.rhs.integer.value);
}

// Test Assignment

test "assign" {
    var parser = Parser.init(testing.allocator, "a = 1");
    defer parser.deinit();
    var result = try parser.parse();

    try testing.expect(result.* == AstNode.assignment);
    try testing.expect(result.assignment.lhs.* == AstNode.name);
    try testing.expectEqualSlices(u8, "a", result.assignment.lhs.name.value);
    try testing.expect(result.assignment.rhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 1), result.assignment.rhs.integer.value);
}

test "declare and assign" {
    var parser = Parser.init(testing.allocator, "var a = 1");
    defer parser.deinit();
    var result = try parser.parse();

    try testing.expect(result.* == AstNode.assignment);
    try testing.expect(result.assignment.lhs.* == AstNode.variable_declaration);
    try testing.expectEqualSlices(u8, "a", result.assignment.lhs.variable_declaration.name);
    try testing.expect(result.assignment.rhs.* == AstNode.integer);
    try testing.expectEqual(@intCast(usize, 1), result.assignment.rhs.integer.value);
}
