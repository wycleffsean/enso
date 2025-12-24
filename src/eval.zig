const std = @import("std");
const testing = std.testing;

const bc = @import("bytecode.zig");
const intern = @import("bytecode/intern.zig");
const utils = @import("utils.zig");
const Iterator = utils.Iterator;
const TestParse = utils.testing.TestParse;

// analogue of Block in IR
//   - always pushes a scope
//      - decl_fn
//   - always pops a scope
//      - yield
const Scope = struct {
    const Self = @This();

    children: std.array_list.Managed(Self),
    parent: ?*const Self,
    symbols: std.array_list.Managed(intern.Index),

    fn init(allocator: std.mem.Allocator, parent: ?*Self) Self {
        return .{
            .parent = parent,
            .children = std.array_list.Managed(Self).init(allocator),
            .symbols = std.array_list.Managed(intern.Index).init(allocator),
        };
    }

    fn deinit(self: Self) void {
        // this is redundant since we use an arena, just deinit the arena
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit();
        self.symbols.deinit();
    }

    // an available variable
    fn avariable(self: Scope, symbol: intern.Index) bool {
        for (self.symbols.items) |sym| {
            if (sym == symbol) return true;
        }
        if (self.parent) |parent| {
            return parent.avariable(symbol);
        }
        return false;
    }
};

const EvalContext = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    insns_iterator: Iterator(bc.Insn),
    root_scope: Scope,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, insns: []const bc.Insn) !Self {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        return .{
            .arena = arena,
            .insns_iterator = Iterator(bc.Insn){ .list = insns },
            .allocator = arena.allocator(),
            .root_scope = Scope.init(arena.allocator(), null),
        };
    }

    fn deinit(self: *Self) void {
        self.root_scope.deinit();
        self.arena.deinit();
        self.arena.child_allocator.destroy(self.arena);
    }

    pub fn eval(self: *Self) !void {
        try self.evalRecursive(&self.root_scope);
    }

    fn evalRecursive(self: *Self, scope: *Scope) !void {
        while (self.insns_iterator.next()) |insn| {
            switch (insn) {
                .decl_var => |decl| {
                    try scope.symbols.append(decl.symbol);
                },
                .decl_fn => |decl| {
                    try scope.symbols.append(decl.symbol);
                    const child_scope = Scope.init(self.allocator, scope);
                    try scope.children.append(child_scope);
                    try self.evalRecursive(&scope.children.items[scope.children.items.len - 1]);
                },
                .yield => {
                    return;
                },
                else => {},
            }
        }
    }
};

pub fn eval(allocator: std.mem.Allocator, insns: []const bc.Insn) !EvalContext {
    var ctx = try EvalContext.init(allocator, insns);
    try ctx.eval();
    return ctx;
}

test "eval: variable scopes" {
    if (true) return error.SkipZigTest;
    const source =
        // tab literals have been made a crime, but the real crime
        // is this unreadable mess
        \\var a = 9
        \\
        \\fn myFunction():
    ++ '\t' ++ "var b = 1" ++ '\t' ++ "a * b";
    var parse_ctx = try TestParse.init(source);
    defer parse_ctx.deinit();
    var eval_ctx = try eval(testing.allocator, parse_ctx.insns);
    defer eval_ctx.deinit();

    const root_scope = eval_ctx.root_scope;
    const function_scope = root_scope.children.items[0];

    const a = parse_ctx.symbol("a").?;
    const b = parse_ctx.symbol("b").?;

    try testing.expect(root_scope.avariable(a));
    try testing.expect(!root_scope.avariable(b));
    try testing.expect(function_scope.avariable(a));
    try testing.expect(function_scope.avariable(b));
}
