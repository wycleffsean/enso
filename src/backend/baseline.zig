/// Baseline Zig-interpreter backend.
///
/// Evaluates SSA procedures by walking values in block order, keeping a
/// TaggedValue register file indexed by ValueId.  No codegen — purely
/// interpreted.  Serves as the evaluation engine for compile-time eval and
/// as a reference implementation against which the MIR backend is verified.
const std = @import("std");
const ir = @import("../ir.zig");
const TaggedValue = @import("../TaggedValue.zig");
const intern = @import("../intern.zig");
const object = @import("../object.zig");
const backend = @import("../backend.zig");
const ctx_mod = @import("../runtime/ctx.zig");
const core = @import("../runtime/core.zig");
const test_utils = @import("../test/utils.zig");

const EnsoCtx = ctx_mod.EnsoCtx;
const Backend = backend.Backend;
const CompiledModule = backend.CompiledModule;

// ── BaselineBackend ──────────────────────────────────────────────────────────

pub const BaselineBackend = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn backend(self: *Self) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

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

    fn compileModule(self: *Self, mod: *const ir.Module) !CompiledModule {
        if (mod.procedures.items.len == 0) return error.EmptyModule;
        const box = try self.allocator.create(BaselineCompiledModule);
        box.* = .{ .mod = mod, .allocator = self.allocator };
        return .{ .ptr = box, .vtable = &BaselineCompiledModule.vtable };
    }
};

// ── BaselineCompiledModule ───────────────────────────────────────────────────

const BaselineCompiledModule = struct {
    mod: *const ir.Module,
    allocator: std.mem.Allocator,

    fn vtableCall(ptr: *anyopaque, ctx: *EnsoCtx) u64 {
        const self: *BaselineCompiledModule = @ptrCast(@alignCast(ptr));
        const proc = &self.mod.procedures.items[0];
        const result = interpret(self.allocator, self.mod, proc, &.{}, ctx) catch TaggedValue.None;
        return result.bits;
    }

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *BaselineCompiledModule = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    const vtable: CompiledModule.VTable = .{
        .call = vtableCall,
        .deinit = vtableDeinit,
    };
};

// ── Interpreter ─────────────────────────────────────────────────────────────

/// Interpret a single procedure.  `args` provides TaggedValues for `arg` nodes.
/// Returns the value produced by `ret`.
pub fn interpret(
    allocator: std.mem.Allocator,
    mod: *const ir.Module,
    proc: *const ir.Procedure,
    args: []const TaggedValue,
    ctx: *EnsoCtx,
) !TaggedValue {
    const regs = try allocator.alloc(TaggedValue, proc.values.len);
    defer allocator.free(regs);
    @memset(regs, TaggedValue.None);

    var arg_idx: u32 = 0;
    var block_idx: u32 = 0;

    outer: while (block_idx < proc.blocks.items.len) {
        const block = &proc.blocks.items[block_idx];
        for (block.values.items) |vid| {
            const i = vid.idx();
            const v = proc.values.get(i);
            switch (v.op) {
                .nop, .identity, .phi, .upsilon => {},

                .arg => {
                    regs[i] = if (arg_idx < args.len) args[arg_idx] else TaggedValue.None;
                    arg_idx += 1;
                },

                .const_obj => {
                    regs[i] = switch (v.repr) {
                        .tagged => TaggedValue.assemble(v.lhs, v.rhs),
                        .object => blk: {
                            const pool_idx: intern.ObjectPool.ObjectIndex = @enumFromInt(v.lhs);
                            const obj_ptr = &mod.object_pool.pool.entries.items(.key)[@intFromEnum(pool_idx)];
                            break :blk TaggedValue.fromPointer(obj_ptr);
                        },
                        else => TaggedValue.None,
                    };
                },

                .py_load_name => {
                    const pool_idx: intern.ObjectPool.ObjectIndex = @enumFromInt(v.lhs);
                    const obj = mod.object_pool.getConst(pool_idx);
                    const name = ctx.intern_pool.get(obj.symbol);
                    regs[i] = if (core.builtinByName(name)) |bid|
                        core.builtinValue(bid)
                    else blk: {
                        std.debug.print("baseline: py_load_name: unknown '{s}'\n", .{name});
                        break :blk TaggedValue.None;
                    };
                },

                .py_store_name => {
                    // Write to global dict — not yet implemented; ignore for now.
                },

                .py_call => {
                    const total: u32 = v.lhs;
                    const nargs: u32 = total - 2;
                    const off: u32 = v.rhs;
                    const receiver = regs[proc.extra.items[off + 0]];
                    const callable = regs[proc.extra.items[off + 1]];
                    var arg_buf: [64]TaggedValue = undefined;
                    for (0..nargs) |a| arg_buf[a] = regs[proc.extra.items[off + 2 + a]];
                    regs[i] = ctx.vtable.py_call(ctx, receiver, callable, &arg_buf, nargs);
                },

                .ret => return regs[v.lhs],

                .jump => {
                    block_idx = v.lhs;
                    continue :outer;
                },

                .branch => {
                    const predicate = regs[v.lhs];
                    const extra = proc.extraData(ir.BranchExtra, v.rhs);
                    const target = if (isTruthy(predicate)) extra.then else extra.@"else";
                    block_idx = target.idx();
                    continue :outer;
                },

                else => {
                    std.debug.print("baseline: unimplemented op {s}\n", .{@tagName(v.op)});
                },
            }
        }
        block_idx += 1;
    }

    return TaggedValue.None;
}

fn isTruthy(val: TaggedValue) bool {
    if (val.bits == TaggedValue.None.bits) return false;
    if (val.isInteger()) return val.asIntegerUnchecked() != 0;
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testBaselineExample(comptime example: test_utils.Example) !void {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();
    var mod = try harness.lowerModule(testing.allocator, example.source());
    defer mod.deinit();

    var base = try BaselineBackend.init(testing.allocator);
    defer base.deinit();

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();

    const compiled = try base.compileModule(&mod);
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
        std.debug.print("\n----- failing: {s} -----\n\n", .{example.path()});
        return err;
    };
}

test "BaselineBackend: example fixtures" {
    inline for (test_utils.examples) |example| {
        if (!example.test_baseline) continue;
        try testBaselineExample(example);
    }
}
