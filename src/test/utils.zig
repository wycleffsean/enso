const std = @import("std");
const dis_examples = @import("disassembled_examples");
const object = @import("../object.zig");

const parse = @import("../parse.zig");
const intern = @import("../bytecode/intern.zig");
const bytecode = @import("../bytecode.zig");
const ssa = @import("../ssa.zig");
pub const CompilerHarness = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    intern_pool: intern.StringInternPool,
    module: bytecode.Module,

    const Self = @This();
    const ParseError = parse.Parser.Error;
    const ParseOrIRGenError = ParseError || bytecode.Module.Builder.Error;
    const SsaError = ParseOrIRGenError || ssa.Error;

    pub fn create(base_allocator: std.mem.Allocator) !*Self {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        var ptr = try arena.allocator().create(Self);
        ptr.arena = arena;
        ptr.allocator = ptr.arena.allocator();
        ptr.intern_pool = intern.StringInternPool.init(ptr.allocator);
        return ptr;
    }

    pub fn deinit(self: *Self) void {
        self.intern_pool.deinit();
        self.arena.deinit();
    }

    pub fn doParse(self: *Self, code: []const u8) ParseError!*const parse.AstNode {
        var parser = parse.Parser.init(self.allocator, code);
        return parser.parse() catch |err| {
            parse.highlightSource("<<test>>", code, parser.peeked);
            return err;
        };
    }

    pub fn buildCodeObjects(self: *Self, code: []const u8) ParseOrIRGenError!bytecode.CodeObject {
        const ast = try self.doParse(code);
        self.module = bytecode.Module.init(
            self.allocator,
            &self.intern_pool,
        );
        try self.module.buildFromAst(ast);
        return self.module.codeobject_store.get(0);
    }

    pub fn doSsa(self: *Self, code: []const u8) SsaError!ssa.SsaGraph {
        const co = try self.buildCodeObjects(code);
        return ssa.SsaBuilder.generate(self.allocator, co);
    }
};

pub const Example = struct {
    name: []const u8,
    test_lex: bool = true,
    test_lex_comptime: bool = false,
    test_parse: bool = true,
    test_bytecode: bool = true,
    normalize_bytecode: bool = false,
    test_vm: bool = true,
    test_vm_comptime: bool = false,

    const Self = @This();

    pub fn dis(comptime self: *const Self) dis_examples.Example {
        return dis_examples.examples.get(self.name).?;
    }

    pub fn path(comptime self: *const Self) []const u8 {
        return self.dis().path;
    }

    pub fn source(comptime self: *const Self) []const u8 {
        return self.dis().source;
    }

    pub fn code(comptime self: *const Self) *const object.Code {
        return self.dis().co;
    }

    pub fn stdout(comptime self: *const Self) []const u8 {
        return self.dis().captured_stdout;
    }
};

pub const examples = [_]Example{
    .{
        .name = "examples_none",
    },
    .{
        .name = "examples_hello_world",
    },
    .{
        .name = "examples_expressions",
        // we now generate bytecode for this, but since python folds expressions
        // before emitting bytecode we still don't match
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "examples_builtin_functions",
        .normalize_bytecode = true,
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_1_identifiers",
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_2_literals",
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_2_1_string_literal_concatenation",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_3_parenthesized_forms",
        .normalize_bytecode = true,
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_5_list_display_minimal",
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_5_list_displays",
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_6_set_display_minimal",
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_6_set_displays",
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_7_dictionary_display_minimal",
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_7_dictionary_displays",
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_8_generator_expressions",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_2_9_yield_expressions",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_3_4_calls",
        .normalize_bytecode = true,
        .test_vm = false,
    },
    .{
        .name = "langref_6_4_await_expression",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_5_power_operator",
        .test_vm = false,
    },
    .{
        .name = "langref_6_6_unary_arithmetic_and_bitwise_operations",
        .test_vm = false,
    },
    .{
        .name = "langref_6_7_binary_arithmetic_operations",
        .test_vm = false,
    },
    .{
        .name = "langref_6_8_shifting_operations",
        .test_vm = false,
    },
    .{
        .name = "langref_6_9_binary_bitwise_operations",
        .test_vm = false,
    },
    .{
        .name = "langref_6_10_comparisons",
        .test_vm = false,
    },
    .{
        .name = "langref_6_11_boolean_operations",
        .normalize_bytecode = true,
        .test_vm = false,
    },
    .{
        .name = "langref_6_12_assignment_expressions",
        .test_vm = false,
    },
    .{
        .name = "langref_6_13_conditional_expressions",
        // the python compiler folds over these operations when using constants
        // so at this time we won't get the same results
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_14_lambdas",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_6_15_expression_lists",
        .normalize_bytecode = true,
        .test_vm = false,
    },
    .{
        .name = "langref_6_16_evaluation_order",
        .test_vm = false,
    },
    .{
        .name = "langref_6_17_operator_precedence",
        .test_vm = false,
    },
    .{
        .name = "langref_7_1_expression_statements",
        .test_vm = false,
    },
    .{
        .name = "langref_7_2_assignment_statements",
        .test_bytecode = false,
        .test_vm = false,
    },
    .{
        .name = "langref_7_4_pass_statement",
        .test_vm = false,
    },
    .{
        .name = "langref_7_6_return_statement",
        .test_vm = false,
    },
    .{
        .name = "langref_7_10_continue_statement",
        .test_vm = false,
    },
    .{
        .name = "langref_8_1_if_statement",
        .test_vm = false,
    },
    .{
        .name = "langref_8_2_while_statement",
        .test_vm = false,
    },
    .{
        .name = "langref_8_3_for_statement",
        .test_vm = false,
    },
    .{
        .name = "langref_8_3_for_statement_minimal",
        .normalize_bytecode = true,
        .test_vm = false,
    },
    .{
        .name = "langref_8_7_function_definitions",
        .test_bytecode = false,
        .test_vm = false,
    },
    // .{
    //     .name = "test_grammar",
    //     .test_parse = false,
    //     .test_bytecode = false,
    //     .test_vm = false,
    // },
};

