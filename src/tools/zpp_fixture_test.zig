const std = @import("std");
const zpp = @import("zpp");

const DiagnosticCase = struct {
    path: []const u8,
    expected: []const u8,
};

const CleanCase = struct {
    path: []const u8,
};

const LoweringCase = struct {
    path: []const u8,
    expected: []const []const u8,
};

const ApiCase = struct {
    path: []const u8,
    expected: []const []const u8,
};

const diagnostic_cases = [_]DiagnosticCase{
    .{
        .path = "tests/diagnostics/missing_deinit.zpp",
        .expected = "owned value must be paired",
    },
    .{
        .path = "tests/diagnostics/double_deinit.zpp",
        .expected = "owned value deinitialized more than once",
    },
    .{
        .path = "tests/diagnostics/use_after_move.zpp",
        .expected = "owned value used after move",
    },
    .{
        .path = "tests/diagnostics/moved_missing_deinit.zpp",
        .expected = "owned value must be paired",
    },
    .{
        .path = "tests/diagnostics/effect_noalloc.zpp",
        .expected = "effects(.noalloc) function contains allocation-like operation",
    },
    .{
        .path = "tests/diagnostics/effect_noio.zpp",
        .expected = "effects(.noio) function contains I/O-like operation",
    },
    .{
        .path = "tests/diagnostics/effect_unsafe.zpp",
        .expected = "effects list must include .unsafe for unsafe-like operation",
    },
    .{
        .path = "tests/diagnostics/effect_nothread.zpp",
        .expected = "effects(.nothread) function contains spawn-like operation",
    },
    .{
        .path = "tests/diagnostics/effect_blocking.zpp",
        .expected = "effects list must include .blocking for blocking-like operation",
    },
    .{
        .path = "tests/diagnostics/effect_dyn.zpp",
        .expected = "effects list must include .dyn for dynamic-dispatch-like operation",
    },
};

const clean_cases = [_]CleanCase{
    .{ .path = "examples/contracts.zpp" },
    .{ .path = "examples/derive_user.zpp" },
    .{ .path = "examples/effects_visibility.zpp" },
    .{ .path = "examples/noalloc_hash.zpp" },
    .{ .path = "examples/owned_buffer.zpp" },
    .{ .path = "examples/where_constraints.zpp" },
};

const lowering_cases = [_]LoweringCase{
    .{
        .path = "examples/contracts.zpp",
        .expected = &.{
            "if (!(i < xs.len)) @panic(\"contract requires failed\");",
            "if (!(xs.len > 0)) @panic(\"contract invariant failed\");",
            "if (!(zpp_result_0 >= 0)) @panic(\"contract ensures failed\");",
        },
    },
    .{
        .path = "examples/dyn_plugin.zpp",
        .expected = &.{
            "pub const VTable = struct",
            "fn render(plugin: AudioPlugin.Dyn, input: []const f32, output: []f32) void",
        },
    },
    .{
        .path = "examples/hello_trait.zpp",
        .expected = &.{
            "comptime Writer.require(@TypeOf(w));",
            "defer writer.deinit();",
        },
    },
    .{
        .path = "examples/derive_user.zpp",
        .expected = &.{
            "pub const json = zpp.derive.Json(@This());",
            "pub const hash = zpp.derive.Hash(@This());",
            "pub const debug = zpp.derive.Debug(@This());",
        },
    },
    .{
        .path = "examples/where_constraints.zpp",
        .expected = &.{
            "// zpp: where T: Ord",
            "comptime Ord.require(T);",
        },
    },
    .{
        .path = "tests/compile/missing_trait_method.zpp",
        .expected = &.{
            "type does not implement Writer: missing method write",
            "comptime Writer.require(@TypeOf(w));",
        },
    },
};

const api_cases = [_]ApiCase{
    .{
        .path = "examples/hello_trait.zpp",
        .expected = &.{
            "\"kind\":\"trait\"",
            "\"kind\":\"trait_method\"",
            "\"kind\":\"owned_struct\"",
            "\"name\":\"main\"",
        },
    },
    .{
        .path = "examples/contracts.zpp",
        .expected = &.{
            "\"kind\":\"function\"",
            "\"name\":\"main\"",
        },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try runDiagnosticCases(allocator);
    try runCleanCases(allocator);
    try runLoweringCases(allocator);
    try runApiCases(allocator);
}

fn runDiagnosticCases(allocator: std.mem.Allocator) !void {
    for (diagnostic_cases) |case| {
        const source = try readCase(allocator, case.path);
        defer allocator.free(source);

        const diags = try zpp.sema.checkSource(allocator, source);
        defer allocator.free(diags);

        if (!diagnosticsContain(diags, case.expected)) {
            std.debug.print("fixture failed: {s}\nexpected diagnostic containing: {s}\n", .{
                case.path,
                case.expected,
            });
            printDiagnostics(diags);
            return error.FixtureFailed;
        }
    }
}

fn runCleanCases(allocator: std.mem.Allocator) !void {
    for (clean_cases) |case| {
        const source = try readCase(allocator, case.path);
        defer allocator.free(source);

        const diags = try zpp.sema.checkSource(allocator, source);
        defer allocator.free(diags);

        if (diags.len != 0) {
            std.debug.print("fixture failed: {s}\nexpected no diagnostics\n", .{case.path});
            printDiagnostics(diags);
            return error.FixtureFailed;
        }
    }
}

fn runLoweringCases(allocator: std.mem.Allocator) !void {
    for (lowering_cases) |case| {
        const source = try readCase(allocator, case.path);
        defer allocator.free(source);

        const lowered = try zpp.lowerSource(allocator, source);
        defer allocator.free(lowered);

        for (case.expected) |needle| {
            if (std.mem.indexOf(u8, lowered, needle) == null) {
                std.debug.print("fixture failed: {s}\nmissing lowered text: {s}\n", .{
                    case.path,
                    needle,
                });
                return error.FixtureFailed;
            }
        }
    }
}

fn runApiCases(allocator: std.mem.Allocator) !void {
    const api = @import("zpp_api.zig");

    for (api_cases) |case| {
        const source = try readCase(allocator, case.path);
        defer allocator.free(source);

        const manifest = try api.generateManifest(allocator, case.path, source);
        defer allocator.free(manifest);

        for (case.expected) |needle| {
            if (std.mem.indexOf(u8, manifest, needle) == null) {
                std.debug.print("fixture failed: {s}\nmissing API manifest text: {s}\n", .{
                    case.path,
                    needle,
                });
                return error.FixtureFailed;
            }
        }
    }
}

fn readCase(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
}

fn diagnosticsContain(diags: []const zpp.diagnostics.Diagnostic, expected: []const u8) bool {
    for (diags) |diag| {
        if (std.mem.indexOf(u8, diag.message, expected) != null) return true;
    }
    return false;
}

fn printDiagnostics(diags: []const zpp.diagnostics.Diagnostic) void {
    for (diags) |diag| {
        std.debug.print("{d}:{d}: {s}\n", .{ diag.line, diag.column, diag.message });
    }
}
