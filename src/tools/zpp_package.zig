const std = @import("std");
const zpp = @import("zpp");
const zpp_api = @import("zpp_api.zig");
const zpp_doc = @import("zpp_doc.zig");

const usage =
    \\usage: zpp-package <package.json> (--audit | --api [-o output.jsonl] | --doc [-o output.md] | --api-check baseline.jsonl | --api-check-compatible baseline.jsonl) [--deny-warnings]
    \\
    \\Package manifest format:
    \\{
    \\  "name": "example",
    \\  "version": "0.1.0",
    \\  "sources": ["examples/hello_trait.zpp"]
    \\}
    \\
;

const PackageManifest = struct {
    name: []const u8,
    version: []const u8 = "",
    sources: []const []const u8,
};

const Command = enum {
    none,
    audit,
    api,
    doc,
    api_check,
    api_check_compatible,
};

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

    if (args.len < 3) {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(2);
    }

    const package_path = args[1];
    var command: Command = .none;
    var output_path: ?[]const u8 = null;
    var baseline_path: ?[]const u8 = null;
    var deny_warnings = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--audit")) {
            try setCommand(&command, .audit);
        } else if (std.mem.eql(u8, arg, "--api")) {
            try setCommand(&command, .api);
        } else if (std.mem.eql(u8, arg, "--doc")) {
            try setCommand(&command, .doc);
        } else if (std.mem.eql(u8, arg, "--api-check")) {
            try setCommand(&command, .api_check);
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stderr().writeAll("zpp-package: --api-check requires a baseline path\n");
                std.process.exit(2);
            }
            baseline_path = args[i];
        } else if (std.mem.eql(u8, arg, "--api-check-compatible")) {
            try setCommand(&command, .api_check_compatible);
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stderr().writeAll("zpp-package: --api-check-compatible requires a baseline path\n");
                std.process.exit(2);
            }
            baseline_path = args[i];
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stderr().writeAll("zpp-package: -o requires a path\n");
                std.process.exit(2);
            }
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--deny-warnings") or std.mem.eql(u8, arg, "-Werror")) {
            deny_warnings = true;
        } else {
            std.debug.print("zpp-package: unknown option: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    if (command == .none) {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(2);
    }

    var parsed = try readPackageManifest(allocator, package_path);
    defer parsed.deinit();
    const package = parsed.value;

    switch (command) {
        .audit => {
            const counts = try auditPackage(allocator, package);
            std.debug.print("zpp-package audit {s}: {d} error(s), {d} warning(s), {d} note(s)\n", .{
                package.name,
                counts.errors,
                counts.warnings,
                counts.notes,
            });
            if (auditFails(counts, deny_warnings)) {
                std.process.exit(1);
            }
        },
        .api => {
            const manifest = try generatePackageApi(allocator, package);
            defer allocator.free(manifest);
            if (output_path) |path| {
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = manifest });
            } else {
                try std.fs.File.stdout().writeAll(manifest);
            }
        },
        .doc => {
            const markdown = try generatePackageDocs(allocator, package);
            defer allocator.free(markdown);
            if (output_path) |path| {
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = markdown });
            } else {
                try std.fs.File.stdout().writeAll(markdown);
            }
        },
        .api_check => {
            const baseline = try readBaseline(allocator, baseline_path);
            defer allocator.free(baseline);
            const manifest = try generatePackageApi(allocator, package);
            defer allocator.free(manifest);

            if (!manifestsEqual(baseline, manifest)) {
                std.debug.print("zpp-package: API manifest differs from {s}\n", .{baseline_path.?});
                std.process.exit(1);
            }
        },
        .api_check_compatible => {
            const baseline = try readBaseline(allocator, baseline_path);
            defer allocator.free(baseline);
            const manifest = try generatePackageApi(allocator, package);
            defer allocator.free(manifest);

            const missing = countMissingManifestLines(baseline, manifest);
            if (missing != 0) {
                std.debug.print("zpp-package: incompatible API manifest: {d} baseline line(s) missing\n", .{missing});
                std.process.exit(1);
            }
        },
        .none => unreachable,
    }
}

fn setCommand(command: *Command, value: Command) !void {
    if (command.* != .none) {
        std.debug.print("zpp-package: choose only one command\n", .{});
        std.process.exit(2);
    }
    command.* = value;
}

