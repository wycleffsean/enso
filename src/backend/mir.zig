/// MIR JIT backend.
///
/// Owns a MIR context for the lifetime of the backend.  Modules are compiled
/// one at a time (MIR constraint: only one module open per context at once).
/// After compilation the module is loaded and linked immediately so the
/// returned CompiledModule can be called without further setup.
const std = @import("std");
const ir = @import("../ir.zig");
const mir = @import("../mir.zig");
const TaggedValue = @import("../TaggedValue.zig");
const backend = @import("../backend.zig");
const intern = @import("../intern.zig");
const object = @import("../object.zig");
const ctx_mod = @import("../runtime/ctx.zig");
const core = @import("../runtime/core.zig");
const test_utils = @import("../test/utils.zig");

const EnsoCtx = ctx_mod.EnsoCtx;
const Backend = backend.Backend;
const CompiledModule = backend.CompiledModule;

// ── MirBackend ──────────────────────────────────────────────────────────────

pub const MirBackend = struct {
    allocator: std.mem.Allocator,
    mctx: mir.Context,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .mctx = try mir.Context.init(),
        };
        self.mctx.genInit();
        self.mctx.genSetOptimizeLevel(0); // regalloc+codegen only for now
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.mctx.genFinish();
        self.mctx.deinit();
        self.allocator.destroy(self);
    }

    /// Return a type-erased Backend handle pointing at this instance.
    pub fn backend(self: *Self) Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // ── vtable implementations ───────────────────────────────────────────

    fn vtableCompileModule(ptr: *anyopaque, mod: *const ir.Module) anyerror!CompiledModule {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.compileModule(mod);
    }

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable: Backend.VTable = .{
        .compileModule = vtableCompileModule,
        .deinit = vtableDeinit,
    };

    // ── compilation ──────────────────────────────────────────────────────

    fn compileModule(self: *Self, mod: *const ir.Module) !CompiledModule {
        // MIR allows only one module open at a time.
        var mir_mod = mir.Module.init(&self.mctx, "<enso>");
        errdefer mir_mod.finish();

        if (mod.procedures.items.len == 0) return error.EmptyModule;
        const proc = &mod.procedures.items[0];

        // Declare imports for runtime shims (resolved at link time).
        const import_load_name = mir_mod.newImport("enso_py_load_name");
        const import_py_call = mir_mod.newImport("enso_py_call");

        // Build prototypes for the shims so MIR can type-check calls.
        // enso_py_load_name(*ctx, sym_idx) -> i64
        const proto_load_name = mir_mod.newProtoArr("p_enso_py_load_name", &.{mir.c.MIR_T_I64}, &.{
            .{ .type = mir.c.MIR_T_I64, .name = "ctx", .size = 0 },
            .{ .type = mir.c.MIR_T_I64, .name = "sym", .size = 0 },
        });
        // enso_py_call(*ctx, receiver, callable, args_ptr, nargs) -> i64
        const proto_py_call = mir_mod.newProtoArr("p_enso_py_call", &.{mir.c.MIR_T_I64}, &.{
            .{ .type = mir.c.MIR_T_I64, .name = "ctx", .size = 0 },
            .{ .type = mir.c.MIR_T_I64, .name = "receiver", .size = 0 },
            .{ .type = mir.c.MIR_T_I64, .name = "callable", .size = 0 },
            .{ .type = mir.c.MIR_T_I64, .name = "args_ptr", .size = 0 },
            .{ .type = mir.c.MIR_T_I64, .name = "nargs", .size = 0 },
        });

        const imports: Imports = .{
            .load_name = import_load_name,
            .py_call = import_py_call,
            .proto_load_name = proto_load_name,
            .proto_py_call = proto_py_call,
        };

        const func_item = try compileProcedure(self, &mir_mod, proc, mod, &imports);

        mir_mod.finish();
        self.mctx.loadModule(mir_mod.m);

        // Resolve runtime shims by address.
        const resolver = struct {
            fn resolve(name: [*c]const u8) callconv(.c) ?*anyopaque {
                const n = std.mem.span(name);
                if (std.mem.eql(u8, n, "enso_py_load_name")) return @ptrCast(@constCast(&core.enso_py_load_name));
                if (std.mem.eql(u8, n, "enso_py_call")) return @ptrCast(@constCast(&core.enso_py_call));
                return null;
            }
        }.resolve;

        self.mctx.link(mir.c.MIR_set_gen_interface, resolver);

        const raw_addr = func_item.*.addr;
        const ModFn = *const fn (ctx: u64) callconv(.c) u64;
        const fn_ptr: ModFn = @ptrCast(@alignCast(raw_addr));

        const box = try self.allocator.create(MirCompiledModule);
        box.* = .{ .fn_ptr = fn_ptr, .allocator = self.allocator };
        return .{
            .ptr = box,
            .vtable = &MirCompiledModule.vtable,
        };
    }

    /// Imported shim items, valid for the duration of module construction.
    const Imports = struct {
        load_name: mir.c.MIR_item_t,
        py_call: mir.c.MIR_item_t,
        proto_load_name: mir.c.MIR_item_t,
        proto_py_call: mir.c.MIR_item_t,
    };

    fn compileProcedure(
        self: *Self,
        mir_mod: *mir.Module,
        proc: *const ir.Procedure,
        mod: *const ir.Module,
        imports: *const Imports,
    ) !mir.c.MIR_item_t {
        const res_types = [_]mir.c.MIR_type_t{mir.c.MIR_T_I64};
        // First arg: *EnsoCtx passed as u64.
        var args = [_]mir.c.MIR_var_t{.{ .type = mir.c.MIR_T_I64, .name = "ctx_ptr", .size = 0 }};

        var name_buf: [256]u8 = undefined;
        const name_z = try std.fmt.bufPrintZ(&name_buf, "{s}", .{proc.name});

        var fb = mir_mod.newFuncArr(name_z, &res_types, &args);

        // ctx_ptr arg reg — holds the *EnsoCtx as a raw u64.
        const ctx_reg = fb.arg("ctx_ptr");

        // Allocate one I64 MIR reg per SSA value.
        var reg_buf: [256]u8 = undefined;
        const nvals = proc.values.len;
        const regs = try self.allocator.alloc(mir.c.MIR_reg_t, nvals);
        defer self.allocator.free(regs);
        for (0..nvals) |i| {
            const reg_name = try std.fmt.bufPrintZ(&reg_buf, "v{d}", .{i});
            regs[i] = fb.reg(mir.c.MIR_T_I64, reg_name);
        }

        for (proc.blocks.items) |*block| {
            for (block.values.items) |vid| {
                try emitValue(self, &fb, proc, mod, regs, ctx_reg, imports, vid);
            }
        }

        fb.finish();
        return fb.func_item;
    }

    fn emitValue(
        self: *Self,
        fb: *mir.FuncBuilder,
        proc: *const ir.Procedure,
        mod: *const ir.Module,
        regs: []const mir.c.MIR_reg_t,
        ctx_reg: mir.c.MIR_reg_t,
        imports: *const Imports,
        vid: ir.ValueId,
    ) !void {
        const mctx = &self.mctx;
        const idx = vid.idx();
        const v = proc.values.get(idx);
        const dest = regs[idx];

        switch (v.op) {
            .nop, .identity => {},

            .const_obj => {
                const bits: u64 = switch (v.repr) {
                    .tagged => TaggedValue.assemble(v.lhs, v.rhs).bits,
                    .object => blk: {
                        // Box a pointer to the object pool entry as a TaggedValue.
                        const pool_idx: intern.ObjectPool.ObjectIndex = @enumFromInt(v.lhs);
                        // getConst returns by value; we need a stable pointer.
                        // The pool does not grow after lowering, so the slice is stable.
                        const obj_ptr = &mod.object_pool.pool.entries.items(.key)[@intFromEnum(pool_idx)];
                        break :blk TaggedValue.fromPointer(obj_ptr).bits;
                    },
                    else => TaggedValue.None.bits,
                };
                fb.append(mir.insn.fixed(mctx, mir.c.MIR_MOV, &.{
                    mir.op.reg(mctx, dest),
                    mir.op.u(mctx, bits),
                }));
            },

            .py_load_name => {
                // lhs = ObjectPool index of the name symbol object.
                // Resolve at compile time if it's a known builtin; otherwise emit a runtime call.
                const pool_idx: intern.ObjectPool.ObjectIndex = @enumFromInt(v.lhs);
                const obj = mod.object_pool.getConst(pool_idx);
                const sym = obj.symbol;
                const name = mod.intern_pool.get(sym);
                if (core.builtinByName(name)) |bid| {
                    // Known builtin — fold to a constant.
                    fb.append(mir.insn.fixed(mctx, mir.c.MIR_MOV, &.{
                        mir.op.reg(mctx, dest),
                        mir.op.u(mctx, core.builtinValue(bid).bits),
                    }));
                } else {
                    // Unknown name — emit a runtime lookup.
                    fb.call(&.{
                        mir.op.ref(mctx, imports.proto_load_name),
                        mir.op.ref(mctx, imports.load_name),
                        mir.op.reg(mctx, dest),
                        mir.op.reg(mctx, ctx_reg),
                        mir.op.u(mctx, @as(u64, sym)),
                    });
                }
            },

            .py_call => {
                // extra layout: [receiver_vid, callable_vid, arg0_vid, ...]
                // lhs = total operand count (receiver + callable + nargs)
                const total: u32 = v.lhs;
                const nargs: u32 = total - 2;
                const off: u32 = v.rhs;
                const receiver_reg = regs[proc.extra.items[off + 0]];
                const callable_reg = regs[proc.extra.items[off + 1]];

                // ALLOCA args_buf, nargs * 8  (may be 0)
                const args_buf_reg = try allocTempReg(fb, "args_buf");
                fb.append(mir.insn.fixed(mctx, mir.c.MIR_ALLOCA, &.{
                    mir.op.reg(mctx, args_buf_reg),
                    mir.op.u(mctx, @as(u64, nargs) * 8),
                }));

                // Store each arg into the buffer.
                for (0..nargs) |a| {
                    const arg_reg = regs[proc.extra.items[off + 2 + a]];
                    fb.append(mir.insn.fixed(mctx, mir.c.MIR_MOV, &.{
                        mir.op.mem(mctx, mir.c.MIR_T_I64, @intCast(a * 8), args_buf_reg, 0, 1),
                        mir.op.reg(mctx, arg_reg),
                    }));
                }

                fb.call(&.{
                    mir.op.ref(mctx, imports.proto_py_call),
                    mir.op.ref(mctx, imports.py_call),
                    mir.op.reg(mctx, dest),
                    mir.op.reg(mctx, ctx_reg),
                    mir.op.reg(mctx, receiver_reg),
                    mir.op.reg(mctx, callable_reg),
                    mir.op.reg(mctx, args_buf_reg),
                    mir.op.u(mctx, nargs),
                });
            },

            .ret => {
                const val_reg = regs[v.lhs];
                fb.ret(&.{mir.op.reg(mctx, val_reg)});
            },

            .jump => {},

            else => {
                std.debug.print("MIR backend: unimplemented op {s} at %v{d}\n", .{ @tagName(v.op), idx });
                fb.append(mir.insn.fixed(mctx, mir.c.MIR_MOV, &.{
                    mir.op.reg(mctx, dest),
                    mir.op.u(mctx, TaggedValue.None.bits),
                }));
            },
        }
    }

    // Temp reg counter — unique per compilation unit is sufficient since MIR
    // names are scoped to the current function.
    var temp_reg_counter: u32 = 0;

    fn allocTempReg(fb: *mir.FuncBuilder, comptime prefix: []const u8) !mir.c.MIR_reg_t {
        var buf: [64]u8 = undefined;
        temp_reg_counter +%= 1;
        const name = try std.fmt.bufPrintZ(&buf, prefix ++ "_{d}", .{temp_reg_counter});
        return fb.reg(mir.c.MIR_T_I64, name);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testMirExample(comptime example: test_utils.Example) !void {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    var mod = try harness.lowerModule(testing.allocator, example.source());
    // mod must outlive compiled (compiled holds pointers into object_pool).
    defer mod.deinit();

    var mir_backend = try MirBackend.init(testing.allocator);
    defer mir_backend.deinit();

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();

    const compiled = try mir_backend.compileModule(&mod);
    defer compiled.deinit();

    const ectx = try EnsoCtx.init(
        testing.allocator,
        &stdout.writer,
        mod.intern_pool,
        &mod.object_pool,
    );
    defer ectx.deinit();

    _ = compiled.call(ectx);

    testing.expectEqualStrings(example.stdout(), stdout.written()) catch |err| {
        std.debug.print("\n----- failing: {s} ------\n\n", .{example.path()});
        return err;
    };
}

test "MirBackend: example fixtures" {
    inline for (test_utils.examples) |example| {
        if (!example.test_mir) continue;
        try testMirExample(example);
    }
}

// ── MirCompiledModule ────────────────────────────────────────────────────────

const MirCompiledModule = struct {
    fn_ptr: *const fn (ctx: u64) callconv(.c) u64,
    allocator: std.mem.Allocator,

    fn vtableCall(ptr: *anyopaque, ectx: *EnsoCtx) u64 {
        const self: *MirCompiledModule = @ptrCast(@alignCast(ptr));
        return self.fn_ptr(@intFromPtr(ectx));
    }

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *MirCompiledModule = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    const vtable: CompiledModule.VTable = .{
        .call = vtableCall,
        .deinit = vtableDeinit,
    };
};
