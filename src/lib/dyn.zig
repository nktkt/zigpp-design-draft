pub const Any = struct {
    ptr: *anyopaque,
    vtable: *const anyopaque,
};

pub fn erase(ptr: anytype, vtable: *const anyopaque) Any {
    return .{
        .ptr = @ptrCast(ptr),
        .vtable = vtable,
    };
}
