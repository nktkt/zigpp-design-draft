const std = @import("std");

pub fn DeinitGuard(comptime T: type) type {
    return struct {
        value: T,
        active: bool = true,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        pub fn disarm(self: *Self) void {
            self.active = false;
        }

        pub fn deinit(self: *Self) void {
            if (self.active and @hasDecl(T, "deinit")) {
                self.value.deinit();
            }
            self.active = false;
        }
    };
}

pub fn Owned(comptime T: type) type {
    return struct {
        value: T,

        pub fn init(value: T) @This() {
            return .{ .value = value };
        }
    };
}

test "owned wrapper stores value" {
    const Box = Owned(u32);
    const item = Box.init(42);
    try std.testing.expectEqual(@as(u32, 42), item.value);
}
