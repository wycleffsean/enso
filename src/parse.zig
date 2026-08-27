const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const assert = std.debug.assert;
const testing = std.testing;
const lex = @import("lex.zig");
const ObjectInt = @import("object.zig").ObjectInt;
const ObjectFloat = @import("object.zig").ObjectFloat;
const Token = lex.Token;
const test_examples = @import("test/utils.zig").examples;

const log = std.log.scoped(.parse);

const AstNodeTag = enum {
    root,
    pass,
    bool,
    integer,
    float,
    complex,
    ellipsis,
    unary_op,
    starred,
    bool_op,
    comparison,
    membership,
    not_membership,
    add,
    sub,
    mult,
    mat_mult,
    div,
    mod,
    pow,
    lshift,
    rshift,
    bit_or,
    bit_xor,
    bit_and,
    floor_div,
    group,
    tuple,
    name,
    var_decl,
    parameter,
    parameters,
    fn_decl,
    lambda,
    assignment,
    augmented_assignment,
    annotated_assignment,
    named_expression,
    call,
    field_access,
    subscript,
    slice,
    list,
    set,
    dictionary,
    target_list,
    for_in,
    if_stmt,
    while_stmt,
    with_stmt,
    raise_stmt,
    assert_stmt,
    break_stmt,
    continue_stmt,
    del_stmt,
    conditional,
    comprehension,
    string_literal,
    class,
    import,
    try_stmt,
    yield,
    @"return",
    await,
};

const UnaryOpKind = enum {
    positive,
    negative,
    logical_not,
    bitwise_not,
};
const UnaryOp = struct { value: *const AstNode, kind: UnaryOpKind };
pub const BinaryOp = struct { lhs: *const AstNode, rhs: *const AstNode };
pub const ComparisonKind = enum {
    lt,
    gt,
    eq,
    leq,
    geq,
    neq,
    identity,
    not_identity,
};
pub const Comparison = struct { kind: ComparisonKind, lhs: *const AstNode, rhs: *const AstNode };
const List = std.ArrayList(*const AstNode);
const BoolOpKind = enum {
    @"and",
    @"or",
};
const BoolOp = struct { lhs: *const AstNode, rhs: *const AstNode, kind: BoolOpKind };
const ComprehensionFor = struct {
    target_list: List,
    iterator: *const AstNode,
    predicate_expression: ?*const AstNode,
};
const Comprehension = struct {
    expression: *const AstNode,
    for_expressions: std.ArrayList(ComprehensionFor),
};
const ListItem = struct { unpack: bool, value: *const AstNode };
const ListDisplay = union(enum) {
    list: std.ArrayList(ListItem),
    comprehension: Comprehension,
    empty: void,
};
const Set = std.ArrayList(ListItem);
const SetDisplay = union(enum) {
    set: Set,
    comprehension: Comprehension,
};
const DictItem = struct { key: ?*const AstNode, value: *const AstNode };
const Dictionary = std.ArrayList(DictItem);
const DictComprehension = struct {
    expression: DictItem,
    for_expressions: std.ArrayList(ComprehensionFor),
};
const DictionaryDisplay = union(enum) {
    dictionary: Dictionary,
    comprehension: DictComprehension,
    empty: void,
};
pub const StatementNode = union(enum) {
    expr: *const AstNode,
    node: *const AstNode,
};
const Statement = std.ArrayList(StatementNode);

const ClassDefinition = struct {
    name: []const u8,
    baseclass: ?*const AstNode,
    suite: Statement,
};
// import sys
// from sys import *
// import test.typinganndata.ann_module as ann_module
// import time, sys
// from time import (time)
// from sys import path, argv
// from sys import (path, argv)
// from sys import (path, argv,)
// from test.support import import_helper
const Ref = struct { symbol: []const u8 };
const RefSpec = struct { refs: []const Ref };
const PackageSpec = union(enum) {
    star: void,
    refspec: RefSpec,
};

const ImportDefinition = struct {
    module: RefSpec,
    package: PackageSpec,
    alias: ?Ref,
};

const ImportExpression = std.ArrayList(ImportDefinition);
const ExpressionContext = enum { Load, Store };
const AugmentedAssignmentKind = enum {
    add,
    sub,
    mult,
    mat_mult,
    div,
    floor_div,
    mod,
    pow,
};
const Parameter = struct {
    identifier: *const AstNode,
    annotation: ?*const AstNode,
    default_value: ?*const AstNode,
};
const ParameterList = std.ArrayList(Parameter);
const Parameters = struct {
    arguments: ParameterList,
    position_only_arguments: ParameterList,
    keyword_only_arguments: ParameterList,
};

const ExceptHandler = struct {
    expression: ?*const AstNode,
    alias: ?[]const u8,
    suite: Statement,
};

const TryStatement = struct {
    suite: Statement,
    except_handlers: std.ArrayList(ExceptHandler),
    else_suite: ?Statement,
    finally_suite: ?Statement,
};

const WithItem = struct {
    expression: *const AstNode,
    alias: ?*const AstNode,
};

const WithStatement = struct {
    items: std.ArrayList(WithItem),
    suite: Statement,
};

const Yield = union(enum) {
    expression: *const AstNode,
    list: std.ArrayList(ListItem),
};

