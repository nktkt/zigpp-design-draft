const std = @import("std");
const zpp = @import("zpp");

const tmp_root = "/tmp/zpp-compile-fixtures";
const tmp_cache = "/tmp/zpp-compile-fixtures/cache";
const tmp_global_cache = "/tmp/zpp-compile-fixtures/global-cache";
const tmp_bin = "/tmp/zpp-compile-fixtures/bin";

const CompileMode = enum {
    exe,
    test_file,
};

const CompileCase = struct {
    source_path: []const u8,
    generated_path: []const u8,
    mode: CompileMode,
};

const CompileFailCase = struct {
    source_path: []const u8,
    generated_path: []const u8,
    expected_stderr: []const u8,
};

const compile_cases = [_]CompileCase{
    .{
        .source_path = "examples/contracts.zpp",
        .generated_path = "contracts.zig",
        .mode = .exe,
    },
    .{
        .source_path = "examples/derive_user.zpp",
        .generated_path = "derive_user.zig",
        .mode = .exe,
    },
    .{
        .source_path = "examples/hello_trait.zpp",
        .generated_path = "hello_trait.zig",
        .mode = .exe,
    },
    .{
        .source_path = "examples/noalloc_hash.zpp",
        .generated_path = "noalloc_hash.zig",
        .mode = .exe,
    },
    .{
        .source_path = "examples/owned_buffer.zpp",
        .generated_path = "owned_buffer.zig",
        .mode = .exe,
    },
    .{
        .source_path = "examples/where_constraints.zpp",
        .generated_path = "where_constraints.zig",
        .mode = .exe,
    },
    .{
        .source_path = "examples/dyn_plugin.zpp",
        .generated_path = "dyn_plugin.zig",
        .mode = .test_file,
    },
};

const compile_fail_cases = [_]CompileFailCase{
    .{
        .source_path = "tests/compile/missing_trait_method.zpp",
        .generated_path = "missing_trait_method.zig",
        .expected_stderr = "type does not implement Writer: missing method write",
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    try std.fs.makeDirAbsolute(tmp_root);
    try std.fs.makeDirAbsolute(tmp_cache);
    try std.fs.makeDirAbsolute(tmp_global_cache);
    try std.fs.makeDirAbsolute(tmp_bin);
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var tmp_dir = try std.fs.openDirAbsolute(tmp_root, .{});
    defer tmp_dir.close();

    for (compile_cases) |case| {
        const generated = try lowerCase(allocator, tmp_dir, case.source_path, case.generated_path);
        defer allocator.free(generated);

        const result = try runZig(allocator, case.mode, generated, case.generated_path);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (!termSucceeded(result.term)) {
            std.debug.print("compile fixture failed: {s}\n{s}\n", .{ case.source_path, result.stderr });
            return error.CompileFixtureFailed;
        }
    }

    for (compile_fail_cases) |case| {
        const generated = try lowerCase(allocator, tmp_dir, case.source_path, case.generated_path);
        defer allocator.free(generated);

        const result = try runZig(allocator, .exe, generated, case.generated_path);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (termSucceeded(result.term)) {
            std.debug.print("compile-fail fixture unexpectedly succeeded: {s}\n", .{case.source_path});
            return error.CompileFixtureFailed;
        }
        if (std.mem.indexOf(u8, result.stderr, case.expected_stderr) == null) {
            std.debug.print(
                "compile-fail fixture did not include expected stderr: {s}\nexpected: {s}\nstderr:\n{s}\n",
                .{ case.source_path, case.expected_stderr, result.stderr },
            );
            return error.CompileFixtureFailed;
        }
    }
}

fn lowerCase(
    allocator: std.mem.Allocator,
    tmp_dir: std.fs.Dir,
    source_path: []const u8,
    generated_path: []const u8,
) ![]u8 {
    const source = try std.fs.cwd().readFileAlloc(allocator, source_path, 16 * 1024 * 1024);
    defer allocator.free(source);

    const diags = try zpp.sema.checkSource(allocator, source);
    defer allocator.free(diags);
    if (diags.len != 0) {
        std.debug.print("compile fixture has zpp diagnostics: {s}\n", .{source_path});
        for (diags) |diag| {
            std.debug.print("{d}:{d}: {s}\n", .{ diag.line, diag.column, diag.message });
        }
        return error.CompileFixtureFailed;
    }

    const lowered = try zpp.lowerSource(allocator, source);
    defer allocator.free(lowered);
    try tmp_dir.writeFile(.{
        .sub_path = generated_path,
        .data = lowered,
    });
    return std.fs.path.join(allocator, &.{ tmp_root, generated_path });
}

fn runZig(
    allocator: std.mem.Allocator,
    mode: CompileMode,
    generated_path: []const u8,
    generated_name: []const u8,
) !std.process.Child.RunResult {
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}/out-{s}", .{ tmp_bin, generated_name });
    defer allocator.free(emit_arg);
    const root_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{generated_path});
    defer allocator.free(root_arg);

    return switch (mode) {
        .exe => std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "zig",
                "build-exe",
                "--dep",
                "zpp",
                root_arg,
                "-Mzpp=src/lib.zig",
                "--cache-dir",
                tmp_cache,
                "--global-cache-dir",
                tmp_global_cache,
                emit_arg,
            },
            .max_output_bytes = 256 * 1024,
        }),
        .test_file => std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "zig",
                "test",
                "--dep",
                "zpp",
                root_arg,
                "-Mzpp=src/lib.zig",
                "--cache-dir",
                tmp_cache,
                "--global-cache-dir",
                tmp_global_cache,
            },
            .max_output_bytes = 256 * 1024,
        }),
    };
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
