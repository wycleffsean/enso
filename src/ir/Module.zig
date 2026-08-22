const std = @import("std");
const ir = @import("../ir.zig");
const bytecode = @import("../bytecode.zig");
const intern = @import("../intern.zig");
const object = @import("../object.zig");
const cfg = @import("../bytecode/cfg.zig");
const TaggedValue = @import("../TaggedValue.zig");
const terminatesBlock = cfg.terminatesBlock;
const Builder = @import("lower/Builder.zig");

const testing = std.testing;
const test_utils = @import("../test/utils.zig");

const Module = @This();

allocator: std.mem.Allocator,
procedures: std.ArrayList(ir.Procedure) = .empty,
object_pool: intern.ObjectPool,
intern_pool: *const intern.StringInternPool,

const BlockId = ir.BlockId;

fn init(allocator: std.mem.Allocator, intern_pool: *const intern.StringInternPool) Module {
    return .{
        .allocator = allocator,
        .object_pool = .init(allocator),
        .intern_pool = intern_pool,
    };
}

pub fn build(allocator: std.mem.Allocator, bmod: *const bytecode.Module) !Module {
    const proccount = bmod.codeobject_store.len;
    var mod: Module = .init(allocator, bmod.intern_pool);
    try mod.procedures.ensureTotalCapacity(mod.allocator, proccount);
    for (0..proccount) |pid| {
        const co = bmod.codeobject_store.get(pid);
        const proc = try lowerCodeObject(&mod, co);
        mod.procedures.appendAssumeCapacity(proc);
    }
    return mod;
}

pub fn deinit(m: *Module) void {
    m.object_pool.deinit();
    for (m.procedures.items) |*proc| proc.deinit();
    m.procedures.deinit(m.allocator);

    m.* = undefined;
}

/// Intern a compile-time constant into the module, returning an ir.Value.
/// Inlines None and small integers as TaggedValues; everything else goes into the object pool.
pub fn internConst(m: *Module, obj: object.Object) !ir.Value {
    switch (obj) {
        .none => return .fromTagged(.None),
        .int => |i| {
            const casted = std.math.cast(i60, i) orelse {
                const idx = try m.object_pool.put(obj);
                return .fromObject(idx);
            };
            return .fromTagged(TaggedValue.integer(casted));
        },
        else => {
            const idx = try m.object_pool.put(obj);
            return .fromObject(idx);
        },
    }
}

pub fn lowerCodeObject(mod: *Module, co: bytecode.CodeObject) !ir.Procedure {
    var proc: ir.Procedure = try .new(mod.allocator, co.co_name);
    var b: Builder = .init(&proc, co);
    defer b.deinit();

    var graph = try cfg.buildFromCodeObject(mod.allocator, co);
    defer graph.deinit();

    // Pass 1: allocate all BlockIds so terminators can reference successor blocks
    // by stable ID before those blocks' instructions are lowered
    for (0..graph.blocks.len) |_| _ = try b.newBlock();

    // Emit arg() nodes for each positional parameter into block 0.
    // Parameters occupy fast local slots 0..co_argcount-1 in the order they were declared.
    if (co.co_argcount > 0) {
        b.switchTo(.from(0));
        for (0..co.co_argcount) |i| {
            const vid = try b.emit(.{ .op = .arg, .repr = .object, .lhs = @intCast(i), .rhs = 0 });
            try b.writeLocal(@intCast(i), vid);
        }
    }

    // Pass 2: lower each block's instructions, including its terminator
    for (0..graph.blocks.len) |bid| {
        const block_id: ir.BlockId = .from(@intCast(bid));
        const insns = graph.blockInsns(@intCast(bid));
        const preds = graph.blockPredecessors(@intCast(bid));
        const succs = graph.blockSuccessors(@intCast(bid));
        try lowerBlock(mod, &b, block_id, insns, preds, succs);
    }

    return proc;
}

fn lowerBlock(
    mod: *Module,
    b: *Builder,
    bid: ir.BlockId,
    insns: []const bytecode.Insn,
    predecessors: []const cfg.Edge,
    successors: []const cfg.Edge,
) !void {
    var block = &b.proc.blocks.items[bid.idx()];
    try block.addPredecessors(b.proc, predecessors);
    b.switchTo(bid);
    var has_terminator = false;
    for (insns) |insn| {
        if (terminatesBlock(insn)) {
            try lowerTerminator(mod, b, insn, successors);
            has_terminator = true;
        } else {
            try lowerInsn(mod, b, insn);
        }
    }
    // A block without an explicit terminator falls through to its single successor.
    // Emit an explicit jump so the IR graph is always complete.
    if (!has_terminator and successors.len > 0) {
        const target: ir.BlockId = .from(successors[0].to);
        _ = try b.emit(.{ .op = .jump, .repr = .none, .lhs = @intFromEnum(target), .rhs = 0 });
    }
    try b.sealBlock(bid);
}

