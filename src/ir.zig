const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const OpCode = enum(u8) {
    nop,
    identity,
    branch,
    ret,

    inline fn isTerminator(op: OpCode) bool {
        return effectsOf(op).terminator;
    }
};

const Effects = packed struct(u8) {
    reads_world: bool = false,
    writes_world: bool = false,
    can_raise: bool = false,
    can_exit: bool = false,
    can_allocate: bool = false,
    terminator: bool = false,
    has_result: bool = false,
    _padding: i1 = 0,
};

fn effectsOf(op: OpCode) Effects {
    return switch (op) {
        .nop, .identity => .{},
        .branch, .ret => .{ .terminator = true },
    };
}

const Repr = enum(u8) {
    none,
    i1,
    i32,
    i64,
    f64,
    ptr, // raw pointer
    object, // owned *Object reference
    tagged, // high bit tagged immediate value or *Object

    fn needsBoxing(r: Repr) bool {
        return switch (r) {
            .i1, .i32, .i64, .f64 => true,
            .none, .ptr, .object, .tagged => false,
        };
    }
};

const ValueId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    inline fn idx(b: ValueId) u32 {
        assert(b != .none);
        return @intFromEnum(b);
    }
    inline fn from(i: u32) ValueId {
        return @enumFromInt(i);
    }
};

const BlockId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    inline fn idx(b: BlockId) u32 {
        assert(b != .none);
        return @intFromEnum(b);
    }
    inline fn from(i: u32) BlockId {
        return @enumFromInt(i);
    }
};

const Value = struct {
    op: OpCode,
    repr: Repr,
    lhs: u32,
    rhs: u32,

    const @"true" = Value{
        .op = .identity,
        .repr = .i1,
        .lhs = 1,
        .rhs = 0,
    };
};

const BranchPayload = struct {
    const Extra = struct {
        then: BlockId,
        @"else": BlockId,
    };

    predicate: u32,
    extra: Extra,
};

const Block = struct {
    // TODO: would a span into the procedure's values would be better?
    values: std.ArrayList(ValueId) = .empty,
    preds: std.ArrayList(BlockId) = .empty,

    fn deinit(b: *Block, allocator: std.mem.Allocator) void {
        b.preds.deinit(allocator);
        b.values.deinit(allocator);
    }

    fn terminator(b: *const Block, p: *const Procedure) ValueId {
        if (b.values.items.len == 0) return .none;
        const last = b.values.items[b.values.items.len - 1];
        return if (p.opcodeOf(last).isTerminator()) last else .none;
    }
};

/// like in B3! :)
const Procedure = struct {
    allocator: std.mem.Allocator,
    values: std.MultiArrayList(Value) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    extra: std.ArrayList(u32) = .empty,

    fn deinit(p: *Procedure) void {
        p.values.deinit(p.allocator);
        p.extra.deinit(p.allocator);

        for (p.blocks.items) |*block| block.deinit(p.allocator);
        p.blocks.deinit(p.allocator);
    }

    fn opcodeOf(p: *const Procedure, vid: ValueId) OpCode {
        return p.getValue(vid).op;
    }

    fn getValue(p: *const Procedure, vid: ValueId) Value {
        return p.values.get(vid.idx());
    }

    /// Extra Payloads - borrowing this DoD from Zig's own compiler
    fn addExtra(p: *Procedure, comptime T: type, payload: T) !u32 {
        const fields = std.meta.fields(T);
        // here we're assuming all fields are 32 bits
        try p.extra.ensureUnusedCapacity(p.allocator, fields.len);
        const off: u32 = @intCast(p.extra.items.len);
        inline for (fields) |f| {
            const raw: u32 = switch (@typeInfo(f.type)) {
                .@"enum" => @intFromEnum(@field(payload, f.name)),
                else => @field(payload, f.name),
            };
            p.extra.appendAssumeCapacity(raw);
        }
        return off;
    }

    /// fetch and decode "extra" payloads
    fn extraData(p: *const Procedure, comptime T: type, off: u32) T {
        var out: T = undefined;
        var i = off;
        inline for (std.meta.fields(T)) |f| {
            const raw = p.extra.items[i];
            @field(out, f.name) = switch (@typeInfo(f.type)) {
                .@"enum" => @enumFromInt(raw),
                else => @intCast(raw),
            };
            i += 1;
        }
        return out;
    }

    pub fn addBlock(p: *Procedure) !BlockId {
        const id = BlockId.from(@intCast(p.blocks.items.len));
        try p.blocks.append(p.allocator, .{});
        return id;
    }

    fn addValue(p: *Procedure, bid: BlockId, value: Value) !ValueId {
        const i = ValueId.from(@intCast(p.values.len));
        try p.values.append(p.allocator, value);
        var block = &p.blocks.items[bid.idx()];
        try block.values.append(p.allocator, i);
        return i;
    }

    pub fn addBranch(p: *Procedure, bid: BlockId, payload: BranchPayload) !ValueId {
        const extra_offset = try p.addExtra(BranchPayload.Extra, payload.extra);
        return try p.addValue(bid, .{
            .op = .branch,
            .repr = .i1,
            .lhs = payload.predicate,
            .rhs = extra_offset,
        });
    }

    pub fn successors(p: *const Procedure, bid: BlockId, buf: *[8]BlockId) []const BlockId {
        const term = p.blocks.items[bid.idx()].terminator(p);
        if (term == .none) return buf[0..0];
        // const lhs = p.values.items(.lhs)[term.idx()];
        const rhs = p.values.items(.rhs)[term.idx()];
        switch (p.opcodeOf(term)) {
            .branch => {
                const extra = p.extraData(BranchPayload.Extra, rhs);
                buf[0] = extra.then;
                buf[1] = extra.@"else";
                return buf[0..2];
            },
            else => return buf[0..0],
        }
    }
};

test "procedure: encoding 'extra' data" {
    var proc: Procedure = .{
        .allocator = testing.allocator,
    };
    defer proc.deinit();

    const predicate: Value = .true;
    const root = try proc.addBlock();
    const then_b = try proc.addBlock();
    const else_b = try proc.addBlock();
    const predicate_id = try proc.addValue(root, predicate);
    const branch_extra: BranchPayload.Extra = .{ .then = then_b, .@"else" = else_b };

    try testing.expectEqual(0, proc.extra.items.len);

    const vid = try proc.addBranch(root, .{ .predicate = predicate_id.idx(), .extra = branch_extra });
    const branch_value = proc.getValue(vid);

    const payload = proc.extraData(BranchPayload.Extra, branch_value.rhs);
    try testing.expectEqual(branch_extra, payload);
}

test "procedure: block successors" {
    var proc: Procedure = .{
        .allocator = testing.allocator,
    };
    defer proc.deinit();

    const root = try proc.addBlock();
    const then_b = try proc.addBlock();
    const else_b = try proc.addBlock();

    const pred = try proc.addValue(root, .true);
    _ = try proc.addBranch(root, .{ .predicate = pred.idx(), .extra = .{ .then = then_b, .@"else" = else_b } });

    var buf: [8]BlockId = undefined;
    try testing.expectEqualSlices(BlockId, ([2]BlockId{ then_b, else_b })[0..], proc.successors(root, &buf));
}