pub const AstNode = union(AstNodeTag) {
    root: []StatementNode,
    pass: void,
    bool: bool,
    integer: struct { value: ObjectInt },
    float: struct { value: ObjectFloat },
    complex: struct { real: ObjectFloat, imaginary: ObjectFloat },
    ellipsis: void,
    unary_op: UnaryOp,
    starred: struct { value: *const AstNode, dict: bool = false },
    bool_op: BoolOp,
    comparison: Comparison,
    membership: BinaryOp,
    not_membership: BinaryOp,
    // TODO: these really only have to be a single binary_op tag
    add: BinaryOp,
    sub: BinaryOp,
    mult: BinaryOp,
    mat_mult: BinaryOp,
    div: BinaryOp,
    mod: BinaryOp,
    pow: BinaryOp,
    lshift: BinaryOp,
    rshift: BinaryOp,
    bit_or: BinaryOp,
    bit_xor: BinaryOp,
    bit_and: BinaryOp,
    floor_div: BinaryOp,
    group: struct { value: *const AstNode },
    tuple: List,
    name: struct { value: []const u8, context: ExpressionContext },
    var_decl: struct { name: []const u8 },
    parameter: Parameter,
    parameters: Parameters,
    fn_decl: struct { name: []const u8, async: bool = false, parameters: Parameters, suite: Statement },
    lambda: struct { parameters: Parameters, expression: *const AstNode },
    assignment: BinaryOp,
    augmented_assignment: struct { kind: AugmentedAssignmentKind, lhs: *const AstNode, rhs: *const AstNode },
    annotated_assignment: struct { lhs: *const AstNode, annotation: *const AstNode, value: ?*const AstNode },
    named_expression: BinaryOp,
    call: struct { ref: *const AstNode, args: List },
    field_access: BinaryOp,
    subscript: BinaryOp,
    slice: struct { start: ?*const AstNode, stop: ?*const AstNode, step: ?*const AstNode },
    list: ListDisplay,
    set: SetDisplay,
    dictionary: DictionaryDisplay,
    target_list: List,
    for_in: struct { target_list: List, iterable: *const AstNode, suite: Statement, else_suite: ?Statement },
    if_stmt: struct { predicate: *const AstNode, suite: Statement, else_suite: ?Statement },
    while_stmt: struct { predicate: *const AstNode, suite: Statement, else_suite: ?Statement },
    with_stmt: WithStatement,
    raise_stmt: struct { expression: ?*const AstNode, cause: ?*const AstNode },
    assert_stmt: struct { predicate: *const AstNode, message: ?*const AstNode },
    break_stmt: void,
    continue_stmt: void,
    del_stmt: *const AstNode,
    conditional: struct { predicate: *const AstNode, lhs: *const AstNode, rhs: *const AstNode },
    comprehension: Comprehension,
    string_literal: struct { value: []const u8 },
    class: ClassDefinition,
    import: []ImportDefinition,
    try_stmt: TryStatement,
    yield: Yield,
    @"return": List,
    await: *const AstNode,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lex.Lexer,
    peeked: ?Token = null,
    last_taken: ?Token = null,
    filename: ?[]const u8 = null,
    // sometimes there is enough ambiguity in the lanaguage
    // that we have to rewind the parser and pursue another path.
    // rather than rewind the token stream and bother parsing again,
    // we retain the and return the last successfully parsed expression
    unwound: ?*AstNode = null,

    const Self = @This();

    const ParseError = error{
        NullDenotationUnhandled,
        LeftDenotationUnhandled,
        UnhandledPrecedence,
        UnexpectedToken,
        UnexpectedEndOfStream,
    };
    pub const Error = ParseError || lex.Lexer.Error || diagnostic.Error ||
        std.fmt.ParseIntError || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) Self {
        return .{ .allocator = allocator, .lexer = lex.Lexer{ .buffer = buffer } };
    }

    pub fn initWithFilename(allocator: std.mem.Allocator, buffer: []const u8, filename: ?[]const u8) Self {
        return .{ .allocator = allocator, .lexer = lex.Lexer{ .buffer = buffer }, .filename = filename };
    }

    fn currentLocation(self: *const Self) ?diagnostic.Location {
        if (self.peeked) |t| return t.getLocation();
        if (self.last_taken) |t| return t.getLocation();
        return null;
    }

    pub fn parse(self: *Self) Error!*const AstNode {
        const root = try self.allocator.create(AstNode);
        var statements: std.ArrayList(StatementNode) = .empty;
        while (self.peek()) |token| {
            _ = token;
            try statements.append(self.allocator, try self.parseStatement());
        }
        root.* = .{ .root = try statements.toOwnedSlice(self.allocator) };
        return root;
    }

    fn parseStatementWithIndent(self: *Self, owner_indent: lex.IndentLength) Error!Statement {
        var statement: Statement = .empty;
        while (self.peek()) |next_token| {
            if (next_token.getLocation().indent <= owner_indent) break;
            try statement.append(self.allocator, try self.parseStatement());
        }
        return statement;
    }

    fn parseStatement(self: *Self) Error!StatementNode {
        const token = self.peek() orelse return Error.UnexpectedEndOfStream;
        return switch (token) {
            .return_kw, .pass_kw, .def_kw, .async_kw, .class_kw, .for_kw, .if_kw, .while_kw, .with_kw, .raise_kw, .assert_kw, .break_kw, .continue_kw, .del_kw, .import_kw, .from_kw, .try_kw, .global_kw, .nonlocal_kw, .at => blk: {
                const null_denotation = tokenMap(token)[1];
                break :blk .{ .node = try null_denotation(self) };
            },
            else => blk: {
                const expr = try self.parseExpressionOrTuple(.eof, false);
                if (self.expect(.colon)) break :blk .{ .expr = try self.parseAnnotatedAssignment(expr) };
                break :blk .{ .expr = expr };
            },
        };
    }

    const Precedence = enum {
        lowest,
        conditional,
        equality,
        lessgreater,
        bit_or,
        bit_xor,
        bit_and,
        shift,
        sum,
        product,
        prefix,
        call,
    };

    const ParseFn = *const fn (*Self) Error!*AstNode;
    const InfixFn = *const fn (*Self, *AstNode) Error!*AstNode;
    const TokenMapping = struct { Precedence, ParseFn, InfixFn };
    fn tokenMap(tag: lex.TokenTag) TokenMapping {
        return switch (tag) {
            .eof => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .integer => .{ .lowest, parseInteger, leftDenotationUnhandled },
            .float => .{ .lowest, parseFloat, leftDenotationUnhandled },
            .imaginary => .{ .lowest, parseImaginary, leftDenotationUnhandled },
            .ellipsis => .{ .lowest, parseEllipsis, leftDenotationUnhandled },
            .plus => .{ .sum, parseUnaryOp, parseBinaryOp },
            .asterisk => .{ .product, parseStarredExpression, parseBinaryOp },
            .asterisk_assign => .{ .equality, nullDenotationUnhandled, parseAugmentedAssignment },
            .double_asterisk => .{ .product, parseStarredExpression, parseBinaryOp },
            .double_asterisk_assign => .{ .equality, nullDenotationUnhandled, parseAugmentedAssignment },
            .solidus => .{ .product, nullDenotationUnhandled, parseBinaryOp },
            .solidus_assign => .{ .equality, nullDenotationUnhandled, parseAugmentedAssignment },
            .double_solidus => .{ .product, nullDenotationUnhandled, parseBinaryOp },
            .double_solidus_assign => .{ .equality, nullDenotationUnhandled, parseAugmentedAssignment },
            .rparen => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .name => .{ .lowest, parseName, leftDenotationUnhandled },
            .assign => .{ .equality, nullDenotationUnhandled, parseAssignment },
            .walrus => .{ .equality, nullDenotationUnhandled, parseNamedExpression },
            // TODO: kinda dumb we call it equality but doesn't align with the
            //   'equality' precedence.  let's fix that
            .equality => .{ .lessgreater, nullDenotationUnhandled, parseComparison },
            .lparen => .{ .call, parseGroupOrGenerator, parseFunctionCall },
            .at => .{ .product, parseDecoratedStatement, parseBinaryOp },
            .at_assign => .{ .equality, nullDenotationUnhandled, parseAugmentedAssignment },
            .string => .{ .lowest, parseStringLiteral, leftDenotationUnhandled },
            .dot => .{ .call, nullDenotationUnhandled, parseFieldAccess },
            .colon => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .comma => .{ .lowest, nullDenotationIllegal, leftDenotationUnhandled },
            .pipe => .{ .bit_or, nullDenotationUnhandled, parseBinaryOp },
            .minus => .{ .prefix, parseUnaryOp, parseBinaryOp },
            .minus_assign => .{ .equality, nullDenotationUnhandled, parseAugmentedAssignment },
            .plus_assign => .{ .equality, nullDenotationUnhandled, parseAugmentedAssignment },
            .percent => .{ .product, nullDenotationUnhandled, parseBinaryOp },
            .percent_assign => .{ .equality, nullDenotationUnhandled, parseAugmentedAssignment },
            .labracket => .{ .lessgreater, nullDenotationIllegal, parseComparison },
            .rabracket => .{ .lessgreater, nullDenotationUnhandled, parseComparison },
            .leq => .{ .lessgreater, nullDenotationUnhandled, parseComparison },
            .geq => .{ .lessgreater, nullDenotationUnhandled, parseComparison },
            .neq => .{ .lessgreater, nullDenotationUnhandled, parseComparison },
            .double_labracket => .{ .shift, nullDenotationUnhandled, parseBinaryOp },
            .double_rabracket => .{ .shift, nullDenotationUnhandled, parseBinaryOp },
            .bang => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .ampersand => .{ .bit_and, nullDenotationUnhandled, parseBinaryOp },
            .caret => .{ .bit_xor, nullDenotationUnhandled, parseBinaryOp },
            .tilde => .{ .lowest, parseUnaryOp, leftDenotationUnhandled },
            .lsbracket => .{ .call, parseList, parseSubscript },
            .rsbracket => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .lcbracket => .{ .lowest, parseSetOrDictionary, leftDenotationUnhandled },
            .rcbracket => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .def_kw => .{ .lowest, parseFunctionDefinition, leftDenotationUnhandled },
            .false_kw => .{ .lowest, parseBool, leftDenotationUnhandled },
            .await_kw => .{ .lowest, parseAwait, leftDenotationUnhandled },
            .else_kw => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .import_kw => .{ .lowest, parseImport, leftDenotationUnhandled },
            .pass_kw => .{ .lowest, parsePass, leftDenotationUnhandled },
            .none_kw => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .break_kw => .{ .lowest, parseBreak, leftDenotationUnhandled },
            .except_kw => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .in_kw => .{ .lessgreater, nullDenotationUnhandled, parseMembershipTest },
            .raise_kw => .{ .lowest, parseRaise, leftDenotationUnhandled },
            .true_kw => .{ .lowest, parseBool, leftDenotationUnhandled },
            .class_kw => .{ .lowest, parseClassDefinition, leftDenotationUnhandled },
            .finally_kw => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .is_kw => .{ .lessgreater, nullDenotationUnhandled, parseIdentityComparison },
            .return_kw => .{ .lowest, parseReturn, leftDenotationUnhandled },
            .and_kw => .{ .sum, nullDenotationUnhandled, parseBoolOp },
            .continue_kw => .{ .lowest, parseContinue, leftDenotationUnhandled },
            .for_kw => .{ .lowest, parseForStatement, leftDenotationUnhandled },
            .lambda_kw => .{ .lowest, parseLambdaDefinition, leftDenotationUnhandled },
            .try_kw => .{ .lowest, parseTryStatement, leftDenotationUnhandled },
            .as_kw => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .from_kw => .{ .lowest, parseFromImport, leftDenotationUnhandled },
            .nonlocal_kw => .{ .lowest, parseDeclarationStatement, leftDenotationUnhandled },
            .while_kw => .{ .lowest, parseWhileStatement, leftDenotationUnhandled },
            .assert_kw => .{ .lowest, parseAssert, leftDenotationUnhandled },
            .del_kw => .{ .lowest, parseDeleteStatement, leftDenotationUnhandled },
            .global_kw => .{ .lowest, parseDeclarationStatement, leftDenotationUnhandled },
            .not_kw => .{ .lessgreater, parseUnaryOp, parseNotMembershipTest },
            .with_kw => .{ .lowest, parseWithStatement, leftDenotationUnhandled },
            .async_kw => .{ .lowest, parseAsyncStatement, leftDenotationUnhandled },
            .elif_kw => .{ .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
            .if_kw => .{ .conditional, parseIfStatement, parseIfExpression },
            .or_kw => .{ .sum, nullDenotationUnhandled, parseBoolOp },
            .yield_kw => .{ .lowest, parseYield, leftDenotationUnhandled },
        };
    }

    inline fn precedenceMap(token: Token) Error!Precedence {
        return tokenMap(std.meta.activeTag(token))[0];
    }

    inline fn nullDenotation(token: Token) Error!ParseFn {
        return tokenMap(std.meta.activeTag(token))[1];
    }

    inline fn leftDenotation(token: Token) Error!InfixFn {
        return tokenMap(std.meta.activeTag(token))[2];
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
        self.last_taken = peeked;
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
        const token = if (self.peek()) |t| @tagName(t) else "<None>";
        return diagnostic.fail(
            Error.UnexpectedToken,
            self.filename,
            self.currentLocation(),
            "expected: {s}, got: {s}",
            .{ @tagName(tag), token },
        );
    }

    fn expectAndSkipOptional(self: *Self, tag: lex.TokenTag) bool {
        if (self.expect(tag)) {
            _ = self.take() catch unreachable;
            return true;
        }
        return false;
    }

    fn expectAndTake(self: *Self, tag: lex.TokenTag) Error!Token {
        if (self.expect(tag)) {
            return self.take();
        }
        return diagnostic.fail(
            Error.UnexpectedToken,
            self.filename,
            self.currentLocation(),
            "expected {s}",
            .{@tagName(tag)},
        );
    }

    fn illegal(self: *Self, tag: lex.TokenTag) Error!void {
        if (self.expect(tag)) return diagnostic.fail(
            Error.UnexpectedToken,
            self.filename,
            self.currentLocation(),
            "unexpected {s}",
            .{@tagName(tag)},
        );
        return;
    }

    fn peekPrecedence(self: *Self) Error!Precedence {
        const peeked = self.peek() orelse return .lowest;
        return try precedenceMap(peeked);
    }

    fn parseExpression(self: *Self, precedence: Precedence) Error!*AstNode {
        if (self.unwound) |node| {
            @branchHint(.unlikely);
            defer self.unwound = null;
            return node;
        }
        var token = self.peek() orelse return Error.UnexpectedEndOfStream;
        const lhsFn = try nullDenotation(token);
        var lhs = try lhsFn(self);
        while (@intFromEnum(precedence) < @intFromEnum(try self.peekPrecedence())) {
            token = self.peek() orelse unreachable;
            if (self.last_taken) |last| {
                if (token.getLocation().line > last.getLocation().line) break;
            }
            const infixFn = try leftDenotation(token);
            lhs = try infixFn(self, lhs);
        }

        return lhs;
    }

    // simple utility for tests
    fn parseSimpleExpression(self: *Self) Error!*const AstNode {
        const node = try self.parseExpression(.lowest);
        return node;
    }

    fn parseExpressionOrTuple(self: *Self, terminal_token: lex.TokenTag, allow_trailing: bool) Error!*AstNode {
        const first = try self.parseExpression(.lowest);
        if (!self.expectAndSkipOptional(.comma)) return first;

        var list: List = .empty;
        try list.append(self.allocator, first);
        while (self.peek()) |next_token| {
            if (next_token == terminal_token) break;
            const item = try self.parseExpression(.lowest);
            try list.append(self.allocator, item);
            if (!self.expectAndSkipOptional(.comma)) break;
            if (allow_trailing and self.expect(terminal_token)) break;
        }

        const tuple = try self.allocator.create(AstNode);
        tuple.* = .{ .tuple = list };
        return tuple;
    }

    fn nullDenotationUnhandled(self: *Self) Error!*AstNode {
        const token = try self.take();
        return diagnostic.fail(
            Error.NullDenotationUnhandled,
            self.filename,
            self.currentLocation(),
            "unexpected token: {any}",
            .{token},
        );
    }

    fn nullDenotationIllegal(self: *Self) Error!*AstNode {
        return diagnostic.fail(
            Error.UnexpectedToken,
            self.filename,
            self.currentLocation(),
            "unexpected token",
            .{},
        );
    }

    fn leftDenotationUnhandled(self: *Self, lhs: *AstNode) Error!*AstNode {
        _ = lhs;
        return diagnostic.fail(
            Error.LeftDenotationUnhandled,
            self.filename,
            self.currentLocation(),
            "unexpected token: {any}",
            .{try self.take()},
        );
    }

    fn parsePass(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.pass_kw);
        const pass_node = try self.allocator.create(AstNode);
        pass_node.* = .{ .pass = {} };
        return pass_node;
    }

    fn skipRemainingLine(self: *Self, line: u32) Error!void {
        while (self.peek()) |token| {
            if (token.getLocation().line != line) break;
            _ = try self.take();
        }
    }

    fn parseDeclarationStatement(self: *Self) Error!*AstNode {
        const token = try self.take();
        try self.skipRemainingLine(token.getLocation().line);
        const pass_node = try self.allocator.create(AstNode);
        pass_node.* = .{ .pass = {} };
        return pass_node;
    }

    fn parseDeleteStatement(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.del_kw);
        const target = try self.parseExpressionOrTuple(.eof, false);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .del_stmt = target };
        return node;
    }

    fn parseDecoratedStatement(self: *Self) Error!*AstNode {
        while (self.expect(.at)) {
            const token = try self.take();
            try self.skipRemainingLine(token.getLocation().line);
        }
        const statement = try self.parseStatement();
        return switch (statement) {
            .node => |node| @constCast(node),
            .expr => |expr| @constCast(expr),
        };
    }

    fn parseBool(self: *Self) Error!*AstNode {
        const token = try self.take();
        const value = switch (token) {
            .true_kw => true,
            .false_kw => false,
            else => return Error.UnexpectedToken,
        };
        const node = try self.allocator.create(AstNode);
        node.* = .{ .bool = value };
        return node;
    }

    fn parseEllipsis(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.ellipsis);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .ellipsis = {} };
        return node;
    }

    fn parseInteger(self: *Self) Error!*AstNode {
        const int_token = try self.take();
        const val = try parseIntegerLiteral(int_token.integer.value);
        const int_node = try self.allocator.create(AstNode);
        int_node.* = .{ .integer = .{ .value = val } };
        return int_node;
    }

    fn parseIntegerLiteral(literal: []const u8) !ObjectInt {
        var buffer: [256]u8 = undefined;
        var cleaned_len: usize = 0;
        for (literal) |byte| {
            if (byte == '_') continue;
            if (cleaned_len >= buffer.len) return 0;
            buffer[cleaned_len] = byte;
            cleaned_len += 1;
        }

        var digits = buffer[0..cleaned_len];
        var base: u8 = 10;
        if (digits.len >= 2 and digits[0] == '0') {
            switch (digits[1]) {
                'b', 'B' => {
                    base = 2;
                    digits = digits[2..];
                },
                'o', 'O' => {
                    base = 8;
                    digits = digits[2..];
                },
                'x', 'X' => {
                    base = 16;
                    digits = digits[2..];
                },
                else => {},
            }
        }

        if (digits.len == 0) return Error.UnexpectedToken;
        return std.fmt.parseInt(ObjectInt, digits, base) catch |err| switch (err) {
            error.Overflow => std.math.maxInt(ObjectInt),
            else => err,
        };
    }

    fn parseFloat(self: *Self) Error!*AstNode {
        const float_token = try self.take();
        const val = try parseFloatLiteral(float_token.float.value);
        const float_node = try self.allocator.create(AstNode);
        float_node.* = .{ .float = .{ .value = val } };
        return float_node;
    }

    fn parseImaginary(self: *Self) Error!*AstNode {
        const imaginary_token = try self.take();
        const len = imaginary_token.imaginary.value.len - 1;
        const val = try parseFloatLiteral(imaginary_token.imaginary.value[0..len]);
        const imaginary_node = try self.allocator.create(AstNode);
        imaginary_node.* = .{ .complex = .{ .real = 0, .imaginary = val } };
        return imaginary_node;
    }

    fn parseFloatLiteral(literal: []const u8) !ObjectFloat {
        var buffer: [256]u8 = undefined;
        var cleaned_len: usize = 0;
        for (literal) |byte| {
            if (byte == '_') continue;
            if (cleaned_len >= buffer.len) return std.math.inf(ObjectFloat);
            buffer[cleaned_len] = byte;
            cleaned_len += 1;
        }
        return std.fmt.parseFloat(ObjectFloat, buffer[0..cleaned_len]);
    }

    fn parseStringLiteral(self: *Self) Error!*AstNode {
        if (self.expect(.string)) {
            const string_token = try self.take();
            var value = string_token.string.value;
            var parts: std.ArrayList([]const u8) = .empty;
            while (self.expect(.string)) {
                if (parts.items.len == 0) try parts.append(self.allocator, value);
                const next = try self.take();
                try parts.append(self.allocator, next.string.value);
            }
            if (parts.items.len > 0) {
                var joined: std.ArrayList(u8) = .empty;
                for (parts.items) |part| try joined.appendSlice(self.allocator, part);
                value = try joined.toOwnedSlice(self.allocator);
            }
            const string_node = try self.allocator.create(AstNode);
            string_node.* = .{ .string_literal = .{ .value = value } };
            return string_node;
        } else {
            return Error.UnexpectedToken;
        }
    }
    fn parseUnaryOp(self: *Self) Error!*AstNode {
        const op_token = try self.take(); // skip sum token
        const rhs = try self.parseExpression(.sum);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .unary_op = .{ .value = rhs, .kind = .positive } };
        switch (op_token) {
            .plus => {
                node.unary_op.kind = .positive;
            },
            .minus => {
                node.unary_op.kind = .negative;
            },
            .tilde => {
                node.unary_op.kind = .bitwise_not;
            },
            .not_kw => {
                node.unary_op.kind = .logical_not;
            },
            else => return Error.UnexpectedToken,
        }
        return node;
    }

    fn parseStarredExpression(self: *Self) Error!*AstNode {
        const op_token = try self.take();
        const value = try self.parseExpression(.product);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .starred = .{
            .value = value,
            .dict = op_token == .double_asterisk,
        } };
        return node;
    }

    fn parseBinaryOp(self: *Self, lhs: *AstNode) Error!*AstNode {
        const op_token = try self.take(); // skip sum token
        const rhs_precedence = try precedenceMap(op_token);
        switch (op_token) {
            .plus => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .add = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .minus => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .sub = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .asterisk => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .mult = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .solidus => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .div = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .double_solidus => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .floor_div = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .percent => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .mod = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .double_asterisk => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .pow = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .double_labracket => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .lshift = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .double_rabracket => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .rshift = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .pipe => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .bit_or = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .caret => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .bit_xor = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .ampersand => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .bit_and = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .at => {
                const rhs = try self.parseExpression(rhs_precedence);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .mat_mult = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            else => return Error.UnexpectedToken,
        }
    }

    // TODO: in the future consider turning these into a chain/list of bool ops
    // i.e. right now we just have a single bool op with a left/right children but
    // it is probably optimal to unify successive operations into a chain
    fn parseBoolOp(self: *Self, lhs: *AstNode) Error!*AstNode {
        const op_token = try self.take();
        const bool_op_kind: BoolOpKind = switch (op_token) {
            .and_kw => .@"and",
            .or_kw => .@"or",
            else => return Error.UnexpectedToken,
        };
        const rhs = try self.parseExpression(.lowest);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .bool_op = .{ .lhs = lhs, .rhs = rhs, .kind = bool_op_kind } };
        return node;
    }

    fn parseComparison(self: *Self, lhs: *AstNode) Error!*AstNode {
        const kind: ComparisonKind = switch (try self.take()) {
            .labracket => .lt,
            .rabracket => .gt,
            .equality => .eq,
            .leq => .leq,
            .geq => .geq,
            .neq => .neq,
            else => return error.UnexpectedToken,
        };

        const rhs = try self.parseExpression(.lessgreater);
        const result = try self.allocator.create(AstNode);
        result.* = .{ .comparison = .{ .kind = kind, .lhs = lhs, .rhs = rhs } };
        return result;
    }

    fn parseMembershipTest(self: *Self, lhs: *AstNode) Error!*AstNode {
        try self.expectAndSkip(.in_kw);

        const rhs = try self.parseExpression(.lowest);
        const result = try self.allocator.create(AstNode);
        result.* = .{ .membership = .{ .lhs = lhs, .rhs = rhs } };
        return result;
    }

    fn parseNotMembershipTest(self: *Self, lhs: *AstNode) Error!*AstNode {
        try self.expectAndSkip(.not_kw);
        try self.expectAndSkip(.in_kw);

        const rhs = try self.parseExpression(.lowest);
        const result = try self.allocator.create(AstNode);
        result.* = .{ .not_membership = .{ .lhs = lhs, .rhs = rhs } };
        return result;
    }

    fn parseIdentityComparison(self: *Self, lhs: *AstNode) Error!*AstNode {
        try self.expectAndSkip(.is_kw);
        const kind: ComparisonKind = if (self.expectAndSkipOptional(.not_kw)) .not_identity else .identity;

        const rhs = try self.parseExpression(.lowest);
        const result = try self.allocator.create(AstNode);
        result.* = .{ .comparison = .{ .kind = kind, .lhs = lhs, .rhs = rhs } };
        return result;
    }

    fn parseIfExpression(self: *Self, lhs: *AstNode) Error!*AstNode {
        try self.expectAndSkip(.if_kw);
        const predicate = try self.parseExpression(.lowest);
        try self.expectAndSkip(.else_kw);
        const rhs = try self.parseExpression(.lowest);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .conditional = .{ .predicate = predicate, .lhs = lhs, .rhs = rhs } };
        return node;
    }

    fn parseGroupOrGenerator(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.lparen);
        if (self.expectAndSkipOptional(.rparen)) {
            const result = try self.allocator.create(AstNode);
            result.* = .{ .tuple = .empty };
            return result;
        }
        const expression = try self.parseExpression(.lowest);
        const result = try self.allocator.create(AstNode);
        errdefer self.allocator.destroy(result);

        if (self.expect(.for_kw)) {
            // generator
            const comprehension = try self.parseComprehension(Comprehension, expression);
            result.* = .{ .comprehension = comprehension };
        } else if (self.expectAndSkipOptional(.comma)) {
            // tuple
            // TODO: this is a copy of parseTargetList - refactor/DRY this up
            var list: List = .empty;
            try list.append(self.allocator, expression);
            while (true) {
                if (self.expect(.rparen)) break;
                const target = try self.parseExpression(.lowest);
                try list.append(self.allocator, target);
                self.expectAndSkip(.comma) catch break;
            }
            result.* = .{ .tuple = list };
        } else {
            // group
            result.* = .{ .group = .{ .value = expression } };
        }
        try self.expectAndSkip(.rparen);
        return result;
    }

    // comprehension: assignment_expression comp_for
    // comp_for:      ["async"] "for" target_list "in" or_test [comp_iter]
    // comp_iter:     comp_for | comp_if
    // comp_if:       "if" or_test [comp_iter]
    fn parseComprehension(self: *Self, comptime T: type, expression: anytype) Error!T {
        var comprehension = T{
            .expression = expression,
            .for_expressions = .empty,
        };
        while (self.expect(.for_kw)) {
            try self.expectAndSkip(.for_kw);
            const comp_for = try self.parseComprehensionFor();
            try comprehension.for_expressions.append(self.allocator, comp_for);
        }
        return comprehension;
    }

    inline fn parseComprehensionFor(self: *Self) Error!ComprehensionFor {
        const target_list = try self.parseTargetList();
        try self.expectAndSkip(.in_kw);
        const iterator = try self.parseExpression(.conditional);
        var predicate_expression: ?*const AstNode = null;
        while (self.expect(.if_kw)) {
            try self.expectAndSkip(.if_kw);
            const predicate = try self.parseExpression(.conditional);
            predicate_expression = if (predicate_expression) |existing| blk: {
                const node = try self.allocator.create(AstNode);
                node.* = .{ .bool_op = .{ .lhs = existing, .rhs = predicate, .kind = .@"and" } };
                break :blk node;
            } else predicate;
        }
        return .{
            .target_list = target_list,
            .iterator = iterator,
            .predicate_expression = predicate_expression,
        };
    }

    fn parseExpressionItems(self: *Self, list: *List, terminal_token: lex.TokenTag, allow_trailing: bool) Error!void {
        while (self.peek()) |next_token| {
            if (next_token == terminal_token) break;
            try self.illegal(.comma);
            var item = try self.parseExpression(.lowest);
            if (self.expect(.for_kw)) {
                const comprehension = try self.parseComprehension(Comprehension, item);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .comprehension = comprehension };
                item = node;
            }
            try list.append(self.allocator, item);
            if (!self.expectAndSkipOptional(.comma)) break;
            if (allow_trailing and self.expect(terminal_token)) break;
        }
    }

    // https://docs.python.org/3/reference/simple_stmts.html#grammar-token-python-grammar-target_list
    fn parseTargetList(self: *Self) Error!List {
        var list: List = .empty;
        while (true) {
            // TODO: there are many more types of targets
            const target = try self.parseTarget();
            try list.append(self.allocator, target);
            self.expectAndSkip(.comma) catch break;
            if (self.expect(.in_kw)) break;
        }
        return list;
    }

    fn parseTarget(self: *Self) Error!*AstNode {
        return switch (self.peek() orelse return Error.UnexpectedEndOfStream) {
            .name => self.parseName(),
            .lparen => self.parseGroupOrGenerator(),
            else => Error.UnexpectedToken,
        };
    }

    fn parseList(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.lsbracket);
        const result = try self.allocator.create(AstNode);
        errdefer self.allocator.destroy(result);

        if (self.expect(.rsbracket)) {
            self.expectAndSkip(.rsbracket) catch unreachable;
            result.* = .{ .list = .{ .empty = {} } };
            return result;
        }

        var list_item = try self.parseListItem();

        if (self.expect(.for_kw)) {
            const comprehension = try self.parseComprehension(Comprehension, list_item.value);
            result.* = .{ .list = .{ .comprehension = comprehension } };
        } else {
            var list: std.ArrayList(ListItem) = .empty;
            while (true) {
                try list.append(self.allocator, list_item);
                self.expectAndSkip(.comma) catch break;
                // trailing commas are legal
                if (self.expect(.rsbracket)) break;
                list_item = try self.parseListItem();
            }
            result.* = .{ .list = .{ .list = list } };
        }

        try self.expectAndSkip(.rsbracket);
        return result;
    }

    fn parseDictItem(self: *Self) Error!DictItem {
        if (self.expectAndSkipOptional(.double_asterisk)) {
            const value = try self.parseExpression(.lowest);
            return .{
                .key = null,
                .value = value,
            };
        }
        const key = try self.parseExpression(.lowest);
        errdefer self.unwound = key; // we're probably dealing with a set here
        try self.expectAndSkip(.colon);
        const value = try self.parseExpression(.lowest);
        return .{
            .key = key,
            .value = value,
        };
    }

    fn parseDictionary(self: *Self) Error!*AstNode {
        var dictionary: Dictionary = .empty;
        errdefer dictionary.deinit(self.allocator);
        const result = try self.allocator.create(AstNode);
        errdefer self.allocator.destroy(result);

        if (self.expect(.rcbracket)) {
            result.* = .{ .dictionary = .{ .empty = {} } };
            return result;
        }

        var item = try self.parseDictItem();

        // Is this a comprehension?
        if (self.expect(.for_kw)) {
            // TODO: is unpacking legal here?
            const comprehension = try self.parseComprehension(DictComprehension, item);
            result.* = .{ .dictionary = .{ .comprehension = comprehension } };
            return result;
        }

        while (true) {
            try dictionary.append(self.allocator, item);
            // trailing commas are grammatically allowed
            self.expectAndSkip(.comma) catch break;
            if (self.expect(.rcbracket)) break;
            item = try self.parseDictItem();
        }
        result.* = .{ .dictionary = .{ .dictionary = dictionary } };
        return result;
    }

    fn parseListItem(self: *Self) Error!ListItem {
        const unpack = self.expectAndSkipOptional(.asterisk);
        const value = try self.parseExpression(.lowest);
        return .{
            .unpack = unpack,
            .value = value,
        };
    }

    fn parseSet(self: *Self) Error!*AstNode {
        var set: Set = .empty;
        errdefer set.deinit(self.allocator);
        const result = try self.allocator.create(AstNode);
        errdefer self.allocator.destroy(result);

        var item = try self.parseListItem();

        // Is this a comprehension?
        if (self.expect(.for_kw)) {
            const comprehension = try self.parseComprehension(Comprehension, item.value);
            result.* = .{ .set = .{ .comprehension = comprehension } };
            return result;
        }

        while (true) {
            try set.append(self.allocator, item);
            // trailing commas are grammatically allowed
            self.expectAndSkip(.comma) catch break;
            if (self.expect(.rcbracket)) break;
            item = try self.parseListItem();
        }
        result.* = .{ .set = .{ .set = set } };
        return result;
    }

    fn parseSetOrDictionary(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.lcbracket);
        // the difference between a set and a dictionary is that a set
        // has no dictionary items (i.e. "a": 1, or **variable).  An
        // empty literal "{}" is considered a dictionary according to:
        // https://docs.python.org/3/reference/expressions.html#set-displays
        const result = blk: {
            if (self.expect(.asterisk)) {
                // special case - if the first token is an asterisk
                // then we've got a set.  We can't rewind logged errors
                // e.g. nullDenotationUnhandled
                @branchHint(.unlikely);
                break :blk try self.parseSet();
            }
            break :blk self.parseDictionary() catch try self.parseSet();
        };
        try self.expectAndSkip(.rcbracket);
        return result;
    }

    fn parseName(self: *Self) Error!*AstNode {
        const name_token = try self.expectAndTake(.name);
        const name_node = try self.allocator.create(AstNode);
        name_node.* = .{ .name = .{ .value = name_token.name.value, .context = .Load } };
        return name_node;
    }

    // TODO: This is a lame way of doing this.  In most cases we want LOAD_OP over STORE_OP.  We know
    // STORE happens during assignment, but of course the left-hand-side of the parse has already passed
    // us by - so we scan the lhs for name nodes and overwrite it to STORE
    inline fn castExpressionContext(ast: *AstNode, context: ExpressionContext) void {
        switch (ast.*) {
            .name => |*name| {
                name.context = context;
            },
            else => {},
        }
    }

    fn parseAssignment(self: *Self, lhs: *AstNode) Error!*AstNode {
        const assign_token = try self.take(); // skip assign token
        assert(assign_token == .assign);
        castExpressionContext(lhs, .Store);
        const rhs = try self.parseExpressionOrTuple(.eof, false);
        const assignment_node = try self.allocator.create(AstNode);
        assignment_node.* = .{ .assignment = .{ .lhs = lhs, .rhs = rhs } };
        return assignment_node;
    }

    fn parseAugmentedAssignment(self: *Self, lhs: *AstNode) Error!*AstNode {
        const op_token = try self.take();
        const kind: AugmentedAssignmentKind = switch (op_token) {
            .plus_assign => .add,
            .minus_assign => .sub,
            .asterisk_assign => .mult,
            .at_assign => .mat_mult,
            .solidus_assign => .div,
            .double_solidus_assign => .floor_div,
            .percent_assign => .mod,
            .double_asterisk_assign => .pow,
            else => return Error.UnexpectedToken,
        };
        const rhs = try self.parseExpression(.lowest);
        const assignment_node = try self.allocator.create(AstNode);
        assignment_node.* = .{ .augmented_assignment = .{ .kind = kind, .lhs = lhs, .rhs = rhs } };
        return assignment_node;
    }

    fn parseAnnotatedAssignment(self: *Self, lhs: *AstNode) Error!*AstNode {
        const colon_token = try self.take();
        assert(colon_token == .colon);
        castExpressionContext(lhs, .Store);
        const annotation = try self.parseExpression(.equality);
        const value = if (self.expectAndSkipOptional(.assign))
            try self.parseExpressionOrTuple(.eof, false)
        else
            null;
        const assignment_node = try self.allocator.create(AstNode);
        assignment_node.* = .{ .annotated_assignment = .{
            .lhs = lhs,
            .annotation = annotation,
            .value = value,
        } };
        return assignment_node;
    }

    fn parseNamedExpression(self: *Self, lhs: *AstNode) Error!*AstNode {
        const walrus_token = try self.take(); // skip walrus token
        assert(walrus_token == .walrus);
        castExpressionContext(lhs, .Store);
        const rhs = try self.parseExpression(.equality);
        const named_expression_node = try self.allocator.create(AstNode);
        named_expression_node.* = .{ .named_expression = .{ .lhs = lhs, .rhs = rhs } };
        return named_expression_node;
    }

    fn parseYield(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.yield_kw);
        const result = try self.allocator.create(AstNode);
        errdefer self.allocator.destroy(result);

        if (self.expectAndSkipOptional(.from_kw)) {
            const expression = try self.parseExpression(.lowest);
            result.* = .{ .yield = .{ .expression = expression } };
        } else {
            var list: std.ArrayList(ListItem) = .empty;
            errdefer list.deinit(self.allocator);

            while (true) {
                const list_item = try self.parseListItem();
                try list.append(self.allocator, list_item);
                self.expectAndSkip(.comma) catch break;
            }
            result.* = .{ .yield = .{ .list = list } };
        }

        return result;
    }

    fn parseReturn(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.return_kw);
        const expressions = try self.parseExpressionList();
        const return_node = try self.allocator.create(AstNode);
        return_node.* = .{ .@"return" = expressions };
        return return_node;
    }

    fn parseAwait(self: *Self) Error!*AstNode {
        // TODO: we don't have the concept of a "primary", but
        // technically we should not allow parsing arbitrary
        // expressions if we want to align with the python grammar
        try self.expectAndSkip(.await_kw);
        const expression = try self.parseExpression(.lowest);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .await = expression };
        return node;
    }

    // a "suite" is the block following the colon in compound statements
    fn parseSuite(self: *Self, owner_indent: lex.IndentLength) Error!Statement {
        const colon = try self.expectAndTake(.colon);
        if (self.peek()) |next| {
            if (next.getLocation().line == colon.getLocation().line) {
                var statement: Statement = .empty;
                try statement.append(self.allocator, try self.parseStatement());
                return statement;
            }
        }
        return self.parseStatementWithIndent(owner_indent);
    }

    fn parseParameter(self: *Self, with_star: bool, with_annotation: bool) Error!Parameter {
        if (with_star) {
            if (self.expectAndSkipOptional(.double_asterisk)) {} else if (self.expectAndSkipOptional(.asterisk)) {}
        }
        const identifier = try self.parseName();
        const annotation = blk: {
            if (with_annotation and self.expectAndSkipOptional(.colon)) {
                break :blk try self.parseExpression(.equality);
            } else break :blk null;
        };
        const default_value = if (self.expectAndSkipOptional(.assign))
            try self.parseExpression(.equality)
        else
            null;

        return .{
            .identifier = identifier,
            .annotation = annotation,
            .default_value = default_value,
        };
    }

    fn parseParameterList(self: *Self, with_star: bool, with_annotation: bool) Error!ParameterList {
        var parameters: ParameterList = .empty;

        while (true) {
            const parameter = self.parseParameter(with_star, with_annotation) catch break;
            try parameters.append(self.allocator, parameter);
            self.expectAndSkip(.comma) catch break;
        }

        return parameters;
    }

    fn parseExpressionList(self: *Self) Error!List {
        var expressions: List = .empty;
        try self.parseExpressionItems(&expressions, .eof, false);
        return expressions;
    }

    // https://docs.python.org/3/reference/compound_stmts.html#grammar-token-python-grammar-parameter_list
    fn parseParameters(self: *Self, with_annotation: bool) Error!Parameters {
        const posargs = try self.parseParameterList(false, with_annotation);
        var posargs2: ParameterList = undefined;
        var positional_only_arguments = false;

        if (self.expectAndSkipOptional(.solidus)) {
            positional_only_arguments = true;
            _ = self.expectAndSkipOptional(.comma);
            posargs2 = try self.parseParameterList(false, with_annotation);
        }

        var starred_parameters: ParameterList = .empty;
        if (self.expectAndSkipOptional(.asterisk)) {
            if (self.expectAndSkipOptional(.comma)) {} else {
                try starred_parameters.append(self.allocator, try self.parseParameter(false, with_annotation));
                _ = self.expectAndSkipOptional(.comma);
            }
        }
        var kwargs = try self.parseParameterList(true, with_annotation);
        if (starred_parameters.items.len > 0) {
            try starred_parameters.appendSlice(self.allocator, kwargs.items);
            kwargs = starred_parameters;
        }

        return .{
            .arguments = if (positional_only_arguments) posargs2 else posargs,
            .position_only_arguments = if (positional_only_arguments) posargs else .empty,
            .keyword_only_arguments = kwargs,
        };
    }

    // https://docs.python.org/3/reference/compound_stmts.html#function
    fn parseFunctionDefinition(self: *Self) Error!*AstNode {
        const def_kw_token = try self.take(); // skip fn_decl token
        assert(def_kw_token == .def_kw);
        const name_token = try self.take();
        if (name_token != .name) return Error.UnexpectedToken;

        try self.expectAndSkip(.lparen);
        const parameters = try self.parseParameters(true);
        try self.expectAndSkip(.rparen);
        if (self.expectAndSkipOptional(.minus)) {
            try self.expectAndSkip(.rabracket);
            _ = try self.parseExpression(.lowest);
        }

        const fn_decl = try self.allocator.create(AstNode);
        fn_decl.* = .{ .fn_decl = .{
            .name = name_token.name.value,
            .parameters = parameters,
            .suite = try self.parseSuite(def_kw_token.getLocation().indent),
        } };

        return fn_decl;
    }

    fn parseAsyncStatement(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.async_kw);
        const node = switch (self.peek() orelse return Error.UnexpectedEndOfStream) {
            .def_kw => try self.parseFunctionDefinition(),
            .for_kw => try self.parseForStatement(),
            .with_kw => try self.parseWithStatement(),
            else => return Error.UnexpectedToken,
        };
        if (node.* == .fn_decl) node.fn_decl.async = true;
        return node;
    }

    // https://docs.python.org/3/reference/expressions.html#lambda
    fn parseLambdaDefinition(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.lambda_kw);
        // the language reference BNF grammar snippets imply that lambdas have
        // the same parameter_list grammar as functions which is not true if you
        // read the text.  We skip annotations as that would lead to ambiguity
        const parameters = try self.parseParameters(false);
        try self.expectAndSkip(.colon);
        const body = try self.parseExpression(.lowest);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .lambda = .{
            .parameters = parameters,
            .expression = body,
        } };
        return node;
    }

    fn parseFunctionCall(self: *Self, lhs: *AstNode) Error!*AstNode {
        self.expectAndSkip(.lparen) catch unreachable;
        var call_node = try self.allocator.create(AstNode);
        call_node.* = .{ .call = .{ .ref = lhs, .args = .empty } };
        try self.parseExpressionItems(&call_node.call.args, .rparen, true);
        try self.expectAndSkip(.rparen);
        return call_node;
    }

    fn parseClassDefinition(self: *Self) Error!*AstNode {
        const class_kw = self.expectAndTake(.class_kw) catch unreachable;
        const name_token = try self.expectAndTake(.name);
        const class_node = try self.allocator.create(AstNode);
        var baseclass: ?*const AstNode = null;
        if (self.expect(.lparen)) {
            self.expectAndSkip(.lparen) catch unreachable;
            if (!self.expect(.rparen)) {
                baseclass = try self.parseExpression(.lowest);
                while (self.expectAndSkipOptional(.comma)) {
                    if (self.expect(.rparen)) break;
                    _ = try self.parseExpression(.lowest);
                }
            }
            try self.expectAndSkip(.rparen);
        }
        class_node.* = .{ .class = .{
            .name = name_token.name.value,
            .baseclass = baseclass,
            .suite = try self.parseSuite(class_kw.getLocation().indent),
        } };

        return class_node;
    }

    fn parseFieldAccess(self: *Self, lhs: *AstNode) Error!*AstNode {
        const dot_token = try self.take(); // skip dot token
        assert(dot_token == .dot);
        const rhs = try self.parseExpression(.call);
        const field_access_node = try self.allocator.create(AstNode);
        field_access_node.* = .{ .field_access = .{ .lhs = lhs, .rhs = rhs } };
        return field_access_node;
    }

    fn parseSubscript(self: *Self, lhs: *AstNode) Error!*AstNode {
        try self.expectAndSkip(.lsbracket);
        const index = try self.parseSubscriptList();
        try self.expectAndSkip(.rsbracket);
        const subscript_node = try self.allocator.create(AstNode);
        subscript_node.* = .{ .subscript = .{ .lhs = lhs, .rhs = index } };
        return subscript_node;
    }

    fn parseSubscriptList(self: *Self) Error!*AstNode {
        const first = try self.parseSubscriptItem();
        if (!self.expectAndSkipOptional(.comma)) return first;

        var list: List = .empty;
        try list.append(self.allocator, first);
        while (self.peek()) |next_token| {
            if (next_token == .rsbracket) break;
            const item = try self.parseSubscriptItem();
            try list.append(self.allocator, item);
            if (!self.expectAndSkipOptional(.comma)) break;
        }

        const tuple = try self.allocator.create(AstNode);
        tuple.* = .{ .tuple = list };
        return tuple;
    }

    fn parseSubscriptItem(self: *Self) Error!*AstNode {
        if (self.expectAndSkipOptional(.colon)) return self.parseSlice(null);

        const first = try self.parseExpression(.lowest);
        if (!self.expectAndSkipOptional(.colon)) return first;
        return self.parseSlice(first);
    }

    fn parseSlice(self: *Self, start: ?*const AstNode) Error!*AstNode {
        const stop = if (!self.expect(.colon) and !self.expect(.rsbracket) and !self.expect(.comma))
            try self.parseExpression(.lowest)
        else
            null;

        const step = if (self.expectAndSkipOptional(.colon)) blk: {
            if (self.expect(.rsbracket) or self.expect(.comma)) break :blk null;
            break :blk try self.parseExpression(.lowest);
        } else null;

        const node = try self.allocator.create(AstNode);
        node.* = .{ .slice = .{ .start = start, .stop = stop, .step = step } };
        return node;
    }

    fn parseForStatement(self: *Self) Error!*AstNode {
        const for_kw = try self.expectAndTake(.for_kw);
        const target_list = try self.parseTargetList();
        try self.expectAndSkip(.in_kw);
        const iterable = try self.parseExpressionOrTuple(.colon, true);
        const for_in = try self.allocator.create(AstNode);
        const indent = for_kw.getLocation().indent;
        const suite = try self.parseSuite(indent);
        var else_suite: ?Statement = null;
        blk: {
            self.expectAndSkip(.else_kw) catch break :blk;
            else_suite = try self.parseSuite(indent);
        }
        for_in.* = .{ .for_in = .{
            .target_list = target_list,
            .iterable = iterable,
            .suite = suite,
            .else_suite = else_suite,
        } };
        return for_in;
    }

    fn parseIfStatement(self: *Self) Error!*AstNode {
        const if_kw = try self.expectAndTake(.if_kw);
        const predicate = try self.parseExpression(.lowest);
        const indent = if_kw.getLocation().indent;
        const suite = try self.parseSuite(indent);
        const else_suite = try self.parseIfTail(indent);
        const if_node = try self.allocator.create(AstNode);
        if_node.* = .{ .if_stmt = .{
            .predicate = predicate,
            .suite = suite,
            .else_suite = else_suite,
        } };
        return if_node;
    }

    fn parseIfTail(self: *Self, indent: lex.IndentLength) Error!?Statement {
        if (self.expectAndSkipOptional(.else_kw)) {
            return try self.parseSuite(indent);
        }
        if (!self.expect(.elif_kw)) return null;

        const elif_kw = try self.expectAndTake(.elif_kw);
        const predicate = try self.parseExpression(.lowest);
        const suite = try self.parseSuite(elif_kw.getLocation().indent);
        const else_suite = try self.parseIfTail(indent);

        const nested_if = try self.allocator.create(AstNode);
        nested_if.* = .{ .if_stmt = .{
            .predicate = predicate,
            .suite = suite,
            .else_suite = else_suite,
        } };

        var statements: Statement = .empty;
        try statements.append(self.allocator, .{ .node = nested_if });
        return statements;
    }

    fn parseWhileStatement(self: *Self) Error!*AstNode {
        const while_kw = try self.expectAndTake(.while_kw);
        const predicate = try self.parseExpression(.lowest);
        const indent = while_kw.getLocation().indent;
        const suite = try self.parseSuite(indent);
        var else_suite: ?Statement = null;
        blk: {
            self.expectAndSkip(.else_kw) catch break :blk;
            else_suite = try self.parseSuite(indent);
        }
        const while_node = try self.allocator.create(AstNode);
        while_node.* = .{ .while_stmt = .{
            .predicate = predicate,
            .suite = suite,
            .else_suite = else_suite,
        } };
        return while_node;
    }

    fn parseTryStatement(self: *Self) Error!*AstNode {
        const try_kw = try self.expectAndTake(.try_kw);
        const indent = try_kw.getLocation().indent;
        const suite = try self.parseSuite(indent);

        var except_handlers: std.ArrayList(ExceptHandler) = .empty;
        while (self.expect(.except_kw)) {
            try except_handlers.append(self.allocator, try self.parseExceptHandler(indent));
        }

        const else_suite = blk: {
            if (!self.expectAndSkipOptional(.else_kw)) break :blk null;
            break :blk try self.parseSuite(indent);
        };
        const finally_suite = blk: {
            if (!self.expectAndSkipOptional(.finally_kw)) break :blk null;
            break :blk try self.parseSuite(indent);
        };

        const try_node = try self.allocator.create(AstNode);
        try_node.* = .{ .try_stmt = .{
            .suite = suite,
            .except_handlers = except_handlers,
            .else_suite = else_suite,
            .finally_suite = finally_suite,
        } };
        return try_node;
    }

    fn parseExceptHandler(self: *Self, owner_indent: lex.IndentLength) Error!ExceptHandler {
        try self.expectAndSkip(.except_kw);
        _ = self.expectAndSkipOptional(.asterisk);
        const expression = if (self.expect(.colon))
            null
        else
            try self.parseExpression(.lowest);
        const alias = blk: {
            if (!self.expectAndSkipOptional(.as_kw)) break :blk null;
            break :blk (try self.expectAndTake(.name)).name.value;
        };
        return .{
            .expression = expression,
            .alias = alias,
            .suite = try self.parseSuite(owner_indent),
        };
    }

    fn parseWithStatement(self: *Self) Error!*AstNode {
        const with_kw = try self.expectAndTake(.with_kw);
        var items: std.ArrayList(WithItem) = .empty;
        const parenthesized = self.expectAndSkipOptional(.lparen);
        while (true) {
            if (parenthesized and self.expect(.rparen)) break;
            const expression = try self.parseExpression(.lowest);
            const alias = blk: {
                if (!self.expectAndSkipOptional(.as_kw)) break :blk null;
                break :blk try self.parseTarget();
            };
            try items.append(self.allocator, .{ .expression = expression, .alias = alias });
            if (parenthesized) {
                if (!self.expectAndSkipOptional(.comma) and self.expect(.rparen)) break;
            } else if (!self.expectAndSkipOptional(.comma)) break;
        }
        if (parenthesized) try self.expectAndSkip(.rparen);

        const with_node = try self.allocator.create(AstNode);
        with_node.* = .{ .with_stmt = .{
            .items = items,
            .suite = try self.parseSuite(with_kw.getLocation().indent),
        } };
        return with_node;
    }

    fn parseContinue(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.continue_kw);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .continue_stmt = {} };
        return node;
    }

    fn parseBreak(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.break_kw);
        const node = try self.allocator.create(AstNode);
        node.* = .{ .break_stmt = {} };
        return node;
    }

    fn parseRaise(self: *Self) Error!*AstNode {
        const raise_token = try self.expectAndTake(.raise_kw);
        const expression = blk: {
            const next = self.peek() orelse break :blk null;
            if (next.getLocation().line != raise_token.getLocation().line) break :blk null;
            break :blk try self.parseExpression(.lowest);
        };
        const cause = blk: {
            if (!self.expectAndSkipOptional(.from_kw)) break :blk null;
            break :blk try self.parseExpression(.lowest);
        };
        const node = try self.allocator.create(AstNode);
        node.* = .{ .raise_stmt = .{ .expression = expression, .cause = cause } };
        return node;
    }

    fn parseAssert(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.assert_kw);
        const predicate = try self.parseExpression(.lowest);
        const message = if (self.expectAndSkipOptional(.comma))
            try self.parseExpression(.lowest)
        else
            null;
        const node = try self.allocator.create(AstNode);
        node.* = .{ .assert_stmt = .{ .predicate = predicate, .message = message } };
        return node;
    }

    fn parseImport(self: *Self) Error!*AstNode {
        self.expectAndSkip(.import_kw) catch unreachable;
        var list: std.ArrayList(ImportDefinition) = .empty;

        while (true) {
            const package = try self.parsePackageSpec(true);
            var import_def = ImportDefinition{ .module = package.refspec, .package = package, .alias = null };
            if (self.expect(.as_kw)) {
                self.expectAndSkip(.as_kw) catch unreachable;
                const ref = Ref{ .symbol = (try self.expectAndTake(.name)).name.value };
                import_def.alias = ref;
            }
            try list.append(self.allocator, import_def);
            self.expectAndSkip(.comma) catch break;
        }
        const result = try self.allocator.create(AstNode);
        result.* = .{ .import = try list.toOwnedSlice(self.allocator) };
        return result;
    }

    fn parseFromImport(self: *Self) Error!*AstNode {
        self.expectAndSkip(.from_kw) catch unreachable;
        var list: std.ArrayList(ImportDefinition) = .empty;
        const module = try self.parseRefSpec();

        try self.expectAndSkip(.import_kw);

        if (self.expectAndSkipOptional(.lparen)) {
            while (!self.expect(.rparen)) {
                const package = try self.parsePackageSpec(false);
                var import_def = ImportDefinition{ .module = module, .package = package, .alias = null };
                if (self.expect(.as_kw)) {
                    self.expectAndSkip(.as_kw) catch unreachable;
                    const ref = Ref{ .symbol = (try self.expectAndTake(.name)).name.value };
                    import_def.alias = ref;
                }
                try list.append(self.allocator, import_def);
                if (!self.expectAndSkipOptional(.comma)) break;
            }
            try self.expectAndSkip(.rparen);
        } else {
            while (true) {
                const package = try self.parsePackageSpec(false);
                var import_def = ImportDefinition{ .module = module, .package = package, .alias = null };
                if (self.expect(.as_kw)) {
                    self.expectAndSkip(.as_kw) catch unreachable;
                    const ref = Ref{ .symbol = (try self.expectAndTake(.name)).name.value };
                    import_def.alias = ref;
                }
                try list.append(self.allocator, import_def);
                self.expectAndSkip(.comma) catch break;
            }
        }
        const result = try self.allocator.create(AstNode);
        result.* = .{ .import = try list.toOwnedSlice(self.allocator) };
        return result;
    }

    fn parsePackageSpec(self: *Self, comptime refspec_only: bool) Error!PackageSpec {
        const token = self.peek() orelse return Error.UnexpectedEndOfStream;
        switch (token) {
            .name => {
                return PackageSpec{ .refspec = try self.parseRefSpec() };
            },
            .asterisk => {
                if (refspec_only) {
                    // TODO: publish error message
                    return Error.UnexpectedToken;
                } else {
                    // should we just take instead?
                    self.expectAndSkip(.asterisk) catch unreachable;
                    return PackageSpec{ .star = {} };
                }
            },
            else => {
                // TODO: publish error message
                return Error.UnexpectedToken;
            },
        }
    }

    fn parseRefSpec(self: *Self) Error!RefSpec {
        var ref_spec: std.ArrayList(Ref) = .empty;
        while (true) {
            const ref = Ref{ .symbol = (try self.expectAndTake(.name)).name.value };
            try ref_spec.append(self.allocator, ref);
            self.expectAndSkip(.dot) catch break;
        }
        const owned = ref_spec.toOwnedSlice(self.allocator);
        const results = RefSpec{ .refs = try owned };
        return results;
    }
};

