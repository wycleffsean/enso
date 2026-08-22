const std = @import("std");
const ir = @import("../ir.zig");
const intern = @import("../intern.zig");

const Error = std.Io.Writer.Error;

pub const FormatModule = struct {
    name: []const u8,
    mod: *const ir.Module,

    const Self = @This();

    pub fn format(self: *const Self, writer: *std.Io.Writer) Error!void {
        try writer.print("{s}:\n", .{self.name});
        for (self.mod.procedures.items) |proc|
            try (FormatProcedure{
                .proc = &proc,
                .pool = &self.mod.object_pool,
                .strings = self.mod.intern_pool,
            }).format(writer);
    }
};

const FormatProcedure = struct {
    proc: *const ir.Procedure,
    pool: *const intern.ObjectPool,
    strings: *const intern.StringInternPool,

    const Self = @This();

    pub fn format(self: *const Self, writer: *std.Io.Writer) Error!void {
        try writer.print("\t{s}:\n", .{self.proc.name});
        for (self.proc.blocks.items, 0..) |block, bi| {
            try writer.print("\t\tbb{d}:\n", .{bi});
            for (block.values.items) |vid| {
                const op: FormatOp = .init(self.proc, self.pool, self.strings, vid);
                try op.format(writer);
            }
            try writer.writeAll("\n");
        }
    }
};

const FormatOp = struct {
    vid: ir.ValueId,
    proc: *const ir.Procedure,
    pool: *const intern.ObjectPool,
    strings: *const intern.StringInternPool,
    value: ir.Value,

    const Self = @This();

    fn init(proc: *const ir.Procedure, pool: *const intern.ObjectPool, strings: *const intern.StringInternPool, vid: ir.ValueId) Self {
        return .{ .proc = proc, .pool = pool, .strings = strings, .vid = vid, .value = proc.values.get(vid.idx()) };
    }

    fn ref(_: *const Self, vid: u32) FormatRef {
        return .{ .vid = ir.ValueId.from(vid) };
    }

    fn block(bid: u32) FormatBlock {
        return .{ .bid = ir.BlockId.from(bid) };
    }

    fn constval(self: *const Self) FormatConst {
        return .{ .value = &self.value, .pool = self.pool, .strings = self.strings };
    }

    pub fn format(self: *const Self, writer: *std.Io.Writer) Error!void {
        const v = &self.value;
        try writer.writeAll("\t\t\t");
        try writer.print("%v{d} = ", .{self.vid.idx()});
        switch (v.op) {
            .nop => try writer.writeAll("nop()"),
            .identity => try writer.print("identity({f})", .{self.ref(v.lhs)}),
            .const_obj => try writer.print("const({f})", .{self.constval()}),
            .ret => try writer.print("ret({f})", .{self.ref(v.lhs)}),
            .jump => try writer.print("jump({f})", .{block(v.lhs)}),
            .branch => {
                const extra = self.proc.extraData(ir.BranchExtra, v.rhs);
                try writer.print("branch({f}, then:{f}, else:{f})", .{
                    self.ref(v.lhs),
                    block(@intFromEnum(extra.then)),
                    block(@intFromEnum(extra.@"else")),
                });
            },
            .phi => try writer.print("phi()", .{}),
            .upsilon => try writer.print("upsilon({f}, ^%v{d})", .{ self.ref(v.lhs), v.rhs }),
            .arg => try writer.print("arg({d})", .{v.lhs}),
            .py_truthy => try writer.print("py_truthy({f})", .{self.ref(v.lhs)}),
            .py_binary_op => try writer.print("py_binary_op(.{s}, {f}, {f})", .{
                @tagName(v.binaryOpKind()), self.ref(v.lhs), self.ref(v.rhs),
            }),
            .py_load_name => {
                const idx: intern.ObjectPool.ObjectIndex = @enumFromInt(v.lhs);
                const obj = self.pool.getConst(idx);
                switch (obj) {
                    .symbol => |sym| try writer.print("py_load_name(\"{s}\")", .{self.strings.get(sym)}),
                    else => try writer.print("py_load_name(<?>)", .{}),
                }
            },
            .py_load_attr => {
                const idx: intern.ObjectPool.ObjectIndex = @enumFromInt(v.rhs);
                const obj = self.pool.getConst(idx);
                switch (obj) {
                    .symbol => |sym| try writer.print("py_load_attr({f}, \"{s}\")", .{ self.ref(v.lhs), self.strings.get(sym) }),
                    else => try writer.print("py_load_attr({f}, <?>)", .{self.ref(v.lhs)}),
                }
            },
            .py_make_function => try writer.print("py_make_function({d})", .{v.lhs}),
            .py_list_extend => try writer.print("py_list_extend({f}, {f})", .{ self.ref(v.lhs), self.ref(v.rhs) }),
            .py_get_iter => try writer.print("py_get_iter({f})", .{self.ref(v.lhs)}),
            .py_for_iter => {
                const extra = self.proc.extraData(ir.ForIterExtra, v.rhs);
                try writer.print("py_for_iter({f}, body:{f}, exit:{f})", .{
                    self.ref(v.lhs),
                    FormatBlock{ .bid = extra.body },
                    FormatBlock{ .bid = extra.exit },
                });
            },
            .py_build_list, .py_build_tuple, .py_build_set, .py_build_map => {
                const name = @tagName(v.op);
                const count = v.lhs;
                try writer.print("{s}(", .{name});
                for (0..count) |i| {
                    if (i > 0) try writer.writeAll(", ");
                    const elem_vid = self.proc.extra.items[v.rhs + @as(u32, @intCast(i))];
                    try writer.print("{f}", .{FormatRef{ .vid = ir.ValueId.from(elem_vid) }});
                }
                try writer.writeAll(")");
            },
            .py_compare_op => try writer.print("py_compare_op(.{s}, {f}, {f})", .{
                @tagName(v.compareOpKind()), self.ref(v.lhs), self.ref(v.rhs),
            }),
            .py_unary_op => {
                const kind: ir.UnaryOp = @enumFromInt(v.rhs);
                try writer.print("py_unary_op(.{s}, {f})", .{ @tagName(kind), self.ref(v.lhs) });
            },
            .py_store_name => {
                const idx: intern.ObjectPool.ObjectIndex = @enumFromInt(v.lhs);
                const obj = self.pool.getConst(idx);
                switch (obj) {
                    .symbol => |sym| try writer.print("py_store_name(\"{s}\", {f})", .{ self.strings.get(sym), self.ref(v.rhs) }),
                    else => try writer.print("py_store_name(<?>, {f})", .{self.ref(v.rhs)}),
                }
            },
            .py_call => {
                // lhs = operand count, rhs = extra offset; extra stores [callable, arg0, ...]
                const count = v.lhs;
                try writer.writeAll("py_call(");
                for (0..count) |i| {
                    if (i > 0) try writer.writeAll(", ");
                    const operand_vid = self.proc.extra.items[v.rhs + @as(u32, @intCast(i))];
                    try writer.print("{f}", .{FormatRef{ .vid = ir.ValueId.from(operand_vid) }});
                }
                try writer.writeAll(")");
            },
        }
        try writer.writeAll("\n");
    }
};

