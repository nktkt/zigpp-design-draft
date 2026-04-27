const std = @import("std");

const usage =
    \\usage: zpp-fmt <file.zpp>...
    \\
    \\Conservatively formats Zig++ source in place.
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

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        }
        try formatFile(allocator, arg);
    }
}

fn formatFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(source);

    const formatted = try formatSource(allocator, source);
    defer allocator.free(formatted);

    if (std.mem.eql(u8, source, formatted)) return;
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = formatted,
    });
}

pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var pending_blank = false;
    var wrote_any = false;

    while (lines.next()) |line| {
        const trimmed_right = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed_right.len == 0) {
            pending_blank = wrote_any;
            continue;
        }

        if (pending_blank) {
            try out.append(allocator, '\n');
            pending_blank = false;
        }

        try out.appendSlice(allocator, trimmed_right);
        try out.append(allocator, '\n');
        wrote_any = true;
    }

    return out.toOwnedSlice(allocator);
}

test "formatSource trims trailing whitespace and collapses blank runs" {
    const source =
        "trait Writer {   \n" ++
        "\tfn write(self) void;\t\n" ++
        "\n" ++
        "\n" ++
        "}\n" ++
        "\n";

    const formatted = try formatSource(std.testing.allocator, source);
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings(
        "trait Writer {\n" ++
            "\tfn write(self) void;\n" ++
            "\n" ++
            "}\n",
        formatted,
    );
}

test "formatSource keeps empty file empty" {
    const formatted = try formatSource(std.testing.allocator, "");
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("", formatted);
}
