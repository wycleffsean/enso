const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const lex = @import("lex.zig");
const Token = lex.Token;

const log = std.log.scoped(.parse);

const AstNodeTag = enum {
    root,
    pass,
    integer,
    sum,
    product,
    division,
    group,
    name,
    var_decl,
    fn_decl,
    assignment,
    call,
    field_access,
    array_literal,
    string_literal,
    class,
};

const BinaryOp = struct { lhs: *const AstNode, rhs: *const AstNode };
const Statement = std.ArrayList(*const AstNode);
const ClassDefinition = struct {
    name: []const u8,
    baseclass: ?[]const u8,
    statement: Statement,
};

pub const AstNode = union(AstNodeTag) {
    root: []*const AstNode,
    pass: void,
    integer: struct { value: usize },
    sum: BinaryOp,
    product: BinaryOp,
    division: BinaryOp,
    group: struct { value: *const AstNode },
    name: struct { value: []const u8 },
    var_decl: struct { name: []const u8 },
    fn_decl: struct { name: []const u8, statement: Statement },
    assignment: BinaryOp,
    call: struct { ref: *const AstNode },
    field_access: BinaryOp,
    array_literal: Statement,
    string_literal: struct { value: []const u8 },
    class: ClassDefinition,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lex.Lexer,
    peeked: ?Token = null,
    //taken: ?Token = null,

    const Self = @This();

    const Error = error{
        NullDenotationUnhandled,
        LeftDenotationUnhandled,
        UnhandledPrecedence,
        UnexpectedToken,
        UnexpectedEndOfStream,
    } || lex.Lexer.Error ||
        std.fmt.ParseIntError || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) Self {
        return .{ .allocator = allocator, .lexer = lex.Lexer{ .buffer = buffer } };
    }

    pub fn parse(self: *Self) Error!*const AstNode {
        var root = try self.allocator.create(AstNode);
        var list = std.ArrayList(*const AstNode).init(self.allocator);
        while (self.peek()) |token| {
            _ = token;
            try list.append(try self.parseExpression(.lowest));
        }
        root.* = AstNode{ .root = try list.toOwnedSlice() };
        return root;
    }

    pub fn parseStatement(self: *Self) Error!*const AstNode {
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

    const ParseFn = *const fn (*Self) Error!*AstNode;
    const InfixFn = *const fn (*Self, *AstNode) Error!*AstNode;
    const TokenMapping = struct { lex.TokenTag, Precedence, ParseFn, InfixFn };
    // Switching on enum is way more efficient, but the ergonomics of this are much better
    // We could also make this a hashmap, but that still has a higher runtime cost
    // than switch.  We'll get there...
    const token_map = [_]TokenMapping{
        .{ .eof, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .integer, .lowest, parseInteger, leftDenotationUnhandled },
        .{ .plus, .sum, nullDenotationUnhandled, parseSum },
        .{ .asterisk, .product, nullDenotationUnhandled, parseProduct },
        .{ .solidus, .product, nullDenotationUnhandled, parseDivision },
        .{ .rparen, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .name, .lowest, parseName, leftDenotationUnhandled },
        .{ .assign, .equality, nullDenotationUnhandled, parseAssignment },
        .{ .lparen, .call, parseGroup, parseFunctionCall },
        .{ .decorator, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .string, .lowest, parseStringLiteral, leftDenotationUnhandled },
        .{ .dot, .call, nullDenotationUnhandled, parseFieldAccess },
        .{ .colon, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .comma, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .pipe, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .minus, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .percent, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .less, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .greater, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .bang, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .ampersand, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .caret, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .tilde, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .lsbracket, .lowest, parseArrayLiteral, leftDenotationUnhandled },
        .{ .rsbracket, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .lcbracket, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .rcbracket, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .def_kw, .lowest, parseFunctionDefinition, leftDenotationUnhandled },
        .{ .false_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .await_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .else_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .import_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .pass_kw, .lowest, parsePass, leftDenotationUnhandled },
        .{ .none_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .break_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .except_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .in_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .raise_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .true_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .class_kw, .lowest, parseClassDefinition, leftDenotationUnhandled },
        .{ .finally_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .is_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .return_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .and_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .continue_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .for_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .lambda_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .try_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .as_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .from_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .nonlocal_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .while_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .assert_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .del_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .global_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .not_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .with_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .async_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .elif_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .if_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .or_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .yield_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
    };

    inline fn precedenceMap(token: Token) Error!Precedence {
        inline for (token_map) |map| {
            if (token == map[0]) return map[1];
        }
        return Error.UnhandledPrecedence;
    }

    inline fn nullDenotation(token: Token) Error!ParseFn {
        inline for (token_map) |map| {
            if (token == map[0]) return map[2];
        }
        return Error.NullDenotationUnhandled;
    }

    inline fn leftDenotation(token: Token) Error!InfixFn {
        inline for (token_map) |map| {
            if (token == map[0]) return map[3];
        }
        return Error.LeftDenotationUnhandled;
    }

    fn peek(self: *Self) ?Token {
        if (self.peeked) |peeked| {
            return peeked;
        } else {
            const peeked = self.lexer.next() catch null;
            if (peeked) |tok| {
                if (tok == .eof) return null;
            }
            self.peeked = peeked;
            return peeked;
        }
    }

    fn take(self: *Self) Error!Token {
        const peeked = self.peek() orelse return Error.UnexpectedEndOfStream;
        self.peeked = null;
        return peeked;
    }

    fn expect(self: *Self, tag: lex.TokenTag) bool {
        if (self.peek()) |token| {
            if (token == tag) return true;
        }
        return false;
    }

    fn expectAndSkip(self: *Self, tag: lex.TokenTag) Error!void {
        if (self.expect(tag)) {
            _ = self.take() catch unreachable;
            return;
        }
        return Error.UnexpectedToken;
    }

    fn expectAndTake(self: *Self, tag: lex.TokenTag) Error!Token {
        if (self.expect(tag)) {
            return self.take();
        }
        return Error.UnexpectedToken;
    }

    fn illegal(self: *Self, tag: lex.TokenTag) Error!void {
        if (self.expect(tag)) return Error.UnexpectedToken;
        return;
    }

    fn peekPrecedence(self: *Self) Error!Precedence {
        var peeked = self.peek() orelse return .lowest;
        return try precedenceMap(peeked);
    }

    fn parseExpression(self: *Self, precedence: Precedence) Error!*AstNode {
        var token = self.peek() orelse return Error.UnexpectedEndOfStream;
        const lhsFn = try nullDenotation(token);
        var lhs = try lhsFn(self);
        while (@intFromEnum(precedence) < @intFromEnum(try self.peekPrecedence())) {
            token = self.peek() orelse unreachable;
            const infixFn = try leftDenotation(token);
            lhs = try infixFn(self, lhs);
        }
        return lhs;
    }

    fn nullDenotationUnhandled(self: *Self) Error!*AstNode {
        log.err("oh no! we don't handle this null denotation: {any}", .{try self.take()});
        unreachable;
        // return Error.NullDenotationUnhandled;
    }

    fn leftDenotationUnhandled(self: *Self, lhs: *AstNode) Error!*AstNode {
        log.err("oh no! we don't handle this denotation: lhs: {any}, token: {any}", .{ lhs, try self.take() });
        unreachable;
        // return Error.NullDenotationUnhandled;
    }

    fn parsePass(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.pass_kw);
        var pass_node = try self.allocator.create(AstNode);
        pass_node.* = .{ .pass = {} };
        return pass_node;
    }

    fn parseInteger(self: *Self) Error!*AstNode {
        var int_token = try self.take();
        const val = try std.fmt.parseInt(usize, int_token.integer.value, 10);
        var int_node = try self.allocator.create(AstNode);
        int_node.* = .{ .integer = .{ .value = val } };
        return int_node;
    }

    fn parseStringLiteral(self: *Self) Error!*AstNode {
        if (self.expect(.string)) {
            var string_token = try self.take();
            var string_node = try self.allocator.create(AstNode);
            string_node.* = .{ .string_literal = .{ .value = string_token.string.value } };
            return string_node;
        } else {
            return Error.UnexpectedToken;
        }
    }

    fn parseSum(self: *Self, lhs: *AstNode) Error!*AstNode {
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

    fn parseArrayLiteral(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.lsbracket);

        var array_literal_node = try self.allocator.create(AstNode);
        array_literal_node.* = .{ .array_literal = Statement.init(self.allocator) };

        while (self.peek()) |next_token| {
            if (next_token == .rsbracket) break;
            try self.illegal(.comma);
            var item = try self.parseExpression(.lowest);
            try array_literal_node.array_literal.append(item);
            self.expectAndSkip(.comma) catch break;
        }

        try self.expectAndSkip(.rsbracket);
        return array_literal_node;
    }

    fn parseName(self: *Self) Error!*AstNode {
        const name_token = try self.take();
        assert(name_token == .name);
        var name_node = try self.allocator.create(AstNode);
        name_node.* = .{ .name = .{ .value = name_token.name.value } };
        return name_node;
    }

    fn parseAssignment(self: *Self, lhs: *AstNode) Error!*AstNode {
        const assign_token = try self.take(); // skip assign token
        assert(assign_token == .assign);
        var rhs = try self.parseExpression(.equality);
        var assignment_node = try self.allocator.create(AstNode);
        assignment_node.* = .{ .assignment = .{ .lhs = lhs, .rhs = rhs } };
        return assignment_node;
    }

    // probably makes more sense to call this parseStatement
    fn parseIndentedBlock(self: *Self, statement: *Statement, owner_indent: lex.IndentLength) Error!void {
        while (self.peek()) |next_token| {
            if (next_token.getLocation().indent <= owner_indent) break;
            try statement.append(try self.parseStatement());
        }
    }

    fn parseFunctionDefinition(self: *Self) Error!*AstNode {
        const def_kw_token = try self.take(); // skip fn_decl token
        assert(def_kw_token == .def_kw);
        const name_token = try self.take();
        if (name_token != .name) return Error.UnexpectedToken;

        // TODO: properly parse argument definitions
        const lparen_token = try self.take(); // skip lparen token
        if (lparen_token != .lparen) return Error.UnexpectedToken;
        const rparen_token = try self.take(); // skip rparen token
        if (rparen_token != .rparen) return Error.UnexpectedToken;

        const colon_token = try self.take(); // skip colon token
        if (colon_token != .colon) return Error.UnexpectedToken;

        var fn_decl = try self.allocator.create(AstNode);
        fn_decl.* = .{ .fn_decl = .{
            .name = name_token.name.value,
            .statement = std.ArrayList(*const AstNode).init(self.allocator),
        } };

        try self.parseIndentedBlock(&fn_decl.fn_decl.statement, def_kw_token.getLocation().indent);

        return fn_decl;
    }

    fn parseFunctionCall(self: *Self, lhs: *AstNode) Error!*AstNode {
        const lparen_token = try self.take(); // skip lparen token
        assert(lparen_token == .lparen);
        const rparen_token = try self.take(); // skip rparen token
        if (rparen_token != .rparen) {
            log.err("expected ')', got {any}", .{rparen_token});
            return Error.UnexpectedToken;
        }
        var call_node = try self.allocator.create(AstNode);
        call_node.* = .{ .call = .{ .ref = lhs } };
        return call_node;
    }

    fn parseClassDefinition(self: *Self) Error!*AstNode {
        const class_kw = self.expectAndTake(.class_kw) catch unreachable;
        const name_token = try self.expectAndTake(.name);
        var class_node = try self.allocator.create(AstNode);
        var baseclass: ?[]const u8 = null;
        if (self.expect(.lparen)) {
            self.expectAndSkip(.lparen) catch unreachable;
            if (self.expect(.name)) {
                var baseclass_node = self.take() catch unreachable;
                baseclass = baseclass_node.name.value;
            }
            try self.expectAndSkip(.rparen);
        }
        try self.expectAndSkip(.colon);
        class_node.* = .{ .class = .{
            .name = name_token.name.value,
            .baseclass = baseclass,
            .statement = std.ArrayList(*const AstNode).init(self.allocator),
        } };

        try self.parseIndentedBlock(&class_node.class.statement, class_kw.getLocation().indent);

        return class_node;
    }

    fn parseFieldAccess(self: *Self, lhs: *AstNode) Error!*AstNode {
        const dot_token = try self.take(); // skip dot token
        assert(dot_token == .dot);
        var rhs = try self.parseExpression(.call);
        var field_access_node = try self.allocator.create(AstNode);
        field_access_node.* = .{ .field_access = .{ .lhs = lhs, .rhs = rhs } };
        return field_access_node;
    }
};

