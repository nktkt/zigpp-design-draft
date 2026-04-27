const std = @import("std");

pub const Severity = enum {
    note,
    warning,
    err,
};

pub const Diagnostic = struct {
    severity: Severity,
    line: usize,
    column: usize,
    message: []const u8,

    pub fn format(self: Diagnostic, writer: anytype) !void {
        const label = switch (self.severity) {
            .note => "note",
            .warning => "warning",
            .err => "error",
        };
        try writer.print("{s}:{d}:{d}: {s}", .{ label, self.line, self.column, self.message });
    }
};

pub const Bag = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator) Bag {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Bag) void {
        self.items.deinit(self.allocator);
    }

    pub fn add(
        self: *Bag,
        severity: Severity,
        line: usize,
        column: usize,
        message: []const u8,
    ) !void {
        try self.items.append(self.allocator, .{
            .severity = severity,
            .line = line,
            .column = column,
            .message = message,
        });
    }

    pub fn hasErrors(self: Bag) bool {
        for (self.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }
};