// Test arithmetic

test "parse: infix sum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "1 + 2");
    const result = try parser.parseSimpleExpression();
    try testing.expect(result.* == AstNode.add);
    try testing.expect(result.add.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(1)), result.add.lhs.integer.value);
    try testing.expect(result.add.rhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(2)), result.add.rhs.integer.value);
}

test "parse: infix product" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "1 + 2 * 3");
    const result = try parser.parseSimpleExpression();
    try testing.expect(result.* == AstNode.add);
    try testing.expect(result.add.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(1)), result.add.lhs.integer.value);
    try testing.expect(result.add.rhs.* == AstNode.mult);
    try testing.expect(result.add.rhs.mult.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(2)), result.add.rhs.mult.lhs.integer.value);
    try testing.expect(result.add.rhs.mult.rhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(3)), result.add.rhs.mult.rhs.integer.value);
}

test "parse: infix division" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "1 + 2 / 3");
    const result = try parser.parseSimpleExpression();
    try testing.expect(result.* == AstNode.add);
    try testing.expect(result.add.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(1)), result.add.lhs.integer.value);
    try testing.expect(result.add.rhs.* == AstNode.div);
    try testing.expect(result.add.rhs.div.lhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(2)), result.add.rhs.div.lhs.integer.value);
    try testing.expect(result.add.rhs.div.rhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(3)), result.add.rhs.div.rhs.integer.value);
}

