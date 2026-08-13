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
};

fn effectsOf(op: OpCode) Effects {
    return switch (op) {
        .nop, .identity, .branch => .{},
        .ret => .{ .terminator = true },
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

const Block = struct {
    // values: std.ArrayList(ValueId) = .empty, - a span into the procedure's values would be better
    preds: std.ArrayList(BlockId) = .empty,

    fn deinit(b: *Block, allocator: std.mem.Allocator) void {
        b.preds.deinit(allocator);
    }

    fn terminator(b: Block, proc: *const Procedure) ValueId {
        if (b.values.items.len == 0) return .none;
        const last = b.values.items[b.values.items.len - 1];
        return if (proc.opcodeOf(last).isTerminator()) last else .none;
    }
};

const BranchPayload = struct {
    const Extra = struct {
        then: BlockId,
        @"else": BlockId,
    };

    predicate: u32,
    extra: Extra,
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

    fn addValue(p: *Procedure, value: Value) !ValueId {
        const i = ValueId.from(@intCast(p.values.len));
        try p.values.append(p.allocator, value);
        return i;
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

    pub fn addBranch(p: *Procedure, payload: BranchPayload) !ValueId {
        const extra_offset = try p.addExtra(BranchPayload.Extra, payload.extra);
        return try p.addValue(.{
            .op = .branch,
            .repr = .i1,
            .lhs = payload.predicate,
            .rhs = extra_offset,
        });
    }

    pub fn addBlock(p: *Procedure) !BlockId {
        const id = BlockId.from(@intCast(p.blocks.items.len));
        try p.blocks.append(p.allocator, .{});
        return id;
    }

    pub fn successors(p: *const Procedure, block: BlockId, buf: *[8]BlockId) []const BlockId {}
};

test "procedure: encoding 'extra' data" {
    var proc: Procedure = .{
        .allocator = testing.allocator,
    };
    defer proc.deinit();

    const predicate: Value = .true;
    const predicate_id = try proc.addValue(predicate);
    const then_b: BlockId = .from(0);
    const else_b: BlockId = .from(1);
    const branch_extra: BranchPayload.Extra = .{ .then = then_b, .@"else" = else_b };

    try testing.expectEqual(0, proc.extra.items.len);

    const vid = try proc.addBranch(.{ .predicate = predicate_id.idx(), .extra = branch_extra });
    const branch_value = proc.getValue(vid);

    const payload = proc.extraData(BranchPayload.Extra, branch_value.rhs);
    try testing.expectEqual(branch_extra, payload);
}

test "procedure: block successors" {
    var proc: Procedure = .{
        .allocator = testing.allocator,
    };
    defer proc.deinit();

    const block1 = try proc.addBlock();
    _ = block1;
}