/// Emit the terminating instruction for a block.
/// `successors` are the CFG edges out of this block, in the order the CFG built them
/// (fallthrough first, then jump — matching pop_jump_if_false semantics).
fn lowerTerminator(_: *Module, b: *Builder, insn: bytecode.Insn, successors: []const cfg.Edge) !void {
    switch (insn) {
        .pop_jump_if_false, .pop_jump_if_true => {
            // successors[0] = fallthrough (then), successors[1] = jump (else)
            const cond_val = b.pop();
            // If the condition is already a boolean (e.g. from compare_op), use it directly.
            // Otherwise wrap in py_truthy to coerce an arbitrary Python object to i1.
            const repr = b.proc.values.items(.repr)[cond_val.idx()];
            const predicate = if (repr == .i1) cond_val else
                try b.emit(.{ .op = .py_truthy, .repr = .i1, .lhs = cond_val.idx(), .rhs = 0 });
            const then_bid: ir.BlockId = if (successors.len > 0) .from(successors[0].to) else .none;
            const else_bid: ir.BlockId = if (successors.len > 1) .from(successors[1].to) else .none;
            _ = try b.proc.addBranch(b.current, .{
                .predicate = predicate.idx(),
                .extra = .{ .then = then_bid, .@"else" = else_bid },
            });
        },
        .for_iter => {
            // Iterator is TOS. FOR_ITER: on success (fallthrough) push next item and continue;
            // on exhaustion (jump) pop iterator and go to exit.
            // successors[0] = body (fallthrough), successors[1] = exit (jump).
            const iter_vid = b.peek(0); // iterator stays on stack, don't pop
            const body_bid: ir.BlockId = if (successors.len > 0) .from(successors[0].to) else .none;
            const exit_bid: ir.BlockId = if (successors.len > 1) .from(successors[1].to) else .none;
            const extra_off = try b.proc.addExtra(ir.ForIterExtra, .{ .body = body_bid, .exit = exit_bid });
            const item_vid = try b.proc.addValue(b.current, .{
                .op = .py_for_iter,
                .repr = .object,
                .lhs = iter_vid.idx(),
                .rhs = extra_off,
            });
            // Push the item onto the abstract stack so the loop body block starts with it at TOS.
            // (The iterator remains beneath it; end_for in the exit block pops it.)
            try b.push(item_vid);
        },
        .jump_forward, .jump_backward, .jump_backward_no_interrupt => {
            const target: ir.BlockId = if (successors.len > 0) .from(successors[0].to) else .none;
            _ = try b.emit(.{ .op = .jump, .repr = .none, .lhs = @intFromEnum(target), .rhs = 0 });
        },
        .return_value => {
            const val = b.pop();
            _ = try b.emit(.{ .op = .ret, .repr = .none, .lhs = val.idx(), .rhs = 0 });
        },
        .return_const => {
            // Our bytecode representation discards the const arg; in practice this is always
            // the implicit `return None` at the end of a function body.
            const vid = try b.emit(.None);
            _ = try b.emit(.{ .op = .ret, .repr = .none, .lhs = vid.idx(), .rhs = 0 });
        },
        else => {
            // Non-branching terminals (return_generator, for_iter, send) — stub
            _ = try b.emit(.{ .op = .ret, .repr = .none, .lhs = 0, .rhs = 0 });
        },
    }
}

