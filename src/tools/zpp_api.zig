const std = @import("std");

const usage =
    \\usage: zpp-api <input.zpp>... [-o output.jsonl] [--check baseline.jsonl] [--check-compatible baseline.jsonl]
    \\
    \\Generate a conservative Zig++ public API manifest as JSON Lines.
    \\--check requires an exact manifest match.
    \\--check-compatible permits added API lines but fails on removed baseline lines.
    \\
;

const FunctionEntry = struct {
    name: []const u8,
    signature: []const u8,
    effects: []const u8 = "",
    bounds: [8][]const u8 = undefined,
    bound_count: usize = 0,
    contracts: [8][]const u8 = undefined,
    contract_count: usize = 0,

    fn addBound(self: *FunctionEntry, bound: []const u8) void {
        if (self.bound_count == self.bounds.len) return;
        self.bounds[self.bound_count] = bound;
        self.bound_count += 1;
    }

    fn addContract(self: *FunctionEntry, contract: []const u8) void {
        if (self.contract_count == self.contracts.len) return;
        self.contracts[self.contract_count] = contract;
        self.contract_count += 1;
    }
};

pub const ManifestSource = struct {
    path: []const u8,
    source: []const u8,
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

    var output_path: ?[]const u8 = null;
    var check_path: ?[]const u8 = null;
    var check_compatible_path: ?[]const u8 = null;
    var input_count: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stderr().writeAll("zpp-api: -o requires a path\n");
                std.process.exit(2);
            }
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--check")) {
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stderr().writeAll("zpp-api: --check requires a baseline path\n");
                std.process.exit(2);
            }
            check_path = args[i];
        } else if (std.mem.eql(u8, arg, "--check-compatible")) {
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stderr().writeAll("zpp-api: --check-compatible requires a baseline path\n");
                std.process.exit(2);
            }
            check_compatible_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("zpp-api: unknown option: {s}\n", .{arg});
            std.process.exit(2);
        } else {
            input_count += 1;
        }
    }

    if (input_count == 0) {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(2);
    }

    if (check_path != null and check_compatible_path != null) {
        try std.fs.File.stderr().writeAll("zpp-api: choose either --check or --check-compatible\n");
        std.process.exit(2);
    }

    const manifest = try generateManifestFromArgs(allocator, args[1..]);
    defer allocator.free(manifest);

    if (check_path) |baseline_path| {
        const baseline = try std.fs.cwd().readFileAlloc(allocator, baseline_path, 16 * 1024 * 1024);
        defer allocator.free(baseline);

        if (!manifestsEqual(baseline, manifest)) {
            std.debug.print("zpp-api: API manifest differs from {s}\n", .{baseline_path});
            printManifestDiff(baseline, manifest);
            std.process.exit(1);
        }
        return;
    }

    if (check_compatible_path) |baseline_path| {
        const baseline = try std.fs.cwd().readFileAlloc(allocator, baseline_path, 16 * 1024 * 1024);
        defer allocator.free(baseline);

        const missing = countMissingManifestLines(baseline, manifest);
        if (missing != 0) {
            std.debug.print("zpp-api: incompatible API manifest: {d} baseline line(s) missing from generated manifest\n", .{
                missing,
            });
            printRemovedManifestLines(baseline, manifest);
            std.process.exit(1);
        }
        return;
    }

    if (output_path) |out_path| {
        try std.fs.cwd().writeFile(.{
            .sub_path = out_path,
            .data = manifest,
        });
    } else {
        try std.fs.File.stdout().writeAll(manifest);
    }
}

fn generateManifestFromArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or
            std.mem.eql(u8, arg, "--check") or
            std.mem.eql(u8, arg, "--check-compatible"))
        {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) continue;

        const source = try std.fs.cwd().readFileAlloc(allocator, arg, 16 * 1024 * 1024);
        defer allocator.free(source);

        const file_manifest = try generateManifest(allocator, arg, source);
        defer allocator.free(file_manifest);
        try out.appendSlice(allocator, file_manifest);
    }

    return out.toOwnedSlice(allocator);
}

pub fn generatePackageManifest(allocator: std.mem.Allocator, sources: []const ManifestSource) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (sources) |source| {
        const manifest = try generateManifest(allocator, source.path, source.source);
        defer allocator.free(manifest);
        try out.appendSlice(allocator, manifest);
    }

    return out.toOwnedSlice(allocator);
}