fn readPackageManifest(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(PackageManifest) {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(source);

    return std.json.parseFromSlice(PackageManifest, allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn readBaseline(allocator: std.mem.Allocator, path: ?[]const u8) ![]u8 {
    const baseline_path = path orelse {
        try std.fs.File.stderr().writeAll("zpp-package: baseline path is required\n");
        std.process.exit(2);
    };
    return std.fs.cwd().readFileAlloc(allocator, baseline_path, 16 * 1024 * 1024);
}

fn auditPackage(allocator: std.mem.Allocator, package: PackageManifest) !Counts {
    var total = Counts{};

    for (package.sources) |path| {
        const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(source);

        const diags = try zpp.sema.checkSource(allocator, source);
        defer allocator.free(diags);

        var counts = Counts{};
        for (diags) |diag| {
            counts.addDiagnostic(diag);
        }
        total.add(counts);
        printDiagnostics(path, diags);
    }

    return total;
}

fn generatePackageApi(allocator: std.mem.Allocator, package: PackageManifest) ![]u8 {
    var sources: std.ArrayList(zpp_api.ManifestSource) = .empty;
    defer {
        for (sources.items) |source| {
            allocator.free(source.source);
        }
        sources.deinit(allocator);
    }

    for (package.sources) |path| {
        const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        errdefer allocator.free(source);
        try sources.append(allocator, .{
            .path = path,
            .source = source,
        });
    }

    return zpp_api.generatePackageManifest(allocator, sources.items);
}

fn generatePackageDocs(allocator: std.mem.Allocator, package: PackageManifest) ![]u8 {
    var sources: std.ArrayList(zpp_api.ManifestSource) = .empty;
    defer {
        for (sources.items) |source| {
            allocator.free(source.source);
        }
        sources.deinit(allocator);
    }

    for (package.sources) |path| {
        const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        errdefer allocator.free(source);
        try sources.append(allocator, .{
            .path = path,
            .source = source,
        });
    }

    return generatePackageDocsFromSources(allocator, package.name, package.version, sources.items);
}

pub fn generatePackageDocsFromSources(
    allocator: std.mem.Allocator,
    package_name: []const u8,
    version: []const u8,
    sources: []const zpp_api.ManifestSource,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.writer(allocator).print("# Zig++ Package API: `{s}`\n", .{package_name});
    if (version.len != 0) {
        try out.writer(allocator).print("\nVersion: `{s}`\n", .{version});
    }
    try out.append(allocator, '\n');

    for (sources) |source| {
        const markdown = try zpp_doc.generateMarkdown(allocator, source.path, source.source);
        defer allocator.free(markdown);
        try out.appendSlice(allocator, markdown);
        if (!std.mem.endsWith(u8, markdown, "\n\n")) {
            try out.append(allocator, '\n');
        }
    }

    return out.toOwnedSlice(allocator);
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

fn manifestsEqual(expected: []const u8, actual: []const u8) bool {
    const normalized_expected = std.mem.trimRight(u8, expected, " \t\r\n");
    const normalized_actual = std.mem.trimRight(u8, actual, " \t\r\n");
    return std.mem.eql(u8, normalized_expected, normalized_actual);
}

fn countMissingManifestLines(baseline: []const u8, actual: []const u8) usize {
    var missing: usize = 0;
    var lines = std.mem.splitScalar(u8, baseline, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (!manifestContainsLine(actual, line)) missing += 1;
    }
    return missing;
}

fn manifestContainsLine(manifest: []const u8, needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, needle)) return true;
    }
    return false;
}

test "package manifest parses source list" {
    const source =
        \\{
        \\  "name": "sample",
        \\  "version": "0.1.0",
        \\  "sources": ["one.zpp", "two.zpp"]
        \\}
    ;

    var parsed = try std.json.parseFromSlice(PackageManifest, std.testing.allocator, source, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("sample", parsed.value.name);
    try std.testing.expectEqualStrings("0.1.0", parsed.value.version);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.sources.len);
}

test "generatePackageDocsFromSources concatenates source docs" {
    const sources = [_]zpp_api.ManifestSource{
        .{
            .path = "one.zpp",
            .source =
            \\trait Writer {
            \\    fn write(self) void;
            \\}
            ,
        },
        .{
            .path = "two.zpp",
            .source =
            \\pub fn main() void {}
            ,
        },
    };

    const markdown = try generatePackageDocsFromSources(std.testing.allocator, "sample", "0.1.0", &sources);
    defer std.testing.allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "# Zig++ Package API: `sample`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "Version: `0.1.0`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "# Zig++ API: `one.zpp`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Trait `Writer`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "# Zig++ API: `two.zpp`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Function `main`") != null);
}

test "audit failure policy matches package command" {
    try std.testing.expect(!auditFails(.{ .warnings = 1 }, false));
    try std.testing.expect(auditFails(.{ .warnings = 1 }, true));
    try std.testing.expect(auditFails(.{ .errors = 1 }, false));
}

test "compatible manifest helper catches missing line" {
    const baseline =
        "{\"kind\":\"trait\",\"name\":\"Writer\"}\n" ++
        "{\"kind\":\"function\",\"name\":\"main\"}\n";
    const actual =
        "{\"kind\":\"trait\",\"name\":\"Writer\"}\n";

    try std.testing.expectEqual(@as(usize, 1), countMissingManifestLines(baseline, actual));
}