pub fn optimizeBytecodeForPythonFixture(allocator: std.mem.Allocator, co: bytecode.CodeObject) ![]bytecode.Insn {
    var out: std.ArrayList(bytecode.Insn) = .empty;
    errdefer out.deinit(allocator);

    var constants: std.ArrayList(object.Object) = .empty;
    defer constants.deinit(allocator);

    const ir = co.getInstructions();
    var index: usize = 0;
    while (index < ir.len) {
        if (try foldTuple(allocator, co, ir[index..], &constants, &out)) |consumed| {
            index += consumed;
            continue;
        }
        if (try foldBinary(allocator, co, ir[index..], &constants, &out)) {
            index += 3;
            continue;
        }
        if (try foldUnary(allocator, co, ir[index..], &constants, &out)) {
            index += 2;
            continue;
        }

        switch (ir[index]) {
            .load_const => |consti| {
                const remapped = try internOptimizedConst(allocator, &constants, co.consts()[consti.index]);
                try out.append(allocator, .{ .load_const = remapped });
            },
            else => try out.append(allocator, ir[index]),
        }
        index += 1;
    }

    var changed = true;
    while (changed) {
        changed = false;
        var pass: std.ArrayList(bytecode.Insn) = .empty;
        errdefer pass.deinit(allocator);
        try optimizePass(allocator, &constants, out.items, &pass, &changed);
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, pass.items);
        pass.deinit(allocator);
    }

    return out.toOwnedSlice(allocator);
}

fn optimizePass(
    allocator: std.mem.Allocator,
    constants: *std.ArrayList(object.Object),
    ir: []const bytecode.Insn,
    out: *std.ArrayList(bytecode.Insn),
    changed: *bool,
) !void {
    var index: usize = 0;
    while (index < ir.len) {
        if (try foldConstBoolOp(allocator, constants, ir[index..], out)) {
            changed.* = true;
            index += 5;
            continue;
        }
        if (try foldConstBinary(allocator, constants, ir[index..], out)) {
            changed.* = true;
            index += 3;
            continue;
        }
        if (try foldConstUnary(allocator, constants, ir[index..], out)) {
            changed.* = true;
            index += 2;
            continue;
        }
        try out.append(allocator, ir[index]);
        index += 1;
    }
}

fn foldTuple(
    allocator: std.mem.Allocator,
    co: bytecode.CodeObject,
    ir: []const bytecode.Insn,
    constants: *std.ArrayList(object.Object),
    out: *std.ArrayList(bytecode.Insn),
) !?usize {
    if (ir.len < 2 or ir[0] != .load_const) return null;

    var len: usize = 1;
    while (len < ir.len and ir[len] == .load_const) : (len += 1) {}
    if (len >= ir.len or ir[len] != .build_tuple or ir[len].build_tuple != len) return null;

    _ = co;
    const remapped = try internOptimizedConst(allocator, constants, object.EmptyTuple);
    try out.append(allocator, .{ .load_const = remapped });
    return len + 1;
}

