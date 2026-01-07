const std = @import("std");
const mir = @import("./mir.zig");

pub fn main() !void {
    var ctx = try mir.Context.init();
    defer ctx.deinit();

    // Use generator (optional here). For JIT interfaces, you should init gen before linking with gen interfaces.
    // ctx.genInit();
    // defer ctx.genFinish();
    // ctx.genSetOptimizeLevel(2);

    var m = mir.Module.init(&ctx, "m");
    // function: i64 loop(i64 arg1)
    const res_types = [_]mir.c.MIR_type_t{mir.c.MIR_T_I64};
    const args = [_]mir.c.MIR_var_t{
        .{ .type = mir.c.MIR_T_I64, .name = "arg1", .size = 0 },
    };

    var fb = m.newFuncArr("loop", &res_types, &args);

    const COUNT = fb.reg(mir.c.MIR_T_I64, "count");
    const ARG1 = fb.arg("arg1");

    const fin = fb.label();
    const cont = fb.label();

    // mov count, 0
    fb.append(mir.insn.fixed(&ctx, mir.c.MIR_MOV, &.{
        mir.op.reg(&ctx, COUNT),
        mir.op.i(&ctx, 0),
    }));

    // bge fin, count, arg1
    fb.append(mir.insn.fixed(&ctx, mir.c.MIR_BGE, &.{
        mir.op.label(&ctx, fin),
        mir.op.reg(&ctx, COUNT),
        mir.op.reg(&ctx, ARG1),
    }));

    // cont:
    fb.append(cont);

    // add count, count, 1
    fb.append(mir.insn.fixed(&ctx, mir.c.MIR_ADD, &.{
        mir.op.reg(&ctx, COUNT),
        mir.op.reg(&ctx, COUNT),
        mir.op.i(&ctx, 1),
    }));

    // blt cont, count, arg1
    fb.append(mir.insn.fixed(&ctx, mir.c.MIR_BLT, &.{
        mir.op.label(&ctx, cont),
        mir.op.reg(&ctx, COUNT),
        mir.op.reg(&ctx, ARG1),
    }));

    // fin:
    fb.append(fin);

    // ret count
    fb.ret(&.{mir.op.reg(&ctx, COUNT)});

    fb.finish();
    m.finish();

    ctx.loadModule(m.m);

    // Choose interface:
    // - interpret:
    // ctx.link(mir.c.MIR_set_interp_interface, null);
    // - generate eagerly:
    ctx.link(mir.c.MIR_set_gen_interface, null);

    // Call via interpreter:
    // var results: [1]mir.c.MIR_val_t = undefined;
    // var argv: [1]mir.c.MIR_val_t = .{ .{ .i = 10 } };
    // ctx.interpArr(fb.func_item, &results, 1, &argv);

    // Or call via function pointer after interface setup:
    const addr = fb.func_item.*.addr;
    const Fn = *const fn (i64) callconv(.C) i64;
    const f: Fn = @ptrCast(addr);
    const r = f(10);
    std.debug.print("loop(10)={}\n", .{r});
}
