const std = @import("std");
const ir = @import("../ir.zig");

const Error = std.Io.Writer.Error;

pub fn format(proc: *const ir.Procedure, writer: *std.Io.Writer) Error!void {
    // TODO: write procname, which is on the co
    // try writer.print("{s}:\n", .{proc.co.name});
    try writer.print("{d}\n", .{proc.blocks.items.len});
    for (proc.blocks.items, 0..) |block, bi| {
        try writer.print("\tbb{d}:\n", .{bi});
        for (block.values.items) |vid| {
            const value = proc.values.get(vid.idx());
            try formatOp(vid, &value, writer);
        }
        try writer.writeAll("\n");
    }
}

pub fn formatOp(vid: ir.ValueId, value: *const ir.Value, writer: *std.Io.Writer) Error!void {
    switch (value.op) {
        inline else => |op| {
            const tag = @tagName(op);
            try writer.print("\t\t%v{d} = {s}({d}, {d})\n", .{ vid, tag, value.lhs, value.rhs });
        },
    }
}