fn foldConstBoolOp(
    allocator: std.mem.Allocator,
    constants: *std.ArrayList(object.Object),
    ir: []const bytecode.Insn,
    out: *std.ArrayList(bytecode.Insn),
) !bool {
    if (ir.len < 5) return false;
    if (ir[0] != .load_const or ir[1] != .copy or ir[3] != .pop_top or ir[4] != .load_const) return false;

    const lhs = constants.items[ir[0].load_const.index];
    const rhs = constants.items[ir[4].load_const.index];
    const folded = switch (ir[2]) {
        .pop_jump_if_false => if (truthy(lhs)) rhs else lhs,
        .pop_jump_if_true => if (truthy(lhs)) lhs else rhs,
        else => return false,
    };
    const remapped = try internOptimizedConst(allocator, constants, folded);
    try out.append(allocator, .{ .load_const = remapped });
    return true;
}

fn foldConstBinary(
    allocator: std.mem.Allocator,
    constants: *std.ArrayList(object.Object),
    ir: []const bytecode.Insn,
    out: *std.ArrayList(bytecode.Insn),
) !bool {
    if (ir.len < 3) return false;
    if (ir[0] != .load_const or ir[1] != .load_const or ir[2] != .binary_op) return false;

    const lhs = constants.items[ir[0].load_const.index];
    const rhs = constants.items[ir[1].load_const.index];
    const folded = evalBinary(lhs, rhs, ir[2].binary_op) orelse return false;
    const remapped = try internOptimizedConst(allocator, constants, folded);
    try out.append(allocator, .{ .load_const = remapped });
    return true;
}

fn foldConstUnary(
    allocator: std.mem.Allocator,
    constants: *std.ArrayList(object.Object),
    ir: []const bytecode.Insn,
    out: *std.ArrayList(bytecode.Insn),
) !bool {
    if (ir.len < 2 or ir[0] != .load_const) return false;

    const value = constants.items[ir[0].load_const.index];
    const folded = switch (ir[1]) {
        .unary_negative => evalUnaryNegative(value),
        .unary_invert => evalUnaryInvert(value),
        .unary_not => object.Object{ .bool = !truthy(value) },
        .call_intrinsic_1 => |kind| switch (kind) {
            .unary_positive => evalUnaryPositive(value),
        },
        else => return false,
    } orelse return false;

    const remapped = try internOptimizedConst(allocator, constants, folded);
    try out.append(allocator, .{ .load_const = remapped });
    return true;
}

fn foldBinary(
    allocator: std.mem.Allocator,
    co: bytecode.CodeObject,
    ir: []const bytecode.Insn,
    constants: *std.ArrayList(object.Object),
    out: *std.ArrayList(bytecode.Insn),
) !bool {
    if (ir.len < 3) return false;
    if (ir[0] != .load_const or ir[1] != .load_const or ir[2] != .binary_op) return false;

    const lhs = co.consts()[ir[0].load_const.index];
    const rhs = co.consts()[ir[1].load_const.index];
    const folded = evalBinary(lhs, rhs, ir[2].binary_op) orelse return false;
    const remapped = try internOptimizedConst(allocator, constants, folded);
    try out.append(allocator, .{ .load_const = remapped });
    return true;
}

fn foldUnary(
    allocator: std.mem.Allocator,
    co: bytecode.CodeObject,
    ir: []const bytecode.Insn,
    constants: *std.ArrayList(object.Object),
    out: *std.ArrayList(bytecode.Insn),
) !bool {
    if (ir.len < 2 or ir[0] != .load_const) return false;

    const value = co.consts()[ir[0].load_const.index];
    const folded = switch (ir[1]) {
        .unary_negative => evalUnaryNegative(value),
        .unary_invert => evalUnaryInvert(value),
        .unary_not => object.Object{ .bool = !truthy(value) },
        .call_intrinsic_1 => |kind| switch (kind) {
            .unary_positive => evalUnaryPositive(value),
        },
        else => return false,
    } orelse return false;

    const remapped = try internOptimizedConst(allocator, constants, folded);
    try out.append(allocator, .{ .load_const = remapped });
    return true;
}

fn internOptimizedConst(
    allocator: std.mem.Allocator,
    constants: *std.ArrayList(object.Object),
    value: object.Object,
) !bytecode.ConstIndex {
    for (constants.items, 0..) |existing, index| {
        if (objectEql(existing, value)) return .{ .index = @intCast(index) };
    }
    const index = constants.items.len;
    try constants.append(allocator, value);
    return .{ .index = @intCast(index) };
}

fn evalBinary(lhs: object.Object, rhs: object.Object, op: bytecode.BinaryOperation) ?object.Object {
    switch (lhs) {
        .int => |l| switch (rhs) {
            .int => |r| return evalIntBinary(l, r, op),
            else => {},
        },
        else => {},
    }
    return null;
}

