//! Core IR for the Enso Python compiler.
//!
//! Design commitments, so that later readers don't relitigate them:
//!
//!  1. Structure-of-arrays. `Procedure.values` is a MultiArrayList. Most passes
//!     scan opcodes; that scan should touch one dense u8 array.
//!
//!  2. IDs, never pointers. `ValueId`/`BlockId` survive reallocation, are 4
//!     bytes, and make the whole IR trivially dumpable and diffable. IDs are
//!     never recycled within a compilation, so a stale ID is a detectable bug
//!     rather than silent aliasing.
//!
//!  3. AIR-style payload encoding. A value has two u32s (`lhs`, `rhs`) whose
//!     meaning depends on the opcode. Anything bigger spills into `extra`, a
//!     flat u32 array, via `addExtra`/`extraData`. This is exactly how Zig's own
//!     compiler encodes ZIR/AIR and it is the right call here too.
//!
//!  4. Upsilon/Phi, not predecessor-indexed phi operands. A `phi` takes no
//!     operands; each predecessor contains `upsilon(value -> phi)`. Deleting an
//!     edge means deleting an upsilon. No positional array in the phi ever has
//!     to be kept in lockstep with the predecessor list. This is the single
//!     thing that makes CFG mutation tolerable.
//!
//!  5. No use lists. `replaceWithIdentity` is O(1); operand reads go through
//!     `resolve()`, which skips identities; a batch `stripIdentities` cleans up.
//!     Use counts and def-use maps are per-pass rebuilds (one linear scan).
//!
//!  6. Two opcode tiers in one IR. `py_*` opcodes are honest Python semantics
//!     (can call user code, can raise, can allocate). Everything else is
//!     machine-level. A specialization pass rewrites tier 1 into tier 2 plus
//!     guards. The lowering pass from bytecode only ever emits tier 1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// ===========================================================================
// IDs
// ===========================================================================

pub const ValueId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub inline fn idx(v: ValueId) u32 {
        assert(v != .none);
        return @intFromEnum(v);
    }
    pub inline fn from(i: u32) ValueId {
        return @enumFromInt(i);
    }
};

pub const BlockId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub inline fn idx(b: BlockId) u32 {
        assert(b != .none);
        return @intFromEnum(b);
    }
    pub inline fn from(i: u32) BlockId {
        return @enumFromInt(i);
    }
};

/// Index into `Procedure.exits`. Exit descriptors are interned and immutable:
/// they describe *shape* ("frame slot 3 comes from my operand 7"), never
/// concrete values. Many checks share one descriptor.
pub const ExitId = enum(u32) { none = std.math.maxInt(u32), _ };

/// Index into the constant pool (Python objects, interned strings, big ints).
pub const ConstId = enum(u32) { _ };

/// Index into the runtime's code-object table. Needed by exit descriptors so an
/// inlined frame knows which code object it belongs to.
pub const CodeId = enum(u32) { _ };

pub const LocalIdx = u16;

// ===========================================================================
// Representation
// ===========================================================================

/// How the bits are laid out. This is *not* the Python type. Keeping them apart
/// matters: the backend and the OSR boxing logic care about `Repr`; the
/// specializer cares about `PyTypeId`. Conflating them is how you end up
/// unable to answer "do I need to box this before writing it to a frame slot?"
pub const Repr = enum(u8) {
    none, // no result
    i1, // predicate
    i32,
    i64, // unboxed machine int
    f64, // unboxed double
    ptr, // raw pointer, not a Python reference
    object, // owned *PyObject reference
    tagged, // tagged: small int inline, else *PyObject

    /// Values in these representations must be boxed before they can appear in
    /// a baseline frame slot. Consequence: OSR exit code can allocate, and
    /// therefore can fail and can trigger GC. Do not model exits as "just
    /// moving bits".
    pub fn needsBoxing(r: Repr) bool {
        return switch (r) {
            .i1, .i32, .i64, .f64 => true,
            .none, .ptr, .object, .tagged => false,
        };
    }
};

