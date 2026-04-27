const std = @import("std");

pub const Feature = enum {
    trait_decl,
    impl_param,
    dyn_param,
    using_binding,
    using_existing,
    owned_struct,
    owned_var,
    move_expr,
    effects_clause,
    contract_clause,
};

pub const Source = struct {
    text: []const u8,
    features: []const Feature,

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        allocator.free(self.features);
    }
};
