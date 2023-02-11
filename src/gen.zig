const std = @import("std");
const ir = @import("ir.zig");
const Insn = ir.Insn;
const testing = std.testing;

const CodeGen = struct {
    allocator: std.mem.Allocator,
    insns: std.ArrayList(Insn),

    const Self = @This();

    const Error = error{};

    const main_decl = "pub fn main() anyerror!void {";

    pub fn init(allocator: std.mem.Allocator, insns: std.ArrayList(Insn)) Self {
        return .{ .allocator = allocator, .insns = insns };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        //
    }

    pub fn generate(self: *Self) Error![]const u8 {
        _ = self;
        return main_decl;
    }
};

test "trivial main" {
    var buf: [9 * @sizeOf(Insn)]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(buf[0..]);
    var insns = std.ArrayList(Insn).init(fba.allocator());
    try insns.append(.{ .push_integer = .{ .value = 1 } });
    try insns.append(.{ .push_integer = .{ .value = 2 } });
    try insns.append(.{ .sum = {} });
    var gen = CodeGen.init(testing.allocator, insns);
    defer gen.deinit();

    const expected =
        \\pub fn main() anyerror!void {
        \\    _ = 1 + 2;
        \\}
    ;
    _ = expected;
    //try testing.expectEqualSlices(u8, expected, try gen.generate());
}