/// Static Python type from annotations / constants / inference. Interned in a
/// side table (not shown) so that `Procedure` stays small. `.unknown` is the
/// `Any` boundary where guards actually have to exist.
pub const PyTypeId = enum(u32) {
    unknown = 0,
    int = 1,
    float = 2,
    str = 3,
    bool_ = 4,
    none_ = 5,
    _,
};

// ===========================================================================
// Opcodes
// ===========================================================================

/// Rule for adding an opcode: an opcode earns its existence if some pass needs
/// to reason about it *differently*. If two candidates get identical treatment
/// by every pass, they are one opcode with a flag field.
pub const Opcode = enum(u16) {
    // --- structural -------------------------------------------------------
    /// Deleted. Swept on the next block rebuild. Never freed.
    nop,
    /// Forwarding node. `replaceWithIdentity` turns a value into this in O(1)
    /// instead of walking a use list. `resolve()` sees through it.
    identity, // un_op
    /// Takes no operands. Its inputs are the `upsilon`s that target it.
    phi, // no_op
    /// "On this path, `phi` takes the value `lhs`." Lives in the predecessor.
    upsilon, // upsilon: lhs = value, rhs = phi
    /// Function parameter. `lhs` = parameter index.
    arg, // imm

    const_int, // imm: lhs/rhs = low/high half of i64
    const_f64, // imm
    const_obj, // const_ref: lhs = ConstId (None, interned str, big int, ...)

    // --- OSR bookkeeping --------------------------------------------------
    /// "Abstract frame slot `rhs` holds `lhs` from here on." Zero machine code.
    /// This is the incremental exit state; dense descriptors are derived from
    /// the stream of these by osr.zig, not stored per guard.
    mov_hint, // upsilon-shaped: lhs = value, rhs = slot index
    /// "The abstract bytecode position is now `lhs`." Delimits the region a
    /// guard can exit to. Also the traceback / line-number marker.
    state_mark, // imm: lhs = bytecode offset

    /// Speculation guard. `lhs` = i1 condition (exit when *false*).
    /// `rhs` -> extra: CheckPayload { exit: ExitId, nargs, args... }.
    /// The stackmap values are real operands, so liveness, DCE and
    /// replaceAllUses work on exits with zero exit-specific code in any pass.
    check, // check

    // --- terminators ------------------------------------------------------
    jump, // imm: lhs = BlockId
    branch, // branch: lhs = cond, rhs -> extra Branch { then_, else_ }
    switch_, // pl_op: lhs = scrutinee, rhs -> extra { ncases, ... }
    ret, // un_op (or .none for bare return)
    /// Reached only if the compiler was wrong. Traps.
    unreachable_, // no_op

    /// Throwing operation with an explicit handler edge. Ordinary Python
    /// exceptions that this function catches are *normal control flow* and the
    /// optimizer should see them. Exits are only for speculation failure.
    invoke, // pl_op: lhs = callee-ish, rhs -> extra Invoke { normal, handler, nargs, args... }

    // --- tier 1: honest Python semantics ----------------------------------
    // These can call arbitrary user code, raise, allocate, and mutate the
    // world. Effects say so. The specializer replaces them when types allow.
    py_binary_op, // pl_op: lhs = extra PyBinOp { kind, a, b }
    py_unary_op,
    py_compare,
    py_truthy, // un_op -> i1, but can call __bool__, so not pure
    py_load_attr, // pl_op: lhs = obj, rhs -> extra { name: ConstId }
    py_store_attr,
    py_load_subscr, // bin_op
    py_store_subscr,
    py_call, // varargs: lhs -> extra { nargs, callee, args... }
    py_load_global, // const_ref
    py_store_global,
    py_get_iter, // un_op
    py_for_iter, // terminator: pl_op -> extra { loop_body, exhausted }
    py_build_seq, // varargs, with kind in extra
    py_raise,
    py_load_deref, // imm: cell index
    py_store_deref,
    py_make_cell,
    py_make_function,
    /// Escape hatch. `rhs` -> extra { helper: RuntimeHelper, nargs, args... }.
    /// This is where the ~150 rare CPython opcodes go (IMPORT_NAME,
    /// LOAD_BUILD_CLASS, MATCH_CLASS, SETUP_ANNOTATIONS...). Do not invent 150
    /// opcodes for things no pass will ever inspect.
    call_runtime, // varargs

    // --- tier 2: machine level --------------------------------------------
    add_i64, // bin_op, pure, wraps (only emitted when range analysis proved it)
    sub_i64,
    mul_i64,
    and_i64,
    or_i64,
    xor_i64,
    shl_i64,
    shr_i64,
    /// Fused checked arithmetic, and a *terminator*.
    ///   lhs -> extra OvfOp { a, b, normal: BlockId, overflow: BlockId }
    /// Defines its result, usable only in `normal` (verifier enforces).
    ///
    /// Two reasons it is fused rather than `add_i64` + `check(no_ovf)`:
    ///  - MIR requires the overflow branch to immediately follow ADDO/SUBO/MULO;
    ///    a materialized overflow boolean does not exist at that level.
    ///  - If a pass separated them, the result would be garbage on the failing
    ///    path. Fusion makes that structurally impossible.
    ///
    /// Note this is *not* an exit. Int overflow -> big int is a cold block in
    /// the same CFG whose result phis back in as `tagged`. No frame state, no
    /// baseline transfer. Reserve OSR for when the *world* assumption breaks.
    add_ovf_i64,
    sub_ovf_i64,
    mul_ovf_i64,

    add_f64, // bin_op, pure
    sub_f64,
    mul_f64,
    div_f64,

    /// `lhs` -> extra Cmp { a, b, pred: CmpPred }. Result i1, pure.
    cmp_i64,
    cmp_f64,
    /// Pure predicate over a boxed value: "is this a `PyTypeId`?". Being an
    /// ordinary CSE-able, GVN-able, foldable value is the entire point: guard
    /// elimination then falls out of the normal optimizer with no
    /// guard-specific machinery.
    is_type, // pl_op: lhs = obj, rhs = PyTypeId
    is_tagged_int, // un_op -> i1

    load, // pl_op: lhs = base, rhs -> extra Mem { offset, repr }
    store, // pl_op: lhs = base, rhs -> extra Mem + value
    /// Object allocation. Sinkable; that is why it is an IR op and not a
    /// `call_runtime`. Sinking it past a guard requires the guard's exit state
    /// to carry a `.materialize` slot source.
    alloc, // pl_op

    // Reference counting as first-class IR. Almost certainly a bigger win than
    // any arithmetic optimization for CPython-object code, and impossible to
    // get if these are hidden inside `call_runtime`.
    incref, // un_op
    decref, // un_op

    box_i64, // un_op: i64 -> tagged. Can allocate if out of small-int range.
    unbox_i64, // un_op: tagged -> i64. Only valid after is_tagged_int guard.
    box_f64,
    unbox_f64,

    select, // pl_op: lhs = cond, rhs -> extra { a, b }

    pub inline fn isTerminator(op: Opcode) bool {
        return effectsOf(op).terminator;
    }
};