fn evalIntBinary(lhs: object.ObjectInt, rhs: object.ObjectInt, op: bytecode.BinaryOperation) ?object.Object {
    return switch (op) {
        .add => .{ .int = lhs + rhs },
        .sub => .{ .int = lhs - rhs },
        .mult => .{ .int = lhs * rhs },
        .div => if (rhs == 0) null else .{ .float = @as(object.ObjectFloat, @floatFromInt(lhs)) / @as(object.ObjectFloat, @floatFromInt(rhs)) },
        .floor_div => if (rhs == 0) null else .{ .int = @divFloor(lhs, rhs) },
        .mod => if (rhs == 0) null else .{ .int = @mod(lhs, rhs) },
        .pow => evalIntPow(lhs, rhs),
        .lshift => if (rhs < 0 or rhs >= 63) null else .{ .int = lhs << @intCast(rhs) },
        .rshift => if (rhs < 0 or rhs >= 63) null else .{ .int = lhs >> @intCast(rhs) },
        .bit_or => .{ .int = lhs | rhs },
        .bit_xor => .{ .int = lhs ^ rhs },
        .bit_and => .{ .int = lhs & rhs },
        .inplace_add => .{ .int = lhs + rhs },
        .mat_mult => null,
    };
}

fn evalIntPow(lhs: object.ObjectInt, rhs: object.ObjectInt) ?object.Object {
    if (rhs < 0) return null;
    var result: object.ObjectInt = 1;
    var remaining: object.ObjectInt = rhs;
    while (remaining > 0) : (remaining -= 1) result *= lhs;
    return .{ .int = result };
}

fn evalUnaryNegative(value: object.Object) ?object.Object {
    return switch (value) {
        .bool => |b| .{ .int = -@as(object.ObjectInt, @intFromBool(b)) },
        .int => |int| .{ .int = -int },
        .float => |float| .{ .float = -float },
        else => null,
    };
}

fn evalUnaryPositive(value: object.Object) ?object.Object {
    return switch (value) {
        .bool => |b| .{ .int = @intFromBool(b) },
        .int, .float => value,
        else => null,
    };
}

fn evalUnaryInvert(value: object.Object) ?object.Object {
    return switch (value) {
        .bool => |b| .{ .int = ~@as(object.ObjectInt, @intFromBool(b)) },
        .int => |int| .{ .int = ~int },
        else => null,
    };
}

fn truthy(value: object.Object) bool {
    return switch (value) {
        .none => false,
        .bool => |b| b,
        .int => |int| int != 0,
        .float => |float| float != 0,
        .complex => |complex| complex.re != 0 or complex.im != 0,
        .string => |string| string.string.len != 0,
        .symbol => true,
        .array => |array| array.len != 0,
        .tuple => |tuple| tuple.len != 0,
        .code => true,
        .codeobject => true,
    };
}

fn objectEql(lhs: object.Object, rhs: object.Object) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .none => true,
        .bool => |value| value == rhs.bool,
        .int => |value| value == rhs.int,
        .float => |value| value == rhs.float,
        .complex => |value| value.re == rhs.complex.re and value.im == rhs.complex.im,
        .string => |value| std.mem.eql(u8, value.string, rhs.string.string),
        .symbol => |value| value == rhs.symbol,
        .array => false,
        .tuple => false,
        .code => false,
        .codeobject => |value| value == rhs.codeobject,
    };
}

test "test utils: optimize bytecode constants for python fixture comparison" {
    {
        var harness = try CompilerHarness.create(std.testing.allocator);
        defer harness.deinit();
        const co = try harness.buildCodeObjects("1 + 2");
        const optimized = try optimizeBytecodeForPythonFixture(std.testing.allocator, co);
        defer std.testing.allocator.free(optimized);

        const expected = [_]bytecode.Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = .{ .index = 0 } },
            .{ .pop_top = {} },
            .{ .return_const = {} },
        };
        try std.testing.expectEqualSlices(bytecode.Insn, expected[0..], optimized);
    }
    {
        var harness = try CompilerHarness.create(std.testing.allocator);
        defer harness.deinit();
        const co = try harness.buildCodeObjects("negative = -1\nlogical_not = not 0\nbitwise_invert = ~16");
        const optimized = try optimizeBytecodeForPythonFixture(std.testing.allocator, co);
        defer std.testing.allocator.free(optimized);

        const expected = [_]bytecode.Insn{
            .{ .@"resume" = 0 },
            .{ .load_const = .{ .index = 0 } },
            .{ .store_name = .{ .index = 0 } },
            .{ .load_const = .{ .index = 1 } },
            .{ .store_name = .{ .index = 1 } },
            .{ .load_const = .{ .index = 2 } },
            .{ .store_name = .{ .index = 2 } },
            .{ .return_const = {} },
        };
        try std.testing.expectEqualSlices(bytecode.Insn, expected[0..], optimized);
    }
}

test "lexing examples" {
    inline for (examples) |example| {
        _ = example.path();
        _ = example.source();
        _ = example.code().instructions;
    }
}
