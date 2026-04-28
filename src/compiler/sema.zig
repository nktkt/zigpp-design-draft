const std = @import("std");
const diagnostics = @import("diagnostics.zig");

const OwnedValue = struct {
    name: []const u8,
    declared_line: usize,
    declared_column: usize,
    deinitialized: bool = false,
    deinit_line: usize = 0,
    moved: bool = false,
    move_line: usize = 0,
};

const EffectSet = struct {
    present: bool = false,
    alloc: bool = false,
    noalloc: bool = false,
    io: bool = false,
    noio: bool = false,
    blocking: bool = false,
    nonblocking: bool = false,
    spawn: bool = false,
    nothread: bool = false,
    dyn: bool = false,
    nodyn: bool = false,
    unsafe: bool = false,
    nounsafe: bool = false,

    fn any(self: EffectSet) bool {
        return self.present;
    }
};

const EffectKind = enum {
    alloc,
    io,
    blocking,
    spawn,
    dyn,
    unsafe,
};

pub fn checkSource(allocator: std.mem.Allocator, source: []const u8) ![]diagnostics.Diagnostic {
    var bag = diagnostics.Bag.init(allocator);
    errdefer bag.deinit();

    try checkOwnership(allocator, source, &bag);
    try checkEffects(source, &bag);

    return bag.items.toOwnedSlice(allocator);
}

pub fn checkMustDeinit(allocator: std.mem.Allocator, source: []const u8) ![]diagnostics.Diagnostic {
    var bag = diagnostics.Bag.init(allocator);
    errdefer bag.deinit();

    try checkOwnership(allocator, source, &bag);

    return bag.items.toOwnedSlice(allocator);
}

fn checkOwnership(allocator: std.mem.Allocator, source: []const u8, bag: *diagnostics.Bag) !void {
    var owned: std.ArrayList(OwnedValue) = .empty;
    defer owned.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const code = stripLineComment(line);
        const trimmed = std.mem.trimLeft(u8, code, " \t");
        var owned_decl_on_line: ?[]const u8 = null;

        if (parseOwnedVar(trimmed)) |decl| {
            owned_decl_on_line = decl.name;
            try owned.append(allocator, .{
                .name = decl.name,
                .declared_line = line_no,
                .declared_column = columnOf(code, decl.name),
            });
        }

        if (parseMoveAssignment(trimmed)) |move| {
            if (findOwnedIndex(owned.items, move.source)) |source_index| {
                var source_value = &owned.items[source_index];
                if (source_value.moved) {
                    try bag.addWithCode(diagnostics.Code.owned_used_after_move, .err, line_no, columnOf(code, move.source), "owned value used after move");
                } else if (source_value.deinitialized) {
                    try bag.addWithCode(diagnostics.Code.owned_moved_after_deinit, .err, line_no, columnOf(code, move.source), "owned value moved after deinit");
                } else {
                    source_value.moved = true;
                    source_value.move_line = line_no;
                }
            }

            if (owned_decl_on_line == null or !std.mem.eql(u8, owned_decl_on_line.?, move.dest)) {
                try owned.append(allocator, .{
                    .name = move.dest,
                    .declared_line = line_no,
                    .declared_column = columnOf(code, move.dest),
                });
            }
        } else if (parseMoveSource(trimmed)) |source_name| {
            if (findOwnedIndex(owned.items, source_name)) |source_index| {
                var source_value = &owned.items[source_index];
                if (source_value.moved) {
                    try bag.addWithCode(diagnostics.Code.owned_used_after_move, .err, line_no, columnOf(code, source_name), "owned value used after move");
                } else if (source_value.deinitialized) {
                    try bag.addWithCode(diagnostics.Code.owned_moved_after_deinit, .err, line_no, columnOf(code, source_name), "owned value moved after deinit");
                } else {
                    source_value.moved = true;
                    source_value.move_line = line_no;
                }
            }
        }

        if (parseUsingExisting(trimmed)) |name| {
            try markDeinitialized(bag, owned.items, name, line_no, columnOf(code, name));
        }

        for (owned.items) |*item| {
            if (containsDeinitCall(code, item.name)) {
                try markDeinitialized(bag, owned.items, item.name, line_no, columnOf(code, item.name));
            }
        }

        for (owned.items) |item| {
            if (!item.moved or line_no <= item.move_line) continue;
            if (containsIdentifier(code, item.name) and
                !isCleanupOfName(trimmed, code, item.name) and
                !isMoveOfName(trimmed, item.name))
            {
                try bag.addWithCode(diagnostics.Code.owned_used_after_move, .err, line_no, columnOf(code, item.name), "owned value used after move");
            }
        }
    }

    for (owned.items) |item| {
        if (!item.deinitialized and !item.moved) {
            try bag.addWithCode(diagnostics.Code.owned_missing_cleanup, .err, item.declared_line, item.declared_column, "owned value must be paired with `using name;` or `name.deinit()`");
        }
    }
}

