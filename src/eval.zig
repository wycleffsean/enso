const std = @import("std");
const ir = @import("ir.zig");
const Iterator = @import("utils.zig").Iterator;

// for testing
const intern = @import("ir/intern.zig");
const Parser = @import("parse.zig").Parser;
const testing = std.testing;

// analogue of Block in IR
//   - always pushes a scope
//      - decl_fn
//   - always pops a scope
//      - yield
const Scope = struct {
    const Self = @This();

    children: std.ArrayList(Self),
    parent: ?*const Self,
    symbols: std.ArrayList(intern.Index),

    fn init(allocator: std.mem.Allocator, parent: ?*Self) Self {
        return .{
            .parent = parent,
            .children = std.ArrayList(Self).init(allocator),
            .symbols = std.ArrayList(intern.Index).init(allocator),
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
    insns_iterator: Iterator(ir.Insn),
    root_scope: Scope,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, insns: []const ir.Insn) !Self {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        return .{
            .arena = arena,
            .insns_iterator = Iterator(ir.Insn){ .list = insns },
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
                    var child_scope = Scope.init(self.allocator, scope);
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

pub fn eval(allocator: std.mem.Allocator, insns: []const ir.Insn) !EvalContext {
    var ctx = try EvalContext.init(allocator, insns);
    try ctx.eval();
    return ctx;
}

const TestContext = struct {
    arena: *std.heap.ArenaAllocator,
    irgen: ir.IrGen,
    ir: []const ir.Insn,
    intern_pool: *intern.StringInternPool,
    res: EvalContext,

    fn symbol(self: TestContext, sym: []const u8) ?intern.Index {
        return self.intern_pool.getIndex(sym);
    }
};

fn testSetup(code: []const u8) !TestContext {
    // this is a strange thing to do but prevents segfault :/
    var arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var parser = Parser.init(arena.allocator(), code);
    const ast = try parser.parse();

    var intern_pool = try testing.allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(arena.allocator());
    var irgen = ir.IrGen.init(arena, intern_pool, ast);
    var insns = try irgen.generate(testing.allocator);
    var eval_ctx = try eval(testing.allocator, insns);

    return TestContext{
        .arena = arena,
        .irgen = irgen,
        .ir = insns,
        .intern_pool = intern_pool,
        .res = eval_ctx,
    };
}

fn testTeardown(ctx: *TestContext) void {
    ctx.res.deinit();
    ctx.irgen.deinit();
    ctx.intern_pool.deinit();
    ctx.arena.deinit();
    testing.allocator.free(ctx.ir);
    testing.allocator.destroy(ctx.intern_pool);
    testing.allocator.destroy(ctx.arena);
}

test "variable scopes" {
    const source =
        \\var a = 9
        \\
        \\fn myFunction():
        \\	var b = 1
        \\	a * b
    ;
    var ctx = try testSetup(source);
    defer testTeardown(&ctx);

    const root_scope = ctx.res.root_scope;
    const function_scope = root_scope.children.items[0];

    const a = ctx.symbol("a").?;
    const b = ctx.symbol("b").?;

    try testing.expect(root_scope.avariable(a));
    try testing.expect(!root_scope.avariable(b));
    try testing.expect(function_scope.avariable(a));
    try testing.expect(function_scope.avariable(b));
}
