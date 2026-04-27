pub const ast = @import("compiler/ast.zig");
pub const diagnostics = @import("compiler/diagnostics.zig");
pub const parser = @import("compiler/parser.zig");
pub const sema = @import("compiler/sema.zig");
pub const lower_to_zig = @import("compiler/lower_to_zig.zig");

pub const traits = @import("lib/traits.zig");
pub const owned = @import("lib/owned.zig");
pub const contracts = @import("lib/contracts.zig");
pub const derive = @import("lib/derive.zig");
pub const dyn = @import("lib/dyn.zig");
pub const async = @import("lib/async.zig");
pub const testing = @import("lib/testing.zig");

pub fn lowerSource(allocator: @import("std").mem.Allocator, source: []const u8) ![]u8 {
    const tree = try parser.parse(allocator, source);
    defer tree.deinit(allocator);
    return lower_to_zig.lower(allocator, tree);
}

test {
    _ = ast;
    _ = diagnostics;
    _ = parser;
    _ = sema;
    _ = lower_to_zig;
    _ = traits;
    _ = owned;
    _ = contracts;
    _ = derive;
    _ = dyn;
    _ = async;
    _ = testing;
}