// Test arithmetic

test "infix sum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "1 + 2");
    var result = try parser.parseStatement();
    try testing.expect(result.* == AstNode.sum);
    try testing.expect(result.sum.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(1)), result.sum.lhs.integer.value);
    try testing.expect(result.sum.rhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(2)), result.sum.rhs.integer.value);
}

test "infix product" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "1 + 2 * 3");
    var result = try parser.parseStatement();
    try testing.expect(result.* == AstNode.sum);
    try testing.expect(result.sum.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(1)), result.sum.lhs.integer.value);
    try testing.expect(result.sum.rhs.* == AstNode.product);
    try testing.expect(result.sum.rhs.product.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(2)), result.sum.rhs.product.lhs.integer.value);
    try testing.expect(result.sum.rhs.product.rhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(3)), result.sum.rhs.product.rhs.integer.value);
}

test "infix division" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "1 + 2 / 3");
    var result = try parser.parseStatement();
    try testing.expect(result.* == AstNode.sum);
    try testing.expect(result.sum.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(1)), result.sum.lhs.integer.value);
    try testing.expect(result.sum.rhs.* == AstNode.division);
    try testing.expect(result.sum.rhs.division.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(2)), result.sum.rhs.division.lhs.integer.value);
    try testing.expect(result.sum.rhs.division.rhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(3)), result.sum.rhs.division.rhs.integer.value);
}

