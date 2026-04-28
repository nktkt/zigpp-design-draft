const std = @import("std");
const zpp = @import("zpp");
const zpp_api = @import("zpp_api.zig");
const zpp_doc = @import("zpp_doc.zig");
const zpp_fmt = @import("zpp_fmt.zig");

const usage =
    \\usage: zpp-package <package.json> (--audit | --fmt-check | --api [-o output.jsonl] | --doc [-o output.md] | --doc-check [baseline.md] | --api-check [baseline.jsonl] | --api-check-compatible [baseline.jsonl]) [--deny-warnings]
    \\
    \\Package manifest format:
    \\{
    \\  "name": "example",
    \\  "version": "0.1.0",
    \\  "sources": ["examples/hello_trait.zpp"],
    \\  "format_sources": ["examples/hello_trait.zpp", "tests/lowering/using.zpp"],
    \\  "api_output": "docs/example.api.jsonl",
    \\  "api_baseline": "docs/example.api.jsonl",
    \\  "docs_output": "docs/example-api.md"
    \\}
    \\
;

const PackageManifest = struct {
    name: []const u8,
    version: []const u8 = "",
    sources: []const []const u8,
    format_sources: []const []const u8 = &.{},
    api_output: []const u8 = "",
    api_baseline: []const u8 = "",
    docs_output: []const u8 = "",
};

