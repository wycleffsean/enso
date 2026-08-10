const std = @import("std");
const intern = @import("bytecode/intern.zig");

// for tests
const lex = @import("lex.zig");
const parse = @import("parse.zig");
pub const bytecode = @import("bytecode.zig");
pub const object = @import("object.zig");
const vm = @import("vm.zig");
const ssa = @import("ir/legacy/ssa.zig");
const runtime = @import("runtime.zig");
const testing = std.testing;
const test_utils = @import("test/utils.zig");

const help =
    \\-h, --help Display this help and exit.
    \\-c,--command <str> Specify the command to execute
    \\<str> File to execute
    \\dis disassemble file
    \\interpret execute through SSA/c2mir/MIR
;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const CliError = error{MissingArgument};

// JUICY MAIN!!!
pub fn main(init: std.process.Init) anyerror!void {
    var allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // we already know the program name :P

    if (args.next()) |arg| {
        if (eql("-h", arg)) {
            // HELP!!!
            return std.debug.print("{s}\n", .{help});
        } else if (eql("-c", arg) or eql("--command", arg)) {
            const command = args.next() orelse return CliError.MissingArgument;
            // user gave us a string of literal code
            return try interpret(allocator, init.io, command);
        } else if (eql("dis", arg)) {
            return try dis(allocator, init.io, &args);
        } else if (eql("interpret", arg) or eql("run", arg)) {
            return try runInterpret(allocator, init.io, &args);
        } else {
            // default argument - file we should run
            const file_bytes = try readFile(allocator, init.io, arg);
            defer allocator.free(file_bytes);
            return try interpret(allocator, init.io, file_bytes);
        }
    }
    // default
    return repl();
}

fn repl() void {
    std.debug.print("REPL not yet implemented\n", .{});
}

fn interpret(allocator: std.mem.Allocator, io: std.Io, code: []const u8) !void {
    _ = io;
    _ = allocator;
    _ = code;
    std.debug.print("Not implemented\n", .{});
}

const dis_help =
    \\-h, --help Display this help and exit.
    \\-c,--command <str> Specify the command to execute
    \\<str> File to execute
;

fn dis(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    if (args.next()) |arg| {
        if (eql("-h", arg)) {
            // HELP!!!
            return std.debug.print("{s}\n", .{dis_help});
        } else if (eql("-c", arg) or eql("--command", arg)) {
            const command = args.next() orelse return CliError.MissingArgument;
            // user gave us a string of literal code
            return try disassemble(allocator, io, command);
        } else {
            // default argument - file we should run
            const file_bytes = try readFile(allocator, io, arg);
            defer allocator.free(file_bytes);
            return try disassemble(allocator, io, file_bytes);
        }
    }
}

fn runInterpret(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    if (args.next()) |arg| {
        if (eql("-h", arg)) {
            return std.debug.print("{s}\n", .{help});
        } else if (eql("-c", arg) or eql("--command", arg)) {
            const command = args.next() orelse return CliError.MissingArgument;
            return try interpret(allocator, io, command);
        } else {
            const file_bytes = try readFile(allocator, io, arg);
            defer allocator.free(file_bytes);
            return try interpret(allocator, io, file_bytes);
        }
    }
}

const FormatInsn = struct {
    insn: *const bytecode.Insn,
    intern_pool: *intern.StringInternPool,
    const Self = @This();

    pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
        var op_buffer: [80]u8 = undefined;
        const insn = self.insn.*;
        const op = std.ascii.upperString(&op_buffer, @tagName(insn));

        try writer.print("{s}", .{op});
        switch (insn) {
            inline else => |payload| {
                const payload_type = @TypeOf(payload);
                if (payload_type == object.Object) {
                    const obj = object.FormatObject{
                        .obj = &payload,
                        .intern_pool = self.intern_pool,
                    };
                    try writer.print("\t ({f})", .{obj});
                } else if (payload_type != void) {
                    try writer.print("\t{any}", .{payload});
                }
            },
        }
    }
};

fn disassemble(allocator: std.mem.Allocator, io: std.Io, code: []const u8) !void {
    var harness = try test_utils.CompilerHarness.create(allocator);
    defer harness.deinit();
    const co = try harness.buildCodeObjects(code);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    for (co.getInstructions()) |insn| {
        //format
        //0    0 RESUME    0
        //
        //1    2 PUSH_NULL
        //     4 LOAD_NAME     0 (print)
        // line number \t bytecode offset \t oparg (human readable oparg)
        // if we encounter a new line number we add a \n
        // TODO: currently location data is lost by the time we get to bytecode
        //   generation, so we don't print line numbers
        const formatted_insn = FormatInsn{ .insn = &insn, .intern_pool = &harness.intern_pool };

        const line_number = null;
        const bytecode_offset = null;

        if (line_number) |num| {
            try stdout.print("{d}\t", .{num});
        } else {
            try stdout.print("\t", .{});
        }
        if (bytecode_offset) |num| {
            try stdout.print("{d} ", .{num});
        } else {
            try stdout.print(" ", .{});
        }

        try stdout.print("{f}\n", .{formatted_insn});
    }
    try stdout.flush();

    var example = try ssa.build(allocator, co);
    defer example.deinit();

    try stdout.print("{f}", .{ssa.format.graph(&example)});
    try stdout.flush();
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
    _ = ssa;
    _ = runtime;
    _ = @import("lex/lexer_test.zig");
    _ = @import("parse/grammar_test.zig");
}
