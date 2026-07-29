const std = @import("std");

pub fn Table(comptime T: type) type {
    const CapacityT = u32;

    return struct {
        table: std.ArrayList(T),

        const Self = @This();

        pub const Index = struct {
            index: CapacityT,

            pub fn init(i: usize) Index {
                return .{ .index = @intCast(i) };
            }
        };
        pub const Slice = []T;

        pub const empty: Self = .{ .table = .empty };
        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) Self {
            return .{
                .table = .initCapacity(allocator, capacity),
            };
        }

        pub fn index(i: usize) Index {
            return .init(i);
        }

        pub inline fn append(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            return self.table.append(allocator, item);
        }

        pub inline fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            return self.table.ensureUnusedCapacity(allocator, capacity);
        }

        pub inline fn appendAssumeCapacity(self: *Self, item: T) void {
            return self.table.appendAssumeCapacity(item);
        }

        pub inline fn clearRetainingCapacity(self: *Self) void {
            self.table.clearRetainingCapacity();
        }

        pub inline fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            return self.table.deinit(allocator);
        }

        pub const Span = struct {
            start: Index,
            len: CapacityT,

            pub inline fn slice(self: @This(), source: []T) Slice {
                return source[self.start.index..][0..self.len];
            }

            pub const empty = @This(){ .len = 0, .start = .init(0) };
        };
    };
}
