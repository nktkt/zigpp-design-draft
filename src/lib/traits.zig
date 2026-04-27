pub const TraitTag = struct {
    name: []const u8,
};

pub fn tag(comptime name: []const u8) TraitTag {
    return .{ .name = name };
}

pub fn targetType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

pub fn implements(comptime T: type, comptime method_name: []const u8) bool {
    return hasMethod(T, method_name);
}

pub fn hasMethod(comptime T: type, comptime method_name: []const u8) bool {
    const U = targetType(T);
    switch (@typeInfo(U)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(U, method_name)) return false;
    return @typeInfo(@TypeOf(@field(U, method_name))) == .@"fn";
}

pub fn requireMethod(comptime T: type, comptime trait_name: []const u8, comptime method_name: []const u8) void {
    if (!hasMethod(T, method_name)) {
        @compileError("type does not implement " ++ trait_name ++ ": missing method " ++ method_name);
    }
}

test "hasMethod unwraps single pointer" {
    const Writer = struct {
        pub fn write(_: *@This(), _: []const u8) !usize {
            return 0;
        }
    };

    try @import("std").testing.expect(hasMethod(*Writer, "write"));
    try @import("std").testing.expect(!hasMethod(u32, "write"));
}