test "parse: group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "(1 + 2) / 3");
    const result = try parser.parseSimpleExpression();

    try testing.expect(result.* == .div);
    try testing.expect(result.div.lhs.* == .group);
    try testing.expect(result.div.lhs.group.value.* == .add);
    try testing.expect(result.div.lhs.group.value.add.lhs.* == .integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(1)), result.div.lhs.group.value.add.lhs.integer.value);
    try testing.expect(result.div.lhs.group.value.add.rhs.* == .integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(2)), result.div.lhs.group.value.add.rhs.integer.value);
    try testing.expect(result.div.rhs.* == .integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(3)), result.div.rhs.integer.value);
}

// Test Assignment

test "parse: assign" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "a = 1");
    const result = try parser.parseSimpleExpression();

    try testing.expect(result.* == AstNode.assignment);
    try testing.expect(result.assignment.lhs.* == AstNode.name);
    try testing.expectEqualSlices(u8, "a", result.assignment.lhs.name.value);
    try testing.expect(result.assignment.rhs.* == AstNode.integer);
    try testing.expectEqual(@as(ObjectInt, @intCast(1)), result.assignment.rhs.integer.value);
}

test "parse: string literal" {
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "\"yo\"");
        const result = try parser.parseSimpleExpression();
        try testing.expect(@as(AstNodeTag, result.*) == .string_literal);
        try testing.expectEqualStrings("yo", result.string_literal.value);
    }
    { // docstring
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "'''yo'''");
        const result = try parser.parseSimpleExpression();
        try testing.expect(@as(AstNodeTag, result.*) == .string_literal);
        try testing.expectEqualStrings("yo", result.string_literal.value);
    }
}

