pub fn Iterator(comptime T: type) type {
    return struct {
        index: usize = 0,
        list: []const T,

        const Self = @This();

        pub fn next(self: *Self) ?T {
            for (self.list[self.index..]) |item| {
                self.index += 1;
                return item;
            }
            return null;
        }
    };
}
