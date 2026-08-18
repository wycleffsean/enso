const std = @import("std");
const ir = @import("../ir.zig");

const Error = std.Io.Writer.Error;

pub const FormatProcedure = struct {
    name: []const u8,
    proc: *const ir.Procedure,

    const Self = @This();

    pub fn format(self: *const Self, writer: *std.Io.Writer) Error!void {
        const blocks = self.proc.blocks;
        const values = self.proc.values;

        try writer.print("{s}:\n", .{self.name});

        for (blocks.items, 0..) |block, bi| {
            try writer.print("\tbb{d}:\n", .{bi});
            for (block.values.items) |vid| {
                const op: FormatOperation = .init(vid, &values.get(vid.idx()));
                try op.format(writer);
            }
            try writer.writeAll("\n");
        }
    }
};

const FormatOperation = struct {
    vid: FormatValue,
    value: *const ir.Value,

    const Self = @This();

    fn init(vid: ir.ValueId, value: *const ir.Value) Self {
        return .{
            .vid = .{ .vid = vid },
            .value = value,
        };
    }

    pub fn format(self: *const Self, writer: *std.Io.Writer) Error!void {
        const value = self.value;
        const lhs: FormatValue = .init(value.lhs);
        const rhs: FormatValue = .init(value.lhs);

        try writer.writeAll("\t\t");
        try writer.print("{f} = ", .{self.vid});
        switch (value.op) {
            .nop => {
                try writer.writeAll("nop()");
            },
            .identity => {
                try writer.print("identity({f})", .{lhs});
            },
            inline else => |op| {
                const tag = @tagName(op);
                try writer.print("{s}({f}, {f})", .{ tag, lhs, rhs });
            },
        }
        try writer.writeAll("\n");
    }
};

const FormatValue = struct {
    vid: ir.ValueId,

    fn init(vid: u32) FormatValue {
        return .{ .vid = ir.ValueId.from(vid) };
    }

    pub fn format(self: *const FormatValue, writer: *std.Io.Writer) Error!void {
        if (self.vid == .none) return writer.writeAll("None");
        try writer.print("%v{d}", .{self.vid.idx()});
    }
};

// fn formatValue(vid: ir.ValueId)