pub const CmpPred = enum(u8) { eq, ne, lt, le, gt, ge, ult, ule, ugt, uge };
pub const PyBinKind = enum(u8) { add, sub, mul, truediv, floordiv, mod, pow, lshift, rshift, and_, or_, xor, matmul, concat };

// ===========================================================================
// Effects
// ===========================================================================

/// Consulted by every pass. Nothing hand-rolls "is this movable". This is the
/// highest-value 60 lines in the IR; get it wrong and correctness bugs become
/// nondeterministic miscompiles rather than crashes.
pub const Effects = packed struct(u16) {
    /// Reads mutable heap / global state.
    reads_world: bool = false,
    /// Writes mutable heap / global state. Nothing that can exit may be moved
    /// across one of these.
    writes_world: bool = false,
    /// Can raise a Python exception.
    can_raise: bool = false,
    /// Can transfer to baseline execution. Pins the value relative to
    /// `writes_world` and requires a valid abstract state at this point.
    can_exit: bool = false,
    can_allocate: bool = false,
    /// Can reenter arbitrary Python, hence can do anything at all.
    can_call_python: bool = false,
    terminator: bool = false,
    has_result: bool = false,
    /// Operands live in `extra` rather than lhs/rhs.
    variadic: bool = false,
    _pad: u7 = 0,

    /// CSE / GVN / LICM eligibility.
    pub inline fn pure(e: Effects) bool {
        return !e.reads_world and !e.writes_world and !e.can_raise and
            !e.can_exit and !e.can_call_python and !e.terminator and
            !e.can_allocate;
    }
};