const OwnedDecl = struct {
    name: []const u8,
};

const MoveAssignment = struct {
    dest: []const u8,
    source: []const u8,
};

fn markDeinitialized(
    bag: *diagnostics.Bag,
    owned: []OwnedValue,
    name: []const u8,
    line_no: usize,
    column: usize,
) !void {
    const index = findOwnedIndex(owned, name) orelse return;
    var item = &owned[index];
    if (item.moved) {
        try bag.addWithCode(diagnostics.Code.owned_used_after_move, .err, line_no, column, "owned value used after move");
        return;
    }
    if (item.deinitialized) {
        try bag.addWithCode(diagnostics.Code.owned_double_deinit, .err, line_no, column, "owned value deinitialized more than once");
        return;
    }
    item.deinitialized = true;
    item.deinit_line = line_no;
}

fn stripLineComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "//")) |comment_start| {
        return line[0..comment_start];
    }
    return line;
}

fn parseOwnedVar(trimmed: []const u8) ?OwnedDecl {
    const prefix = "own var ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const rest = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
    const name = readIdentifier(rest) orelse return null;
    return .{ .name = name };
}

fn parseUsingExisting(trimmed: []const u8) ?[]const u8 {
    const prefix = "using ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '=') != null) return null;

    const rest = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
    return readIdentifier(rest);
}

fn parseMoveAssignment(trimmed: []const u8) ?MoveAssignment {
    const var_prefix = if (std.mem.startsWith(u8, trimmed, "own var "))
        "own var "
    else if (std.mem.startsWith(u8, trimmed, "var "))
        "var "
    else
        return null;

    const rest = std.mem.trimLeft(u8, trimmed[var_prefix.len..], " \t");
    const dest = readIdentifier(rest) orelse return null;
    const eq_pos = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const rhs = std.mem.trimLeft(u8, rest[eq_pos + 1 ..], " \t");
    const source = parseMoveSource(rhs) orelse return null;
    return .{ .dest = dest, .source = source };
}

fn parseMoveSource(trimmed: []const u8) ?[]const u8 {
    const move_pos = std.mem.indexOf(u8, trimmed, "move ") orelse return null;
    if (move_pos != 0 and isIdentChar(trimmed[move_pos - 1])) return null;

    const rest = trimmed[move_pos + "move ".len ..];
    return readIdentifier(std.mem.trimLeft(u8, rest, " \t"));
}

fn findOwnedIndex(owned: []OwnedValue, name: []const u8) ?usize {
    var i: usize = owned.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, owned[i].name, name)) return i;
    }
    return null;
}

fn containsDeinitCall(line: []const u8, name: []const u8) bool {
    if (!containsIdentifier(line, name)) return false;
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, line[search_start..], name)) |rel| {
        const pos = search_start + rel;
        const after_name = pos + name.len;
        if (isIdentifierBoundary(line, pos, after_name) and
            std.mem.startsWith(u8, line[after_name..], ".deinit("))
        {
            return true;
        }
        search_start = after_name;
    }
    return false;
}

