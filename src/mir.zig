const std = @import("std");
// pub const c = @import("./mir/consts.zig");
const abi = @import("mir_abi");

pub const c = @cImport({
    @cInclude("mir.h");
    @cInclude("mir-gen.h");
});

// extern fn enso_mir_op_reg(ctx: c.MIR_context_t, out: *c.MIR_op_t, reg: c.MIR_reg_t) void;
// extern fn enso_mir_op_int(ctx: c.MIR_context_t, out: *c.MIR_op_t, v: i64) void;
// extern fn enso_mir_op_label(ctx: c.MIR_context_t, out: *c.MIR_op_t, lab: c.MIR_label_t) void;
// extern fn enso_mir_new_insn_arr(ctx: c.MIR_context_t, code: c.MIR_insn_code_t, nops: usize, ops: [*]c.MIR_op_t) c.MIR_insn_t;

extern fn MIR_new_reg_op(ctx: c.MIR_context_t, reg: c.MIR_reg_t) abi.MIR_op_t;
extern fn MIR_new_int_op(ctx: c.MIR_context_t, v: i64) abi.MIR_op_t;
extern fn MIR_new_uint_op(ctx: c.MIR_context_t, v: u64) abi.MIR_op_t;
extern fn MIR_new_label_op(ctx: c.MIR_context_t, lab: c.MIR_label_t) abi.MIR_op_t;
extern fn MIR_new_ref_op(ctx: c.MIR_context_t, item: c.MIR_item_t) abi.MIR_op_t;
extern fn MIR_new_mem_op(ctx: c.MIR_context_t, t: c.MIR_type_t, disp: c.MIR_disp_t, base: c.MIR_reg_t, index: c.MIR_reg_t, scale: c.MIR_scale_t) abi.MIR_op_t;

// And the insn constructor we care about:
extern fn MIR_new_insn_arr(ctx: c.MIR_context_t, code: c.MIR_insn_code_t, nops: usize, ops: [*]const abi.MIR_op_t) c.MIR_insn_t;

pub const MirError = error{
    InitFailed,
    VersionMismatch,
};

const MIR_API_VERSION: f64 = 0.2;

fn MIR_init_checked() MirError!c.MIR_context_t {
    const v = c._MIR_get_api_version();
    if (v != MIR_API_VERSION) return MirError.VersionMismatch;

    const ctx = c._MIR_init(null, null);
    if (ctx == null) return MirError.InitFailed;
    return ctx;
}

//////////////////////////////////

