const std = @import("std");

pub fn Debug(comptime T: type) type {
    return struct {
        pub fn typeName() []const u8 {
            return @typeName(T);
        }
    };
}

pub fn Hash(comptime T: type) type {
    return struct {
        pub fn typeName() []const u8 {
            return @typeName(T);
        }
    };
}

pub fn Json(comptime T: type) type {
    return struct {
        pub fn typeName() []const u8 {
            return @typeName(T);
        }
    };
}

test "derive helpers expose target type names" {
    const User = struct {
        id: u64,
    };

    try std.testing.expect(std.mem.indexOf(u8, Debug(User).typeName(), "User") != null);
    try std.testing.expect(std.mem.indexOf(u8, Hash(User).typeName(), "User") != null);
    try std.testing.expect(std.mem.indexOf(u8, Json(User).typeName(), "User") != null);
}
