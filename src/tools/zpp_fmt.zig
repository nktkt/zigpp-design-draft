const std = @import("std");

const usage =
    \\usage: zpp-fmt [--check] <file.zpp>...
    \\
    \\Conservatively formats Zig++ source in place.
    \\--check reports files that would change without writing them.
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
            std.debug.print("zpp-fmt: unknown option: {s}\n", .{arg});
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

        const changed = try formatFile(allocator, arg, check_only);
        if (changed) {
            changed_any = true;
            if (check_only) {
                std.debug.print("zpp-fmt: would change {s}\n", .{arg});
            }
        }
    }

    if (check_only and checkFails(changed_any)) {
        std.process.exit(1);
    }
}

fn formatFile(allocator: std.mem.Allocator, path: []const u8, check_only: bool) !bool {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(source);

    const formatted = try formatSource(allocator, source);
    defer allocator.free(formatted);

    if (std.mem.eql(u8, source, formatted)) return false;
    if (!check_only) {
        try std.fs.cwd().writeFile(.{
            .sub_path = path,
            .data = formatted,
        });
    }
    return true;
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

test "check mode failure policy follows changed files" {
    try std.testing.expect(!checkFails(false));
    try std.testing.expect(checkFails(true));
}

fn checkFails(changed_any: bool) bool {
    return changed_any;
}
