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

    const params = comptime clap.parseParamsComptime(
        \\-h, --help		Display this help and exit.
        \\-c,--command <str>	Specify the command to execute
        \\<str>			File to execute
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
        try interpret(gpa.allocator(), cmd);
    for (res.positionals) |pos|
        std.debug.print("{s}\n", .{pos});
}

fn interpret(allocator: std.mem.Allocator, code: []const u8) !void {
    var parser = parse.Parser.init(allocator, code);
    const ast = try parser.parse();

    const intern_pool = try allocator.create(intern.StringInternPool);
    intern_pool.* = intern.StringInternPool.init(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var irgen = bytecode.IrGen.init(&arena, intern_pool, ast);
    const ir = try irgen.generate(allocator);

    const stdout_writer = std.io.getStdOut().writer();
    var virtual_machine = vm.VM(@TypeOf(stdout_writer)).init(intern_pool, stdout_writer);
    try virtual_machine.eval(ir);
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
