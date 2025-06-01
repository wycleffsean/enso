const std = @import("std");

pub fn Iterator(comptime T: type) type {
    return struct {
        index: usize = 0,
        list: []const T,

        const Self = @This();

        pub fn next(self: *Self) ?T {
            for (self.list[self.index..]) |item| {
                self.index += 1;
                return item;
            }
            return null;
        }
    };
}

pub fn fatalExit(exit_code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args); // TODO: stderr instead?
    const mode = @import("builtin").mode;
    if (mode == .Debug) std.debug.dumpCurrentStackTrace(null);
    std.process.exit(exit_code);
}

pub const testing = struct {
    const bc = @import("bytecode.zig");
    const intern = @import("bytecode/intern.zig");
    const Parser = @import("parse.zig").Parser;

    pub const TestParse = struct {
        const Self = @This();

        arena: *std.heap.ArenaAllocator,
        irgen: bc.IrGen,
        insns: []const bc.Insn,
        intern_pool: *intern.StringInternPool,

        pub fn init(code: []const u8) !Self {
            // this is a strange thing to do but prevents segfault :/
            var arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);

            var parser = Parser.init(arena.allocator(), code);
            const ast = try parser.parse();

            const intern_pool = try std.testing.allocator.create(intern.StringInternPool);
            intern_pool.* = intern.StringInternPool.init(arena.allocator());
            var irgen = bc.IrGen.init(arena, intern_pool, ast);
            const insns = try irgen.generate(std.testing.allocator);
            return .{
                .arena = arena,
                .irgen = irgen,
                .insns = insns,
                .intern_pool = intern_pool,
            };
        }

        pub fn deinit(self: *Self) void {
            self.irgen.deinit();
            self.intern_pool.deinit();
            self.arena.deinit();
            std.testing.allocator.free(self.insns);
            std.testing.allocator.destroy(self.intern_pool);
            std.testing.allocator.destroy(self.arena);
        }

        pub fn symbol(self: Self, sym: []const u8) ?intern.Index {
            return self.intern_pool.getIndex(sym);
        }
    };
};