test "group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "(1 + 2) / 3");
    var result = try parser.parseStatement();

    try testing.expect(result.* == .division);
    try testing.expect(result.division.lhs.* == .group);
    try testing.expect(result.division.lhs.group.value.* == .sum);
    try testing.expect(result.division.lhs.group.value.sum.lhs.* == .integer);
    try testing.expectEqual(@as(usize, @intCast(1)), result.division.lhs.group.value.sum.lhs.integer.value);
    try testing.expect(result.division.lhs.group.value.sum.rhs.* == .integer);
    try testing.expectEqual(@as(usize, @intCast(2)), result.division.lhs.group.value.sum.rhs.integer.value);
    try testing.expect(result.division.rhs.* == .integer);
    try testing.expectEqual(@as(usize, @intCast(3)), result.division.rhs.integer.value);
}

// Test Assignment

test "assign" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "a = 1");
    var result = try parser.parseStatement();

    try testing.expect(result.* == AstNode.assignment);
    try testing.expect(result.assignment.lhs.* == AstNode.name);
    try testing.expectEqualSlices(u8, "a", result.assignment.lhs.name.value);
    try testing.expect(result.assignment.rhs.* == AstNode.integer);
    try testing.expectEqual(@as(usize, @intCast(1)), result.assignment.rhs.integer.value);
}

