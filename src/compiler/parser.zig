const std = @import("std");
const ast = @import("ast.zig");

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ast.Source {
    var features: std.ArrayList(ast.Feature) = .empty;
    errdefer features.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "trait ")) {
            try features.append(allocator, .trait_decl);
        }
        if (std.mem.indexOf(u8, trimmed, "impl ") != null) {
            try features.append(allocator, .impl_param);
        }
        if (std.mem.indexOf(u8, trimmed, "dyn ") != null) {
            try features.append(allocator, .dyn_param);
        }
        if (std.mem.startsWith(u8, trimmed, "using ")) {
            if (std.mem.indexOfScalar(u8, trimmed, '=') != null) {
                try features.append(allocator, .using_binding);
            } else {
                try features.append(allocator, .using_existing);
            }
        }
        if (std.mem.startsWith(u8, trimmed, "owned struct ")) {
            try features.append(allocator, .owned_struct);
        }
        if (std.mem.startsWith(u8, trimmed, "own var ")) {
            try features.append(allocator, .owned_var);
        }
        if (std.mem.indexOf(u8, trimmed, "move ") != null) {
            try features.append(allocator, .move_expr);
        }
        if (std.mem.startsWith(u8, trimmed, "effects(")) {
            try features.append(allocator, .effects_clause);
        }
        if (std.mem.startsWith(u8, trimmed, "requires(") or
            std.mem.startsWith(u8, trimmed, "ensures(") or
            std.mem.startsWith(u8, trimmed, "invariant("))
        {
            try features.append(allocator, .contract_clause);
        }
    }

    return .{
        .text = source,
        .features = try features.toOwnedSlice(allocator),
    };
}

test "parser records visible abstraction features" {
    const source =
        \\trait Writer {
        \\    fn write(self, bytes: []const u8) !usize;
        \\}
        \\using w = try FileWriter.init("log.txt");
    ;

    const parsed = try parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.features.len);
    try std.testing.expectEqual(ast.Feature.trait_decl, parsed.features[0]);
    try std.testing.expectEqual(ast.Feature.using_binding, parsed.features[1]);
}
