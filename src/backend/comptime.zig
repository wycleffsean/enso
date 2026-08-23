/// Compile-time evaluation of pure SSA procedures.
///
/// Entry point is `evalPure`, which:
///   1. Scans the procedure for world effects (checkPure) — fails fast with a
///      good error if any opcode reads or writes world state.
///   2. Runs the procedure through the baseline interpreter with a comptime
///      EnsoCtx whose vtable slots trap any world-effect calls that slipped
///      through (defense in depth).
///
/// Use cases: constant folding, compile-time name/MRO resolution, type
/// expression evaluation, import machinery.
///
/// Calling Python from Zig at compile time is just `evalPure` on the
/// procedure you want.  Down the road the same mechanism will serve
/// `import enso.intrinsics` — Zig functions registered in the builtin table
/// and callable as `TaggedValue.integer(IntrinsicId)` through the same
/// py_call vtable slot.
const std = @import("std");
const ir = @import("../ir.zig");
const TaggedValue = @import("../TaggedValue.zig");
const intern = @import("../intern.zig");
const ctx_mod = @import("../runtime/ctx.zig");
const EnsoCtx = ctx_mod.EnsoCtx;
const baseline = @import("baseline.zig");

pub const EvalError = error{
    /// A world-effect opcode was found during the pre-scan.
    SideEffect,
    OutOfMemory,
};

/// Check that every value in `proc` is free of world effects.
/// Returns `error.SideEffect` on the first violation, naming the opcode.
pub fn checkPure(proc: *const ir.Procedure) EvalError!void {
    for (proc.blocks.items) |*block| {
        for (block.values.items) |vid| {
            const fx = ir.effectsOf(proc.values.items(.op)[vid.idx()]);
            if (fx.reads_world or fx.writes_world) return error.SideEffect;
        }
    }
}

/// Evaluate a pure SSA procedure at compile time.
///
/// `args` provides TaggedValues for `arg` nodes (positional, in order).
/// `mod` must be the module the procedure belongs to (needed for the object pool).
///
/// Fails with `error.SideEffect` if the procedure touches world state.
/// Interpreter errors (e.g. unimplemented op) surface as `TaggedValue.None`
/// with a debug print — they do not abort compilation.
pub fn evalPure(
    allocator: std.mem.Allocator,
    mod: *const ir.Module,
    proc: *const ir.Procedure,
    args: []const TaggedValue,
) EvalError!TaggedValue {
    try checkPure(proc);

    // Build a comptime EnsoCtx on the stack — no heap allocation.
    // stdout is unreachable: the vtable traps any print before it arrives.
    var unreachable_writer: std.Io.Writer = .failing;
    var ctx = EnsoCtx{
        .allocator = allocator,
        .stdout = &unreachable_writer,
        .intern_pool = mod.intern_pool,
        .object_pool = &mod.object_pool,
        .vtable = .{
            .py_call = comptimePyCall,
            .py_print = comptimePyPrint,
        },
    };

    return baseline.interpret(allocator, mod, proc, args, &ctx) catch TaggedValue.None;
}

// ── Comptime vtable traps ────────────────────────────────────────────────────
//
// These should never be reached after checkPure passes.  They exist so that
// if an opcode is mistagged in the effects table, the trap fires instead of
// silently corrupting state.

fn comptimePyCall(
    ctx: *EnsoCtx,
    receiver: TaggedValue,
    callable: TaggedValue,
    args: [*]const TaggedValue,
    nargs: u32,
) TaggedValue {
    _ = ctx;
    _ = receiver;
    _ = callable;
    _ = args;
    _ = nargs;
    @panic("comptime: py_call reached despite checkPure — effects table bug");
}

fn comptimePyPrint(ctx: *EnsoCtx, val: TaggedValue) void {
    _ = ctx;
    _ = val;
    @panic("comptime: py_print reached despite checkPure — effects table bug");
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_utils = @import("../test/utils.zig");

// Module-level expression statements are discarded; the module returns None.
test "evalPure: module proc returns None" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    var mod = try harness.lowerModule(testing.allocator, "42");
    defer mod.deinit();

    const result = try evalPure(testing.allocator, &mod, &mod.procedures.items[0], &.{});
    try testing.expectEqual(TaggedValue.None.bits, result.bits);
}

// A nested function with no effects returns its constant.
test "evalPure: function returning integer constant" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    var mod = try harness.lowerModule(testing.allocator,
        \\def f():
        \\    return 42
    );
    defer mod.deinit();

    // proc[0] = module body, proc[1] = f
    const result = try evalPure(testing.allocator, &mod, &mod.procedures.items[1], &.{});
    try testing.expect(result.isInteger());
    try testing.expectEqual(@as(i60, 42), result.asIntegerUnchecked());
}

// print() has writes_world — checkPure must reject it before interpretation.
test "evalPure: side effect is rejected" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    var mod = try harness.lowerModule(testing.allocator, "print('hello')");
    defer mod.deinit();

    const result = evalPure(testing.allocator, &mod, &mod.procedures.items[0], &.{});
    try testing.expectError(error.SideEffect, result);
}