test "parse: array literal" {
    { // Empty Array
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[]");
        const result = try parser.parseSimpleExpression();
        try testing.expect(result.list == .empty);
    }
    { // single element
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[1]");
        const result = try parser.parseSimpleExpression();
        try testing.expect(result.list.list.items.len == 1);
    }
    { // trailing comma
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[1,]");
        const result = try parser.parseSimpleExpression();
        try testing.expect(result.list.list.items.len == 1);
    }
    { // Unclosed
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[1,");
        try testing.expectError(Parser.Error.UnexpectedEndOfStream, parser.parseSimpleExpression());
    }
    { // illegal trailing comma
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[,]");
        try testing.expectError(error.DiagnosticError, parser.parseSimpleExpression());
    }
}

test "parse: declare function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    // you can thank zig 0.14.0 for this
    const fn_decl = "def myFunction():\n\ta = 1\n\ta * 3";
    var parser = Parser.init(allocator, fn_decl);
    const result = try parser.parseSimpleExpression();

    try testing.expect(result.* == AstNode.fn_decl);
    try testing.expectEqualSlices(u8, "myFunction", result.fn_decl.name);

    // Statement
    try testing.expectEqual(@as(usize, 2), result.fn_decl.suite.items.len);
    const expr1 = result.fn_decl.suite.items[0];
    try testing.expect(expr1.expr.* == AstNode.assignment);
    const expr2 = result.fn_decl.suite.items[1];
    try testing.expect(expr2.expr.* == AstNode.mult);
}

