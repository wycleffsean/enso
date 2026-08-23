/// Built-in function implementations — initial Zig versions of Python builtins.
///
/// Each function matches the slot signature in EnsoCtx.Vtable and can be
/// replaced with a MIR-compiled version when the compiler can produce one.
const std = @import("std");
const TaggedValue = @import("../TaggedValue.zig");
const object = @import("../object.zig");
const ctx_mod = @import("ctx.zig");
const EnsoCtx = ctx_mod.EnsoCtx;

/// `print(val)` — writes the Python string representation of each arg.
/// Note: the VM fixture captures stdout without a trailing newline per value.
pub fn pyPrint(ctx: *EnsoCtx, val: TaggedValue) void {
    printVal(ctx, val) catch {};
}

fn printVal(ctx: *EnsoCtx, val: TaggedValue) !void {
    if (val.isPointer()) {
        // Boxed object — pointer tag wraps a *const object.Object.
        const obj: *const object.Object = @ptrCast(@alignCast(val.asPointer()));
        const fmt: object.FormatObject = .{ .obj = obj, .intern_pool = ctx.intern_pool };
        try ctx.stdout.print("{f}", .{fmt});
    } else {
        try val.format(ctx.stdout);
    }
}
