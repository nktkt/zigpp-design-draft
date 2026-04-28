const std = @import("std");

pub const Severity = enum {
    note,
    warning,
    err,
};

pub const unknown_code = "ZPP0000";

pub const Code = struct {
    pub const owned_missing_cleanup = "ZPP1001";
    pub const owned_used_after_move = "ZPP1002";
    pub const owned_moved_after_deinit = "ZPP1003";
    pub const owned_double_deinit = "ZPP1004";

    pub const effect_noalloc = "ZPP2001";
    pub const effect_noio = "ZPP2002";
    pub const effect_nonblocking = "ZPP2003";
    pub const effect_nothread = "ZPP2004";
    pub const effect_nodyn = "ZPP2005";
    pub const effect_nounsafe = "ZPP2006";

    pub const missing_alloc_effect = "ZPP2101";
    pub const missing_io_effect = "ZPP2102";
    pub const missing_blocking_effect = "ZPP2103";
    pub const missing_spawn_effect = "ZPP2104";
    pub const missing_dyn_effect = "ZPP2105";
    pub const missing_unsafe_effect = "ZPP2106";
};

pub const Diagnostic = struct {
    code: []const u8 = unknown_code,
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
        try writer.print("{d}:{d}: {s}[{s}]: {s}", .{ self.line, self.column, label, self.code, self.message });
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
        try self.addWithCode(unknown_code, severity, line, column, message);
    }

    pub fn addWithCode(
        self: *Bag,
        code: []const u8,
        severity: Severity,
        line: usize,
        column: usize,
        message: []const u8,
    ) !void {
        try self.items.append(self.allocator, .{
            .code = code,
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

test "diagnostic format includes code" {
    const diag = Diagnostic{
        .code = Code.owned_missing_cleanup,
        .severity = .err,
        .line = 3,
        .column = 5,
        .message = "owned value must be cleaned up",
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try diag.format(out.writer(std.testing.allocator));

    try std.testing.expectEqualStrings("3:5: error[ZPP1001]: owned value must be cleaned up", out.items);
}

test "diagnostic bag preserves explicit codes" {
    var bag = Bag.init(std.testing.allocator);
    defer bag.deinit();

    try bag.addWithCode(Code.effect_noalloc, .err, 1, 9, "noalloc violation");

    try std.testing.expectEqual(@as(usize, 1), bag.items.items.len);
    try std.testing.expectEqualStrings(Code.effect_noalloc, bag.items.items[0].code);
}