pub fn effectsOf(op: Opcode) Effects {
    const world_call: Effects = .{
        .reads_world = true,
        .writes_world = true,
        .can_raise = true,
        .can_allocate = true,
        .can_call_python = true,
        .has_result = true,
    };
    return switch (op) {
        .nop => .{},
        .identity, .phi, .arg, .const_int, .const_f64, .const_obj => .{ .has_result = true },
        .upsilon => .{},
        // Zero machine code, but they *define* the abstract state, so they are
        // not freely movable either: reordering a mov_hint changes what a later
        // guard would reconstruct.
        .mov_hint, .state_mark => .{ .writes_world = false },

        .check => .{ .can_exit = true, .variadic = true },

        .jump, .unreachable_ => .{ .terminator = true },
        .branch, .switch_ => .{ .terminator = true },
        .ret => .{ .terminator = true },
        .invoke => blk: {
            var e = world_call;
            e.terminator = true;
            e.variadic = true;
            break :blk e;
        },

        .py_binary_op,
        .py_unary_op,
        .py_compare,
        .py_truthy,
        .py_load_attr,
        .py_load_subscr,
        .py_load_global,
        .py_get_iter,
        .py_build_seq,
        .py_load_deref,
        .py_make_cell,
        .py_make_function,
        => world_call,

        .py_store_attr, .py_store_subscr, .py_store_global, .py_store_deref => blk: {
            var e = world_call;
            e.has_result = false;
            break :blk e;
        },
        .py_call, .call_runtime => blk: {
            var e = world_call;
            e.variadic = true;
            break :blk e;
        },
        .py_for_iter => blk: {
            var e = world_call;
            e.terminator = true;
            break :blk e;
        },
        .py_raise => .{ .terminator = true, .can_raise = true, .writes_world = true },

        .add_i64,
        .sub_i64,
        .mul_i64,
        .and_i64,
        .or_i64,
        .xor_i64,
        .shl_i64,
        .shr_i64,
        .add_f64,
        .sub_f64,
        .mul_f64,
        .div_f64,
        .cmp_i64,
        .cmp_f64,
        .is_type,
        .is_tagged_int,
        .unbox_i64,
        .unbox_f64,
        .select,
        => .{ .has_result = true },

        .add_ovf_i64, .sub_ovf_i64, .mul_ovf_i64 => .{ .terminator = true, .has_result = true },

        .load => .{ .reads_world = true, .has_result = true },
        .store => .{ .writes_world = true },
        .alloc => .{ .can_allocate = true, .has_result = true },
        .incref => .{ .writes_world = true },
        .decref => .{ .writes_world = true, .can_call_python = true }, // __del__!
        .box_i64, .box_f64 => .{ .can_allocate = true, .has_result = true },
    };
}

// ===========================================================================
// Values
// ===========================================================================

pub const Value = struct {
    op: Opcode,
    repr: Repr,
    /// Bytecode offset this came from. Debugging, tracebacks, and the initial
    /// `state_mark` placement all need it.
    origin: u32,
    lhs: u32,
    rhs: u32,
};

/// Payload structs written into `extra`. Every field must be a u32-sized
/// integer or enum so that `addExtra` can blit them.
pub const Branch = struct { then_: BlockId, else_: BlockId };
pub const OvfOp = struct { a: ValueId, b: ValueId, normal: BlockId, overflow: BlockId };
pub const Cmp = struct { a: ValueId, b: ValueId, pred: u32 };
pub const PyBinOp = struct { kind: u32, a: ValueId, b: ValueId };
pub const Mem = struct { offset: u32, repr: u32, value: ValueId };
/// Followed by `nargs` ValueIds: the stackmap operands.
pub const CheckPayload = struct { exit: ExitId, nargs: u32 };

// ===========================================================================
// Blocks
// ===========================================================================