fn lowerInsn(mod: *Module, b: *Builder, insn: bytecode.Insn) !void {
    switch (insn) {
        .@"resume", .nop => {
            _ = try b.emit(.{ .op = .nop, .repr = .none, .lhs = 0, .rhs = 0 });
        },
        .push_null => {
            // Receiver slot: None means no bound receiver (module-level / builtin function).
            const v = try b.emit(.None);
            try b.push(v);
        },
        .load_const => |ci| {
            const obj = b.co.consts()[ci.index];
            const val = try mod.internConst(obj);
            const v = try b.emit(val);
            try b.push(v);
        },
        .load_name => |sym| {
            // Global/builtin lookup — not tracked by Braun SSA.
            // The symbol index in ObjectPool identifies which name to look up at runtime.
            const idx = try mod.object_pool.put(.{ .symbol = sym });
            const v = try b.emit(.{
                .op = .py_load_name,
                .repr = .object,
                .lhs = @intFromEnum(idx),
                .rhs = 0,
            });
            try b.push(v);
        },
        .load_fast => |obj| {
            const local_idx: ir.LocalIdx = @intCast(obj.int);
            const v = try b.readLocal(local_idx);
            try b.push(v);
        },
        .store_name => |sym| {
            const val = b.pop();
            const idx = try mod.object_pool.put(.{ .symbol = sym });
            _ = try b.emit(.{
                .op = .py_store_name,
                .repr = .none,
                .lhs = @intFromEnum(idx),
                .rhs = val.idx(),
            });
        },
        .store_fast => |obj| {
            const local_idx: ir.LocalIdx = @intCast(obj.int);
            const v = b.pop();
            try b.writeLocal(local_idx, v);
        },
        .binary_op => |kind| {
            const rhs = b.pop();
            const lhs = b.pop();
            const v = try b.emit(.binaryOp(kind, lhs.idx(), rhs.idx()));
            try b.push(v);
        },
        .call => |argc| {
            // Stack before CALL: [..., receiver, callable, arg0, ..., arg_{argc-1}]
            // operands: [receiver, callable, arg0, ..., arg_{argc-1}]
            var buf: [64]u32 = undefined;
            const total = 2 + argc; // receiver + callable + argc args
            const operands: []u32 = if (total <= buf.len)
                buf[0..total]
            else
                try b.allocator.alloc(u32, total);
            defer if (total > buf.len) b.allocator.free(operands);

            // Pop args in LIFO order into tail of operands.
            var i: usize = total - 1;
            while (i >= 2) : (i -= 1) operands[i] = b.pop().idx();
            operands[1] = b.pop().idx(); // callable
            operands[0] = b.pop().idx(); // receiver (from push_null or load_attr)

            const v = try b.proc.addCall(b.current, operands);
            try b.push(v);
        },
        .load_attr => |sym| {
            const obj = b.pop();
            const idx = try mod.object_pool.put(.{ .symbol = sym });
            const v = try b.emit(.{ .op = .py_load_attr, .repr = .object, .lhs = obj.idx(), .rhs = @intFromEnum(idx) });
            try b.push(v);
        },
        .compare_op => |kind| {
            const rhs = b.pop();
            const lhs = b.pop();
            const v = try b.emit(.compareOp(kind, lhs.idx(), rhs.idx()));
            try b.push(v);
        },
        .unary_negative => {
            const operand = b.pop();
            const v = try b.emit(.{ .op = .py_unary_op, .repr = .object, .lhs = operand.idx(), .rhs = @intFromEnum(ir.UnaryOp.negative) });
            try b.push(v);
        },
        .unary_invert => {
            const operand = b.pop();
            const v = try b.emit(.{ .op = .py_unary_op, .repr = .object, .lhs = operand.idx(), .rhs = @intFromEnum(ir.UnaryOp.invert) });
            try b.push(v);
        },
        .unary_not => {
            const operand = b.pop();
            const v = try b.emit(.{ .op = .py_unary_op, .repr = .object, .lhs = operand.idx(), .rhs = @intFromEnum(ir.UnaryOp.not) });
            try b.push(v);
        },
        .make_function => {
            // The code object index was pushed by LOAD_CONST as a codeobject value.
            // We need to look it up in the object pool to recover the index.
            const co_vid = b.pop();
            const co_val = b.proc.values.get(co_vid.idx());
            // The const_obj for a codeobject stores the index in lhs (via fromObject).
            // But codeobject is stored as a tagged int — recover from the pool.
            const co_idx: u32 = switch (co_val.repr) {
                .object => blk: {
                    const pool_idx: intern.ObjectPool.ObjectIndex = @enumFromInt(co_val.lhs);
                    const obj = mod.object_pool.getConst(pool_idx);
                    break :blk obj.codeobject;
                },
                else => 0,
            };
            const v = try b.emit(.{ .op = .py_make_function, .repr = .object, .lhs = co_idx, .rhs = 0 });
            try b.push(v);
        },
        .build_list, .build_tuple, .build_set => |count| {
            const ir_op: ir.OpCode = switch (insn) {
                .build_list => .py_build_list,
                .build_tuple => .py_build_tuple,
                .build_set => .py_build_set,
                else => unreachable,
            };
            var buf: [64]u32 = undefined;
            const elems: []u32 = if (count <= buf.len)
                buf[0..count]
            else
                try b.allocator.alloc(u32, count);
            defer if (count > buf.len) b.allocator.free(elems);
            // Pop in reverse; store left-to-right in extra.
            var i: usize = count;
            while (i > 0) { i -= 1; elems[i] = b.pop().idx(); }
            const v = try b.proc.addCollection(b.current, ir_op, elems);
            try b.push(v);
        },
        .build_const_key_map => |count| {
            // Stack: [v0, v1, ..., v_{n-1}, keys_tuple_const]
            // Extra layout: [k0, v0, k1, v1, ...]
            const keys_vid = b.pop(); // pop the const tuple of keys
            const keys_val = b.proc.values.get(keys_vid.idx());

            // Recover the tuple from the object pool.
            const keys_obj: object.Object = switch (keys_val.repr) {
                .object => blk: {
                    const pool_idx: intern.ObjectPool.ObjectIndex = @enumFromInt(keys_val.lhs);
                    break :blk mod.object_pool.getConst(pool_idx);
                },
                .tagged => .{ .tuple = &.{} }, // shouldn't happen but be safe
                else => .{ .tuple = &.{} },
            };
            const key_objects: []const object.Object = switch (keys_obj) {
                .tuple => |t| t,
                else => &.{},
            };

            var buf: [128]u32 = undefined;
            const pair_count = count * 2;
            const elems: []u32 = if (pair_count <= buf.len)
                buf[0..pair_count]
            else
                try b.allocator.alloc(u32, pair_count);
            defer if (pair_count > buf.len) b.allocator.free(elems);

            // Pop values in reverse, pair with keys.
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                const val = b.pop();
                const key_val = if (i < key_objects.len)
                    try mod.internConst(key_objects[i])
                else
                    ir.Value.None;
                const key_vid = try b.emit(key_val);
                elems[i * 2 + 0] = key_vid.idx();
                elems[i * 2 + 1] = val.idx();
            }
            const v = try b.proc.addCollection(b.current, .py_build_map, elems);
            try b.push(v);
        },
        .build_map => |count| {
            // Stack (top-down): v_{n-1}, k_{n-1}, ..., v_0, k_0
            // extra layout: [k0, v0, k1, v1, ...]
            const pair_count = count * 2;
            var buf: [128]u32 = undefined;
            const elems: []u32 = if (pair_count <= buf.len)
                buf[0..pair_count]
            else
                try b.allocator.alloc(u32, pair_count);
            defer if (pair_count > buf.len) b.allocator.free(elems);
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                const val = b.pop();
                const key = b.pop();
                elems[i * 2 + 0] = key.idx();
                elems[i * 2 + 1] = val.idx();
            }
            const v = try b.proc.addCollection(b.current, .py_build_map, elems);
            try b.push(v);
        },
        .list_extend => |i| {
            // STACK[-i] is the list (before pop); TOS is the iterable.
            // Peek the list at depth i (0-indexed from top, so depth i since iterable is at 0).
            const list_vid = b.peek(i); // list is i items below TOS (TOS = iterable at depth 0)
            const iterable = b.pop();
            const v = try b.emit(.{ .op = .py_list_extend, .repr = .object, .lhs = list_vid.idx(), .rhs = iterable.idx() });
            // Replace the list slot with the new value representing the extended list.
            b.stack.items[b.stack.items.len - i] = v;
        },
        .get_iter => {
            const obj = b.pop();
            const v = try b.emit(.{ .op = .py_get_iter, .repr = .object, .lhs = obj.idx(), .rhs = 0 });
            try b.push(v);
        },
        .end_for => {
            // The iterator is at TOS in the exit block; consuming it here means the loop is done.
            _ = b.pop();
        },
        .pop_top => {
            _ = b.pop();
        },
        else => {
            // TODO: delete me, this switch should be exhaustive
            std.debug.print("lowerInsn: unhandled '{s}'\n", .{@tagName(insn)});
            return error.UnhandledInstruction;
        },
    }
}