pub fn generateManifest(allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var pending_function: ?FunctionEntry = null;
    var in_trait = false;
    var trait_depth: isize = 0;
    var trait_name: []const u8 = "";

    var depth: isize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = stripLineComment(line);
        const trimmed = std.mem.trim(u8, code, " \t\r");
        if (trimmed.len == 0) continue;

        if (in_trait) {
            if (parseFnSignature(trimmed)) |signature| {
                try appendTraitMethodEntry(allocator, &out, path, trait_name, signature);
            }
            trait_depth += braceDelta(trimmed);
            if (trait_depth <= 0) {
                in_trait = false;
                trait_depth = 0;
                trait_name = "";
            }
            continue;
        }

        if (pending_function) |*function| {
            if (std.mem.startsWith(u8, trimmed, "effects(")) {
                function.effects = trimmed;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "where ")) {
                function.addBound(trimmed);
                continue;
            }
            if (isContractLine(trimmed)) {
                function.addContract(trimmed);
                continue;
            }
            if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                try appendFunctionEntry(allocator, &out, path, function.*);
                pending_function = null;
            }
        }

        if (depth == 0) {
            if (parseTraitName(trimmed)) |name| {
                try appendNamedEntry(allocator, &out, path, "trait", name);
                in_trait = true;
                trait_depth = braceDelta(trimmed);
                trait_name = name;
                if (trait_depth <= 0) {
                    in_trait = false;
                    trait_depth = 0;
                    trait_name = "";
                }
                continue;
            }

            if (parseOwnedStructName(trimmed)) |name| {
                try appendNamedEntry(allocator, &out, path, "owned_struct", name);
            }

            if (parsePubFnSignature(trimmed)) |signature| {
                pending_function = .{
                    .name = functionName(signature),
                    .signature = signature,
                };
                if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                    try appendFunctionEntry(allocator, &out, path, pending_function.?);
                    pending_function = null;
                }
            }
        }

        depth += braceDelta(trimmed);
        if (depth < 0) depth = 0;
    }

    if (pending_function) |function| {
        try appendFunctionEntry(allocator, &out, path, function);
    }

    return out.toOwnedSlice(allocator);
}

fn appendNamedEntry(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    kind: []const u8,
    name: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"kind\":");
    try appendJsonString(allocator, out, kind);
    try out.appendSlice(allocator, ",\"path\":");
    try appendJsonString(allocator, out, path);
    try out.appendSlice(allocator, ",\"name\":");
    try appendJsonString(allocator, out, name);
    try out.appendSlice(allocator, "}\n");
}

fn appendTraitMethodEntry(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    owner: []const u8,
    signature: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"kind\":\"trait_method\",\"path\":");
    try appendJsonString(allocator, out, path);
    try out.appendSlice(allocator, ",\"owner\":");
    try appendJsonString(allocator, out, owner);
    try out.appendSlice(allocator, ",\"name\":");
    try appendJsonString(allocator, out, functionName(signature));
    try out.appendSlice(allocator, ",\"signature\":");
    try appendJsonString(allocator, out, signature);
    try out.appendSlice(allocator, "}\n");
}

fn appendFunctionEntry(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    function: FunctionEntry,
) !void {
    try out.appendSlice(allocator, "{\"kind\":\"function\",\"path\":");
    try appendJsonString(allocator, out, path);
    try out.appendSlice(allocator, ",\"name\":");
    try appendJsonString(allocator, out, function.name);
    try out.appendSlice(allocator, ",\"signature\":");
    try appendJsonString(allocator, out, function.signature);
    try out.appendSlice(allocator, ",\"effects\":");
    try appendJsonString(allocator, out, function.effects);
    try out.appendSlice(allocator, ",\"bounds\":");
    try appendStringArray(allocator, out, function.bounds[0..function.bound_count]);
    try out.appendSlice(allocator, ",\"contracts\":");
    try appendStringArray(allocator, out, function.contracts[0..function.contract_count]);
    try out.appendSlice(allocator, "}\n");
}

fn appendStringArray(allocator: std.mem.Allocator, out: *std.ArrayList(u8), items: []const []const u8) !void {
    try out.append(allocator, '[');
    for (items, 0..) |item, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, item);
    }
    try out.append(allocator, ']');
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
        const line = normalizeManifestLine(raw_line);
        if (line.len == 0) continue;
        if (!manifestContainsLine(actual, line)) missing += 1;
    }
    return missing;
}

fn countAddedManifestLines(baseline: []const u8, actual: []const u8) usize {
    var added: usize = 0;
    var lines = std.mem.splitScalar(u8, actual, '\n');
    while (lines.next()) |raw_line| {
        const line = normalizeManifestLine(raw_line);
        if (line.len == 0) continue;
        if (!manifestContainsLine(baseline, line)) added += 1;
    }
    return added;
}

fn manifestContainsLine(manifest: []const u8, needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = normalizeManifestLine(raw_line);
        if (std.mem.eql(u8, line, needle)) return true;
    }
    return false;
}

fn normalizeManifestLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, " \t\r");
}

fn printManifestDiff(baseline: []const u8, actual: []const u8) void {
    printRemovedManifestLines(baseline, actual);
    printAddedManifestLines(baseline, actual);
}

fn printRemovedManifestLines(baseline: []const u8, actual: []const u8) void {
    var lines = std.mem.splitScalar(u8, baseline, '\n');
    while (lines.next()) |raw_line| {
        const line = normalizeManifestLine(raw_line);
        if (line.len == 0) continue;
        if (!manifestContainsLine(actual, line)) {
            std.debug.print("- {s}\n", .{line});
        }
    }
}

