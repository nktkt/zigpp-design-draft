const std = @import("std");

const usage =
    \\usage: zpp-migrate [--check] <file.zig|file.zpp>...
    \\
    \\Conservatively rewrites adjacent Zig deinit patterns into Zig++ using.
    \\Only this exact ownership pattern is migrated:
    \\
    \\    var name = expr;
    \\    defer name.deinit();
    \\
;

const Line = struct {
    text: []const u8,
    had_newline: bool,
};

const VarDecl = struct {
    indent: []const u8,
    name: []const u8,
    expr: []const u8,
};

const DeinitStmt = struct {
    indent: []const u8,
    name: []const u8,
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

    var check_only = false;
    var path_count: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try writeFileFmt(allocator, std.fs.File.stderr(), "zpp-migrate: unknown option: {s}\n", .{arg});
            std.process.exit(2);
        } else {
            path_count += 1;
        }
    }

    if (path_count == 0) {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(2);
    }

    var changed_any = false;
    i = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-")) continue;

        const changed = try migrateFile(allocator, arg, check_only);
        if (changed) {
            changed_any = true;
            if (check_only) {
                try writeFileFmt(allocator, std.fs.File.stdout(), "zpp-migrate: would change {s}\n", .{arg});
            }
        }
    }

    if (check_only and changed_any) {
        std.process.exit(1);
    }
}

fn writeFileFmt(allocator: std.mem.Allocator, file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try file.writeAll(message);
}

fn migrateFile(allocator: std.mem.Allocator, path: []const u8, check_only: bool) !bool {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(source);

    const migrated = try migrateSource(allocator, source);
    defer allocator.free(migrated);

    if (std.mem.eql(u8, source, migrated)) return false;
    if (!check_only) {
        try std.fs.cwd().writeFile(.{
            .sub_path = path,
            .data = migrated,
        });
    }
    return true;
}

pub fn migrateSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(allocator);

    var index: usize = 0;
    while (index < source.len) {
        const line_start = index;
        while (index < source.len and source[index] != '\n') : (index += 1) {}

        const line_end = index;
        const had_newline = index < source.len;
        if (had_newline) index += 1;

        try lines.append(allocator, .{
            .text = source[line_start..line_end],
            .had_newline = had_newline,
        });
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_index: usize = 0;
    while (line_index < lines.items.len) {
        if (line_index + 1 < lines.items.len) {
            if (parseVarDecl(lines.items[line_index].text)) |var_decl| {
                if (parseDeinitStmt(lines.items[line_index + 1].text)) |deinit_stmt| {
                    if (std.mem.eql(u8, var_decl.indent, deinit_stmt.indent) and
                        std.mem.eql(u8, var_decl.name, deinit_stmt.name))
                    {
                        try appendUsing(allocator, &out, var_decl, lines.items[line_index + 1].had_newline);
                        line_index += 2;
                        continue;
                    }
                }
            }
        }

        try appendLine(allocator, &out, lines.items[line_index]);
        line_index += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn appendUsing(allocator: std.mem.Allocator, out: *std.ArrayList(u8), var_decl: VarDecl, had_newline: bool) !void {
    try out.appendSlice(allocator, var_decl.indent);
    try out.appendSlice(allocator, "using ");
    try out.appendSlice(allocator, var_decl.name);
    try out.appendSlice(allocator, " = ");
    try out.appendSlice(allocator, var_decl.expr);
    try out.append(allocator, ';');
    if (had_newline) {
        try out.append(allocator, '\n');
    }
}

fn appendLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: Line) !void {
    try out.appendSlice(allocator, line.text);
    if (line.had_newline) {
        try out.append(allocator, '\n');
    }
}

fn parseVarDecl(raw_line: []const u8) ?VarDecl {
    const line = trimCarriageReturn(raw_line);
    const indent_len = indentationLen(line);
    const indent = line[0..indent_len];
    var rest = line[indent_len..];

    if (!std.mem.startsWith(u8, rest, "var ")) return null;
    rest = std.mem.trimLeft(u8, rest["var ".len..], " \t");
    if (rest.len == 0 or !isIdentStart(rest[0])) return null;

    var name_end: usize = 1;
    while (name_end < rest.len and isIdentChar(rest[name_end])) : (name_end += 1) {}
    const name = rest[0..name_end];
    rest = std.mem.trimLeft(u8, rest[name_end..], " \t");

    if (rest.len == 0 or rest[0] != '=') return null;
    rest = std.mem.trim(u8, rest[1..], " \t");

    if (rest.len == 0 or rest[rest.len - 1] != ';') return null;
    const expr = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
    if (expr.len == 0) return null;
    if (std.mem.indexOf(u8, expr, "//") != null) return null;

    return .{
        .indent = indent,
        .name = name,
        .expr = expr,
    };
}

fn parseDeinitStmt(raw_line: []const u8) ?DeinitStmt {
    const line = trimCarriageReturn(raw_line);
    const indent_len = indentationLen(line);
    const indent = line[0..indent_len];
    var rest = line[indent_len..];

    if (!std.mem.startsWith(u8, rest, "defer ")) return null;
    rest = std.mem.trimLeft(u8, rest["defer ".len..], " \t");
    if (rest.len == 0 or !isIdentStart(rest[0])) return null;

    var name_end: usize = 1;
    while (name_end < rest.len and isIdentChar(rest[name_end])) : (name_end += 1) {}
    const name = rest[0..name_end];
    rest = std.mem.trim(u8, rest[name_end..], " \t");

    if (!std.mem.eql(u8, rest, ".deinit();")) return null;
    return .{
        .indent = indent,
        .name = name,
    };
}

fn trimCarriageReturn(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

fn indentationLen(line: []const u8) usize {
    var len: usize = 0;
    while (len < line.len and (line[len] == ' ' or line[len] == '\t')) : (len += 1) {}
    return len;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "migrateSource converts adjacent var and defer deinit" {
    const source =
        \\pub fn main() !void {
        \\    var file = try File.open("log.txt");
        \\    defer file.deinit();
        \\    try file.writeAll("hello");
        \\}
        \\
    ;

    const migrated = try migrateSource(std.testing.allocator, source);
    defer std.testing.allocator.free(migrated);

    try std.testing.expectEqualStrings(
        \\pub fn main() !void {
        \\    using file = try File.open("log.txt");
        \\    try file.writeAll("hello");
        \\}
        \\
    , migrated);
}

test "migrateSource leaves close defer and non-adjacent deinit untouched" {
    const source =
        \\pub fn main() void {
        \\    var file = open();
        \\    defer file.close();
        \\    var buf = init();
        \\
        \\    defer buf.deinit();
        \\}
        \\
    ;

    const migrated = try migrateSource(std.testing.allocator, source);
    defer std.testing.allocator.free(migrated);

    try std.testing.expectEqualStrings(source, migrated);
}

test "migrateSource requires matching indentation and name" {
    const source =
        \\pub fn main() void {
        \\    var a = init();
        \\        defer a.deinit();
        \\    var b = init();
        \\    defer c.deinit();
        \\}
        \\
    ;

    const migrated = try migrateSource(std.testing.allocator, source);
    defer std.testing.allocator.free(migrated);

    try std.testing.expectEqualStrings(source, migrated);
}