/// MIR Zig bindings + small convenience layer.
///
/// This module:
/// - exposes the raw C API under `c`
/// - provides `Context`, `Module`, and `FuncBuilder` wrappers
/// - provides ergonomic operand constructors (`op.*`)
///
/// MIR constraints to keep in mind:
/// - Only one module can be "open" at a time per context (finish it before starting another).
/// - Only one function can be "open" at a time per context (finish it before starting another).
/// - Non-arg regs: the only permitted integer reg type is MIR_T_I64 (per docs / mir.h comments).
/// Owns MIR_context_t. All MIR items/modules/insns allocated in this context
/// are freed by `MIR_finish`.
pub const Context = struct {
    ctx: c.MIR_context_t,

    /// Create a new MIR context using default allocators.
    pub fn init() !Context {
        return .{ .ctx = try MIR_init_checked() };
    }

    /// Create a new MIR context using custom allocators.
    // TODO: there is a library called zalloc which might give us that
    // zig->c alloc.  not worth the squeeze now though
    // pub fn init2(alloc: ?c.MIR_alloc_t, code_alloc: ?c.MIR_code_alloc_t) Context {
    //     return .{ .ctx = c.MIR_init2(alloc, code_alloc) };
    // }

    /// Free all MIR internal data and all IR allocated in this context.
    pub fn deinit(self: *Context) void {
        c.MIR_finish(self.ctx);
        self.* = undefined;
    }

    /// Set MIR error handler. The default prints to stderr and exits(1).
    // pub fn setErrorFunc(self: *Context, f: c.MIR_error_func_t) void {
    //     c.MIR_set_error_func(self.ctx, f);
    // }

    /// Initialize MIR generator (JIT backend) for this context.
    pub fn genInit(self: *Context) void {
        c.MIR_gen_init(self.ctx);
    }

    /// Set generator optimize level:
    /// 0 = regalloc+codegen only
    /// 1 = + code selection
    /// 2 = + CSE + SCCP (default)
    /// 3 = + reg renaming + LICM
    pub fn genSetOptimizeLevel(self: *Context, level: u32) void {
        c.MIR_gen_set_optimize_level(self.ctx, level);
    }

    /// Finish generator and free generator internal data for this context.
    pub fn genFinish(self: *Context) void {
        c.MIR_gen_finish(self.ctx);
    }

    /// Load a finished module into the context. This simplifies the code
    /// and allocates module data/bss/refs/lrefs sections.
    pub fn loadModule(self: *Context, m: c.MIR_module_t) void {
        c.MIR_load_module(self.ctx, m);
    }

    /// Provide an address for an imported item name (e.g. a Zig/C runtime helper).
    pub fn loadExternal(self: *Context, name: [:0]const u8, addr: *anyopaque) void {
        c.MIR_load_external(self.ctx, name.ptr, addr);
    }

    /// Link all modules loaded since last link.
    ///
    /// `set_interface` controls how MIR calls execute:
    /// - MIR_set_interp_interface: interpret MIR code
    /// - MIR_set_gen_interface: eagerly compile all funcs, then execute machine code
    /// - MIR_set_lazy_gen_interface: compile funcs on first call
    /// - MIR_set_lazy_bb_gen_interface: compile basic blocks on first execution (enables BB versioning)
    pub fn link(
        self: *Context,
        set_interface: ?*const fn (c.MIR_context_t, c.MIR_item_t) callconv(.c) void,
        import_resolver: ?*const fn ([*c]const u8) callconv(.c) ?*anyopaque,
    ) void {
        c.MIR_link(self.ctx, set_interface, import_resolver);
    }

    /// Execute a MIR function by interpreter with argv array.
    pub fn interpArr(
        self: *Context,
        func_item: c.MIR_item_t,
        results: [*c]c.MIR_val_t,
        nargs: usize,
        args: [*c]c.MIR_val_t,
    ) void {
        c.MIR_interp_arr(self.ctx, func_item, results, nargs, args);
    }

    /// TODO: ideally we aren't calling into libc here, but
    /// not sure of a better way to do it.  This is only relevant
    /// for debugging anyway so probably ok
    pub fn dumpAll(self: *Context) void {
        const stderr = std.Io.File.stderr();
        // FILE* is hidden inside libc; use fdopen
        const file: *c.FILE = @ptrCast(c.fdopen(stderr.handle, "w"));
        c.MIR_output(self.ctx, file);
    }
};

/// Module builder wrapper.
pub const Module = struct {
    ctx: *Context,
    m: c.MIR_module_t,

    /// Start a new module. Only one module can be open at a time per context.
    pub fn init(ctx: *Context, name: [:0]const u8) Module {
        return .{ .ctx = ctx, .m = c.MIR_new_module(ctx.ctx, name.ptr) };
    }

    /// Finish building this module. Must be called before `loadModule`.
    pub fn finish(self: *Module) void {
        c.MIR_finish_module(self.ctx.ctx);
    }

    pub fn newImport(self: *Module, name: [:0]const u8) c.MIR_item_t {
        return c.MIR_new_import(self.ctx.ctx, name.ptr);
    }

    pub fn newExport(self: *Module, name: [:0]const u8) c.MIR_item_t {
        return c.MIR_new_export(self.ctx.ctx, name.ptr);
    }

    pub fn newProtoArr(
        self: *Module,
        name: [:0]const u8,
        res_types: []const c.MIR_type_t,
        args: []const c.MIR_var_t,
    ) c.MIR_item_t {
        return c.MIR_new_proto_arr(
            self.ctx.ctx,
            name.ptr,
            res_types.len,
            @ptrCast(@constCast(res_types.ptr)),
            args.len,
            @ptrCast(@constCast(args.ptr)),
        );
    }

    pub fn newFuncArr(
        self: *Module,
        name: [:0]const u8,
        res_types: []const c.MIR_type_t,
        args: []const c.MIR_var_t,
    ) FuncBuilder {
        const item = c.MIR_new_func_arr(
            self.ctx.ctx,
            name.ptr,
            res_types.len,
            @ptrCast(@constCast(res_types.ptr)),
            args.len,
            @ptrCast(@constCast(args.ptr)),
        );
        return .{ .ctx = self.ctx, .func_item = item, .func = item.*.u.func };
    }

    pub fn newData(self: *Module, name: ?[:0]const u8, el_type: c.MIR_type_t, bytes: []const u8) c.MIR_item_t {
        return c.MIR_new_data(
            self.ctx.ctx,
            if (name) |n| n.ptr else null,
            el_type,
            bytes.len,
            bytes.ptr,
        );
    }
};