test "ir/lower: none" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("");
    defer proc.deinit();
    try testing.expectEqualSlices(ir.OpCode, ([_]ir.OpCode{ .nop, .const_obj, .ret })[0..], proc.values.items(.op));
}

test "ir/lower: hello_world" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("print('hello world')");
    defer proc.deinit();
    // Value allocation order:
    //   %v0 = nop()                       (RESUME)
    //   %v1 = const(None)                 (PUSH_NULL → receiver)
    //   %v2 = py_load_name("print")       (LOAD_NAME → global lookup)
    //   %v3 = const_obj("hello world")    (LOAD_CONST)
    //   %v4 = py_call(v1, v2, v3)         (CALL 1)
    //   %v5 = const(None)                 (return_const)
    //   %v6 = ret(v5)
    try testing.expectEqualSlices(
        ir.OpCode,
        ([_]ir.OpCode{ .nop, .const_obj, .py_load_name, .const_obj, .py_call, .const_obj, .ret })[0..],
        proc.values.items(.op),
    );
    // py_call operand count = 3: receiver + callable + 1 arg
    const call_vid = ir.ValueId.from(4);
    try testing.expectEqual(@as(u32, 3), proc.values.items(.lhs)[call_vid.idx()]);
    // Verify operand order: [receiver(%v1), callable(%v2), arg(%v3)]
    const rhs = proc.values.items(.rhs)[call_vid.idx()];
    try testing.expectEqual(@as(u32, 1), proc.extra.items[rhs + 0]); // receiver = %v1
    try testing.expectEqual(@as(u32, 2), proc.extra.items[rhs + 1]); // callable = %v2
    try testing.expectEqual(@as(u32, 3), proc.extra.items[rhs + 2]); // arg = %v3
}