fn isCleanupOfName(trimmed: []const u8, code: []const u8, name: []const u8) bool {
    if (parseUsingExisting(trimmed)) |using_name| {
        if (std.mem.eql(u8, using_name, name)) return true;
    }
    return containsDeinitCall(code, name);
}

fn isMoveOfName(trimmed: []const u8, name: []const u8) bool {
    if (parseMoveSource(trimmed)) |source_name| {
        return std.mem.eql(u8, source_name, name);
    }
    return false;
}

fn containsIdentifier(line: []const u8, name: []const u8) bool {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, line[search_start..], name)) |rel| {
        const pos = search_start + rel;
        const after_name = pos + name.len;
        if (isIdentifierBoundary(line, pos, after_name)) return true;
        search_start = after_name;
    }
    return false;
}

fn isIdentifierBoundary(line: []const u8, start: usize, end: usize) bool {
    const before_ok = start == 0 or !isIdentChar(line[start - 1]);
    const after_ok = end >= line.len or !isIdentChar(line[end]);
    return before_ok and after_ok;
}

fn readIdentifier(text: []const u8) ?[]const u8 {
    if (text.len == 0 or !isIdentStart(text[0])) return null;
    var end: usize = 1;
    while (end < text.len and isIdentChar(text[end])) : (end += 1) {}
    return text[0..end];
}

fn columnOf(line: []const u8, needle: []const u8) usize {
    if (std.mem.indexOf(u8, line, needle)) |index| {
        return index + 1;
    }
    return 1;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn checkEffects(source: []const u8, bag: *diagnostics.Bag) !void {
    var pending_effects = EffectSet{};
    var active_effects = EffectSet{};
    var body_depth: isize = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const code = stripLineComment(line);
        const trimmed = std.mem.trimLeft(u8, code, " \t");

        if (active_effects.any()) {
            try checkEffectLine(active_effects, code, line_no, bag);
            body_depth += braceDelta(code);
            if (body_depth <= 0) {
                active_effects = .{};
                body_depth = 0;
            }
            continue;
        }

        if (parseEffects(trimmed)) |effects| {
            pending_effects = effects;
            if (std.mem.indexOfScalar(u8, code, '{') != null) {
                active_effects = pending_effects;
                pending_effects = .{};
                body_depth = braceDelta(code);
                if (body_depth <= 0) {
                    active_effects = .{};
                    body_depth = 0;
                }
            }
            continue;
        }

        if (pending_effects.any() and std.mem.indexOfScalar(u8, code, '{') != null) {
            active_effects = pending_effects;
            pending_effects = .{};
            body_depth = braceDelta(code);
            if (body_depth <= 0) {
                active_effects = .{};
                body_depth = 0;
            }
        }
    }
}

fn parseEffects(trimmed: []const u8) ?EffectSet {
    const start = std.mem.indexOf(u8, trimmed, "effects(") orelse return null;
    const effects_text = trimmed[start..];
    return .{
        .present = true,
        .alloc = std.mem.indexOf(u8, effects_text, ".alloc") != null and std.mem.indexOf(u8, effects_text, ".noalloc") == null,
        .noalloc = std.mem.indexOf(u8, effects_text, ".noalloc") != null,
        .io = std.mem.indexOf(u8, effects_text, ".io") != null and std.mem.indexOf(u8, effects_text, ".noio") == null,
        .noio = std.mem.indexOf(u8, effects_text, ".noio") != null,
        .blocking = std.mem.indexOf(u8, effects_text, ".blocking") != null and std.mem.indexOf(u8, effects_text, ".nonblocking") == null,
        .nonblocking = std.mem.indexOf(u8, effects_text, ".nonblocking") != null,
        .spawn = std.mem.indexOf(u8, effects_text, ".spawn") != null,
        .nothread = std.mem.indexOf(u8, effects_text, ".nothread") != null,
        .dyn = std.mem.indexOf(u8, effects_text, ".dyn") != null and std.mem.indexOf(u8, effects_text, ".nodyn") == null,
        .nodyn = std.mem.indexOf(u8, effects_text, ".nodyn") != null,
        .unsafe = std.mem.indexOf(u8, effects_text, ".unsafe") != null and std.mem.indexOf(u8, effects_text, ".nounsafe") == null,
        .nounsafe = std.mem.indexOf(u8, effects_text, ".nounsafe") != null,
    };
}