pub const Block = struct {
    /// Flat and ordered; the terminator, if present, is last. Cheap to scan,
    /// cheap to rebuild, and rebuilt in one shot by InsertionSet.
    values: std.ArrayListUnmanaged(ValueId) = .{},
    /// Successors are *derived* from the terminator, never stored. One source
    /// of truth.
    preds: std.ArrayListUnmanaged(BlockId) = .{},
    /// Braun construction: all predecessors known.
    sealed: bool = false,

    pub fn deinit(b: *Block, gpa: Allocator) void {
        b.values.deinit(gpa);
        b.preds.deinit(gpa);
    }

    pub fn terminator(b: Block, proc: *const Procedure) ValueId {
        if (b.values.items.len == 0) return .none;
        const last = b.values.items[b.values.items.len - 1];
        return if (proc.opcodeOf(last).isTerminator()) last else .none;
    }
};

// ===========================================================================
// Exit descriptors
// ===========================================================================

/// Where a baseline frame slot gets its value. `.operand` is an index into the
/// *check's* operand list, not a ValueId: that is what makes descriptors
/// internable and makes exits participate in ordinary dataflow for free.
pub const SlotSource = packed struct(u32) {
    kind: enum(u2) { operand, constant, dead, materialize },
    repr: Repr,
    payload: u22,
};

/// One frame in the exit's frame *stack*. Once you inline, an exit must
/// reconstruct N baseline frames, not one. Getting this wrong is expensive to
/// retrofit, so it is a stack from day one even before inlining exists.
pub const FrameState = struct {
    code: CodeId,
    resume_pc: u32,
    nlocals: u16,
    nstack: u16,
    /// Offset into `ExitTable.slots`: nlocals + nstack entries, locals first.
    slots_off: u32,
};

pub const ExitDescriptor = struct {
    /// Offset into `ExitTable.frames`, outermost frame first.
    frames_off: u32,
    frames_len: u32,
};

pub const ExitTable = struct {
    descs: std.ArrayListUnmanaged(ExitDescriptor) = .{},
    frames: std.ArrayListUnmanaged(FrameState) = .{},
    slots: std.ArrayListUnmanaged(SlotSource) = .{},
    /// Interning. Two guards at the same bytecode offset with no intervening
    /// world-write share a descriptor, which is where the memory win is.
    dedup: std.HashMapUnmanaged(u64, ExitId, HashCtx, 80) = .{},

    const HashCtx = struct {
        pub fn hash(_: HashCtx, k: u64) u64 {
            return k;
        }
        pub fn eql(_: HashCtx, a: u64, b: u64) bool {
            return a == b;
        }
    };

    pub fn deinit(t: *ExitTable, gpa: Allocator) void {
        t.descs.deinit(gpa);
        t.frames.deinit(gpa);
        t.slots.deinit(gpa);
        t.dedup.deinit(gpa);
    }

    /// `frames` and `slots` are borrowed; copied in. Returns an existing id if
    /// an identical descriptor was already interned.
    pub fn intern(
        t: *ExitTable,
        gpa: Allocator,
        frames: []const FrameState,
        slots: []const SlotSource,
    ) !ExitId {
        var h = std.hash.Wyhash.init(0xE0501);
        for (frames) |f| {
            h.update(std.mem.asBytes(&f.code));
            h.update(std.mem.asBytes(&f.resume_pc));
            h.update(std.mem.asBytes(&f.nlocals));
            h.update(std.mem.asBytes(&f.nstack));
        }
        h.update(std.mem.sliceAsBytes(slots));
        const key = h.final();
        if (t.dedup.get(key)) |existing| return existing;

        const slots_off: u32 = @intCast(t.slots.items.len);
        try t.slots.appendSlice(gpa, slots);
        const frames_off: u32 = @intCast(t.frames.items.len);
        for (frames) |f| {
            var copy = f;
            copy.slots_off += slots_off;
            try t.frames.append(gpa, copy);
        }
        const id: ExitId = @enumFromInt(t.descs.items.len);
        try t.descs.append(gpa, .{ .frames_off = frames_off, .frames_len = @intCast(frames.len) });
        try t.dedup.put(gpa, key, id);
        return id;
    }
};

