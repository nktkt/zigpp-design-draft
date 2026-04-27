const std = @import("std");

pub fn requires(ok: bool) void {
    std.debug.assert(ok);
}

pub fn ensures(ok: bool) void {
    std.debug.assert(ok);
}

pub fn invariant(ok: bool) void {
    std.debug.assert(ok);
}
