const std = @import("std");
const testing = std.testing;

// w (word) i32/u32, l (long) i64/u64, s (single) f32, and d (double) f64
const Word = i32;
const UWord = u32;
const Long = i64;
const ULong = u64;
const Single = f32;
const Double = f64;
const Memory = *void;
// b (byte) u8 and h (half word) u16
const Byte = u8;
const HalfWord = u16;

// T stands for wlsd
const Numeric = union(enum) {
    integer: Integer,
    float: Float,
};
// I stands for wl
const Integer = union(enum) {
    word: Word,
    unsigned_word: UWord,
    long: Long,
    unsigned_long: ULong,
};
// F stands for sd
const Float = union(enum) {
    single: Single,
    double: Double,
};
// m stands for the type of pointers on the target; on 64-bit architectures it is the same as l
const Function = struct {
    exported: bool,
    return_type: Numeric,
    name: []const u8,
    instructions: std.AutoArrayHashMap([]const u8, Instruction),

    const Self = @This();

    fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        exported: bool,
        return_type: Numeric,
    ) Self {
        return .{
            .name = name,
            .exported = exported,
            .return_type = return_type,
            .instructions = std.AutoArrayHashMap([]const u8, Instruction).init(allocator),
        };
    }
};

const Data = struct { data: []const Byte };

const Instruction = struct {};
const Control = struct {};
const Call = struct {};
const Assignment = struct {};

// Arithmetic and Bits
// add, sub, div, mul -- T(T,T)
fn add(comptime Type: type, a: Type, b: Type) Type {
    // TODO: assert type is Numeric
    return a + b;
}
fn sub(comptime Type: type, a: Type, b: Type) Type {
    // TODO: assert type is Numeric
    return a - b;
}
fn div(comptime Type: type, a: Type, b: Type) Type {
    // TODO: assert type is Numeric
    return @divTrunc(a, b);
}
fn mul(comptime Type: type, a: Type, b: Type) Type {
    // TODO: assert type is Numeric
    return a * b;
}

test "arithmetic" {
    var aw: Word = 100;
    var bw: Word = 33;
    try testing.expectEqual(@as(Word, 133), add(Word, aw, bw));
    try testing.expectEqual(@as(Word, 67), sub(Word, aw, bw));
    try testing.expectEqual(@as(Word, 3), div(Word, aw, bw));
    try testing.expectEqual(@as(Word, 3300), mul(Word, aw, bw));

    var al: Long = 100;
    var bl: Long = 33;
    try testing.expectEqual(@as(Long, 133), add(Long, al, bl));
    try testing.expectEqual(@as(Long, 67), sub(Long, al, bl));
    try testing.expectEqual(@as(Long, 3), div(Long, al, bl));
    try testing.expectEqual(@as(Long, 3300), mul(Long, al, bl));

    var as: Single = 100;
    var bs: Single = 33;
    try testing.expectEqual(@as(Single, 133), add(Single, as, bs));
    try testing.expectEqual(@as(Single, 67), sub(Single, as, bs));
    try testing.expectEqual(@as(Single, 3), div(Single, as, bs));
    try testing.expectEqual(@as(Single, 3300), mul(Single, as, bs));

    var ad: Single = 100;
    var bd: Single = 33;
    try testing.expectEqual(@as(Single, 133), add(Single, ad, bd));
    try testing.expectEqual(@as(Single, 67), sub(Single, ad, bd));
    try testing.expectEqual(@as(Single, 3), div(Single, ad, bd));
    try testing.expectEqual(@as(Single, 3300), mul(Single, ad, bd));
}

// neg -- T(T)
fn neg(comptime Type: type, value: Type) Type {
    // Should it be -%value instead?
    return switch (Type) {
        Word, Long => -%value,
        Single, Double => -value,
        else => @compileError("Numeric values only"),
    };
}

test "neg" {
    try testing.expectEqual(@as(Word, -100), neg(Word, @as(Word, 100)));
    // try testing.expectEqual(@as(UWord, -100), neg(UWord, @as(UWord, 100)));
    try testing.expectEqual(@as(Long, -100), neg(Long, @as(Long, 100)));
    // try testing.expectEqual(@as(ULong, -100), neg(ULong, @as(ULong, 10Long0)));
    try testing.expectEqual(@as(Single, -100), neg(Single, @as(Single, 100)));
    try testing.expectEqual(@as(Double, -100), neg(Double, @as(Double, 100)));
    // integers don't overflow
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), neg(Word, std.math.minInt(i32)));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), neg(Long, std.math.minInt(i64)));
}

// udiv, rem, urem -- I(I,I)
fn udiv(a: Integer, b: @TypeOf(a)) @TypeOf(a) {
    return a + b;
}
fn rem(comptime T: type, a: T, b: T) T {
    return @rem(a, b);
}
fn urem(comptime T: type, a: T, b: T) T {
    return @rem(a, b);
}

// or, xor, and -- I(I,I)
fn @"or"(a: Integer, b: @TypeOf(a)) @TypeOf(a) {
    return a + b;
}
fn @"and"(a: Integer, b: @TypeOf(a)) @TypeOf(a) {
    return a + b;
}
// sar, shr, shl -- I(I,ww)
fn sar(a: Integer, b: Word) @TypeOf(a) {
    return a + b;
}
fn shr(a: Integer, b: Word) @TypeOf(a) {
    return a + b;
}
fn shl(a: Integer, b: Word) @TypeOf(a) {
    return a + b;
}

//Memory
// Store instructions.
//     stored -- (d,m)
fn stored(value: Double, address: Memory) void {
    _ = value;
    _ = address;
}
//     stores -- (s,m)
fn stores(value: Single, address: Memory) void {
    _ = value;
    _ = address;
}
//     storel -- (l,m)
fn storel(value: Long, address: Memory) void {
    _ = value;
    _ = address;
}
//     storew -- (w,m)
fn storew(value: Word, address: Memory) void {
    _ = value;
    _ = address;
}
//     storeh -- (w,m)
fn storeh(value: Word, address: Memory) void {
    _ = value;
    _ = address;
}
//     storeb -- (w,m)
fn storeb(value: Word, address: Memory) void {
    _ = value;
    _ = address;
}
// Load instructions.
//    loadd -- d(m)
fn loadd(address: Memory) Double {
    _ = address;
}
//    loads -- s(m)
fn loads(address: Memory) Single {
    _ = address;
}
//    loadl -- l(m)
fn loadl(address: Memory) Long {
    _ = address;
}
//    loadsw, loaduw -- I(mm)
fn loadsw(address: Memory) Integer {
    _ = address;
}
fn loaduw(address: Memory) Integer {
    _ = address;
}
//    loadsh, loaduh -- I(mm)
fn loadsh(address: Memory) Integer {
    _ = address;
}
fn loaduh(address: Memory) Integer {
    _ = address;
}
//    loadsb, loadub -- I(mm)
fn loadsb(address: Memory) Integer {
    _ = address;
}
fn loadub(address: Memory) Integer {
    _ = address;
}
// Blits.
//    blit -- (m,m,w)
fn blit(source: Memory, destination: Memory, value: Word) void {
    _ = source;
    _ = destination;
    _ = value;
}
// Stack allocation.
//    alloc4 -- m(l)
fn alloc4(size: Long) Memory {
    _ = size;
}
//    alloc8 -- m(l)
fn alloc8(size: Long) Memory {
    _ = size;
}
//    alloc16 -- m(l)
fn alloc16(size: Long) Memory {
    _ = size;
}
