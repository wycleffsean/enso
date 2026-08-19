const std = @import("std");
const ir = @import("../ir.zig");

const Error = std.Io.Writer.Error;

pub const FormatModule = struct {
    name: []const u8,
    mod: *const ir.Module,

    const Self = @This();

    pub fn format(self: *const Self, writer: *std.Io.Writer) Error!void {
        try writer.print("{s}:\n", .{self.name});

        const procs = self.mod.procedures.items;

        for (procs) |proc| try (FormatProcedure{ .proc = &proc }).format(writer);
    }
};

const FormatProcedure = struct {
    proc: *const ir.Procedure,

    const Self = @This();

    pub fn format(self: *const Self, writer: *std.Io.Writer) Error!void {
        const blocks = self.proc.blocks;
        const values = self.proc.values;

        try writer.print("\t{s}:\n", .{self.proc.name});

        for (blocks.items, 0..) |block, bi| {
            try writer.print("\t\tbb{d}:\n", .{bi});
            for (block.values.items) |vid| {
                const op: FormatOperation = .init(self.proc, vid, &values.get(vid.idx()));
                try op.format(writer);
            }
            try writer.writeAll("\n");
        }
    }
};

const FormatOperation = struct {
    vid: ir.ValueId,
    proc: *const ir.Procedure,
    value: *const ir.Value,

    const Self = @This();

    fn init(proc: *const ir.Procedure, vid: ir.ValueId, value: *const ir.Value) Self {
        return .{
            .proc = proc,
            .vid = vid,
            .value = value,
        };
    }

    inline fn fmtval(self: *const Self, id: u32) FormatValue {
        const value = self.proc.values.get(id);
        return .init(id, &value);
    }

    pub fn format(self: *const Self, writer: *std.Io.Writer) Error!void {
        const value = self.value;
        const lhs = value.lhs;
        const rhs = value.rhs;

        try writer.writeAll("\t\t\t");
        try writer.print("%v{d} = ", .{self.vid});
        switch (value.op) {
            .nop => {
                try writer.writeAll("nop()");
            },
            .identity => {
                try writer.print("identity({f})", .{self.fmtval(lhs)});
            },
            .const_obj => {
                try writer.print("const({f})", .{FormatValue{ .vid = self.vid, .value = value }});
            },
            inline else => |op| {
                const tag = @tagName(op);
                try writer.print("{s}({f}, {f})", .{ tag, self.fmtval(lhs), self.fmtval(rhs) });
            },
        }
        try writer.writeAll("\n");
    }
};

const FormatValue = struct {
    vid: ir.ValueId,
    value: *const ir.Value,

    fn init(vid: u32, value: *const ir.Value) FormatValue {
        return .{ .vid = ir.ValueId.from(vid), .value = value };
    }

    pub fn format(self: *const FormatValue, writer: *std.Io.Writer) Error!void {
        // if (self.vid == .none) return writer.writeAll("None");
        switch (self.value.repr) {
            .tagged => {
                try writer.print("{f}", .{self.value.asTagged()});
            },
            else => {
                try writer.print("%v{d}", .{self.vid.idx()});
            },
        }
    }
};

// fn formatValue(vid: ir.ValueId)
