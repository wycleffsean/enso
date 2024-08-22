const std = @import("std");
const StringArrayHashMap = std.StringArrayHashMap;
const testing = std.testing;

pub const Index = usize;

// This is a thin wrapper around StringArrayHashMap which allocates/copies key data
// as the lifetime of this is intended to outlive the source buffers
//
// Callers trade a string key for an index into the table, and may use the index to fetch the key again
pub const StringInternPool = struct {
    pool: StringArrayHashMap(void),
    allocator: std.mem.Allocator,

    const Self = @This();
    pub const Error = error{} || std.mem.Allocator.Error;

    // allocator must be an ArenaAllocator
    pub fn init(allocator: std.mem.Allocator) Self {
        // TODO: unsure how to guard here, allocator.ptr is opaque
        return .{
            .pool = StringArrayHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pool.deinit();
    }

    pub fn put(self: *Self, string: []const u8) Error!Index {
        var entry = try self.pool.getOrPut(string);
        if (!entry.found_existing) {
            var string_dup = try self.allocator.dupe(u8, string);
            entry.key_ptr = &string_dup;
        }
        return entry.index;
    }

    // O(n)
    pub fn getIndex(self: *Self, needle: []const u8) ?Index {
        const slice = self.pool.unmanaged.entries.slice();
        const keys_array = slice.items(.key);
        var index: Index = 0;
        for (keys_array) |key| {
            if (std.mem.eql(u8, key, needle)) {
                return index;
            }
            index += 1;
        }
        return null;
    }

    pub fn get(self: *Self, index: Index) Error![]const u8 {
        const slice = self.pool.unmanaged.entries.slice();
        const keys_array = slice.items(.key);
        return keys_array[index];
    }
};

test "intern: put and get" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var intern_pool = StringInternPool.init(arena.allocator());
    defer intern_pool.deinit();
    const a = "yo";
    var b = [_]u8{ 'y', 'o' };
    std.debug.assert(std.mem.eql(u8, a, &b));
    const key_idx = try intern_pool.put(a);
    try testing.expect(key_idx == 0);
    const key_get = try intern_pool.get(key_idx);
    try testing.expectEqualSlices(u8, a, key_get);
    try testing.expectEqual(key_idx, try intern_pool.put(&b));
    try testing.expectEqual(@as(Index, 1), try intern_pool.put("yoyo"));
    try testing.expectEqual(@as(Index, 2), intern_pool.pool.count());
}