test "string literal" {
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "\"yo\"");
        var result = try parser.parseStatement();
        try testing.expect(@as(AstNodeTag, result.*) == .string_literal);
        try testing.expectEqualStrings("yo", result.string_literal.value);
    }
    { // docstring
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "'''yo'''");
        var result = try parser.parseStatement();
        try testing.expect(@as(AstNodeTag, result.*) == .string_literal);
        try testing.expectEqualStrings("yo", result.string_literal.value);
    }
}

test "array literal" {
    { // Empty Array
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[]");
        var result = try parser.parseStatement();
        try testing.expect(result.array_literal.items.len == 0);
    }
    { // single element
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[1]");
        var result = try parser.parseStatement();
        try testing.expect(result.array_literal.items.len == 1);
    }
    { // trailing comma
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[1,]");
        var result = try parser.parseStatement();
        try testing.expect(result.array_literal.items.len == 1);
    }
    { // Unclosed
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[1,");
        try testing.expectError(Parser.Error.UnexpectedToken, parser.parseStatement());
    }
    { // illegal trailing comma
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[,]");
        try testing.expectError(Parser.Error.UnexpectedToken, parser.parseStatement());
    }
}

test "declare function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    const fn_decl =
        \\def myFunction():
        \\	a = 1
        \\	a * 3
    ;
    var parser = Parser.init(allocator, fn_decl);
    var result = try parser.parseStatement();

    try testing.expect(result.* == AstNode.fn_decl);
    try testing.expectEqualSlices(u8, "myFunction", result.fn_decl.name);

    // Statement
    try testing.expectEqual(@as(usize, 2), result.fn_decl.statement.items.len);
    const expr1 = result.fn_decl.statement.items[0];
    try testing.expect(expr1.* == AstNode.assignment);
    const expr2 = result.fn_decl.statement.items[1];
    try testing.expect(expr2.* == AstNode.product);
}

