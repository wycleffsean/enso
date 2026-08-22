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
