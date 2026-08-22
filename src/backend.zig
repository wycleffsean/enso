/// Backend interface — the compilation target for enso IR.
///
/// A Backend outlives any single module: it owns resources (JIT context,
/// object file handles, etc.) that span many compilation units.  Modules
/// are submitted one at a time via `compileModule`, which returns an opaque
/// `CompiledModule` handle the caller can then execute.
const std = @import("std");
const ir = @import("ir.zig");
pub const MirBackend = @import("backend/mir.zig").MirBackend;

/// A successfully compiled module.  The top-level body of the module is
/// callable as a zero-argument C function returning u64 (a TaggedValue)
pub const CompiledModule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Call the module's top-level body.  Returns the TaggedValue produced
        /// by the module's final `ret` instruction.
        call: *const fn (ptr: *anyopaque) u64,
        /// Release any resources held by this CompiledModule.
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn call(self: CompiledModule) u64 {
        return self.vtable.call(self.ptr);
    }

    pub fn deinit(self: CompiledModule) void {
        self.vtable.deinit(self.ptr);
    }
};

/// The backend interface in the flesh
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Compile one IR module.  The backend may link it immediately or
        /// defer linking until `call` is invoked on the resulting handle.
        compileModule: *const fn (ptr: *anyopaque, mod: *const ir.Module) anyerror!CompiledModule,

        /// Tear down the backend and release all held resources.
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn compileModule(self: Backend, mod: *const ir.Module) !CompiledModule {
        return self.vtable.compileModule(self.ptr, mod);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
};