fn printAddedManifestLines(baseline: []const u8, actual: []const u8) void {
    var lines = std.mem.splitScalar(u8, actual, '\n');
    while (lines.next()) |raw_line| {
        const line = normalizeManifestLine(raw_line);
        if (line.len == 0) continue;
        if (!manifestContainsLine(baseline, line)) {
            std.debug.print("+ {s}\n", .{line});
        }
    }
}

fn stripLineComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "//")) |comment_start| {
        return line[0..comment_start];
    }
    return line;
}

fn parseTraitName(line: []const u8) ?[]const u8 {
    return parseNamedDecl(line, "trait ");
}

fn parseOwnedStructName(line: []const u8) ?[]const u8 {
    return parseNamedDecl(line, "owned struct ");
}

fn parseNamedDecl(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = std.mem.trimLeft(u8, line[prefix.len..], " \t");
    if (rest.len == 0 or !isIdentStart(rest[0])) return null;

    var end: usize = 1;
    while (end < rest.len and isIdentChar(rest[end])) : (end += 1) {}
    return rest[0..end];
}

fn parseFnSignature(line: []const u8) ?[]const u8 {
    if (!(std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub fn "))) return null;
    return std.mem.trimRight(u8, line, " \t{");
}

fn parsePubFnSignature(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "pub fn ")) return null;
    return std.mem.trimRight(u8, line, " \t{");
}

fn functionName(signature: []const u8) []const u8 {
    const rest = if (std.mem.startsWith(u8, signature, "pub fn "))
        signature["pub fn ".len..]
    else if (std.mem.startsWith(u8, signature, "fn "))
        signature["fn ".len..]
    else
        signature;

    var end: usize = 0;
    while (end < rest.len and isIdentChar(rest[end])) : (end += 1) {}
    return rest[0..end];
}

fn isContractLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "requires(") or
        std.mem.startsWith(u8, line, "invariant(") or
        std.mem.startsWith(u8, line, "ensures(");
}

fn braceDelta(line: []const u8) isize {
    var delta: isize = 0;
    for (line) |c| {
        if (c == '{') delta += 1;
        if (c == '}') delta -= 1;
    }
    return delta;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hexDigit(c >> 4));
                    try out.append(allocator, hexDigit(c & 0x0f));
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

test "generateManifest emits public API json lines" {
    const source =
        \\trait Writer {
        \\    fn write(self, bytes: []const u8) !usize;
        \\}
        \\
        \\owned struct FileWriter {
        \\}
        \\
        \\fn helper() void {}
        \\
        \\pub fn emit(w: impl Writer, msg: []const u8) !void
        \\    effects(.io)
        \\    where T: Writer
        \\    requires(msg.len > 0)
        \\{
        \\    _ = try w.write(msg);
        \\}
    ;

    const manifest = try generateManifest(std.testing.allocator, "sample.zpp", source);
    defer std.testing.allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"kind\":\"trait\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"kind\":\"trait_method\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"kind\":\"owned_struct\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\":\"emit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"effects\":\"effects(.io)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"bounds\":[\"where T: Writer\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"contracts\":[\"requires(msg.len > 0)\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\":\"helper\"") == null);
}

test "generatePackageManifest concatenates multiple source manifests" {
    const sources = [_]ManifestSource{
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

    const manifest = try generatePackageManifest(std.testing.allocator, &sources);
    defer std.testing.allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"path\":\"one.zpp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"path\":\"two.zpp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"kind\":\"trait\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"kind\":\"function\"") != null);
}

test "manifestsEqual ignores trailing whitespace" {
    try std.testing.expect(manifestsEqual("{\"kind\":\"trait\"}\n", "{\"kind\":\"trait\"}\n\n"));
    try std.testing.expect(!manifestsEqual("{\"kind\":\"trait\"}\n", "{\"kind\":\"function\"}\n"));
}

test "compatible manifest check permits additions" {
    const baseline =
        "{\"kind\":\"trait\",\"name\":\"Writer\"}\n" ++
        "{\"kind\":\"function\",\"name\":\"main\"}\n";
    const actual =
        "{\"kind\":\"trait\",\"name\":\"Writer\"}\n" ++
        "{\"kind\":\"function\",\"name\":\"main\"}\n" ++
        "{\"kind\":\"function\",\"name\":\"extra\"}\n";

    try std.testing.expectEqual(@as(usize, 0), countMissingManifestLines(baseline, actual));
    try std.testing.expectEqual(@as(usize, 1), countAddedManifestLines(baseline, actual));
}

test "compatible manifest check catches removals" {
    const baseline =
        "{\"kind\":\"trait\",\"name\":\"Writer\"}\n" ++
        "{\"kind\":\"function\",\"name\":\"main\"}\n";
    const actual =
        "{\"kind\":\"trait\",\"name\":\"Writer\"}\n";

    try std.testing.expectEqual(@as(usize, 1), countMissingManifestLines(baseline, actual));
    try std.testing.expectEqual(@as(usize, 0), countAddedManifestLines(baseline, actual));
}