test "call function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "myFunction()");
    var result = try parser.parseStatement();

    try testing.expect(result.* == AstNode.call);
    try testing.expectEqualSlices(u8, "myFunction", result.call.ref.name.value);
}

test "class definition" {
    { // trivial class
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();

        const class =
            \\class Foo:
            \\	pass
        ;
        var parser = Parser.init(allocator, class);
        var result = (try parser.parse()).root[0];

        try testing.expectEqual(AstNode.class, result.*);
        try testing.expectEqualStrings("Foo", result.class.name);
        try testing.expect(result.class.baseclass == null);
        try testing.expectEqual(@as(usize, 1), result.class.statement.items.len);
    }
    { // implied baseclass
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();

        const class =
            \\class Foo():
            \\	pass
        ;
        var parser = Parser.init(allocator, class);
        var result = (try parser.parse()).root[0];

        try testing.expectEqual(AstNode.class, result.*);
        try testing.expectEqualStrings("Foo", result.class.name);
        try testing.expect(result.class.baseclass == null);
        try testing.expectEqual(@as(usize, 1), result.class.statement.items.len);
    }
    { // with baseclass
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var allocator = arena.allocator();
        defer arena.deinit();

        const class =
            \\class Foo(Bar):
            \\	pass
        ;
        var parser = Parser.init(allocator, class);
        var result = (try parser.parse()).root[0];
        try testing.expectEqual(AstNode.class, result.*);
        try testing.expectEqualStrings("Foo", result.class.name);
        try testing.expectEqualStrings("Bar", result.class.baseclass.?);
        try testing.expectEqual(@as(usize, 1), result.class.statement.items.len);
    }
}

test "access field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "foo.bar");
    var result = try parser.parseStatement();

    try testing.expect(result.* == AstNode.field_access);
    try testing.expectEqualSlices(u8, "foo", result.field_access.lhs.name.value);
    try testing.expectEqualSlices(u8, "bar", result.field_access.rhs.name.value);
}
