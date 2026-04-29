const std = @import("std");
const zpp = @import("zpp");
const zpp_api = @import("zpp_api.zig");
const zpp_doc = @import("zpp_doc.zig");
const zpp_fmt = @import("zpp_fmt.zig");

const usage =
    \\usage: zpp-package <package.json> (--validate | --audit | --fmt | --fmt-check | --refresh | --check | --api [-o output.jsonl] | --doc [-o output.md] | --doc-check [baseline.md] | --api-check [baseline.jsonl] | --api-check-compatible [baseline.jsonl]) [--deny-warnings]
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
    validate,
    audit,
    fmt,
    fmt_check,
    refresh,
    check,
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
        } else if (std.mem.eql(u8, arg, "--validate")) {
            try setCommand(&command, .validate);
        } else if (std.mem.eql(u8, arg, "--audit")) {
            try setCommand(&command, .audit);
        } else if (std.mem.eql(u8, arg, "--fmt")) {
            try setCommand(&command, .fmt);
        } else if (std.mem.eql(u8, arg, "--fmt-check")) {
            try setCommand(&command, .fmt_check);
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            try setCommand(&command, .refresh);
        } else if (std.mem.eql(u8, arg, "--check")) {
            try setCommand(&command, .check);
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
        .validate => {
            const result = validatePackage(package);
            printValidationSummary(package.name, result);
            if (validationFails(result)) {
                std.process.exit(1);
            }
        },
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
        .fmt => {
            const changed = try formatPackage(allocator, package, .write);
            std.debug.print("zpp-package fmt {s}: {d} file(s) formatted\n", .{ package.name, changed });
        },
        .fmt_check => {
            const changed = try formatPackage(allocator, package, .check);
            if (changed != 0) {
                std.debug.print("zpp-package fmt-check {s}: {d} file(s) would change\n", .{ package.name, changed });
                std.process.exit(1);
            }
        },
        .refresh => {
            const validation = validatePackage(package);
            if (validationFails(validation)) {
                printValidationSummary(package.name, validation);
                std.process.exit(1);
            }
            const result = try refreshPackage(allocator, package);
            std.debug.print("zpp-package refresh {s}: {d} file(s) formatted, api={s}, docs={s}\n", .{
                package.name,
                result.formatted,
                enabledLabel(result.wrote_api),
                enabledLabel(result.wrote_docs),
            });
        },
        .check => {
            const result = try checkPackage(allocator, package);
            std.debug.print("zpp-package check {s}: manifest={s}, fmt={d}, {d} error(s), {d} warning(s), {d} note(s), api={s}, docs={s}\n", .{
                package.name,
                passLabel(!validationFails(result.validation)),
                result.format_changes,
                result.diagnostics.errors,
                result.diagnostics.warnings,
                result.diagnostics.notes,
                passLabel(result.api_ok),
                passLabel(result.docs_ok),
            });
            if (packageCheckFails(result, deny_warnings)) {
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
            if (!try checkPackageDocs(allocator, baseline_path, package)) {
                std.process.exit(1);
            }
        },
        .api_check => {
            if (!try checkPackageApi(allocator, baseline_path, package)) {
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

const FormatMode = enum {
    write,
    check,
};

const RefreshResult = struct {
    formatted: usize,
    wrote_api: bool,
    wrote_docs: bool,
};

const PackageCheckResult = struct {
    validation: ValidationResult,
    format_changes: usize,
    diagnostics: Counts,
    api_ok: bool,
    docs_ok: bool,
};

fn checkPackage(allocator: std.mem.Allocator, package: PackageManifest) !PackageCheckResult {
    const validation = validatePackage(package);
    if (validationFails(validation)) {
        return .{
            .validation = validation,
            .format_changes = 0,
            .diagnostics = .{},
            .api_ok = false,
            .docs_ok = false,
        };
    }

    return .{
        .validation = validation,
        .format_changes = try formatPackage(allocator, package, .check),
        .diagnostics = try auditPackage(allocator, package),
        .api_ok = try checkPackageApi(allocator, null, package),
        .docs_ok = try checkPackageDocs(allocator, null, package),
    };
}

fn packageCheckFails(result: PackageCheckResult, deny_warnings: bool) bool {
    return validationFails(result.validation) or
        result.format_changes != 0 or
        auditFails(result.diagnostics, deny_warnings) or
        !result.api_ok or
        !result.docs_ok;
}

const ValidationResult = struct {
    empty_lists: usize = 0,
    empty_paths: usize = 0,
    absolute_paths: usize = 0,
    parent_paths: usize = 0,
    missing_paths: usize = 0,
    duplicate_entries: usize = 0,
    invalid_extensions: usize = 0,
    invalid_outputs: usize = 0,

    fn errors(self: ValidationResult) usize {
        return self.empty_lists + self.empty_paths + self.absolute_paths + self.parent_paths + self.missing_paths + self.duplicate_entries + self.invalid_extensions + self.invalid_outputs;
    }
};

fn validatePackage(package: PackageManifest) ValidationResult {
    var result = ValidationResult{};
    validateRequiredPathList("sources", package.sources, ".zpp", &result);
    if (package.format_sources.len != 0) {
        validateRequiredPathList("format_sources", package.format_sources, ".zpp", &result);
    }
    validateOutputPath("api_output", package.api_output, ".jsonl", &result);
    validateOutputPath("api_baseline", package.api_baseline, ".jsonl", &result);
    validateOutputPath("docs_output", package.docs_output, ".md", &result);
    return result;
}

fn validateRequiredPathList(label: []const u8, paths: []const []const u8, expected_ext: []const u8, result: *ValidationResult) void {
    if (paths.len == 0) {
        result.empty_lists += 1;
        std.debug.print("zpp-package: {s} must not be empty\n", .{label});
        return;
    }

    for (paths) |path| {
        if (path.len == 0) {
            result.empty_paths += 1;
            std.debug.print("zpp-package: {s} contains an empty path entry\n", .{label});
            continue;
        }

        const unsafe_path = pathIsUnsafeForAccess(path);
        if (pathIsAbsolute(path)) {
            result.absolute_paths += 1;
            std.debug.print("zpp-package: {s} must be repo-relative: {s}\n", .{ label, path });
        }
        if (pathHasParentTraversal(path)) {
            result.parent_paths += 1;
            std.debug.print("zpp-package: {s} must not contain '..': {s}\n", .{ label, path });
        }
        if (!pathHasExtension(path, expected_ext)) {
            result.invalid_extensions += 1;
            std.debug.print("zpp-package: {s} invalid extension: {s} (expected {s})\n", .{ label, path, expected_ext });
        }
        if (!unsafe_path and !pathExists(path)) {
            result.missing_paths += 1;
            std.debug.print("zpp-package: {s} missing file: {s}\n", .{ label, path });
        }
    }

    var i: usize = 0;
    while (i < paths.len) : (i += 1) {
        if (paths[i].len == 0) continue;
        if (firstIndexOfPath(paths[0..i], paths[i]) != null) {
            result.duplicate_entries += 1;
            std.debug.print("zpp-package: {s} duplicate entry: {s}\n", .{ label, paths[i] });
        }
    }
}

fn validateOutputPath(label: []const u8, path: []const u8, expected_ext: []const u8, result: *ValidationResult) void {
    if (path.len == 0) return;
    if (pathIsAbsolute(path)) {
        result.absolute_paths += 1;
        std.debug.print("zpp-package: {s} must be repo-relative: {s}\n", .{ label, path });
    }
    if (pathHasParentTraversal(path)) {
        result.parent_paths += 1;
        std.debug.print("zpp-package: {s} must not contain '..': {s}\n", .{ label, path });
    }
    if (pathHasExtension(path, expected_ext)) return;

    result.invalid_outputs += 1;
    std.debug.print("zpp-package: {s} invalid output path: {s} (expected {s})\n", .{ label, path, expected_ext });
}

fn pathIsAbsolute(path: []const u8) bool {
    return std.fs.path.isAbsolutePosix(path) or std.fs.path.isAbsoluteWindows(path);
}

fn pathHasParentTraversal(path: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, path, "/\\");
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

fn pathIsUnsafeForAccess(path: []const u8) bool {
    return pathIsAbsolute(path) or pathHasParentTraversal(path);
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn firstIndexOfPath(paths: []const []const u8, needle: []const u8) ?usize {
    for (paths, 0..) |path, index| {
        if (std.mem.eql(u8, path, needle)) return index;
    }
    return null;
}

fn pathHasExtension(path: []const u8, expected_ext: []const u8) bool {
    return std.mem.endsWith(u8, path, expected_ext);
}

fn countInvalidExtensions(paths: []const []const u8, expected_ext: []const u8) usize {
    var invalid: usize = 0;
    for (paths) |path| {
        if (!pathHasExtension(path, expected_ext)) invalid += 1;
    }
    return invalid;
}

fn countInvalidOutputExtensions(paths: []const []const u8, expected_ext: []const u8) usize {
    var invalid: usize = 0;
    for (paths) |path| {
        if (path.len != 0 and !pathHasExtension(path, expected_ext)) invalid += 1;
    }
    return invalid;
}

fn countAbsolutePaths(paths: []const []const u8) usize {
    var absolute: usize = 0;
    for (paths) |path| {
        if (pathIsAbsolute(path)) absolute += 1;
    }
    return absolute;
}

fn countParentTraversalPaths(paths: []const []const u8) usize {
    var parent_paths: usize = 0;
    for (paths) |path| {
        if (pathHasParentTraversal(path)) parent_paths += 1;
    }
    return parent_paths;
}

fn countEmptyPaths(paths: []const []const u8) usize {
    var empty: usize = 0;
    for (paths) |path| {
        if (path.len == 0) empty += 1;
    }
    return empty;
}

fn countDuplicateEntries(paths: []const []const u8) usize {
    var duplicates: usize = 0;
    var i: usize = 0;
    while (i < paths.len) : (i += 1) {
        if (firstIndexOfPath(paths[0..i], paths[i]) != null) duplicates += 1;
    }
    return duplicates;
}

fn validationFails(result: ValidationResult) bool {
    return result.errors() != 0;
}

fn printValidationSummary(package_name: []const u8, result: ValidationResult) void {
    std.debug.print("zpp-package validate {s}: {d} empty list(s), {d} empty path(s), {d} absolute path(s), {d} parent path(s), {d} missing path(s), {d} duplicate entry(s), {d} invalid extension(s), {d} invalid output(s)\n", .{
        package_name,
        result.empty_lists,
        result.empty_paths,
        result.absolute_paths,
        result.parent_paths,
        result.missing_paths,
        result.duplicate_entries,
        result.invalid_extensions,
        result.invalid_outputs,
    });
}

fn refreshPackage(allocator: std.mem.Allocator, package: PackageManifest) !RefreshResult {
    return .{
        .formatted = try formatPackage(allocator, package, .write),
        .wrote_api = try writeConfiguredPackageApi(allocator, package),
        .wrote_docs = try writeConfiguredPackageDocs(allocator, package),
    };
}

fn writeConfiguredPackageApi(allocator: std.mem.Allocator, package: PackageManifest) !bool {
    const path = resolveOutputPath(null, package.api_output) orelse return false;
    const manifest = try generatePackageApi(allocator, package);
    defer allocator.free(manifest);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = manifest });
    std.debug.print("zpp-package: wrote API manifest {s}\n", .{path});
    return true;
}

fn writeConfiguredPackageDocs(allocator: std.mem.Allocator, package: PackageManifest) !bool {
    const path = resolveOutputPath(null, package.docs_output) orelse return false;
    const markdown = try generatePackageDocs(allocator, package);
    defer allocator.free(markdown);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = markdown });
    std.debug.print("zpp-package: wrote docs {s}\n", .{path});
    return true;
}

fn enabledLabel(enabled: bool) []const u8 {
    return if (enabled) "yes" else "no";
}

fn passLabel(passed: bool) []const u8 {
    return if (passed) "ok" else "fail";
}

fn formatPackage(allocator: std.mem.Allocator, package: PackageManifest, mode: FormatMode) !usize {
    var changed: usize = 0;

    for (packageFormatSources(package)) |path| {
        const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(source);

        const formatted = try zpp_fmt.formatSource(allocator, source);
        defer allocator.free(formatted);

        if (std.mem.eql(u8, source, formatted)) continue;

        changed += 1;
        switch (mode) {
            .check => {
                std.debug.print("zpp-package: would change {s}\n", .{path});
            },
            .write => {
                try std.fs.cwd().writeFile(.{
                    .sub_path = path,
                    .data = formatted,
                });
                std.debug.print("zpp-package: formatted {s}\n", .{path});
            },
        }
    }

    return changed;
}

fn formatPackageSourcesForTest(allocator: std.mem.Allocator, sources: []const []const u8) !usize {
    var changed: usize = 0;
    for (sources) |source| {
        if (try formatCheckSource(allocator, source)) {
            changed += 1;
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

fn checkPackageApi(allocator: std.mem.Allocator, baseline_path: ?[]const u8, package: PackageManifest) !bool {
    const baseline = try readBaseline(allocator, baseline_path, package);
    defer allocator.free(baseline);
    const manifest = try generatePackageApi(allocator, package);
    defer allocator.free(manifest);

    if (manifestsEqual(baseline, manifest)) return true;

    std.debug.print("zpp-package: API manifest differs from {s}\n", .{resolveBaselinePath(baseline_path, package) orelse ""});
    printFirstDifference(baseline, manifest);
    return false;
}

fn checkPackageDocs(allocator: std.mem.Allocator, baseline_path: ?[]const u8, package: PackageManifest) !bool {
    const baseline = try readDocBaseline(allocator, baseline_path, package);
    defer allocator.free(baseline);
    const markdown = try generatePackageDocs(allocator, package);
    defer allocator.free(markdown);

    if (manifestsEqual(baseline, markdown)) return true;

    std.debug.print("zpp-package: docs output differs from {s}\n", .{resolveDocBaselinePath(baseline_path, package) orelse ""});
    printFirstDifference(baseline, markdown);
    return false;
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

test "package check failure policy combines all package checks" {
    try std.testing.expect(!packageCheckFails(.{
        .validation = .{},
        .format_changes = 0,
        .diagnostics = .{},
        .api_ok = true,
        .docs_ok = true,
    }, false));
    try std.testing.expect(packageCheckFails(.{
        .validation = .{ .missing_paths = 1 },
        .format_changes = 0,
        .diagnostics = .{},
        .api_ok = true,
        .docs_ok = true,
    }, false));
    try std.testing.expect(packageCheckFails(.{
        .validation = .{},
        .format_changes = 1,
        .diagnostics = .{},
        .api_ok = true,
        .docs_ok = true,
    }, false));
    try std.testing.expect(packageCheckFails(.{
        .validation = .{},
        .format_changes = 0,
        .diagnostics = .{ .warnings = 1 },
        .api_ok = true,
        .docs_ok = true,
    }, true));
    try std.testing.expect(packageCheckFails(.{
        .validation = .{},
        .format_changes = 0,
        .diagnostics = .{},
        .api_ok = false,
        .docs_ok = true,
    }, false));
    try std.testing.expect(packageCheckFails(.{
        .validation = .{},
        .format_changes = 0,
        .diagnostics = .{},
        .api_ok = true,
        .docs_ok = false,
    }, false));
}

test "manifest duplicate helper counts repeated entries" {
    const paths = [_][]const u8{ "one.zpp", "two.zpp", "one.zpp", "one.zpp" };
    try std.testing.expectEqual(@as(usize, 2), countDuplicateEntries(&paths));
    try std.testing.expectEqual(@as(?usize, 0), firstIndexOfPath(paths[0..2], "one.zpp"));
    try std.testing.expectEqual(@as(?usize, null), firstIndexOfPath(paths[0..2], "missing.zpp"));
}

test "manifest extension helper catches non-zpp paths" {
    const paths = [_][]const u8{ "one.zpp", "two.zig", "three.zpp.md" };
    try std.testing.expect(pathHasExtension("one.zpp", ".zpp"));
    try std.testing.expect(!pathHasExtension("one.zig", ".zpp"));
    try std.testing.expectEqual(@as(usize, 2), countInvalidExtensions(&paths, ".zpp"));
}

test "manifest output extension helper ignores unset outputs" {
    const paths = [_][]const u8{ "docs/api.jsonl", "", "docs/api.md" };
    try std.testing.expectEqual(@as(usize, 1), countInvalidOutputExtensions(&paths, ".jsonl"));
}

test "manifest path helper catches posix and windows absolute paths" {
    const paths = [_][]const u8{ "examples/one.zpp", "/tmp/one.zpp", "C:\\tmp\\one.zpp" };
    try std.testing.expect(!pathIsAbsolute("examples/one.zpp"));
    try std.testing.expect(pathIsAbsolute("/tmp/one.zpp"));
    try std.testing.expect(pathIsAbsolute("C:\\tmp\\one.zpp"));
    try std.testing.expectEqual(@as(usize, 2), countAbsolutePaths(&paths));
}

test "manifest path helper catches parent traversal segments" {
    const paths = [_][]const u8{ "examples/one.zpp", "../one.zpp", "examples/../one.zpp", "examples\\..\\one.zpp", "examples/two..zpp" };
    try std.testing.expect(!pathHasParentTraversal("examples/one.zpp"));
    try std.testing.expect(!pathHasParentTraversal("examples/two..zpp"));
    try std.testing.expect(pathHasParentTraversal("../one.zpp"));
    try std.testing.expect(pathHasParentTraversal("examples/../one.zpp"));
    try std.testing.expect(pathHasParentTraversal("examples\\..\\one.zpp"));
    try std.testing.expectEqual(@as(usize, 3), countParentTraversalPaths(&paths));
}

test "manifest path helper counts empty path entries" {
    const paths = [_][]const u8{ "examples/one.zpp", "", "tests/two.zpp", "" };
    try std.testing.expectEqual(@as(usize, 2), countEmptyPaths(&paths));
}

test "validation failure policy follows validation errors" {
    try std.testing.expect(!validationFails(.{}));
    try std.testing.expect(validationFails(.{ .empty_lists = 1 }));
    try std.testing.expect(validationFails(.{ .empty_paths = 1 }));
    try std.testing.expect(validationFails(.{ .absolute_paths = 1 }));
    try std.testing.expect(validationFails(.{ .parent_paths = 1 }));
    try std.testing.expect(validationFails(.{ .missing_paths = 1 }));
    try std.testing.expect(validationFails(.{ .duplicate_entries = 1 }));
    try std.testing.expect(validationFails(.{ .invalid_extensions = 1 }));
    try std.testing.expect(validationFails(.{ .invalid_outputs = 1 }));
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

test "enabled label is stable for command summaries" {
    try std.testing.expectEqualStrings("yes", enabledLabel(true));
    try std.testing.expectEqualStrings("no", enabledLabel(false));
}

test "pass label is stable for command summaries" {
    try std.testing.expectEqualStrings("ok", passLabel(true));
    try std.testing.expectEqualStrings("fail", passLabel(false));
}

test "package format source counting follows formatter drift" {
    const sources = [_][]const u8{
        "trait Writer {\n}\n",
        "trait Writer {  \n}\n",
    };
    try std.testing.expectEqual(@as(usize, 1), try formatPackageSourcesForTest(std.testing.allocator, &sources));
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
