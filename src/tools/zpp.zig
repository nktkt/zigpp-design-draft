const std = @import("std");
const zpp = @import("zpp");

const usage =
    \\usage: zpp <input.zpp> [-o output.zig] [--check] [--deny-warnings]
    \\
    \\Lower Zig++ source to Zig. --check runs diagnostics without writing output.
    \\Warnings are reported but do not fail unless --deny-warnings is set.
    \\
;

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

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var check_only = false;
    var deny_warnings = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--deny-warnings") or std.mem.eql(u8, arg, "-Werror")) {
            deny_warnings = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stderr().writeAll("zpp: -o requires a path\n");
                std.process.exit(2);
            }
            output_path = args[i];
        } else if (input_path == null) {
            input_path = arg;
        } else {
            try std.fs.File.stderr().writeAll("zpp: unexpected argument\n");
            std.process.exit(2);
        }
    }

    const path = input_path orelse {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(2);
    };

    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(source);

    const sema_diags = try zpp.sema.checkSource(allocator, source);
    defer allocator.free(sema_diags);

    if (sema_diags.len != 0) {
        printDiagnostics(path, sema_diags);
        if (shouldFailDiagnostics(sema_diags, deny_warnings)) {
            std.process.exit(1);
        }
    }

    if (check_only) return;

    const lowered = try zpp.lowerSource(allocator, source);
    defer allocator.free(lowered);

    if (output_path) |out_path| {
        try std.fs.cwd().writeFile(.{
            .sub_path = out_path,
            .data = lowered,
        });
    } else {
        try std.fs.File.stdout().writeAll(lowered);
    }
}

fn printDiagnostics(path: []const u8, diags: []const zpp.diagnostics.Diagnostic) void {
    for (diags) |diag| {
        std.debug.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
            path,
            diag.line,
            diag.column,
            severityLabel(diag.severity),
            diag.code,
            diag.message,
        });
    }
}

fn shouldFailDiagnostics(diags: []const zpp.diagnostics.Diagnostic, deny_warnings: bool) bool {
    for (diags) |diag| {
        switch (diag.severity) {
            .err => return true,
            .warning => if (deny_warnings) return true,
            .note => {},
        }
    }
    return false;
}

fn severityLabel(severity: zpp.diagnostics.Severity) []const u8 {
    return switch (severity) {
        .note => "note",
        .warning => "warning",
        .err => "error",
    };
}

test "warnings do not fail by default" {
    const diags = [_]zpp.diagnostics.Diagnostic{
        .{ .severity = .warning, .line = 1, .column = 1, .message = "visible effect missing" },
    };

    try std.testing.expect(!shouldFailDiagnostics(&diags, false));
}

test "deny warnings fails on warnings" {
    const diags = [_]zpp.diagnostics.Diagnostic{
        .{ .severity = .warning, .line = 1, .column = 1, .message = "visible effect missing" },
    };

    try std.testing.expect(shouldFailDiagnostics(&diags, true));
}

test "errors always fail and notes never fail alone" {
    const notes = [_]zpp.diagnostics.Diagnostic{
        .{ .severity = .note, .line = 1, .column = 1, .message = "note" },
    };
    const errors = [_]zpp.diagnostics.Diagnostic{
        .{ .severity = .err, .line = 1, .column = 1, .message = "error" },
    };

    try std.testing.expect(!shouldFailDiagnostics(&notes, true));
    try std.testing.expect(shouldFailDiagnostics(&errors, false));
}