/// Formats a reference to another value by its id.
const FormatRef = struct {
    vid: ir.ValueId,

    pub fn format(self: *const FormatRef, writer: *std.Io.Writer) Error!void {
        try writer.print("%v{d}", .{self.vid.idx()});
    }
};

const FormatBlock = struct {
    bid: ir.BlockId,

    pub fn format(self: *const FormatBlock, writer: *std.Io.Writer) Error!void {
        try writer.print("bb{d}", .{self.bid.idx()});
    }
};

/// Formats the payload of a const_obj inline: tagged values print their Python literal,
/// object-pool entries delegate to object.Object.format (with symbol resolution).
const FormatConst = struct {
    value: *const ir.Value,
    pool: *const intern.ObjectPool,
    strings: *const intern.StringInternPool,

    pub fn format(self: *const FormatConst, writer: *std.Io.Writer) Error!void {
        switch (self.value.repr) {
            .tagged => try writer.print("{f}", .{self.value.asTagged()}),
            .object => {
                const idx: intern.ObjectPool.ObjectIndex = @enumFromInt(self.value.lhs);
                const obj = self.pool.getConst(idx);
                switch (obj) {
                    .symbol => |sym| try writer.print("\"{s}\"", .{self.strings.get(sym)}),
                    else => try writer.print("{f}", .{obj}),
                }
            },
            else => try writer.print("<repr:{s}>", .{@tagName(self.value.repr)}),
        }
    }
};