fn checkEffectLine(effects: EffectSet, code: []const u8, line_no: usize, bag: *diagnostics.Bag) !void {
    if (effects.noalloc) {
        if (firstAllocationColumn(code)) |column| {
            try bag.addWithCode(diagnostics.Code.effect_noalloc, .err, line_no, column, "effects(.noalloc) function contains allocation-like operation");
        }
    }

    if (effects.noio) {
        if (firstIoColumn(code)) |column| {
            try bag.addWithCode(diagnostics.Code.effect_noio, .err, line_no, column, "effects(.noio) function contains I/O-like operation");
        }
    }

    if (effects.nonblocking) {
        if (firstBlockingColumn(code)) |column| {
            try bag.addWithCode(diagnostics.Code.effect_nonblocking, .err, line_no, column, "effects(.nonblocking) function contains blocking-like operation");
        }
    }

    if (effects.nothread) {
        if (firstSpawnColumn(code)) |column| {
            try bag.addWithCode(diagnostics.Code.effect_nothread, .err, line_no, column, "effects(.nothread) function contains spawn-like operation");
        }
    }

    if (effects.nodyn) {
        if (firstDynColumn(code)) |column| {
            try bag.addWithCode(diagnostics.Code.effect_nodyn, .err, line_no, column, "effects(.nodyn) function contains dynamic-dispatch-like operation");
        }
    }

    if (effects.nounsafe) {
        if (firstUnsafeColumn(code)) |column| {
            try bag.addWithCode(diagnostics.Code.effect_nounsafe, .err, line_no, column, "effects(.nounsafe) function contains unsafe-like operation");
        }
    }

    try checkMissingVisibleEffect(effects, code, line_no, bag, .alloc, effects.alloc or effects.noalloc);
    try checkMissingVisibleEffect(effects, code, line_no, bag, .io, effects.io or effects.noio);
    try checkMissingVisibleEffect(effects, code, line_no, bag, .blocking, effects.blocking or effects.nonblocking);
    try checkMissingVisibleEffect(effects, code, line_no, bag, .spawn, effects.spawn or effects.nothread);
    try checkMissingVisibleEffect(effects, code, line_no, bag, .dyn, effects.dyn or effects.nodyn);
    try checkMissingVisibleEffect(effects, code, line_no, bag, .unsafe, effects.unsafe or effects.nounsafe);
}

fn checkMissingVisibleEffect(
    effects: EffectSet,
    code: []const u8,
    line_no: usize,
    bag: *diagnostics.Bag,
    kind: EffectKind,
    declared: bool,
) !void {
    _ = effects;
    if (declared) return;

    const column = switch (kind) {
        .alloc => firstAllocationColumn(code),
        .io => firstIoColumn(code),
        .blocking => firstBlockingColumn(code),
        .spawn => firstSpawnColumn(code),
        .dyn => firstDynColumn(code),
        .unsafe => firstUnsafeColumn(code),
    } orelse return;

    try bag.addWithCode(switch (kind) {
        .alloc => diagnostics.Code.missing_alloc_effect,
        .io => diagnostics.Code.missing_io_effect,
        .blocking => diagnostics.Code.missing_blocking_effect,
        .spawn => diagnostics.Code.missing_spawn_effect,
        .dyn => diagnostics.Code.missing_dyn_effect,
        .unsafe => diagnostics.Code.missing_unsafe_effect,
    }, .warning, line_no, column, switch (kind) {
        .alloc => "effects list must include .alloc for allocation-like operation",
        .io => "effects list must include .io for I/O-like operation",
        .blocking => "effects list must include .blocking for blocking-like operation",
        .spawn => "effects list must include .spawn for spawn-like operation",
        .dyn => "effects list must include .dyn for dynamic-dispatch-like operation",
        .unsafe => "effects list must include .unsafe for unsafe-like operation",
    });
}

