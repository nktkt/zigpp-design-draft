const std = @import("std");

pub const CancellationToken = struct {
    cancelled: bool = false,

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled = true;
    }

    pub fn isCancelled(self: CancellationToken) bool {
        return self.cancelled;
    }
};

pub const TaskGroup = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TaskGroup {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TaskGroup) void {
        _ = self;
    }

    pub fn join(self: *TaskGroup) !void {
        _ = self;
    }
};
