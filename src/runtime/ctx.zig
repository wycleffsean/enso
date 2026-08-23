/// EnsoCtx — the runtime context threaded through every JIT-compiled function.
///
/// Every MIR-compiled function receives a `*EnsoCtx` as its first argument
/// (passed as a u64 pointer in the I64 register file).  The vtable starts
/// populated with Zig implementations; slots can be overwritten in place with
/// MIR-compiled versions as the compiler bootstraps itself.
const std = @import("std");
const TaggedValue = @import("../TaggedValue.zig");
const intern = @import("../intern.zig");
const object = @import("../object.zig");
const core = @import("core.zig");
const builtins = @import("builtins.zig");

pub const EnsoCtx = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    vtable: Vtable,
    /// Interned name strings — needed by py_load_name at runtime.
    intern_pool: *const intern.StringInternPool,
    /// Object constants pool — needed to materialise boxed objects at runtime.
    object_pool: *const intern.ObjectPool,

    pub const Vtable = struct {
        /// Python-level call: `callable(receiver, *args)`.
        /// args[0..nargs] are the positional arguments (receiver NOT included).
        py_call: *const fn (
            ctx: *EnsoCtx,
            receiver: TaggedValue,
            callable: TaggedValue,
            args: [*]const TaggedValue,
            nargs: u32,
        ) TaggedValue,

        /// Python-level print: `print(val)` — writes to ctx.stdout.
        py_print: *const fn (ctx: *EnsoCtx, val: TaggedValue) void,
    };

    /// Initialise with default Zig implementations.
    pub fn init(
        allocator: std.mem.Allocator,
        stdout: *std.Io.Writer,
        intern_pool: *const intern.StringInternPool,
        object_pool: *const intern.ObjectPool,
    ) !*EnsoCtx {
        const self = try allocator.create(EnsoCtx);
        self.* = .{
            .allocator = allocator,
            .stdout = stdout,
            .intern_pool = intern_pool,
            .object_pool = object_pool,
            .vtable = .{
                .py_call = core.pyCall,
                .py_print = builtins.pyPrint,
            },
        };
        return self;
    }

    pub fn deinit(self: *EnsoCtx) void {
        self.allocator.destroy(self);
    }
};
