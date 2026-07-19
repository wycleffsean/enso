const std = @import("std");
const bytecode = @import("../bytecode.zig");

pub const BlockId = bytecode.Cfg.BlockIndex;
pub const VariableId = u32;
pub const ValueId = u32;

const missing_value: ?ValueId = null;
const no_value = std.math.maxInt(ValueId);

pub const Error = error{
    InvalidBlock,
    InvalidPhi,
    InvalidVariable,
    OutOfMemory,
};

pub const ValueTag = enum {
    undef,
    phi,
    insn,
};

const Value = struct {
    tag: ValueTag,
    block: BlockId,
    variable: VariableId,
    replacement: ValueId,
    phi_operands_start: u32,
    phi_operands_len: u32,
};

const PhiOperand = struct {
    pred: BlockId,
    value: ValueId,
};

pub const PhiOperands = struct {
    preds: []const BlockId,
    values: []const ValueId,
    len: usize,
};

/// Thin Braun-style SSA name builder.
///
/// `bytecode.Cfg` owns blocks and predecessor edges. This builder only owns:
/// - dense block x variable current definitions
/// - incomplete phis for blocks lowered before all predecessor writes exist
/// - SSA value records and phi operands
pub const Builder = struct {
    allocator: std.mem.Allocator,
    cfg: *const bytecode.Cfg,
    variable_count: u32,

    sealed: []bool = &.{},
    current_defs: []?ValueId = &.{},
    incomplete_phis: []?ValueId = &.{},

    values: std.MultiArrayList(Value) = .empty,
    phi_operands: std.MultiArrayList(PhiOperand) = .empty,

    pub fn init(allocator: std.mem.Allocator, cfg: *const bytecode.Cfg, variable_count: u32) Error!Builder {
        var self = Builder{
            .allocator = allocator,
            .cfg = cfg,
            .variable_count = variable_count,
        };
        errdefer self.deinit();

        self.sealed = try allocator.alloc(bool, cfg.blocks.len);
        @memset(self.sealed, false);

        const table_len = cfg.blocks.len * variable_count;
        self.current_defs = try allocator.alloc(?ValueId, table_len);
        self.incomplete_phis = try allocator.alloc(?ValueId, table_len);
        @memset(self.current_defs, missing_value);
        @memset(self.incomplete_phis, missing_value);

        _ = try self.addValue(.{
            .tag = .undef,
            .block = 0,
            .variable = 0,
            .replacement = no_value,
            .phi_operands_start = 0,
            .phi_operands_len = 0,
        });
        return self;
    }

    pub fn deinit(self: *Builder) void {
        self.allocator.free(self.sealed);
        self.allocator.free(self.current_defs);
        self.allocator.free(self.incomplete_phis);
        self.values.deinit(self.allocator);
        self.phi_operands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn undefValue(_: *const Builder) ValueId {
        return 0;
    }

    pub fn addInsnValue(self: *Builder, block: BlockId) Error!ValueId {
        try self.requireBlock(block);
        return self.addValue(.{
            .tag = .insn,
            .block = block,
            .variable = 0,
            .replacement = no_value,
            .phi_operands_start = 0,
            .phi_operands_len = 0,
        });
    }

    pub fn writeVariable(self: *Builder, variable: VariableId, block: BlockId, value: ValueId) Error!void {
        try self.requireVariable(variable);
        try self.requireBlock(block);
        try self.requireValue(value);
        self.current_defs[self.tableIndex(block, variable)] = value;
    }

    pub fn readVariable(self: *Builder, variable: VariableId, block: BlockId) Error!ValueId {
        try self.requireVariable(variable);
        try self.requireBlock(block);

        if (self.current_defs[self.tableIndex(block, variable)]) |value| {
            return self.valueReplacement(value);
        }
        return self.readVariableRecursive(variable, block);
    }

    fn readVariableRecursive(self: *Builder, variable: VariableId, block: BlockId) Error!ValueId {
        const preds = self.cfg.blockPredecessors(block);

        const value = if (!self.sealed[block]) blk: {
            const phi = try self.newPhi(block, variable);
            self.incomplete_phis[self.tableIndex(block, variable)] = phi;
            break :blk phi;
        } else if (preds.len == 0) blk: {
            break :blk self.undefValue();
        } else if (preds.len == 1) blk: {
            break :blk try self.readVariable(variable, preds[0].from);
        } else blk: {
            const phi = try self.newPhi(block, variable);
            try self.writeVariable(variable, block, phi);
            break :blk try self.addPhiOperands(variable, phi);
        };

        try self.writeVariable(variable, block, value);
        return self.valueReplacement(value);
    }

    pub fn sealBlock(self: *Builder, block: BlockId) Error!void {
        try self.requireBlock(block);
        if (self.sealed[block]) return;
        self.sealed[block] = true;

        var variable: VariableId = 0;
        while (variable < self.variable_count) : (variable += 1) {
            const idx = self.tableIndex(block, variable);
            if (self.incomplete_phis[idx]) |phi| {
                const value = try self.addPhiOperands(variable, phi);
                self.current_defs[idx] = self.valueReplacement(value);
                self.incomplete_phis[idx] = null;
            }
        }
    }

    /// Follows replacement links until the real value is reached
    ///
    /// We trivially eliminate phi operands with a replacement technique,
    /// this function is necessary to retrieve actual replaced valued.
    pub fn valueReplacement(self: *const Builder, value: ValueId) ValueId {
        var current = value;
        while (self.values.items(.replacement)[current] != no_value) {
            current = self.values.items(.replacement)[current];
        }
        return current;
    }

    pub fn phiOperands(self: *const Builder, phi: ValueId) PhiOperands {
        const start = self.values.items(.phi_operands_start)[phi];
        const len = self.values.items(.phi_operands_len)[phi];
        return .{
            .preds = self.phi_operands.items(.pred)[start..][0..len],
            .values = self.phi_operands.items(.value)[start..][0..len],
            .len = len,
        };
    }

    pub fn valueTag(self: *const Builder, value: ValueId) ValueTag {
        return self.values.items(.tag)[self.valueReplacement(value)];
    }

    fn addPhiOperands(self: *Builder, variable: VariableId, phi: ValueId) Error!ValueId {
        const block = self.values.items(.block)[phi];
        const start: u32 = @intCast(self.phi_operands.len);

        for (self.cfg.blockPredecessors(block)) |edge| {
            try self.phi_operands.append(self.allocator, .{
                .pred = edge.from,
                .value = try self.readVariable(variable, edge.from),
            });
        }

        self.values.items(.phi_operands_start)[phi] = start;
        self.values.items(.phi_operands_len)[phi] = @intCast(self.phi_operands.len - start);
        return self.removeTrivialPhi(phi);
    }

    fn removeTrivialPhi(self: *Builder, phi: ValueId) Error!ValueId {
        var same: ?ValueId = null;
        for (self.phiOperands(phi).values) |operand| {
            const value = self.valueReplacement(operand);
            if (value == phi) continue;
            if (same == null) {
                same = value;
            } else if (same.? != value) {
                return phi;
            }
        }

        const replacement = same orelse self.undefValue();
        self.values.items(.replacement)[phi] = replacement;
        return replacement;
    }

    fn newPhi(self: *Builder, block: BlockId, variable: VariableId) Error!ValueId {
        return self.addValue(.{
            .tag = .phi,
            .block = block,
            .variable = variable,
            .replacement = no_value,
            .phi_operands_start = 0,
            .phi_operands_len = 0,
        });
    }

    fn addValue(self: *Builder, value: Value) Error!ValueId {
        const id: ValueId = @intCast(self.values.len);
        try self.values.append(self.allocator, value);
        return id;
    }

    fn tableIndex(self: *const Builder, block: BlockId, variable: VariableId) usize {
        return (@as(usize, block) * self.variable_count) + variable;
    }

    fn requireBlock(self: *const Builder, block: BlockId) Error!void {
        if (block >= self.cfg.blocks.len) return Error.InvalidBlock;
    }

    fn requireVariable(self: *const Builder, variable: VariableId) Error!void {
        if (variable >= self.variable_count) return Error.InvalidVariable;
    }

    fn requireValue(self: *const Builder, value: ValueId) Error!void {
        if (value >= self.values.len) return Error.InvalidPhi;
    }
};

test "ssa/builder2: uses cfg predecessors without copying blocks" {
    const insns = [_]bytecode.Insn{
        .{ .@"resume" = 0 },
        .{ .pop_jump_if_false = .{ .delta = 1 } },
        .{ .return_const = {} },
        .{ .return_const = {} },
    };
    var cfg = try bytecode.Cfg.build(std.testing.allocator, &insns);
    defer cfg.deinit();

    var builder = try Builder.init(std.testing.allocator, &cfg, 1);
    defer builder.deinit();

    const left = try builder.addInsnValue(1);
    const right = try builder.addInsnValue(2);
    try builder.writeVariable(0, 1, left);
    try builder.writeVariable(0, 2, right);

    try builder.sealBlock(0);
    try builder.sealBlock(1);
    try builder.sealBlock(2);

    const value = try builder.readVariable(0, 2);
    try std.testing.expectEqual(right, value);
}

test "ssa/builder2: incomplete loop phi completes on seal" {
    const insns = [_]bytecode.Insn{
        .{ .pop_jump_if_false = .{ .delta = 1 } },
        .{ .jump_backward = .{ .delta = 0 } },
        .{ .return_const = {} },
    };
    var cfg = try bytecode.Cfg.build(std.testing.allocator, &insns);
    defer cfg.deinit();

    var builder = try Builder.init(std.testing.allocator, &cfg, 1);
    defer builder.deinit();

    const initial = try builder.addInsnValue(0);
    try builder.writeVariable(0, 0, initial);

    const loop_phi = try builder.readVariable(0, 1);
    try std.testing.expectEqual(ValueTag.phi, builder.valueTag(loop_phi));

    const backedge = try builder.addInsnValue(1);
    try builder.writeVariable(0, 1, backedge);

    try builder.sealBlock(0);
    try builder.sealBlock(1);

    const completed = builder.valueReplacement(loop_phi);
    try std.testing.expectEqual(ValueTag.phi, builder.valueTag(completed));
    try std.testing.expectEqual(@as(usize, 2), builder.phiOperands(completed).len);
}