fn firstAllocationColumn(code: []const u8) ?usize {
    return firstNeedleColumn(code, &.{
        ".alloc(",
        ".create(",
        ".dupe(",
        ".realloc(",
        "readFileAlloc(",
        "toOwnedSlice(",
        "std.heap.",
    });
}

fn firstIoColumn(code: []const u8) ?usize {
    return firstNeedleColumn(code, &.{
        "std.fs.",
        ".openFile(",
        ".createFile(",
        ".readAll(",
        ".readToEnd",
        ".writeAll(",
        "std.debug.print(",
        "stdout()",
        "stderr()",
    });
}

fn firstBlockingColumn(code: []const u8) ?usize {
    return firstNeedleColumn(code, &.{
        "std.time.sleep(",
        ".sleep(",
        ".join(",
        ".wait(",
        ".accept(",
        ".connect(",
    });
}

fn firstSpawnColumn(code: []const u8) ?usize {
    return firstNeedleColumn(code, &.{
        "std.Thread.spawn(",
        "Thread.spawn(",
        ".spawn(",
        ".spawnThread(",
        "TaskGroup",
    });
}

fn firstDynColumn(code: []const u8) ?usize {
    return firstNeedleColumn(code, &.{
        "dyn ",
        ".Dyn",
        ".vtable",
        "vtable.",
    });
}

fn firstUnsafeColumn(code: []const u8) ?usize {
    return firstNeedleColumn(code, &.{
        "@ptrCast(",
        "@ptrFromInt(",
        "@intFromPtr(",
        "@alignCast(",
        "@constCast(",
        "@volatileCast(",
        "@fieldParentPtr(",
        "asm ",
    });
}

fn firstNeedleColumn(code: []const u8, needles: []const []const u8) ?usize {
    var best: ?usize = null;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, code, needle)) |index| {
            if (best == null or index < best.?) {
                best = index;
            }
        }
    }
    return if (best) |index| index + 1 else null;
}

fn braceDelta(line: []const u8) isize {
    var delta: isize = 0;
    for (line) |c| {
        if (c == '{') delta += 1;
        if (c == '}') delta -= 1;
    }
    return delta;
}

test "must-deinit checker reports missing cleanup" {
    const source =
        \\pub fn main() !void {
        \\    own var buf = try Buffer.init(allocator);
        \\    _ = buf;
        \\}
    ;

    const diags = try checkMustDeinit(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostics.Severity.err, diags[0].severity);
    try std.testing.expectEqualStrings(diagnostics.Code.owned_missing_cleanup, diags[0].code);
}

