const std = @import("std");
const io = std.io;
const clap = @import("clap");
const intern = @import("bytecode/intern.zig");

// for tests
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const bytecode = @import("bytecode.zig");
const eval = @import("eval.zig");
const gen = @import("gen.zig");
const vm = @import("vm.zig");
const testing = std.testing;
const test_utils = @import("test/utils.zig");

const ReferenceCapabilities = enum {
    isolated,
    value,
    reference,
    box,
    transition,
    tag,
};

const Allocation = enum {
    stack,
    heap,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
    // tabs aren't cool in multiline literals: https://github.com/ziglang/zig-spec/issues/38
    // so this formatting is a bit lame
        \\-h, --help Display this help and exit.
        \\-c,--command <str> Specify the command to execute
        \\<str> File to execute
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| {
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    if (res.args.command) |cmd|
        try interpret(allocator, cmd);
    if (res.positionals[0]) |file_path| {
        const file_bytes = try readFile(allocator, file_path);
        defer allocator.free(file_bytes);
        try interpret(allocator, file_bytes);
    }
}

fn interpret(allocator: std.mem.Allocator, code: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var arena_allocator = arena.allocator();

    var parser = parse.Parser.init(arena_allocator, code);
    const ast = try parser.parse();

    const intern_pool = try arena_allocator.create(intern.StringInternPool);
    defer arena_allocator.destroy(intern_pool);
    intern_pool.* = intern.StringInternPool.init(arena_allocator);
    defer intern_pool.deinit();

    var irgen = bytecode.IrGen.init(&arena, intern_pool, ast);
    const ir = try irgen.generate(arena_allocator);

    const stdout_writer = std.io.getStdOut().writer();
    var virtual_machine = vm.VM(@TypeOf(stdout_writer)).init(intern_pool, stdout_writer);
    try virtual_machine.eval(ir);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    const buffer = try allocator.alloc(u8, size);
    _ = try file.readAll(buffer);
    return buffer;
}
test {
    try testing.expect(true);
    // Broke after zig 0.9.1 :(
    // testing.refAllDecls(@This());

    _ = test_utils;

    _ = lex;
    _ = parse;
    _ = bytecode;
    _ = eval;
    _ = gen;
    _ = vm;
    _ = @import("lex/lexer_test.zig");
    _ = @import("parse/grammar_test.zig");
}