const Command = enum {
    none,
    audit,
    fmt_check,
    api,
    doc,
    doc_check,
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
        } else if (std.mem.eql(u8, arg, "--fmt-check")) {
            try setCommand(&command, .fmt_check);
        } else if (std.mem.eql(u8, arg, "--api")) {
            try setCommand(&command, .api);
        } else if (std.mem.eql(u8, arg, "--doc")) {
            try setCommand(&command, .doc);
        } else if (std.mem.eql(u8, arg, "--doc-check")) {
            try setCommand(&command, .doc_check);
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                baseline_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--api-check")) {
            try setCommand(&command, .api_check);
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                baseline_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--api-check-compatible")) {
            try setCommand(&command, .api_check_compatible);
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                baseline_path = args[i];
            }
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
        .fmt_check => {
            const changed = try formatCheckPackage(allocator, package);
            if (changed != 0) {
                std.debug.print("zpp-package fmt-check {s}: {d} file(s) would change\n", .{ package.name, changed });
                std.process.exit(1);
            }
        },
        .api => {
            const manifest = try generatePackageApi(allocator, package);
            defer allocator.free(manifest);
            if (resolveOutputPath(output_path, package.api_output)) |path| {
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = manifest });
            } else {
                try std.fs.File.stdout().writeAll(manifest);
            }
        },
        .doc => {
            const markdown = try generatePackageDocs(allocator, package);
            defer allocator.free(markdown);
            if (resolveOutputPath(output_path, package.docs_output)) |path| {
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = markdown });
            } else {
                try std.fs.File.stdout().writeAll(markdown);
            }
        },
        .doc_check => {
            const baseline = try readDocBaseline(allocator, baseline_path, package);
            defer allocator.free(baseline);
            const markdown = try generatePackageDocs(allocator, package);
            defer allocator.free(markdown);

            if (!manifestsEqual(baseline, markdown)) {
                std.debug.print("zpp-package: docs output differs from {s}\n", .{resolveDocBaselinePath(baseline_path, package) orelse ""});
                printFirstDifference(baseline, markdown);
                std.process.exit(1);
            }
        },
        .api_check => {
            const baseline = try readBaseline(allocator, baseline_path, package);
            defer allocator.free(baseline);
            const manifest = try generatePackageApi(allocator, package);
            defer allocator.free(manifest);

            if (!manifestsEqual(baseline, manifest)) {
                std.debug.print("zpp-package: API manifest differs from {s}\n", .{resolveBaselinePath(baseline_path, package) orelse ""});
                printFirstDifference(baseline, manifest);
                std.process.exit(1);
            }
        },
        .api_check_compatible => {
            const baseline = try readBaseline(allocator, baseline_path, package);
            defer allocator.free(baseline);
            const manifest = try generatePackageApi(allocator, package);
            defer allocator.free(manifest);

            const missing = countMissingManifestLines(baseline, manifest);
            if (missing != 0) {
                std.debug.print("zpp-package: incompatible API manifest: {d} baseline line(s) missing\n", .{missing});
                if (firstMissingManifestLine(baseline, manifest)) |line| {
                    std.debug.print("  first missing baseline line: {s}\n", .{line});
                }
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

fn readBaseline(allocator: std.mem.Allocator, path: ?[]const u8, package: PackageManifest) ![]u8 {
    const baseline_path = resolveBaselinePath(path, package) orelse {
        try std.fs.File.stderr().writeAll("zpp-package: baseline path is required\n");
        std.process.exit(2);
    };
    return std.fs.cwd().readFileAlloc(allocator, baseline_path, 16 * 1024 * 1024);
}

fn readDocBaseline(allocator: std.mem.Allocator, path: ?[]const u8, package: PackageManifest) ![]u8 {
    const baseline_path = resolveDocBaselinePath(path, package) orelse {
        try std.fs.File.stderr().writeAll("zpp-package: docs baseline path is required\n");
        std.process.exit(2);
    };
    return std.fs.cwd().readFileAlloc(allocator, baseline_path, 16 * 1024 * 1024);
}

fn resolveBaselinePath(path: ?[]const u8, package: PackageManifest) ?[]const u8 {
    if (path) |explicit| return explicit;
    if (package.api_baseline.len != 0) return package.api_baseline;
    return null;
}

fn resolveDocBaselinePath(path: ?[]const u8, package: PackageManifest) ?[]const u8 {
    if (path) |explicit| return explicit;
    if (package.docs_output.len != 0) return package.docs_output;
    return null;
}

fn resolveOutputPath(path: ?[]const u8, package_default: []const u8) ?[]const u8 {
    if (path) |explicit| return explicit;
    if (package_default.len != 0) return package_default;
    return null;
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

fn formatCheckPackage(allocator: std.mem.Allocator, package: PackageManifest) !usize {
    var changed: usize = 0;

    for (packageFormatSources(package)) |path| {
        const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(source);

        if (try formatCheckSource(allocator, source)) {
            changed += 1;
            std.debug.print("zpp-package: would change {s}\n", .{path});
        }
    }

    return changed;
}

fn packageFormatSources(package: PackageManifest) []const []const u8 {
    if (package.format_sources.len != 0) return package.format_sources;
    return package.sources;
}

fn formatCheckSource(allocator: std.mem.Allocator, source: []const u8) !bool {
    const formatted = try zpp_fmt.formatSource(allocator, source);
    defer allocator.free(formatted);
    return !std.mem.eql(u8, source, formatted);
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

const Difference = struct {
    line: usize,
    expected: ?[]const u8,
    actual: ?[]const u8,
};

fn firstDifference(expected: []const u8, actual: []const u8) ?Difference {
    const normalized_expected = std.mem.trimRight(u8, expected, " \t\r\n");
    const normalized_actual = std.mem.trimRight(u8, actual, " \t\r\n");

    var expected_lines = std.mem.splitScalar(u8, normalized_expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, normalized_actual, '\n');
    var line: usize = 1;

    while (true) : (line += 1) {
        const expected_line = expected_lines.next();
        const actual_line = actual_lines.next();

        if (expected_line == null and actual_line == null) return null;
        if (expected_line == null or actual_line == null) {
            return .{
                .line = line,
                .expected = expected_line,
                .actual = actual_line,
            };
        }
        if (!std.mem.eql(u8, expected_line.?, actual_line.?)) {
            return .{
                .line = line,
                .expected = expected_line,
                .actual = actual_line,
            };
        }
    }
}

fn printFirstDifference(expected: []const u8, actual: []const u8) void {
    const difference = firstDifference(expected, actual) orelse return;
    std.debug.print("  first difference at line {d}\n", .{difference.line});
    printDifferenceLine("expected", difference.expected);
    printDifferenceLine("actual", difference.actual);
}

fn printDifferenceLine(label: []const u8, line: ?[]const u8) void {
    if (line) |value| {
        std.debug.print("  {s}: {s}\n", .{ label, value });
    } else {
        std.debug.print("  {s}: <end of file>\n", .{label});
    }
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

fn firstMissingManifestLine(baseline: []const u8, actual: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, baseline, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (!manifestContainsLine(actual, line)) return line;
    }
    return null;
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
        \\  "sources": ["one.zpp", "two.zpp"],
        \\  "format_sources": ["one.zpp", "tests/one.zpp"],
        \\  "api_output": "docs/sample.api.jsonl",
        \\  "api_baseline": "docs/sample.api.jsonl",
        \\  "docs_output": "docs/sample-api.md"
        \\}
    ;

    var parsed = try std.json.parseFromSlice(PackageManifest, std.testing.allocator, source, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("sample", parsed.value.name);
    try std.testing.expectEqualStrings("0.1.0", parsed.value.version);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.sources.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.format_sources.len);
    try std.testing.expectEqualStrings("tests/one.zpp", parsed.value.format_sources[1]);
    try std.testing.expectEqualStrings("docs/sample.api.jsonl", parsed.value.api_output);
    try std.testing.expectEqualStrings("docs/sample.api.jsonl", parsed.value.api_baseline);
    try std.testing.expectEqualStrings("docs/sample-api.md", parsed.value.docs_output);
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

test "package defaults resolve output and baseline paths" {
    const package = PackageManifest{
        .name = "sample",
        .sources = &.{},
        .api_output = "docs/sample.api.jsonl",
        .api_baseline = "docs/sample.api.jsonl",
        .docs_output = "docs/sample-api.md",
    };

    try std.testing.expectEqualStrings("docs/sample.api.jsonl", resolveOutputPath(null, package.api_output).?);
    try std.testing.expectEqualStrings("override.jsonl", resolveOutputPath("override.jsonl", package.api_output).?);
    try std.testing.expectEqualStrings("docs/sample-api.md", resolveOutputPath(null, package.docs_output).?);
    try std.testing.expectEqualStrings("docs/sample.api.jsonl", resolveBaselinePath(null, package).?);
    try std.testing.expectEqualStrings("baseline.jsonl", resolveBaselinePath("baseline.jsonl", package).?);
    try std.testing.expectEqualStrings("docs/sample-api.md", resolveDocBaselinePath(null, package).?);
    try std.testing.expectEqualStrings("baseline.md", resolveDocBaselinePath("baseline.md", package).?);
}

test "package format sources default to package sources" {
    const sources = [_][]const u8{ "one.zpp", "two.zpp" };
    const explicit = [_][]const u8{"fmt.zpp"};

    try std.testing.expectEqualSlices([]const u8, &sources, packageFormatSources(.{
        .name = "sample",
        .sources = &sources,
    }));
    try std.testing.expectEqualSlices([]const u8, &explicit, packageFormatSources(.{
        .name = "sample",
        .sources = &sources,
        .format_sources = &explicit,
    }));
}

test "format check source reports formatter drift" {
    try std.testing.expect(!try formatCheckSource(std.testing.allocator, "trait Writer {\n}\n"));
    try std.testing.expect(try formatCheckSource(std.testing.allocator, "trait Writer {  \n}\n"));
}

test "compatible manifest helper catches missing line" {
    const baseline =
        "{\"kind\":\"trait\",\"name\":\"Writer\"}\n" ++
        "{\"kind\":\"function\",\"name\":\"main\"}\n";
    const actual =
        "{\"kind\":\"trait\",\"name\":\"Writer\"}\n";

    try std.testing.expectEqual(@as(usize, 1), countMissingManifestLines(baseline, actual));
    try std.testing.expectEqualStrings("{\"kind\":\"function\",\"name\":\"main\"}", firstMissingManifestLine(baseline, actual).?);
}

test "firstDifference reports changed and missing lines" {
    const changed = firstDifference("one\ntwo\nthree\n", "one\nTWO\nthree\n").?;
    try std.testing.expectEqual(@as(usize, 2), changed.line);
    try std.testing.expectEqualStrings("two", changed.expected.?);
    try std.testing.expectEqualStrings("TWO", changed.actual.?);

    const missing = firstDifference("one\ntwo\n", "one\n").?;
    try std.testing.expectEqual(@as(usize, 2), missing.line);
    try std.testing.expectEqualStrings("two", missing.expected.?);
    try std.testing.expectEqual(@as(?[]const u8, null), missing.actual);
}

test "firstDifference follows manifest equality normalization" {
    try std.testing.expect(firstDifference("one\n\n", "one") == null);
}