test "parse: call function" {
    { // no args
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var parser = Parser.init(allocator, "myFunction()");
        const result = try parser.parseSimpleExpression();

        try testing.expect(result.* == AstNode.call);
        try testing.expectEqualSlices(u8, "myFunction", result.call.ref.name.value);
        try testing.expectEqual(@as(usize, 0), result.call.args.items.len);
    }
    { // single arg
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var parser = Parser.init(allocator, "myFunction(1 + 1)");
        const result = try parser.parseSimpleExpression();

        try testing.expect(result.* == AstNode.call);
        try testing.expectEqualSlices(u8, "myFunction", result.call.ref.name.value);

        try testing.expectEqual(@as(usize, 1), result.call.args.items.len);
    }
    { // multiple args
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var parser = Parser.init(allocator, "myFunction(1, 1)");
        const result = try parser.parseSimpleExpression();

        try testing.expect(result.* == AstNode.call);
        try testing.expectEqualSlices(u8, "myFunction", result.call.ref.name.value);

        try testing.expectEqual(@as(usize, 2), result.call.args.items.len);
    }
}

test "parse: class definition" {
    { // trivial class
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        const class = "class Foo:\n\tpass";
        var parser = Parser.init(allocator, class);
        const result = (try parser.parse()).root[0].node;

        try testing.expectEqual(AstNode.class, std.meta.activeTag(result.*));
        try testing.expectEqualStrings("Foo", result.class.name);
        try testing.expect(result.class.baseclass == null);
        try testing.expectEqual(@as(usize, 1), result.class.suite.items.len);
    }
    { // implied baseclass
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        const class = "class Foo():\n\tpass";
        var parser = Parser.init(allocator, class);
        const result = (try parser.parse()).root[0].node;

        try testing.expectEqual(AstNode.class, @as(AstNodeTag, result.*));
        try testing.expectEqualStrings("Foo", result.class.name);
        try testing.expect(result.class.baseclass == null);
        try testing.expectEqual(@as(usize, 1), result.class.suite.items.len);
    }
    { // with baseclass
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        const class = "class Foo(Bar):\n\tpass";
        var parser = Parser.init(allocator, class);
        const result = (try parser.parse()).root[0].node;
        try testing.expectEqual(AstNode.class, @as(AstNodeTag, result.*));
        try testing.expectEqualStrings("Foo", result.class.name);
        try testing.expectEqual(AstNode.name, @as(AstNodeTag, result.class.baseclass.?.*));
        try testing.expectEqualStrings("Bar", result.class.baseclass.?.name.value);
        try testing.expectEqual(@as(ExpressionContext, .Load), result.class.baseclass.?.name.context);
        try testing.expectEqual(@as(usize, 1), result.class.suite.items.len);
    }
    { // dotted baseclass
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        const class = "class Foo(unittest.TestCase):\n\tpass";
        var parser = Parser.init(allocator, class);
        const result = (try parser.parse()).root[0].node;
        try testing.expectEqual(AstNode.class, @as(AstNodeTag, result.*));
        try testing.expectEqual(AstNode.field_access, @as(AstNodeTag, result.class.baseclass.?.*));
        try testing.expectEqualStrings("unittest", result.class.baseclass.?.field_access.lhs.name.value);
        try testing.expectEqualStrings("TestCase", result.class.baseclass.?.field_access.rhs.name.value);
        try testing.expectEqual(@as(usize, 1), result.class.suite.items.len);
    }
}