// ===========================================================================
// Procedure
// ===========================================================================

pub const Procedure = struct {
    gpa: Allocator,
    values: std.MultiArrayList(Value) = .{},
    /// Static Python type per value. Side table: only the specializer reads it,
    /// so it stays out of the hot SoA scan.
    py_types: std.ArrayListUnmanaged(PyTypeId) = .{},
    extra: std.ArrayListUnmanaged(u32) = .{},
    blocks: std.ArrayListUnmanaged(Block) = .{},
    exits: ExitTable = .{},
    entry: BlockId = .none,
    /// Set by osr.zig. `exit_ok[v]` is false if the abstract state is stale at
    /// `v`, i.e. a world-write has happened since the last state_mark without
    /// the hints being brought up to date. The verifier asserts every
    /// `can_exit` value has `exit_ok`.
    exit_ok: std.DynamicBitSetUnmanaged = .{},

    pub fn init(gpa: Allocator) Procedure {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Procedure) void {
        p.values.deinit(p.gpa);
        p.py_types.deinit(p.gpa);
        p.extra.deinit(p.gpa);
        for (p.blocks.items) |*b| b.deinit(p.gpa);
        p.blocks.deinit(p.gpa);
        p.exits.deinit(p.gpa);
        p.exit_ok.deinit(p.gpa);
    }

    // --- accessors --------------------------------------------------------

    pub inline fn opcodeOf(p: *const Procedure, v: ValueId) Opcode {
        return p.values.items(.op)[v.idx()];
    }
    pub inline fn reprOf(p: *const Procedure, v: ValueId) Repr {
        return p.values.items(.repr)[v.idx()];
    }
    pub inline fn effectsFor(p: *const Procedure, v: ValueId) Effects {
        return effectsOf(p.opcodeOf(v));
    }

    /// See through `identity` chains. Every operand read goes through this.
    /// This is what buys us "no use lists".
    pub fn resolve(p: *const Procedure, v: ValueId) ValueId {
        var cur = v;
        const ops = p.values.items(.op);
        const lhs = p.values.items(.lhs);
        var guard: u32 = 0;
        while (cur != .none and ops[cur.idx()] == .identity) {
            cur = ValueId.from(lhs[cur.idx()]);
            guard += 1;
            assert(guard < 1_000_000); // identity cycle => bug
        }
        return cur;
    }

    // --- extra payloads ---------------------------------------------------

    pub fn addExtra(p: *Procedure, comptime T: type, payload: T) !u32 {
        const fields = std.meta.fields(T);
        try p.extra.ensureUnusedCapacity(p.gpa, fields.len);
        const off: u32 = @intCast(p.extra.items.len);
        inline for (fields) |f| {
            const raw: u32 = switch (@typeInfo(f.type)) {
                .@"enum" => @intFromEnum(@field(payload, f.name)),
                else => @field(payload, f.name),
            };
            p.extra.appendAssumeCapacity(raw);
        }
        return off;
    }

    pub fn extraData(p: *const Procedure, comptime T: type, off: u32) T {
        var out: T = undefined;
        var i = off;
        inline for (std.meta.fields(T)) |f| {
            const raw = p.extra.items[i];
            @field(out, f.name) = switch (@typeInfo(f.type)) {
                .@"enum" => @enumFromInt(raw),
                else => @intCast(raw),
            };
            i += 1;
        }
        return out;
    }

    pub fn addExtraSlice(p: *Procedure, ids: []const ValueId) !void {
        try p.extra.ensureUnusedCapacity(p.gpa, ids.len);
        for (ids) |id| p.extra.appendAssumeCapacity(@intFromEnum(id));
    }

    pub fn extraSlice(p: *const Procedure, off: u32, len: u32) []const u32 {
        return p.extra.items[off..][0..len];
    }

    // --- construction -----------------------------------------------------

    pub fn addBlock(p: *Procedure) !BlockId {
        const id = BlockId.from(@intCast(p.blocks.items.len));
        try p.blocks.append(p.gpa, .{});
        return id;
    }

    /// Creates a value but does not place it in a block. Use `Builder.emit` or
    /// `InsertionSet` for placement.
    pub fn addValue(p: *Procedure, v: Value) !ValueId {
        const id = ValueId.from(@intCast(p.values.len));
        try p.values.append(p.gpa, v);
        try p.py_types.append(p.gpa, .unknown);
        return id;
    }

    pub fn appendToBlock(p: *Procedure, block: BlockId, v: ValueId) !void {
        const b = &p.blocks.items[block.idx()];
        // Terminator stays last.
        if (b.values.items.len > 0) {
            const last = b.values.items[b.values.items.len - 1];
            if (p.opcodeOf(last).isTerminator()) {
                try b.values.insert(p.gpa, b.values.items.len - 1, v);
                return;
            }
        }
        try b.values.append(p.gpa, v);
    }

    pub fn successors(p: *const Procedure, block: BlockId, buf: *[8]BlockId) []const BlockId {
        const term = p.blocks.items[block.idx()].terminator(p);
        if (term == .none) return buf[0..0];
        const lhs = p.values.items(.lhs)[term.idx()];
        const rhs = p.values.items(.rhs)[term.idx()];
        switch (p.opcodeOf(term)) {
            .jump => {
                buf[0] = BlockId.from(lhs);
                return buf[0..1];
            },
            .branch => {
                const d = p.extraData(Branch, rhs);
                buf[0] = d.then_;
                buf[1] = d.else_;
                return buf[0..2];
            },
            .add_ovf_i64, .sub_ovf_i64, .mul_ovf_i64 => {
                const d = p.extraData(OvfOp, lhs);
                buf[0] = d.normal;
                buf[1] = d.overflow;
                return buf[0..2];
            },
            .ret, .unreachable_, .py_raise => return buf[0..0],
            else => return buf[0..0], // switch_/invoke/py_for_iter: TODO
        }
    }

    // --- mutation ---------------------------------------------------------
    //
    // Deliberately small. Notice what is *absent*: general edge redirection,
    // arbitrary block splitting, addPredecessor. Those are needed almost only
    // for inlining, and inlining should happen during bytecode lowering
    // (push a new symbolic frame and keep walking the callee), where Braun
    // construction handles the joins for free.

    /// O(1) replace-all-uses. No use list walk, no traversal.
    pub fn replaceWithIdentity(p: *Procedure, old: ValueId, new: ValueId) void {
        assert(old != new);
        assert(p.reprOf(old) == p.reprOf(new));
        p.values.items(.op)[old.idx()] = .identity;
        p.values.items(.lhs)[old.idx()] = @intFromEnum(new);
        p.values.items(.rhs)[old.idx()] = 0;
    }

    /// In-place mutation keeping the ValueId. Nothing else has to be updated,
    /// so constant folding needs no replaceAllUses at all.
    pub fn replaceWithConstInt(p: *Procedure, v: ValueId, x: i64) void {
        const u: u64 = @bitCast(x);
        p.values.items(.op)[v.idx()] = .const_int;
        p.values.items(.repr)[v.idx()] = .i64;
        p.values.items(.lhs)[v.idx()] = @truncate(u);
        p.values.items(.rhs)[v.idx()] = @truncate(u >> 32);
    }

    pub fn deleteValue(p: *Procedure, v: ValueId) void {
        assert(!p.effectsFor(v).terminator);
        p.values.items(.op)[v.idx()] = .nop;
        p.values.items(.repr)[v.idx()] = .none;
    }

    /// Sweeps `nop`s and collapses `identity` chains in every operand position.
    /// Run at pass boundaries, not inside passes.
    pub fn stripIdentitiesAndNops(p: *Procedure) void {
        const ops = p.values.items(.op);
        const lhs = p.values.items(.lhs);
        const rhs = p.values.items(.rhs);

        var i: u32 = 0;
        while (i < p.values.len) : (i += 1) {
            const op = ops[i];
            if (op == .identity or op == .nop) continue;
            const e = effectsOf(op);
            if (e.variadic) {
                // Variadic operands live in `extra`; layouts differ per opcode,
                // so each variadic opcode patches its own arg region here.
                switch (op) {
                    .check => {
                        const pay = p.extraData(CheckPayload, rhs[i]);
                        const args = p.extra.items[rhs[i] + 2 ..][0..pay.nargs];
                        for (args) |*a| a.* = @intFromEnum(p.resolve(ValueId.from(a.*)));
                        lhs[i] = @intFromEnum(p.resolve(ValueId.from(lhs[i])));
                    },
                    else => {},
                }
                continue;
            }
            // Non-variadic: lhs is a ValueId only for these shapes.
            switch (op) {
                .identity, .nop, .phi, .arg, .const_int, .const_f64, .const_obj, .jump, .state_mark, .unreachable_ => {},
                .upsilon, .mov_hint => lhs[i] = @intFromEnum(p.resolve(ValueId.from(lhs[i]))),
                else => {
                    lhs[i] = @intFromEnum(p.resolve(ValueId.from(lhs[i])));
                },
            }
        }

        for (p.blocks.items) |*b| {
            var w: usize = 0;
            for (b.values.items) |v| {
                const op = ops[v.idx()];
                if (op == .nop or op == .identity) continue;
                b.values.items[w] = v;
                w += 1;
            }
            b.values.shrinkRetainingCapacity(w);
        }
    }
};