/// Function builder.
pub const FuncBuilder = struct {
    ctx: *Context,
    func_item: c.MIR_item_t,
    func: c.MIR_func_t,

    /// Create a non-arg function reg (local).
    /// For integer regs, MIR expects c.MIR_T_I64.
    pub fn reg(self: *FuncBuilder, ty: c.MIR_type_t, name: [:0]const u8) c.MIR_reg_t {
        return c.MIR_new_func_reg(self.ctx.ctx, self.func, ty, name.ptr);
    }

    /// Look up an arg reg by name in this function.
    pub fn arg(self: *FuncBuilder, name: [:0]const u8) c.MIR_reg_t {
        return c.MIR_reg(self.ctx.ctx, name.ptr, self.func);
    }

    /// Create a label insn you can append into the insn list.
    pub fn label(self: *FuncBuilder) c.MIR_insn_t {
        return c.MIR_new_label(self.ctx.ctx);
    }

    /// Append an instruction to this function.
    pub fn append(self: *FuncBuilder, isn: c.MIR_insn_t) void {
        c.MIR_append_insn(self.ctx.ctx, self.func_item, isn);
    }

    /// Finish function construction (required).
    pub fn finish(self: *FuncBuilder) void {
        c.MIR_finish_func(self.ctx.ctx);
    }

    /// Convenience: append a `RET` with given operands (0..N).
    pub fn ret(self: *FuncBuilder, ops: []const abi.MIR_op_t) void {
        // const insn = insn.newRet(self.ctx, rets);
        // c.MIR_append_insn(self.ctx.ctx, self.func_item, insn);
        // const isn = c.MIR_new_ret_insn(self.ctx.ctx, ops.len, ops.ptr);

        // const isn = c.MIR_new_insn_arr(self.ctx.ctx, c.MIR_RET, ops.len, ops.ptr);
        // self.append(isn);

        self.append(insn.ret(self.ctx, ops));
    }

    /// Convenience: append a CALL.
    ///
    /// Layout must follow MIR rules:
    ///   [0] proto ref
    ///   [1] callee address (ref op or reg containing address)
    ///   [2..2+nres) result destinations
    ///   remaining: args
    pub fn call(self: *FuncBuilder, ops: []const abi.MIR_op_t) void {
        const isn = c.MIR_new_call_insn(self.ctx.ctx, ops.len, ops.ptr);
        self.append(isn);
    }
};