test "ir/lower: store and load name" {
    // x = 1; x + 1
    // STORE_NAME discards (global write, not modeled).
    // LOAD_NAME emits a fresh const_obj symbol stub — it's a global lookup, not a local.
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("x = 1\nx + 1");
    defer proc.deinit();

    // Expected flat value sequence:
    //   %v0 = nop()                     (RESUME)
    //   %v1 = const(1)                  (LOAD_CONST 1)
    //   %v2 = py_store_name("x", %v1)   (STORE_NAME x)
    //   %v3 = py_load_name("x")         (LOAD_NAME x)
    //   %v4 = const(1)                  (LOAD_CONST 1)
    //   %v5 = py_binary_op(%v3, %v4)    (BINARY_OP +)
    //   %v6 = const(None)               (return_const)
    //   %v7 = ret
    const ops = proc.values.items(.op);
    try testing.expectEqual(ir.OpCode.nop, ops[0]);
    try testing.expectEqual(ir.OpCode.const_obj, ops[1]);          // const(1) for x=1
    try testing.expectEqual(ir.OpCode.py_store_name, ops[2]);      // store_name(x, %v1)
    try testing.expectEqual(ir.OpCode.py_load_name, ops[3]);       // load_name(x)
    try testing.expectEqual(ir.OpCode.const_obj, ops[4]);          // const(1) for literal
    try testing.expectEqual(ir.OpCode.py_binary_op, ops[5]);
    try testing.expectEqual(ir.OpCode.const_obj, ops[6]);          // return_const None
    try testing.expectEqual(ir.OpCode.ret, ops[7]);
    try testing.expectEqual(@as(usize, 8), ops.len);

    // binary_op: lhs = LOAD_NAME(x) = %v3, rhs = literal 1 = %v4
    const binop_lhs = proc.values.items(.lhs)[5];
    const binop_rhs = proc.values.items(.rhs)[5];
    try testing.expectEqual(@as(u32, 3), binop_lhs);
    try testing.expectEqual(@as(u32, 4), binop_rhs);
}

test "ir/lower: call operands are complete and ordered" {
    // print('a', 'b') — 2 args; operands must be [receiver, print, 'a', 'b'] in that order.
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("print('a', 'b')");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    // Find the py_call
    var call_vid_idx: usize = 0;
    for (ops, 0..) |op, i| {
        if (op == .py_call) { call_vid_idx = i; break; }
    }
    try testing.expect(call_vid_idx > 0); // found it

    const lhs = proc.values.items(.lhs)[call_vid_idx]; // operand count
    const rhs = proc.values.items(.rhs)[call_vid_idx]; // extra offset
    try testing.expectEqual(@as(u32, 4), lhs); // receiver + callable + 2 args

    // operands[0] = receiver (const None), operands[1] = callable (py_load_name),
    // operands[2] = 'a', operands[3] = 'b'
    const recv_vid = proc.extra.items[rhs];
    const callable_vid = proc.extra.items[rhs + 1];
    const arg0_vid = proc.extra.items[rhs + 2];
    const arg1_vid = proc.extra.items[rhs + 3];

    try testing.expectEqual(ir.OpCode.const_obj, proc.values.items(.op)[recv_vid]);        // receiver = None
    try testing.expectEqual(ir.OpCode.py_load_name, proc.values.items(.op)[callable_vid]); // print lookup
    try testing.expectEqual(ir.OpCode.const_obj, proc.values.items(.op)[arg0_vid]);     // 'a'
    try testing.expectEqual(ir.OpCode.const_obj, proc.values.items(.op)[arg1_vid]);     // 'b'

    // arg0 must come before arg1 in allocation order (left-to-right)
    try testing.expect(arg0_vid < arg1_vid);
}