test "must-deinit checker accepts using" {
    const source =
        \\pub fn main() !void {
        \\    own var buf = try Buffer.init(allocator);
        \\    using buf;
        \\}
    ;

    const diags = try checkMustDeinit(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "must-deinit checker reports double cleanup" {
    const source =
        \\pub fn main() !void {
        \\    own var buf = try Buffer.init(allocator);
        \\    using buf;
        \\    buf.deinit();
        \\}
    ;

    const diags = try checkMustDeinit(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings(diagnostics.Code.owned_double_deinit, diags[0].code);
    try std.testing.expectEqualStrings("owned value deinitialized more than once", diags[0].message);
}

test "must-deinit checker reports use after move" {
    const source =
        \\pub fn main() !void {
        \\    own var buf = try Buffer.init(allocator);
        \\    var moved = move buf;
        \\    _ = buf;
        \\    using moved;
        \\}
    ;

    const diags = try checkMustDeinit(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings(diagnostics.Code.owned_used_after_move, diags[0].code);
    try std.testing.expectEqualStrings("owned value used after move", diags[0].message);
}

test "must-deinit checker requires moved destination cleanup" {
    const source =
        \\pub fn main() !void {
        \\    own var buf = try Buffer.init(allocator);
        \\    var moved = move buf;
        \\}
    ;

    const diags = try checkMustDeinit(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(usize, 3), diags[0].line);
    try std.testing.expectEqualStrings(diagnostics.Code.owned_missing_cleanup, diags[0].code);
}

test "must-deinit checker does not duplicate own var move destination" {
    const source =
        \\pub fn main() !void {
        \\    own var buf = try Buffer.init(allocator);
        \\    own var moved = move buf;
        \\    using moved;
        \\}
    ;

    const diags = try checkMustDeinit(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "must-deinit checker reports one cleanup after move diagnostic" {
    const source =
        \\pub fn main() !void {
        \\    own var buf = try Buffer.init(allocator);
        \\    var moved = move buf;
        \\    using buf;
        \\    using moved;
        \\}
    ;

    const diags = try checkMustDeinit(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings(diagnostics.Code.owned_used_after_move, diags[0].code);
    try std.testing.expectEqualStrings("owned value used after move", diags[0].message);
}

test "effect checker accepts pure noalloc noio function" {
    const source =
        \\fn hashBytes(bytes: []const u8) u64
        \\    effects(.noalloc, .noio)
        \\{
        \\    var h: u64 = 1469598103934665603;
        \\    for (bytes) |b| {
        \\        h ^= b;
        \\        h *%= 1099511628211;
        \\    }
        \\    return h;
        \\}
    ;

    const diags = try checkSource(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "effect checker reports noalloc violation" {
    const source =
        \\fn make(allocator: std.mem.Allocator) ![]u8
        \\    effects(.noalloc)
        \\{
        \\    return try allocator.alloc(u8, 16);
        \\}
    ;

    const diags = try checkSource(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings(diagnostics.Code.effect_noalloc, diags[0].code);
    try std.testing.expectEqualStrings("effects(.noalloc) function contains allocation-like operation", diags[0].message);
}

test "effect checker reports noio violation" {
    const source =
        \\fn write(file: std.fs.File) !void
        \\    effects(.noio)
        \\{
        \\    try file.writeAll("hello");
        \\}
    ;

    const diags = try checkSource(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings(diagnostics.Code.effect_noio, diags[0].code);
    try std.testing.expectEqualStrings("effects(.noio) function contains I/O-like operation", diags[0].message);
}

test "effect checker reports omitted unsafe visibility" {
    const source =
        \\fn addr(ptr: *u8) usize
        \\    effects(.cpu)
        \\{
        \\    return @intFromPtr(ptr);
        \\}
    ;

    const diags = try checkSource(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostics.Severity.warning, diags[0].severity);
    try std.testing.expectEqualStrings(diagnostics.Code.missing_unsafe_effect, diags[0].code);
    try std.testing.expectEqualStrings("effects list must include .unsafe for unsafe-like operation", diags[0].message);
}

test "effect checker reports nothread violation" {
    const source =
        \\fn run() void
        \\    effects(.nothread)
        \\{
        \\    _ = std.Thread.spawn(.{}, worker, .{});
        \\}
    ;

    const diags = try checkSource(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings(diagnostics.Code.effect_nothread, diags[0].code);
    try std.testing.expectEqualStrings("effects(.nothread) function contains spawn-like operation", diags[0].message);
}

test "effect checker accepts visible unsafe dyn spawn blocking effects" {
    const source =
        \\fn visible(plugin: Plugin.Dyn, ptr: *u8) void
        \\    effects(.unsafe, .dyn, .spawn, .blocking)
        \\{
        \\    _ = @intFromPtr(ptr);
        \\    _ = plugin.vtable;
        \\    _ = std.Thread.spawn;
        \\    std.time.sleep(1);
        \\}
    ;

    const diags = try checkSource(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "contract checker accepts ensures" {
    const source =
        \\fn abs(x: i32) i32
        \\    ensures(result >= 0)
        \\{
        \\    return if (x < 0) -x else x;
        \\}
    ;

    const diags = try checkSource(std.testing.allocator, source);
    defer std.testing.allocator.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}
