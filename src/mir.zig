const std = @import("std");

// zig's translate-c doesn't like the mir.h header, so we
// declare the opaque type and extern functions below

pub const MIR_alloc_t = ?*opaque {};
pub const MIR_code_alloc_t = ?*opaque {};
pub const MIR_context_t = ?*opaque {};

extern fn _MIR_get_api_version() f64;
extern fn _MIR_init(MIR_alloc_t, MIR_code_alloc_t) MIR_context_t;
extern fn MIR_finish(ctx: MIR_context_t) void;

pub const MirError = error{
    InitFailed,
    VersionMismatch,
};

const MIR_API_VERSION: f64 = 0.2;

fn MIR_init_checked() MirError!MIR_context_t {
    const v = _MIR_get_api_version();
    if (v != MIR_API_VERSION) return MirError.VersionMismatch;

    const ctx = _MIR_init(null, null);
    if (ctx == null) return MirError.InitFailed;
    return ctx;
}

pub const Context = struct {
    ctx: MIR_context_t,

    pub fn init() !Context {
        return .{ .ctx = try MIR_init_checked() };
    }

    pub fn deinit(self: *const Context) void {
        MIR_finish(self.ctx);
    }
};
