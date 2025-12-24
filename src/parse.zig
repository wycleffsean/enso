const std = @import("std");
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
    unary_op,
    bool_op,
    comparison,
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
    name,
    var_decl,
    parameter,
    parameters,
    fn_decl,
    lambda,
    assignment,
    named_expression,
    call,
    field_access,
    list,
    set,
    dictionary,
    target_list,
    for_in,
    conditional,
    comprehension,
    string_literal,
    class,
    import,
    yield,
    @"await",
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
const Statement = List;
const ClassDefinition = struct {
    name: []const u8,
    baseclass: ?[]const u8,
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

const Yield = union(enum) {
    expression: *const AstNode,
    list: std.ArrayList(ListItem),
};

pub const AstNode = union(AstNodeTag) {
    root: []*const AstNode,
    pass: void,
    bool: bool,
    integer: struct { value: ObjectInt },
    float: struct { value: ObjectFloat },
    complex: struct { real: ObjectFloat, imaginary: ObjectFloat },
    unary_op: UnaryOp,
    bool_op: BoolOp,
    comparison: Comparison,
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
    name: struct { value: []const u8, context: ExpressionContext },
    var_decl: struct { name: []const u8 },
    parameter: Parameter,
    parameters: Parameters,
    fn_decl: struct { name: []const u8, @"async": bool = false, parameters: Parameters, suite: Statement },
    lambda: struct { parameters: Parameters, body: *const AstNode },
    assignment: BinaryOp,
    named_expression: BinaryOp,
    call: struct { ref: *const AstNode, args: List, discard_return_value: bool = false },
    field_access: BinaryOp,
    list: ListDisplay,
    set: SetDisplay,
    dictionary: DictionaryDisplay,
    target_list: List,
    for_in: struct { target_list: List, iterable: *const AstNode, suite: Statement, else_suite: ?Statement },
    conditional: struct { predicate: *const AstNode, lhs: *const AstNode, rhs: *const AstNode },
    comprehension: Comprehension,
    string_literal: struct { value: []const u8 },
    class: ClassDefinition,
    import: []ImportDefinition,
    yield: Yield,
    @"await": *const AstNode,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lex.Lexer,
    peeked: ?Token = null,
    //taken: ?Token = null,
    // sometimes there is enough ambiguity in the lanaguage
    // that we have to rewind the parser and pursue another path.
    // rather than rewind the token stream and bother parsing again,
    // we retain the and return the last successfully parsed expression
    unwound: ?*AstNode = null,

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
        const root = try self.allocator.create(AstNode);
        // const statement = try self.parseStatement();
        var statement = std.ArrayList(*const AstNode).init(self.allocator);
        while (self.peek()) |token| {
            _ = token;
            try statement.append(try self.parseExpression(.lowest));
        }
        root.* = AstNode{ .root = try statement.toOwnedSlice() };
        return root;
    }

    fn parseStatementWithIndent(self: *Self, owner_indent: lex.IndentLength) Error!Statement {
        var statement = Statement.init(self.allocator);
        while (self.peek()) |next_token| {
            if (next_token.getLocation().indent <= owner_indent) break;
            try statement.append(try self.parseExpression(.lowest));
        }
        return statement;
    }

    // fn parseStatement(self: *Self) Error!*Statement {
    //     var statement = Statement.init(self.allocator);
    //     while (self.peek()) |token| {
    //         _ = token;
    //         try statement.append(try self.parseExpression(.lowest));
    //     }
    //     return &statement;
    // }

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
        .{ .float, .lowest, parseFloat, leftDenotationUnhandled },
        .{ .imaginary, .lowest, parseImaginary, leftDenotationUnhandled },
        .{ .plus, .sum, parseUnaryOp, parseBinaryOp },
        .{ .asterisk, .product, nullDenotationUnhandled, parseBinaryOp },
        .{ .double_asterisk, .product, nullDenotationUnhandled, parseBinaryOp },
        .{ .solidus, .product, nullDenotationUnhandled, parseBinaryOp },
        .{ .double_solidus, .product, nullDenotationUnhandled, parseBinaryOp },
        .{ .rparen, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .name, .lowest, parseName, leftDenotationUnhandled },
        .{ .assign, .equality, nullDenotationUnhandled, parseAssignment },
        .{ .walrus, .equality, nullDenotationUnhandled, parseNamedExpression },
        // TODO: kinda dumb we call it equality but doesn't align with the
        //   'equality' precedence.  let's fix that
        .{ .equality, .lessgreater, nullDenotationUnhandled, parseComparison },
        .{ .lparen, .call, parseGroupOrGenerator, parseFunctionCall },
        .{ .at, .product, nullDenotationUnhandled, parseBinaryOp },
        .{ .string, .lowest, parseStringLiteral, leftDenotationUnhandled },
        .{ .dot, .call, nullDenotationUnhandled, parseFieldAccess },
        .{ .colon, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .comma, .lowest, nullDenotationIllegal, leftDenotationUnhandled },
        .{ .pipe, .lowest, nullDenotationUnhandled, parseBinaryOp },
        .{ .minus, .prefix, parseUnaryOp, parseBinaryOp },
        .{ .percent, .product, nullDenotationUnhandled, parseBinaryOp },
        .{ .labracket, .lessgreater, nullDenotationIllegal, parseComparison },
        .{ .rabracket, .lessgreater, nullDenotationUnhandled, parseComparison },
        .{ .leq, .lessgreater, nullDenotationUnhandled, parseComparison },
        .{ .geq, .lessgreater, nullDenotationUnhandled, parseComparison },
        .{ .neq, .lessgreater, nullDenotationUnhandled, parseComparison },
        .{ .double_labracket, .product, nullDenotationUnhandled, parseBinaryOp },
        .{ .double_rabracket, .product, nullDenotationUnhandled, parseBinaryOp },
        .{ .bang, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .ampersand, .lowest, nullDenotationUnhandled, parseBinaryOp },
        .{ .caret, .lowest, nullDenotationUnhandled, parseBinaryOp },
        .{ .tilde, .lowest, parseUnaryOp, leftDenotationUnhandled },
        .{ .lsbracket, .lowest, parseList, leftDenotationUnhandled },
        .{ .rsbracket, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .lcbracket, .lowest, parseSetOrDictionary, leftDenotationUnhandled },
        .{ .rcbracket, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .def_kw, .lowest, parseFunctionDefinition, leftDenotationUnhandled },
        .{ .false_kw, .lowest, parseBool, leftDenotationUnhandled },
        .{ .await_kw, .lowest, parseAwait, leftDenotationUnhandled },
        .{ .else_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .import_kw, .lowest, parseImport, leftDenotationUnhandled },
        .{ .pass_kw, .lowest, parsePass, leftDenotationUnhandled },
        .{ .none_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .break_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .except_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .in_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .raise_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .true_kw, .lowest, parseBool, leftDenotationUnhandled },
        .{ .class_kw, .lowest, parseClassDefinition, leftDenotationUnhandled },
        .{ .finally_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .is_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .return_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .and_kw, .sum, nullDenotationUnhandled, parseBoolOp },
        .{ .continue_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .for_kw, .lowest, parseForStatement, leftDenotationUnhandled },
        .{ .lambda_kw, .lowest, parseLambdaDefinition, leftDenotationUnhandled },
        .{ .try_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .as_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .from_kw, .lowest, parseFromImport, leftDenotationUnhandled },
        .{ .nonlocal_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .while_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .assert_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .del_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .global_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .not_kw, .lowest, parseUnaryOp, leftDenotationUnhandled },
        .{ .with_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .async_kw, .lowest, parseAsyncFunctionDefinition, leftDenotationUnhandled },
        .{ .elif_kw, .lowest, nullDenotationUnhandled, leftDenotationUnhandled },
        .{ .if_kw, .sum, nullDenotationUnhandled, parseIfExpression },
        .{ .or_kw, .sum, nullDenotationUnhandled, parseBoolOp },
        .{ .yield_kw, .lowest, parseYield, leftDenotationUnhandled },
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
        return Error.UnexpectedToken;
    }

    fn illegal(self: *Self, tag: lex.TokenTag) Error!void {
        if (self.expect(tag)) return Error.UnexpectedToken;
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
            const infixFn = try leftDenotation(token);
            lhs = try infixFn(self, lhs);
        }

        // this check is a little bit gross, but if the outermost bit of the expression
        // is a function call then it means the return value of the call is discarded.
        // This impacts bytecode generation and this is far easier than scanning or
        // some other stateful solution
        switch (lhs.*) {
            .call => |*call| call.discard_return_value = true,
            else => {},
        }

        return lhs;
    }

    // simple utility for tests
    fn parseSimpleExpression(self: *Self) Error!*const AstNode {
        const node = try self.parseExpression(.lowest);
        return node;
    }

    fn nullDenotationUnhandled(self: *Self) Error!*AstNode {
        log.err("oh no! we don't handle this null denotation: {any}", .{try self.take()});
        return Error.NullDenotationUnhandled;
    }

    fn nullDenotationIllegal(self: *Self) Error!*AstNode {
        _ = self;
        return Error.UnexpectedToken;
    }

    fn leftDenotationUnhandled(self: *Self, lhs: *AstNode) Error!*AstNode {
        log.err("oh no! we don't handle this denotation: lhs: {any}, token: {any}", .{ lhs, try self.take() });
        return Error.LeftDenotationUnhandled;
    }

    fn parsePass(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.pass_kw);
        const pass_node = try self.allocator.create(AstNode);
        pass_node.* = .{ .pass = {} };
        return pass_node;
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

    fn parseInteger(self: *Self) Error!*AstNode {
        const int_token = try self.take();
        const val = try std.fmt.parseInt(ObjectInt, int_token.integer.value, 10);
        const int_node = try self.allocator.create(AstNode);
        int_node.* = .{ .integer = .{ .value = val } };
        return int_node;
    }

    fn parseFloat(self: *Self) Error!*AstNode {
        const float_token = try self.take();
        const val = try std.fmt.parseFloat(ObjectFloat, float_token.float.value);
        const float_node = try self.allocator.create(AstNode);
        float_node.* = .{ .float = .{ .value = val } };
        return float_node;
    }

    fn parseImaginary(self: *Self) Error!*AstNode {
        const imaginary_token = try self.take();
        const len = imaginary_token.imaginary.value.len - 1;
        const val = try std.fmt.parseFloat(ObjectFloat, imaginary_token.imaginary.value[0..len]);
        const imaginary_node = try self.allocator.create(AstNode);
        imaginary_node.* = .{ .complex = .{ .real = 0, .imaginary = val } };
        return imaginary_node;
    }

    fn parseStringLiteral(self: *Self) Error!*AstNode {
        if (self.expect(.string)) {
            const string_token = try self.take();
            const string_node = try self.allocator.create(AstNode);
            string_node.* = .{ .string_literal = .{ .value = string_token.string.value } };
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

    fn parseBinaryOp(self: *Self, lhs: *AstNode) Error!*AstNode {
        const op_token = try self.take(); // skip sum token
        switch (op_token) {
            .plus => {
                const rhs = try self.parseExpression(.sum);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .add = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .minus => {
                const rhs = try self.parseExpression(.sum);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .sub = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .asterisk => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .mult = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .solidus => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .div = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .double_solidus => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .floor_div = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .percent => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .mod = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .double_asterisk => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .pow = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .double_labracket => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .lshift = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .double_rabracket => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .rshift = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .pipe => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .bit_or = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .caret => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .bit_xor = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .ampersand => {
                const rhs = try self.parseExpression(.product);
                const node = try self.allocator.create(AstNode);
                node.* = .{ .bit_and = .{ .lhs = lhs, .rhs = rhs } };
                return node;
            },
            .at => {
                const rhs = try self.parseExpression(.product);
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
        const expression = try self.parseExpression(.lowest);
        const result = try self.allocator.create(AstNode);
        errdefer self.allocator.destroy(result);

        if (self.expect(.for_kw)) {
            // generator
            const comprehension = try self.parseComprehension(Comprehension, expression);
            result.* = .{ .comprehension = comprehension };
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
            .for_expressions = std.ArrayList(ComprehensionFor).init(self.allocator),
        };
        while (self.expect(.for_kw)) {
            try self.expectAndSkip(.for_kw);
            const comp_for = try self.parseComprehensionFor();
            try comprehension.for_expressions.append(comp_for);
        }
        return comprehension;
    }

    inline fn parseComprehensionFor(self: *Self) Error!ComprehensionFor {
        const target_list = try self.parseTargetList();
        try self.expectAndSkip(.in_kw);
        const iterator = try self.parseExpression(.lowest);
        var predicate_expression: ?*const AstNode = null;
        if (self.expect(.if_kw)) {
            try self.expectAndSkip(.if_kw);
            predicate_expression = try self.parseExpression(.lowest);
        }
        return .{
            .target_list = target_list,
            .iterator = iterator,
            .predicate_expression = predicate_expression,
        };
    }

    // TODO: as we evolve and more formally attempt to match the grammar, this should probably be replaced
    // with parseTargetList
    fn parseCommaSeparatedList(self: *Self, list: *List, terminal_token: lex.TokenTag) Error!void {
        while (self.peek()) |next_token| {
            if (next_token == terminal_token) break;
            try self.illegal(.comma);
            const item = try self.parseExpression(.lowest);
            try list.append(item);
            self.expectAndSkip(.comma) catch break;
        }
    }

    // https://docs.python.org/3/reference/simple_stmts.html#grammar-token-python-grammar-target_list
    fn parseTargetList(self: *Self) Error!List {
        var list = List.init(self.allocator);
        while (true) {
            // TODO: there are many more types of targets
            const target = try self.parseName();
            try list.append(target);
            self.expectAndSkip(.comma) catch break;
        }
        return list;
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
            var list = std.ArrayList(ListItem).init(self.allocator);
            while (true) {
                try list.append(list_item);
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
        var dictionary = Dictionary.init(self.allocator);
        errdefer dictionary.deinit();
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
            try dictionary.append(item);
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
        var set = Set.init(self.allocator);
        errdefer set.deinit();
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
            if (self.unwound == null and self.expect(.rcbracket)) break;
            try set.append(item);
            // trailing commas are grammatically allowed
            self.expectAndSkip(.comma) catch break;
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
        const rhs = try self.parseExpression(.equality);
        const assignment_node = try self.allocator.create(AstNode);
        assignment_node.* = .{ .assignment = .{ .lhs = lhs, .rhs = rhs } };
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
            var list = std.ArrayList(ListItem).init(self.allocator);
            errdefer list.deinit();

            while (true) {
                const list_item = try self.parseListItem();
                try list.append(list_item);
                self.expectAndSkip(.comma) catch break;
            }
            result.* = .{ .yield = .{ .list = list } };
        }

        return result;
    }

    fn parseAwait(self: *Self) Error!*AstNode {
        // TODO: we don't have the concept of a "primary", but
        // technically we should not allow parsing arbitrary
        // expressions if we want to align with the python grammar
        try self.expectAndSkip(.await_kw);
        return self.parseExpression(.lowest);
    }

    // a "suite" is the block following the colon in compound statements
    fn parseSuite(self: *Self, owner_indent: lex.IndentLength) Error!Statement {
        try self.expectAndSkip(.colon);
        return self.parseStatementWithIndent(owner_indent);
    }

    fn parseParameter(self: *Self, with_star: bool, with_annotation: bool) Error!Parameter {
        if (with_star) try self.expectAndSkip(.asterisk);
        const identifier = try self.parseName();
        const annotation = blk: {
            if (with_annotation and self.expectAndSkipOptional(.colon)) {
                if (with_star) try self.expectAndSkip(.asterisk);
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
        var parameters = ParameterList.init(self.allocator);

        while (true) {
            const parameter = self.parseParameter(with_star, with_annotation) catch break;
            try parameters.append(parameter);
            self.expectAndSkip(.comma) catch break;
        }

        return parameters;
    }

    // https://docs.python.org/3/reference/compound_stmts.html#grammar-token-python-grammar-parameter_list
    fn parseParameters(self: *Self, with_annotation: bool) Error!Parameters {
        const posargs = try self.parseParameterList(false, with_annotation);
        var posargs2: ParameterList = undefined;
        var positional_only_arguments = false;

        if (self.expectAndSkipOptional(.solidus)) {
            positional_only_arguments = true;
            posargs2 = try self.parseParameterList(false, with_annotation);
        }

        const kwargs = try self.parseParameterList(true, with_annotation);

        return .{
            .arguments = if (positional_only_arguments) posargs2 else posargs,
            .position_only_arguments = if (positional_only_arguments) posargs else ParameterList.init(self.allocator),
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

        const fn_decl = try self.allocator.create(AstNode);
        fn_decl.* = .{ .fn_decl = .{
            .name = name_token.name.value,
            .parameters = parameters,
            .suite = try self.parseSuite(def_kw_token.getLocation().indent),
        } };

        return fn_decl;
    }

    fn parseAsyncFunctionDefinition(self: *Self) Error!*AstNode {
        try self.expectAndSkip(.async_kw);
        const fn_decl = try self.parseFunctionDefinition();
        return fn_decl;
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
            .body = body,
        } };
        return node;
    }

    fn parseFunctionCall(self: *Self, lhs: *AstNode) Error!*AstNode {
        self.expectAndSkip(.lparen) catch unreachable;
        var call_node = try self.allocator.create(AstNode);
        call_node.* = .{ .call = .{ .ref = lhs, .args = List.init(self.allocator) } };
        try self.parseCommaSeparatedList(&call_node.call.args, .rparen);
        try self.expectAndSkip(.rparen);
        return call_node;
    }

    fn parseClassDefinition(self: *Self) Error!*AstNode {
        const class_kw = self.expectAndTake(.class_kw) catch unreachable;
        const name_token = try self.expectAndTake(.name);
        const class_node = try self.allocator.create(AstNode);
        var baseclass: ?[]const u8 = null;
        if (self.expect(.lparen)) {
            self.expectAndSkip(.lparen) catch unreachable;
            if (self.expect(.name)) {
                const baseclass_node = self.take() catch unreachable;
                baseclass = baseclass_node.name.value;
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

    fn parseForStatement(self: *Self) Error!*AstNode {
        const for_kw = try self.expectAndTake(.for_kw);
        const target_list = try self.parseTargetList();
        try self.expectAndSkip(.in_kw);
        const iterable = try self.parseExpression(.lowest);
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

    fn parseImport(self: *Self) Error!*AstNode {
        self.expectAndSkip(.import_kw) catch unreachable;
        var list = std.ArrayList(ImportDefinition).init(self.allocator);

        while (true) {
            const package = try self.parsePackageSpec(true);
            var import_def = ImportDefinition{ .module = package.refspec, .package = package, .alias = null };
            if (self.expect(.as_kw)) {
                self.expectAndSkip(.as_kw) catch unreachable;
                const ref = Ref{ .symbol = (try self.expectAndTake(.name)).name.value };
                import_def.alias = ref;
            }
            try list.append(import_def);
            self.expectAndSkip(.comma) catch break;
        }
        const result = try self.allocator.create(AstNode);
        result.* = .{ .import = try list.toOwnedSlice() };
        return result;
    }

    fn parseFromImport(self: *Self) Error!*AstNode {
        self.expectAndSkip(.from_kw) catch unreachable;
        var list = std.ArrayList(ImportDefinition).init(self.allocator);
        const module = try self.parseRefSpec();

        try self.expectAndSkip(.import_kw);

        while (true) {
            const package = try self.parsePackageSpec(false);
            var import_def = ImportDefinition{ .module = module, .package = package, .alias = null };
            if (self.expect(.as_kw)) {
                self.expectAndSkip(.as_kw) catch unreachable;
                const ref = Ref{ .symbol = (try self.expectAndTake(.name)).name.value };
                import_def.alias = ref;
            }
            try list.append(import_def);
            self.expectAndSkip(.comma) catch break;
        }
        const result = try self.allocator.create(AstNode);
        result.* = .{ .import = try list.toOwnedSlice() };
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
        var ref_spec = std.ArrayList(Ref).init(self.allocator);
        while (true) {
            const ref = Ref{ .symbol = (try self.expectAndTake(.name)).name.value };
            try ref_spec.append(ref);
            self.expectAndSkip(.dot) catch break;
        }
        const owned = ref_spec.toOwnedSlice();
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
        testing.expectError(Parser.Error.UnexpectedEndOfStream, parser.parseSimpleExpression()) catch |err| {
            highlightSource("Unclosed array literal", "[1,", parser.peek());
            return err;
        };
    }
    { // illegal trailing comma
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();
        var parser = Parser.init(allocator, "[,]");
        testing.expectError(Parser.Error.UnexpectedToken, parser.parseSimpleExpression()) catch |err| {
            highlightSource("Illegal trailiing comma", "[,]", parser.peek());
            return err;
        };
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
    try testing.expect(expr1.* == AstNode.assignment);
    const expr2 = result.fn_decl.suite.items[1];
    try testing.expect(expr2.* == AstNode.mult);
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
        const result = (try parser.parse()).root[0];

        try testing.expectEqual(AstNode.class, @as(AstNodeTag, result.*));
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
        const result = (try parser.parse()).root[0];

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
        const result = (try parser.parse()).root[0];
        try testing.expectEqual(AstNode.class, @as(AstNodeTag, result.*));
        try testing.expectEqualStrings("Foo", result.class.name);
        try testing.expectEqualStrings("Bar", result.class.baseclass.?);
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
        const result = (try parser.parse()).root[0];

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
        const result = (try parser.parse()).root[0];

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
        const result = (try parser.parse()).root[0];

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
        const result = (try parser.parse()).root[0];

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

// TODO: move this formatting stuff somewhere else
// also this is fragile and doesn't totally work right BUT leaving this broken starting
// point because it's still useful
fn highlightSource(filename: []const u8, source: []const u8, token: ?lex.Token) void {
    //ansi escape codes
    const esc = "\x1B";
    const csi = esc ++ "[";

    const ansi_reset = csi ++ "0m";
    const ansi_bold = csi ++ "1m";
    const highlight_red = csi ++ "4:3m" ++ csi ++ "58;2;240;143;104m";
    const highlight_end = csi ++ "59m" ++ csi ++ "4:0m";

    std.debug.print("\n{s}# {s}{s}\n", .{ ansi_bold, filename, ansi_reset });
    if (token) |tok| {
        var iter = std.mem.splitSequence(u8, source, "\n");
        var i: usize = 0;
        const location = tok.getLocation();
        while (iter.next()) |line| {
            i += 1;
            if (i != location.line) continue;
            const raw_index = if (location.col > 0) location.col - 1 else 0;
            const index = @min(raw_index, line.len);
            const beforeHighlight = line[0..index];
            const highlight = line[beforeHighlight.len..];
            std.debug.print("\t{d}: {s}{s}{s}{s}\n", .{ location.line, beforeHighlight, highlight_red, highlight, highlight_end });
        }
    }
    std.debug.print("\n\n\n", .{});
}

test "parse: example fixtures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    inline for (test_examples) |example| {
        if (!example.test_parse) continue;
        var parser = Parser.init(allocator, example.source());
        _ = parser.parse() catch |err| {
            highlightSource(example.path(), example.source(), parser.peek());
            return err;
        };
    }
}