test "ir/lower: binary_op lhs and rhs are correct" {
    // x = 1; y = 2; z = x + y
    // binary_op lhs should be x (const 1), rhs should be y (const 2)
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("x = 1\ny = 2\nz = x + y");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    var binop_idx: usize = 0;
    for (ops, 0..) |op, i| {
        if (op == .py_binary_op) { binop_idx = i; break; }
    }
    try testing.expect(binop_idx > 0);

    const lhs = proc.values.items(.lhs)[binop_idx];
    const rhs = proc.values.items(.rhs)[binop_idx];

    // lhs = LOAD_NAME(x) = py_load_name, rhs = LOAD_NAME(y) = py_load_name
    try testing.expectEqual(ir.OpCode.py_load_name, ops[lhs]);
    try testing.expectEqual(ir.OpCode.py_load_name, ops[rhs]);

    // lhs (x) was loaded before rhs (y)
    try testing.expect(lhs < rhs);
}

fn assertSuccession(p: *const ir.Procedure, pred: BlockId, succ: BlockId) !void {
    var buf: [8]ir.BlockId = undefined;
    const successors = p.successors(pred, &buf);
    try testing.expect(successors.len > 0);
    for (successors) |successor| if (successor == succ) return;
    return error.TestExpectedSuccessor;
}

fn assertContainsPhi(p: *const ir.Procedure, bid: BlockId) !void {
    var has_phi = false;
    for (p.blocks.items[bid.idx()].values.items) |vid| {
        has_phi = has_phi or p.values.items(.op)[vid.idx()] == .phi;
    }
    try testing.expect(has_phi);
}

test "ir/lower: branching" {
    // def ex(cond):
    //     if cond:   ← entry block: load cond, py_truthy, branch → then(1) / else(2)
    //         x = 10 ← then block: store_fast, jump → exit(3)
    //     else:
    //         x = 20 ← else block: store_fast, jump → exit(3)
    //     return x+1 ← exit block: load x (phi), binary_op, ret
    const code =
        \\ def ex(cond):
        \\     if cond:
        \\         x = 10
        \\     else:
        \\         x = 20
        \\     return x + 1
    ;

    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const root_co = try harness.buildCodeObjects(code);
    const co = root_co.module.codeobject_store.get(1);
    var mod: Module = .init(arena.allocator(), &harness.intern_pool);
    defer mod.object_pool.deinit();
    var proc = try lowerCodeObject(&mod, co);
    defer proc.deinit();

    const entryb: BlockId = .from(0);
    const thenb: BlockId = .from(1);
    const elseb: BlockId = .from(2);
    const exitb: BlockId = .from(3);

    try testing.expectEqual(4, proc.blocks.items.len);

    try assertSuccession(&proc, entryb, thenb);
    try assertSuccession(&proc, entryb, elseb);
    try assertSuccession(&proc, thenb, exitb);
    try assertSuccession(&proc, elseb, exitb);

    try assertContainsPhi(&proc, exitb);
}

test "ir/lower: function args map to arg() nodes via Braun" {
    // def f(x, y): return x + y
    // The function body (co index 1) should have arg(0), arg(1) at the top,
    // and LOAD_FAST 0/1 should resolve directly to those nodes without phi.
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lowerAt("def f(x, y): return x + y", 1);
    defer proc.deinit();

    const ops = proc.values.items(.op);
    // Expected: arg(0), arg(1), nop(resume), py_binary_op(.add, %v0, %v1), ret(%v3)
    try testing.expectEqual(ir.OpCode.arg, ops[0]);
    try testing.expectEqual(ir.OpCode.arg, ops[1]);
    try testing.expectEqual(ir.OpCode.nop, ops[2]);
    try testing.expectEqual(ir.OpCode.py_binary_op, ops[3]);
    try testing.expectEqual(ir.OpCode.ret, ops[4]);
    try testing.expectEqual(@as(usize, 5), ops.len);

    // arg indices
    try testing.expectEqual(@as(u32, 0), proc.values.items(.lhs)[0]); // arg(0) = x
    try testing.expectEqual(@as(u32, 1), proc.values.items(.lhs)[1]); // arg(1) = y

    // binary_op operands resolve directly to arg nodes (Braun forwarded them)
    try testing.expectEqual(@as(u32, 0), proc.values.items(.lhs)[3]); // lhs = %v0 = x
    try testing.expectEqual(@as(u32, 1), proc.values.items(.rhs)[3]); // rhs = %v1 = y
    try testing.expectEqual(ir.BinaryOp.add, proc.values.get(3).binaryOpKind());
}

