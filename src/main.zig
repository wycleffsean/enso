const std = @import("std");
const clap = @import("clap");
const intern = @import("bytecode/intern.zig");

// for tests
const lex = @import("lex.zig");
const parse = @import("parse.zig");
pub const bytecode = @import("bytecode.zig");
pub const object = @import("object.zig");
const vm = @import("vm.zig");
const testing = std.testing;
const test_utils = @import("test/utils.zig");

pub fn main(init: std.process.Init) anyerror!void {
    var allocator = init.gpa;
    // defer _ = gpa.deinit();
    // var allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        // tabs aren't cool in multiline literals: https://github.com/ziglang/zig-spec/issues/38
        // so this formatting is a bit lame
        \\-h, --help Display this help and exit.
        \\-c,--command <str> Specify the command to execute
        \\<str> File to execute
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
    if (res.args.command) |cmd|
        try interpret(allocator, init.io, cmd);
    if (res.positionals[0]) |file_path| {
        const file_bytes = try readFile(allocator, init.io, file_path);
        defer allocator.free(file_bytes);
        try interpret(allocator, init.io, file_bytes);
    }
}

fn interpret(allocator: std.mem.Allocator, io: std.Io, code: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var arena_allocator = arena.allocator();

    var parser = parse.Parser.init(arena_allocator, code);
    const ast = try parser.parse();

    const intern_pool = try arena_allocator.create(intern.StringInternPool);
    defer arena_allocator.destroy(intern_pool);
    intern_pool.* = intern.StringInternPool.init(arena_allocator);
    defer intern_pool.deinit();

    var irgen = bytecode.IrGen.init(arena_allocator, intern_pool, ast);
    const ir = try irgen.generate(arena_allocator);

    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);

    var virtual_machine = vm.VM{ .intern_pool = intern_pool, .stdout = &stdout_writer.interface };
    try virtual_machine.eval(ir);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, .unlimited);
}
test {
    try testing.expect(true);
    // Broke after zig 0.9.1 :(
    // testing.refAllDecls(@This());

    _ = test_utils;

    _ = lex;
    _ = parse;
    _ = bytecode;
    _ = vm;
    _ = @import("lex/lexer_test.zig");
    _ = @import("parse/grammar_test.zig");
}
