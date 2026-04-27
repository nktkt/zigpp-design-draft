const std = @import("std");

const usage =
    \\usage: zpp-doc <input.zpp> [-o output.md]
    \\
    \\Generate conservative Markdown API notes from Zig++ source.
    \\
;

const FunctionDoc = struct {
    signature: []const u8,
    effects: []const u8 = "",
    bounds: [8][]const u8 = undefined,
    bound_count: usize = 0,
    contracts: [8][]const u8 = undefined,
    contract_count: usize = 0,

    fn addBound(self: *FunctionDoc, bound: []const u8) void {
        if (self.bound_count == self.bounds.len) return;
        self.bounds[self.bound_count] = bound;
        self.bound_count += 1;
    }

    fn addContract(self: *FunctionDoc, contract: []const u8) void {
        if (self.contract_count == self.contracts.len) return;
        self.contracts[self.contract_count] = contract;
        self.contract_count += 1;
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

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stderr().writeAll("zpp-doc: -o requires a path\n");
                std.process.exit(2);
            }
            output_path = args[i];
        } else if (input_path == null) {
            input_path = arg;
        } else {
            try std.fs.File.stderr().writeAll("zpp-doc: unexpected argument\n");
            std.process.exit(2);
        }
    }

    const path = input_path orelse {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(2);
    };

    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(source);

    const markdown = try generateMarkdown(allocator, path, source);
    defer allocator.free(markdown);

    if (output_path) |out_path| {
        try std.fs.cwd().writeFile(.{
            .sub_path = out_path,
            .data = markdown,
        });
    } else {
        try std.fs.File.stdout().writeAll(markdown);
    }
}

pub fn generateMarkdown(allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.writer(allocator).print("# Zig++ API: `{s}`\n\n", .{path});

    var pending_function: ?FunctionDoc = null;
    var in_trait = false;
    var trait_depth: isize = 0;
    var trait_has_methods = false;

    var depth: isize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = stripLineComment(line);
        const trimmed = std.mem.trim(u8, code, " \t\r");
        if (trimmed.len == 0) continue;

        if (in_trait) {
            if (parseFnSignature(trimmed)) |signature| {
                if (!trait_has_methods) {
                    try out.appendSlice(allocator, "\nMethods:\n");
                    trait_has_methods = true;
                }
                try out.writer(allocator).print("- `{s}`\n", .{signature});
            }
            trait_depth += braceDelta(trimmed);
            if (trait_depth <= 0) {
                try out.append(allocator, '\n');
                in_trait = false;
                trait_depth = 0;
                trait_has_methods = false;
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
                try appendFunctionDoc(allocator, &out, function.*);
                pending_function = null;
            }
        }

        if (depth == 0) {
            if (parseTraitName(trimmed)) |name| {
                try out.writer(allocator).print("## Trait `{s}`\n", .{name});
                in_trait = true;
                trait_depth = braceDelta(trimmed);
                trait_has_methods = false;
                if (trait_depth <= 0) {
                    try out.append(allocator, '\n');
                    in_trait = false;
                    trait_depth = 0;
                }
                continue;
            }

            if (parseOwnedStructName(trimmed)) |name| {
                try out.writer(allocator).print("## Owned Struct `{s}`\n\n", .{name});
            }

            if (parseFnSignature(trimmed)) |signature| {
                pending_function = .{ .signature = signature };
                if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                    try appendFunctionDoc(allocator, &out, pending_function.?);
                    pending_function = null;
                }
            }
        }

        depth += braceDelta(trimmed);
        if (depth < 0) depth = 0;
    }

    if (pending_function) |function| {
        try appendFunctionDoc(allocator, &out, function);
    }

    return out.toOwnedSlice(allocator);
}

fn appendFunctionDoc(allocator: std.mem.Allocator, out: *std.ArrayList(u8), function: FunctionDoc) !void {
    try out.writer(allocator).print("## Function `{s}`\n", .{functionName(function.signature)});
    try out.writer(allocator).print("\n```zig\n{s}\n```\n", .{function.signature});

    if (function.effects.len != 0) {
        try out.writer(allocator).print("\nEffects: `{s}`\n", .{function.effects});
    }

    if (function.bound_count != 0) {
        try out.appendSlice(allocator, "\nBounds:\n");
        var i: usize = 0;
        while (i < function.bound_count) : (i += 1) {
            try out.writer(allocator).print("- `{s}`\n", .{function.bounds[i]});
        }
    }

    if (function.contract_count != 0) {
        try out.appendSlice(allocator, "\nContracts:\n");
        var i: usize = 0;
        while (i < function.contract_count) : (i += 1) {
            try out.writer(allocator).print("- `{s}`\n", .{function.contracts[i]});
        }
    }

    try out.append(allocator, '\n');
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

test "generateMarkdown documents traits functions effects and contracts" {
    const source =
        \\trait Writer {
        \\    fn write(self, bytes: []const u8) !usize;
        \\}
        \\
        \\owned struct FileWriter {
        \\}
        \\
        \\fn hashBytes(bytes: []const u8) u64
        \\    effects(.noalloc, .noio)
        \\    where T: Hashable
        \\    ensures(result > 0)
        \\{
        \\    return 1;
        \\}
    ;

    const markdown = try generateMarkdown(std.testing.allocator, "sample.zpp", source);
    defer std.testing.allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Trait `Writer`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- `fn write(self, bytes: []const u8) !usize;`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Owned Struct `FileWriter`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Function `hashBytes`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "Effects: `effects(.noalloc, .noio)`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- `where T: Hashable`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- `ensures(result > 0)`") != null);
}