// ===========================================================================
// InsertionSet
// ===========================================================================

/// Passes never mutate a block's value list while iterating it. They record
/// intended insertions here and call `execute` once. That is what lets block
/// storage be a flat array and lets passes be written in the obvious
/// scan-forward style with no iterator-invalidation hazards.
pub const InsertionSet = struct {
    const Entry = struct { index: u32, value: ValueId, order: u32 };
    entries: std.ArrayListUnmanaged(Entry) = .{},

    pub fn deinit(s: *InsertionSet, gpa: Allocator) void {
        s.entries.deinit(gpa);
    }

    /// `index` is a position in the block's *current* value list.
    pub fn insertAt(s: *InsertionSet, gpa: Allocator, index: u32, value: ValueId) !void {
        try s.entries.append(gpa, .{
            .index = index,
            .value = value,
            .order = @intCast(s.entries.items.len),
        });
    }

    pub fn execute(s: *InsertionSet, proc: *Procedure, block: BlockId) !void {
        if (s.entries.items.len == 0) return;
        std.mem.sort(Entry, s.entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.index != b.index) return a.index < b.index;
                return a.order < b.order; // stable within a position
            }
        }.lt);

        const b = &proc.blocks.items[block.idx()];
        var out = std.ArrayListUnmanaged(ValueId){};
        try out.ensureTotalCapacity(proc.gpa, b.values.items.len + s.entries.items.len);
        var ei: usize = 0;
        for (b.values.items, 0..) |v, i| {
            while (ei < s.entries.items.len and s.entries.items[ei].index == i) : (ei += 1) {
                out.appendAssumeCapacity(s.entries.items[ei].value);
            }
            out.appendAssumeCapacity(v);
        }
        while (ei < s.entries.items.len) : (ei += 1) {
            out.appendAssumeCapacity(s.entries.items[ei].value);
        }
        b.values.deinit(proc.gpa);
        b.values = out;
        s.entries.clearRetainingCapacity();
    }
};

// ===========================================================================
// Printer
// ===========================================================================

pub fn dump(p: *const Procedure, w: anytype) !void {
    for (p.blocks.items, 0..) |b, bi| {
        try w.print("bb{d}:", .{bi});
        if (b.preds.items.len > 0) {
            try w.writeAll("  ; preds:");
            for (b.preds.items) |pr| try w.print(" bb{d}", .{pr.idx()});
        }
        try w.writeAll("\n");
        for (b.values.items) |v| {
            const i = v.idx();
            const op = p.values.items(.op)[i];
            const e = effectsOf(op);
            if (e.has_result) {
                try w.print("    %{d}: {s} = {s}", .{ i, @tagName(p.values.items(.repr)[i]), @tagName(op) });
            } else {
                try w.print("    {s}", .{@tagName(op)});
            }
            try w.print(" [lhs={d} rhs={d}]\n", .{ p.values.items(.lhs)[i], p.values.items(.rhs)[i] });
        }
    }
}