pub const op = struct {
    pub fn reg(ctx: *Context, r: c.MIR_reg_t) abi.MIR_op_t {
        return MIR_new_reg_op(ctx.ctx, r);
    }
    pub fn i(ctx: *Context, v: i64) abi.MIR_op_t {
        return MIR_new_int_op(ctx.ctx, v);
    }
    pub fn u(ctx: *Context, v: u64) abi.MIR_op_t {
        return MIR_new_uint_op(ctx.ctx, v);
    }
    pub fn ref(ctx: *Context, item: c.MIR_item_t) abi.MIR_op_t {
        return MIR_new_ref_op(ctx.ctx, item);
    }
    pub fn label(ctx: *Context, lab: c.MIR_label_t) abi.MIR_op_t {
        return MIR_new_label_op(ctx.ctx, lab);
    }
    /// Memory operand: type: [disp](base, index, scale)
    pub fn mem(ctx: *Context, ty: c.MIR_type_t, disp: c.MIR_disp_t, base: c.MIR_reg_t, index: c.MIR_reg_t, scale: c.MIR_scale_t) abi.MIR_op_t {
        return MIR_new_mem_op(ctx.ctx, ty, disp, base, index, scale);
    }
    // /// Memory operand with alias/nonalias.
    // pub fn memAlias(
    //     ctx: *Context,
    //     ty: c.MIR_type_t,
    //     disp: c.MIR_disp_t,
    //     base: c.MIR_reg_t,
    //     index: c.MIR_reg_t,
    //     scale: c.MIR_scale_t,
    //     alias: c.MIR_alias_t,
    //     @"noalias": c.MIR_alias_t,
    // ) abi.MIR_op_t {
    //     return MIR_new_alias_mem_op(ctx.ctx, ty, disp, base, index, scale, alias, @"noalias");
    // }
};

// const Op = struct { storage: c.MIR_op_t };

// /// Operand constructors (ergonomic and LSP-friendly).
// pub const op = struct {
//     pub fn reg(ctx: *Context, r: c.MIR_reg_t) Op {
//         var o: Op = undefined;
//         enso_mir_op_reg(ctx.ctx, &o.storage, r);
//         return o;
//     }
//     pub fn i(ctx: *Context, s: i64) Op {
//         var o: Op = undefined;
//         enso_mir_op_int(ctx.ctx, &o.storage, s);
//         return o;
//     }
//     pub fn label(ctx: *Context, lab: c.MIR_label_t) Op {
//         var o: Op = undefined;
//         enso_mir_op_label(ctx.ctx, &o.storage, lab);
//         return o;
//     }
// };

/// Instruction constructors.
pub const insn = struct {
    /// Fixed-arity insns: c.MIR_new_insn_arr(code, nops, ops)
    pub fn fixed(ctx: *Context, code: c.MIR_insn_code_t, ops: []const abi.MIR_op_t) c.MIR_insn_t {
        return c.MIR_new_insn_arr(ctx.ctx, code, ops.len, @ptrCast(@constCast(ops.ptr)));
    }

    /// PRSET var, const
    pub fn prset(ctx: *Context, var_op: c.MIR_op_t, k: i64) c.MIR_insn_t {
        var ops = [_]c.MIR_op_t{ var_op, c.MIR_new_int_op(ctx.ctx, k) };
        return c.MIR_new_insn_arr(ctx.ctx, c.c.MIR_PRSET, ops.len, &ops);
    }

    /// PRBEQ label, var, const
    pub fn prbeq(ctx: *Context, label_op: c.MIR_op_t, var_op: abi.MIR_op_t, k: i64) c.MIR_insn_t {
        var ops = [_]c.MIR_op_t{ label_op, var_op, c.MIR_new_int_op(ctx.ctx, k) };
        return c.MIR_new_insn_arr(ctx.ctx, c.c.MIR_PRBEQ, ops.len, &ops);
    }

    /// PRBNE label, var, const
    pub fn prbne(ctx: *Context, label_op: c.MIR_op_t, var_op: abi.MIR_op_t, k: i64) c.MIR_insn_t {
        var ops = [_]c.MIR_op_t{ label_op, var_op, c.MIR_new_int_op(ctx.ctx, k) };
        return c.MIR_new_insn_arr(ctx.ctx, c.c.MIR_PRBNE, ops.len, &ops);
    }

    // pub fn fixed(ctx: *Context, code: c.MIR_insn_code_t, ops: []const MIR_op_t) c.MIR_insn_t {
    //     return MIR_new_insn_arr(ctx.ctx, code, ops.len, ops.ptr);
    // }

    pub fn ret(ctx: *Context, ops: []const abi.MIR_op_t) c.MIR_insn_t {
        return MIR_new_insn_arr(ctx.ctx, c.MIR_RET, ops.len, ops.ptr);
    }
};
