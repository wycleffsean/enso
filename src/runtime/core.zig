/// Core runtime dispatch — Python-level call semantics.
///
/// `pyCall` is the initial Zig implementation of the py_call vtable slot.
/// It will eventually be replaced with a MIR-compiled Python method dispatch
/// once MRO is implemented.
const std = @import("std");
const TaggedValue = @import("../TaggedValue.zig");
const intern = @import("../intern.zig");
const ctx_mod = @import("ctx.zig");
const EnsoCtx = ctx_mod.EnsoCtx;

// ── C-ABI shims imported by MIR-compiled code ────────────────────────────────
//
// These are exported with callconv(.c) so MIR can import them by name and call
// through the vtable without knowing field offsets.

/// MIR import: load a name from the global/builtin namespace.
/// `name_sym` is the intern.Index of the name string.
pub export fn enso_py_load_name(ctx: *EnsoCtx, name_sym: u64) u64 {
    const sym: intern.Index = @intCast(name_sym);
    const name = ctx.intern_pool.get(sym);
    if (builtinByName(name)) |id| return builtinValue(id).bits;
    std.debug.print("runtime: py_load_name: unknown name '{s}'\n", .{name});
    return TaggedValue.None.bits;
}

/// MIR import: call a Python callable.
/// `args_ptr` points to an array of `nargs` TaggedValue u64 words.
pub export fn enso_py_call(
    ctx: *EnsoCtx,
    receiver_bits: u64,
    callable_bits: u64,
    args_ptr: [*]const u64,
    nargs: u64,
) u64 {
    const receiver: TaggedValue = .{ .bits = receiver_bits };
    const callable: TaggedValue = .{ .bits = callable_bits };
    // Reinterpret the u64 array as TaggedValue array (same layout).
    const args: [*]const TaggedValue = @ptrCast(args_ptr);
    return ctx.vtable.py_call(ctx, receiver, callable, args, @intCast(nargs)).bits;
}

/// Builtin function identifiers.  Encoded as TaggedValue.integer(id) by
/// py_load_name so the call site can dispatch without a heap pointer.
pub const BuiltinId = enum(i60) {
    print = 0,
};

/// Return the BuiltinId for a named builtin, or null if not a builtin.
pub fn builtinByName(name: []const u8) ?BuiltinId {
    const map = std.StaticStringMap(BuiltinId).initComptime(.{
        .{ "print", .print },
    });
    return map.get(name);
}

/// Encode a BuiltinId as a TaggedValue so py_load_name can return it.
pub fn builtinValue(id: BuiltinId) TaggedValue {
    return TaggedValue.integer(@intFromEnum(id));
}

/// Python-level call dispatch.
///
/// For now this only handles builtins encoded as TaggedValue.integer(BuiltinId).
/// Future: heap-allocated callable objects (functions, methods, types).
pub fn pyCall(
    ctx: *EnsoCtx,
    receiver: TaggedValue,
    callable: TaggedValue,
    args: [*]const TaggedValue,
    nargs: u32,
) TaggedValue {
    _ = receiver;
    // Builtins are encoded as integers in the callable slot.
    if (callable.isInteger()) {
        const id: BuiltinId = @enumFromInt(callable.asIntegerUnchecked());
        switch (id) {
            .print => {
                // print accepts any number of args; for now print each one.
                for (args[0..nargs]) |arg| {
                    ctx.vtable.py_print(ctx, arg);
                }
                return TaggedValue.None;
            },
        }
    }
    std.debug.print("runtime: py_call: unhandled callable bits=0x{x}\n", .{callable.bits});
    return TaggedValue.None;
}
