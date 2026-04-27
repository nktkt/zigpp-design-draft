const std = @import("std");
const zpp = @import("zpp");

const usage =
    \\usage: zpp-audit [--deny-warnings] <file.zpp>...
    \\
    \\Run Zig++ diagnostics over one or more files and print an aggregate summary.
    \\Errors fail the audit. Warnings fail only when --deny-warnings is set.
    \\
;

const Counts = struct {
    notes: usize = 0,
    warnings: usize = 0,
    errors: usize = 0,

    fn addDiagnostic(self: *Counts, diag: zpp.diagnostics.Diagnostic) void {
        switch (diag.severity) {
            .note => self.notes += 1,
            .warning => self.warnings += 1,
            .err => self.errors += 1,
        }
    }

    fn add(self: *Counts, other: Counts) void {
        self.notes += other.notes;
        self.warnings += other.warnings;
        self.errors += other.errors;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(2);
    }

    var deny_warnings = false;
    var path_count: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--deny-warnings") or std.mem.eql(u8, arg, "-Werror")) {
            deny_warnings = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("zpp-audit: unknown option: {s}\n", .{arg});
            std.process.exit(2);
        } else {
            path_count += 1;
        }
    }

    if (path_count == 0) {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(2);
    }

    var total = Counts{};
    i = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-")) continue;

        const source = try std.fs.cwd().readFileAlloc(allocator, arg, 16 * 1024 * 1024);
        defer allocator.free(source);

        const diags = try zpp.sema.checkSource(allocator, source);
        defer allocator.free(diags);

        const file_counts = countDiagnostics(diags);
        total.add(file_counts);
        printDiagnostics(arg, diags);
    }

    std.debug.print("zpp-audit: {d} error(s), {d} warning(s), {d} note(s)\n", .{
        total.errors,
        total.warnings,
        total.notes,
    });

    if (auditFails(total, deny_warnings)) {
        std.process.exit(1);
    }
}

fn printDiagnostics(path: []const u8, diags: []const zpp.diagnostics.Diagnostic) void {
    for (diags) |diag| {
        std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{
            path,
            diag.line,
            diag.column,
            severityLabel(diag.severity),
            diag.message,
        });
    }
}

fn countDiagnostics(diags: []const zpp.diagnostics.Diagnostic) Counts {
    var counts = Counts{};
    for (diags) |diag| {
        counts.addDiagnostic(diag);
    }
    return counts;
}

fn auditFails(counts: Counts, deny_warnings: bool) bool {
    return counts.errors != 0 or (deny_warnings and counts.warnings != 0);
}

fn severityLabel(severity: zpp.diagnostics.Severity) []const u8 {
    return switch (severity) {
        .note => "note",
        .warning => "warning",
        .err => "error",
    };
}

test "countDiagnostics groups severities" {
    const diags = [_]zpp.diagnostics.Diagnostic{
        .{ .severity = .note, .line = 1, .column = 1, .message = "note" },
        .{ .severity = .warning, .line = 2, .column = 1, .message = "warning" },
        .{ .severity = .err, .line = 3, .column = 1, .message = "error" },
    };

    const counts = countDiagnostics(&diags);
    try std.testing.expectEqual(@as(usize, 1), counts.notes);
    try std.testing.expectEqual(@as(usize, 1), counts.warnings);
    try std.testing.expectEqual(@as(usize, 1), counts.errors);
}

test "audit failure policy treats warnings as configurable" {
    try std.testing.expect(!auditFails(.{ .warnings = 1 }, false));
    try std.testing.expect(auditFails(.{ .warnings = 1 }, true));
    try std.testing.expect(auditFails(.{ .errors = 1 }, false));
}