test "ir/lower: build_list with variable elements" {
    // [a, b, c] — three LOAD_NAME + BUILD_LIST 3
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("[a, b, c]");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    var build_idx: usize = 0;
    for (ops, 0..) |op, i| {
        if (op == .py_build_list) { build_idx = i; break; }
    }
    try testing.expect(build_idx > 0);

    const count = proc.values.items(.lhs)[build_idx];
    const off = proc.values.items(.rhs)[build_idx];
    try testing.expectEqual(@as(u32, 3), count);
    // elements left-to-right: a=%v1, b=%v2, c=%v3
    try testing.expectEqual(ir.OpCode.py_load_name, ops[proc.extra.items[off + 0]]); // a
    try testing.expectEqual(ir.OpCode.py_load_name, ops[proc.extra.items[off + 1]]); // b
    try testing.expectEqual(ir.OpCode.py_load_name, ops[proc.extra.items[off + 2]]); // c
    // left-to-right allocation order
    try testing.expect(proc.extra.items[off + 0] < proc.extra.items[off + 1]);
    try testing.expect(proc.extra.items[off + 1] < proc.extra.items[off + 2]);
}

test "ir/lower: build_tuple with variable elements" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("(a, b)");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    var build_idx: usize = 0;
    for (ops, 0..) |op, i| {
        if (op == .py_build_tuple) { build_idx = i; break; }
    }
    try testing.expect(build_idx > 0);
    try testing.expectEqual(@as(u32, 2), proc.values.items(.lhs)[build_idx]);
}

test "ir/lower: build_set with variable elements" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("{a, b}");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    var found = false;
    for (ops) |op| if (op == .py_build_set) { found = true; break; };
    try testing.expect(found);
}

test "ir/lower: build_map with variable keys and values" {
    // {a: b, c: d} — interleaved [k0,v0,k1,v1] in extra
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("{a: b, c: d}");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    var build_idx: usize = 0;
    for (ops, 0..) |op, i| {
        if (op == .py_build_map) { build_idx = i; break; }
    }
    try testing.expect(build_idx > 0);

    const count = proc.values.items(.lhs)[build_idx]; // pair count
    const off = proc.values.items(.rhs)[build_idx];
    try testing.expectEqual(@as(u32, 4), count); // 2 pairs = 4 vids in extra
    // extra layout: [k0, v0, k1, v1]
    try testing.expectEqual(ir.OpCode.py_load_name, ops[proc.extra.items[off + 0]]); // k0=a
    try testing.expectEqual(ir.OpCode.py_load_name, ops[proc.extra.items[off + 1]]); // v0=b
    try testing.expectEqual(ir.OpCode.py_load_name, ops[proc.extra.items[off + 2]]); // k1=c
    try testing.expectEqual(ir.OpCode.py_load_name, ops[proc.extra.items[off + 3]]); // v1=d
}

test "ir/lower: build_list literal uses list_extend" {
    // [1, 2, 3] — CPython emits BUILD_LIST 0 + LIST_EXTEND, lowered to py_build_list + py_list_extend
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("[1, 2, 3]");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    var extend_idx: usize = 0;
    for (ops, 0..) |op, i| {
        if (op == .py_list_extend) { extend_idx = i; break; }
    }
    try testing.expect(extend_idx > 0);
    // extend's lhs must be the empty list
    const extend_lhs = proc.values.items(.lhs)[extend_idx];
    try testing.expectEqual(ir.OpCode.py_build_list, ops[extend_lhs]);
}

test "ir/lower: for loop structure" {
    // for x in items: print(x)
    // Expected blocks:
    //   bb0: nop, py_get_iter, jump(bb1)
    //   bb1: py_for_iter(iter, body:bb2, exit:bb3)   ← loop header
    //   bb2: store x, call print(x), jump(bb1)       ← loop body
    //   bb3: const(None), ret                        ← exit
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower(
        \\for x in items:
        \\    print(x)
    );
    defer proc.deinit();

    try testing.expectEqual(@as(usize, 4), proc.blocks.items.len);

    // Loop header block (bb1) must contain exactly one py_for_iter.
    const bb1_values = proc.blocks.items[1].values.items;
    try testing.expectEqual(@as(usize, 1), bb1_values.len);
    try testing.expectEqual(ir.OpCode.py_for_iter, proc.values.items(.op)[bb1_values[0].idx()]);

    // py_for_iter must be a terminator.
    try testing.expect(ir.OpCode.py_for_iter.isTerminator());

    // py_for_iter successors: body = bb2, exit = bb3.
    const for_iter_vid = bb1_values[0];
    const fi_rhs = proc.values.items(.rhs)[for_iter_vid.idx()];
    const fi_extra = proc.extraData(ir.ForIterExtra, fi_rhs);
    try testing.expectEqual(ir.BlockId.from(2), fi_extra.body);
    try testing.expectEqual(ir.BlockId.from(3), fi_extra.exit);

    // bb0 must contain py_get_iter.
    var has_get_iter = false;
    for (proc.blocks.items[0].values.items) |vid| {
        if (proc.values.items(.op)[vid.idx()] == .py_get_iter) has_get_iter = true;
    }
    try testing.expect(has_get_iter);

    // loop body (bb2) must jump back to the loop header (bb1).
    var buf: [8]ir.BlockId = undefined;
    const body_succs = proc.successors(ir.BlockId.from(2), &buf);
    try testing.expectEqual(@as(usize, 1), body_succs.len);
    try testing.expectEqual(ir.BlockId.from(1), body_succs[0]);
}

