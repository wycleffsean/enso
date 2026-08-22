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

const Backend = backend.Backend;
const CompiledModule = backend.CompiledModule;

// ── MirBackend ──────────────────────────────────────────────────────────────

pub const MirBackend = struct {
    allocator: std.mem.Allocator,
    ctx: mir.Context,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .ctx = try mir.Context.init(),
        };
        self.ctx.genInit();
        self.ctx.genSetOptimizeLevel(0); // regalloc+codegen only for now
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.ctx.genFinish();
        self.ctx.deinit();
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
        var mir_mod = mir.Module.init(&self.ctx, "<enso>");
        errdefer mir_mod.finish();

        // Compile the first procedure (the module's top-level body).
        // The function signature is: i64 <name>()
        if (mod.procedures.items.len == 0) return error.EmptyModule;
        const proc = &mod.procedures.items[0];

        const func_item = try compileProcedure(self, &mir_mod, proc);

        mir_mod.finish();
        self.ctx.loadModule(mir_mod.m);
        self.ctx.link(mir.c.MIR_set_gen_interface, null);

        // The function pointer after JIT codegen lives at func_item.*.addr.
        const raw_addr = func_item.*.addr;
        const ModFn = *const fn () callconv(.c) u64;
        const fn_ptr: ModFn = @ptrCast(@alignCast(raw_addr));

        // Box the fn_ptr in a heap allocation so CompiledModule can hold it.
        const box = try self.allocator.create(MirCompiledModule);
        box.* = .{ .fn_ptr = fn_ptr, .allocator = self.allocator };
        return .{
            .ptr = box,
            .vtable = &MirCompiledModule.vtable,
        };
    }

    fn compileProcedure(self: *Self, mir_mod: *mir.Module, proc: *const ir.Procedure) !mir.c.MIR_item_t {
        const res_types = [_]mir.c.MIR_type_t{mir.c.MIR_T_I64};
        const no_args: []const mir.c.MIR_var_t = &.{};

        // Build a null-terminated name.  proc.name is already a slice.
        var name_buf: [256]u8 = undefined;
        const name_z = try std.fmt.bufPrintZ(&name_buf, "{s}", .{proc.name});

        var fb = mir_mod.newFuncArr(name_z, &res_types, no_args);

        // Allocate one I64 MIR reg per SSA value so we can reference any vid.
        var reg_buf: [256]u8 = undefined;
        const nvals = proc.values.len;
        const regs = try self.allocator.alloc(mir.c.MIR_reg_t, nvals);
        defer self.allocator.free(regs);
        for (0..nvals) |i| {
            const reg_name = try std.fmt.bufPrintZ(&reg_buf, "v{d}", .{i});
            regs[i] = fb.reg(mir.c.MIR_T_I64, reg_name);
        }

        // Walk every block in order, then every value in the block.
        for (proc.blocks.items) |*block| {
            for (block.values.items) |vid| {
                try emitValue(self, &fb, proc, regs, vid);
            }
        }

        fb.finish();
        return fb.func_item;
    }

    fn emitValue(
        self: *Self,
        fb: *mir.FuncBuilder,
        proc: *const ir.Procedure,
        regs: []const mir.c.MIR_reg_t,
        vid: ir.ValueId,
    ) !void {
        const ctx = &self.ctx;
        const idx = vid.idx();
        const v = proc.values.get(idx);
        const dest = regs[idx];

        switch (v.op) {
            .nop, .identity => {}, // nothing to emit

            .const_obj => {
                // Encode the constant as a 64-bit integer (TaggedValue bits).
                const bits: u64 = switch (v.repr) {
                    .tagged => TaggedValue.assemble(v.lhs, v.rhs).bits,
                    else => TaggedValue.None.bits, // fallback
                };
                fb.append(mir.insn.fixed(ctx, mir.c.MIR_MOV, &.{
                    mir.op.reg(ctx, dest),
                    mir.op.u(ctx, bits),
                }));
            },

            .ret => {
                const val_reg = regs[v.lhs];
                fb.ret(&.{mir.op.reg(ctx, val_reg)});
            },

            .jump => {
                // Fallthrough within a linear procedure — no MIR insn needed
                // when blocks are emitted in order.  Label-based jumps are
                // required once we handle branching; leave that for later.
            },

            else => {
                // Unimplemented op: emit a MOV of None so the reg is defined
                // (keeps MIR happy) and leave a debug marker.
                std.debug.print("MIR backend: unimplemented op {s} at %v{d}\n", .{ @tagName(v.op), idx });
                fb.append(mir.insn.fixed(ctx, mir.c.MIR_MOV, &.{
                    mir.op.reg(ctx, dest),
                    mir.op.u(ctx, TaggedValue.None.bits),
                }));
            },
        }
    }
};

// ── MirCompiledModule ────────────────────────────────────────────────────────

const MirCompiledModule = struct {
    fn_ptr: *const fn () callconv(.c) u64,
    allocator: std.mem.Allocator,

    fn vtableCall(ptr: *anyopaque) u64 {
        const self: *MirCompiledModule = @ptrCast(@alignCast(ptr));
        return self.fn_ptr();
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