test "parse: access field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var parser = Parser.init(allocator, "foo.bar");
    const result = try parser.parseSimpleExpression();

    try testing.expect(result.* == AstNode.field_access);
    try testing.expectEqualSlices(u8, "foo", result.field_access.lhs.name.value);
    try testing.expectEqualSlices(u8, "bar", result.field_access.rhs.name.value);
}

test "parse: imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();
    // from sys import *
    // from time import (time)
    // from sys import path, argv
    // from sys import (path, argv)
    // from sys import (path, argv,)
    // from test.support import import_helper
    { // trivial class
        var parser = Parser.init(allocator, "import sys");
        const result = (try parser.parse()).root[0].node;

        try testing.expectEqual(AstNode.import, @as(AstNodeTag, result.*));
        // count of import expressions i.e. import (foo, bar) == 2
        try testing.expectEqual(@as(usize, 1), result.import.len);

        const import_def = result.import[0];
        // count of source i.e. os.path == 2
        try testing.expectEqual(@as(usize, 1), import_def.module.refs.len);
        try testing.expectEqualStrings("sys", import_def.module.refs[0].symbol);
        try testing.expect(import_def.alias == null);
        try testing.expectEqualStrings("sys", import_def.package.refspec.refs[0].symbol);
    }
    { // import multiple
        var parser = Parser.init(allocator, "import time as yo, sys as dude");
        const result = (try parser.parse()).root[0].node;

        try testing.expectEqual(AstNode.import, @as(AstNodeTag, result.*));
        // count of import expressions i.e. import (foo, bar) == 2
        try testing.expectEqual(@as(usize, 2), result.import.len);

        var import_def = result.import[0];
        // count of source i.e. os.path == 2
        try testing.expectEqual(@as(usize, 1), import_def.module.refs.len);
        try testing.expectEqualStrings("time", import_def.module.refs[0].symbol);
        // try testing.expectEqualStrings("yo", import_def.alias.ref.symbol);
        try testing.expectEqualStrings("time", import_def.package.refspec.refs[0].symbol);

        import_def = result.import[1];
        // count of source i.e. os.path == 2
        try testing.expectEqual(@as(usize, 1), import_def.module.refs.len);
        try testing.expectEqualStrings("sys", import_def.module.refs[0].symbol);
        // try testing.expectEqualStrings("dude", import_def.alias.?);
        try testing.expectEqualStrings("sys", import_def.package.refspec.refs[0].symbol);
    }
    { // import multiple
        var parser = Parser.init(allocator, "from foo.bar import time as yo, sys as dude");
        const result = (try parser.parse()).root[0].node;

        try testing.expectEqual(AstNode.import, @as(AstNodeTag, result.*));

        try testing.expectEqual(@as(usize, 2), result.import.len);

        var import_def = result.import[0];
        // count of source i.e. os.path == 2
        try testing.expectEqual(@as(usize, 2), import_def.module.refs.len);
        try testing.expectEqualStrings("foo", import_def.module.refs[0].symbol);
        try testing.expectEqualStrings("bar", import_def.module.refs[1].symbol);
        try testing.expectEqualStrings("time", import_def.package.refspec.refs[0].symbol);
        try testing.expectEqualStrings("yo", import_def.alias.?.symbol);
        import_def = result.import[1];
        // count of source i.e. os.path == 2
        try testing.expectEqual(@as(usize, 2), import_def.module.refs.len);
        try testing.expectEqualStrings("foo", import_def.module.refs[0].symbol);
        try testing.expectEqualStrings("bar", import_def.module.refs[1].symbol);
        try testing.expectEqualStrings("sys", import_def.package.refspec.refs[0].symbol);
        try testing.expectEqualStrings("dude", import_def.alias.?.symbol);
    }
    { // import star
        // TODO: write assertion that star cannot be aliased
        var parser = Parser.init(allocator, "from foo.bar import *");
        const result = (try parser.parse()).root[0].node;

        try testing.expectEqual(AstNode.import, @as(AstNodeTag, result.*));

        try testing.expectEqual(@as(usize, 1), result.import.len);

        const import_def = result.import[0];
        // count of source i.e. os.path == 2
        try testing.expectEqual(@as(usize, 2), import_def.module.refs.len);
        try testing.expectEqualStrings("foo", import_def.module.refs[0].symbol);
        try testing.expectEqualStrings("bar", import_def.module.refs[1].symbol);
        try testing.expectEqualStrings("star", @tagName(import_def.package));
    }
}

test "parse: example fixtures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    inline for (test_examples) |example| {
        if (!example.test_parse) continue;
        var parser = Parser.init(allocator, example.source());
        _ = parser.parse() catch |err| {
            switch (err) {
                diagnostic.Error.DiagnosticError => try diagnostic.printDiagnostics(testing.io, testing.allocator, example.source()),
                else => std.debug.print("\n*** An error has occurred which should be emitted as a diagnostic ***\n", .{}),
            }
            return err;
        };
    }
}