test "ir/lower: for loop iteration value is py_for_iter result" {
    // The loop variable (x) is the direct result of py_for_iter — confirmed by
    // checking that py_store_name's value operand is the py_for_iter vid.
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower(
        \\for x in items:
        \\    print(x)
    );
    defer proc.deinit();

    // Find py_for_iter vid (it's the only value in bb1).
    const for_iter_vid = proc.blocks.items[1].values.items[0];

    // First instruction in bb2 should be py_store_name("x", <for_iter_vid>).
    const bb2_vals = proc.blocks.items[2].values.items;
    try testing.expect(bb2_vals.len > 0);
    const store_op = proc.values.items(.op)[bb2_vals[0].idx()];
    try testing.expectEqual(ir.OpCode.py_store_name, store_op);
    // rhs of py_store_name is the value being stored = the for_iter result.
    const store_rhs = proc.values.items(.rhs)[bb2_vals[0].idx()];
    try testing.expectEqual(for_iter_vid.idx(), store_rhs);
}

test "ir/lower: method call uses object as receiver" {
    // obj.method(a, b) must produce:
    //   py_call(obj, py_load_attr(obj, "method"), a, b)
    // where operands[0] = receiver = py_load_name("obj")
    //       operands[1] = callable = py_load_attr(_, "method")
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("obj.method(a, b)");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    // Find py_call
    var call_idx: usize = 0;
    for (ops, 0..) |op, i| {
        if (op == .py_call) { call_idx = i; break; }
    }
    try testing.expect(call_idx > 0);

    const count = proc.values.items(.lhs)[call_idx]; // operand count: receiver + callable + 2 args
    const off = proc.values.items(.rhs)[call_idx];   // extra offset
    try testing.expectEqual(@as(u32, 4), count);

    const recv_vid = proc.extra.items[off + 0];
    const callable_vid = proc.extra.items[off + 1];

    // receiver must be a py_load_name (the object, not const(None))
    try testing.expectEqual(ir.OpCode.py_load_name, ops[recv_vid]);
    // callable must be a py_load_attr
    try testing.expectEqual(ir.OpCode.py_load_attr, ops[callable_vid]);
    // py_load_attr's lhs is the object it reads the attribute from (another load of obj)
    const attr_obj_vid = proc.values.items(.lhs)[callable_vid];
    try testing.expectEqual(ir.OpCode.py_load_name, ops[attr_obj_vid]);
}

test "ir/lower: free function call uses const(None) as receiver" {
    // print(x) should have const(None) as receiver, not an object reference.
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    var proc = try harness.lower("print(x)");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    var call_idx: usize = 0;
    for (ops, 0..) |op, i| {
        if (op == .py_call) { call_idx = i; break; }
    }
    try testing.expect(call_idx > 0);

    const off = proc.values.items(.rhs)[call_idx];
    const recv_vid = proc.extra.items[off + 0];
    // receiver must be const(None) (tagged immediate)
    try testing.expectEqual(ir.OpCode.const_obj, ops[recv_vid]);
    // receiver is a tagged immediate (None), not an object pool ref
    const recv_repr = proc.values.items(.repr)[recv_vid];
    try testing.expectEqualStrings("tagged", @tagName(recv_repr));
}

test "ir/lower: make_function in module emits py_make_function" {
    var harness = try test_utils.CompilerHarness.create(testing.allocator);
    defer harness.deinit();

    // Module-level proc (co 0): nop, const(co), py_make_function, py_store_name("f"), const(None), ret
    var proc = try harness.lower("def f(x): return x + 1");
    defer proc.deinit();

    const ops = proc.values.items(.op);
    var found_make_fn = false;
    for (ops) |op| if (op == .py_make_function) { found_make_fn = true; break; };
    try testing.expect(found_make_fn);
}
