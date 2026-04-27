const std = @import("std");
const ast = @import("ast.zig");

const ImplParam = struct {
    name: []const u8,
    trait_name: []const u8,
};

const ImplParamSet = struct {
    items: [8]ImplParam = undefined,
    len: usize = 0,

    fn append(self: *ImplParamSet, item: ImplParam) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }
};

const WhereBound = struct {
    type_name: []const u8,
    trait_name: []const u8,
};

const WhereBoundSet = struct {
    items: [8]WhereBound = undefined,
    len: usize = 0,

    fn append(self: *WhereBoundSet, item: WhereBound) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    fn appendAll(self: *WhereBoundSet, other: WhereBoundSet) void {
        var i: usize = 0;
        while (i < other.len) : (i += 1) {
            self.append(other.items[i]);
        }
    }
};

const ContractKind = enum {
    requires,
    invariant,
    ensures,
};

const Contract = struct {
    kind: ContractKind,
    expr: []const u8,
};

const ContractSet = struct {
    items: [8]Contract = undefined,
    len: usize = 0,

    fn append(self: *ContractSet, item: Contract) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    fn any(self: ContractSet) bool {
        return self.len != 0;
    }
};

const TraitMethod = struct {
    name: []const u8,
    params_after_self: []const u8,
    return_type: []const u8,
};

const TraitMethodSet = struct {
    items: [8]TraitMethod = undefined,
    len: usize = 0,

    fn append(self: *TraitMethodSet, item: TraitMethod) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }
};

const DeriveSet = struct {
    items: [8][]const u8 = undefined,
    len: usize = 0,

    fn append(self: *DeriveSet, name: []const u8) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = name;
        self.len += 1;
    }
};

pub fn lower(allocator: std.mem.Allocator, source: ast.Source) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_trait = false;
    var in_derive = false;
    var trait_depth: isize = 0;
    var trait_name: []const u8 = "";
    var trait_indent: []const u8 = "";
    var trait_methods = TraitMethodSet{};
    var derive_indent: []const u8 = "";
    var derive_names = DeriveSet{};
    var owned_struct_depth: isize = 0;
    var pending_impl_params = ImplParamSet{};
    var pending_where_bounds = WhereBoundSet{};
    var pending_contracts = ContractSet{};
    var active_ensures = ContractSet{};
    var active_ensure_depth: isize = 0;
    var ensure_return_index: usize = 0;

    var lines = std.mem.splitScalar(u8, source.text, '\n');
    while (lines.next()) |line| {
        const indent_len = line.len - std.mem.trimLeft(u8, line, " \t").len;
        const indent = line[0..indent_len];
        const trimmed = line[indent_len..];

        if (in_trait) {
            const next_depth = trait_depth + braceDelta(trimmed);
            if (next_depth <= 0 and std.mem.eql(u8, std.mem.trim(u8, trimmed, " \t"), "}")) {
                try appendTraitDefinition(allocator, &out, trait_indent, trait_name, trait_methods);
                in_trait = false;
                trait_depth = 0;
                trait_name = "";
                trait_indent = "";
                trait_methods = .{};
                continue;
            }

            if (parseTraitMethod(trimmed)) |method| {
                trait_methods.append(method);
            } else if (std.mem.trim(u8, trimmed, " \t").len != 0) {
                try appendCommentedLine(allocator, &out, indent, trimmed);
                try out.append(allocator, '\n');
            }
            trait_depth = next_depth;
            continue;
        }

        if (in_derive) {
            collectDeriveNames(&derive_names, trimmed);
            if (deriveEnds(trimmed)) {
                try appendDeriveDecls(allocator, &out, derive_indent, derive_names);
                in_derive = false;
                derive_indent = "";
                derive_names = .{};
                owned_struct_depth = 0;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "trait ")) {
            trait_name = parseTraitName(trimmed) orelse {
                try appendCommentedLine(allocator, &out, indent, trimmed);
                try out.append(allocator, '\n');
                continue;
            };
            trait_indent = indent;
            trait_methods = .{};
            in_trait = true;
            trait_depth = braceDelta(trimmed);
            if (trait_depth <= 0) {
                try appendTraitDefinition(allocator, &out, trait_indent, trait_name, trait_methods);
                in_trait = false;
                trait_depth = 0;
                trait_name = "";
                trait_indent = "";
                trait_methods = .{};
            }
            continue;
        }

        if (try lowerOwnedStruct(allocator, &out, indent, trimmed)) {
            owned_struct_depth = braceDelta(trimmed);
            try out.append(allocator, '\n');
            continue;
        }

        if (parseDeriveStart(trimmed)) |derive_rest| {
            derive_indent = indent;
            derive_names = .{};
            collectDeriveNames(&derive_names, derive_rest);
            if (deriveEnds(derive_rest)) {
                try appendDeriveDecls(allocator, &out, derive_indent, derive_names);
                derive_indent = "";
                derive_names = .{};
                owned_struct_depth = 0;
            } else {
                in_derive = true;
            }
            continue;
        }

        if (owned_struct_depth > 0) {
            const next_depth = owned_struct_depth + braceDelta(trimmed);
            if (next_depth == 0 and std.mem.eql(u8, std.mem.trim(u8, trimmed, " \t"), "}")) {
                try out.appendSlice(allocator, indent);
                try out.appendSlice(allocator, "};");
                try out.append(allocator, '\n');
                owned_struct_depth = 0;
                continue;
            }
            owned_struct_depth = next_depth;
        }

        if (try lowerUsing(allocator, &out, indent, trimmed)) {
            try out.append(allocator, '\n');
            updateEnsureScope(&active_ensures, &active_ensure_depth, trimmed);
            continue;
        }

        if (parseContract(trimmed)) |contract| {
            pending_contracts.append(contract);
            continue;
        }

        if (parseWhereClause(trimmed)) |bounds| {
            pending_where_bounds.appendAll(bounds);
            try appendCommentedLine(allocator, &out, indent, trimmed);
            try out.append(allocator, '\n');
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "effects(") or
            std.mem.startsWith(u8, trimmed, "ensures("))
        {
            try appendCommentedLine(allocator, &out, indent, trimmed);
            try out.append(allocator, '\n');
            continue;
        }

        if (active_ensures.any()) {
            if (parseReturnExpr(trimmed)) |return_expr| {
                try appendEnsuredReturn(allocator, &out, indent, return_expr, active_ensures, ensure_return_index);
                ensure_return_index += 1;
                updateEnsureScope(&active_ensures, &active_ensure_depth, trimmed);
                continue;
            }
        }

        const impl_params = collectImplParams(trimmed);

        try out.appendSlice(allocator, indent);
        try appendRewrittenSyntax(allocator, &out, trimmed);
        try out.append(allocator, '\n');

        if (impl_params.len != 0) {
            pending_impl_params = impl_params;
        }
        if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
            try appendFunctionEntryChecks(allocator, &out, indent, pending_impl_params, pending_where_bounds, pending_contracts);
            active_ensures = onlyEnsures(pending_contracts);
            active_ensure_depth = if (active_ensures.any()) braceDelta(trimmed) else 0;
            pending_impl_params = .{};
            pending_where_bounds = .{};
            pending_contracts = .{};
        } else {
            updateEnsureScope(&active_ensures, &active_ensure_depth, trimmed);
        }
    }

    if (pending_contracts.any()) {
        try out.appendSlice(allocator, "// zpp: dangling contract ignored during lowering\n");
    }

    return out.toOwnedSlice(allocator);
}

fn appendFunctionEntryChecks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    impl_params: ImplParamSet,
    where_bounds: WhereBoundSet,
    contracts: ContractSet,
) !void {
    if (impl_params.len != 0) {
        try appendImplRequires(allocator, out, indent, impl_params);
    }
    if (where_bounds.len != 0) {
        try appendWhereRequires(allocator, out, indent, where_bounds);
    }
    if (contracts.len != 0) {
        try appendContractChecks(allocator, out, indent, contracts);
    }
}

fn appendContractChecks(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, contracts: ContractSet) !void {
    var i: usize = 0;
    while (i < contracts.len) : (i += 1) {
        const contract = contracts.items[i];
        if (contract.kind == .ensures) continue;
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "    if (!(");
        try out.appendSlice(allocator, contract.expr);
        try out.appendSlice(allocator, ")) @panic(\"contract ");
        try out.appendSlice(allocator, switch (contract.kind) {
            .requires => "requires",
            .invariant => "invariant",
            .ensures => unreachable,
        });
        try out.appendSlice(allocator, " failed\");\n");
    }
}

fn appendEnsuredReturn(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    return_expr: []const u8,
    ensures: ContractSet,
    return_index: usize,
) !void {
    try out.appendSlice(allocator, indent);
    try out.writer(allocator).print("const zpp_result_{d} = ", .{return_index});
    try out.appendSlice(allocator, return_expr);
    try out.appendSlice(allocator, ";\n");

    var i: usize = 0;
    while (i < ensures.len) : (i += 1) {
        const contract = ensures.items[i];
        if (contract.kind != .ensures) continue;
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "if (!(");
        try appendExprWithResultAlias(allocator, out, contract.expr, return_index);
        try out.appendSlice(allocator, ")) @panic(\"contract ensures failed\");\n");
    }

    try out.appendSlice(allocator, indent);
    try out.writer(allocator).print("return zpp_result_{d};\n", .{return_index});
}

fn appendExprWithResultAlias(allocator: std.mem.Allocator, out: *std.ArrayList(u8), expr: []const u8, return_index: usize) !void {
    var cursor: usize = 0;
    while (cursor < expr.len) {
        if (std.mem.indexOf(u8, expr[cursor..], "result")) |rel| {
            const pos = cursor + rel;
            const end = pos + "result".len;
            try out.appendSlice(allocator, expr[cursor..pos]);
            if (isIdentifierBoundary(expr, pos, end)) {
                try out.writer(allocator).print("zpp_result_{d}", .{return_index});
            } else {
                try out.appendSlice(allocator, "result");
            }
            cursor = end;
        } else {
            try out.appendSlice(allocator, expr[cursor..]);
            return;
        }
    }
}

fn onlyEnsures(contracts: ContractSet) ContractSet {
    var result = ContractSet{};
    var i: usize = 0;
    while (i < contracts.len) : (i += 1) {
        if (contracts.items[i].kind == .ensures) {
            result.append(contracts.items[i]);
        }
    }
    return result;
}

fn updateEnsureScope(active_ensures: *ContractSet, active_depth: *isize, line: []const u8) void {
    if (!active_ensures.any()) return;
    active_depth.* += braceDelta(line);
    if (active_depth.* <= 0) {
        active_ensures.* = .{};
        active_depth.* = 0;
    }
}

fn appendCommentedLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, line: []const u8) !void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "// zpp: ");
    try out.appendSlice(allocator, line);
}

fn parseContract(trimmed: []const u8) ?Contract {
    const kind: ContractKind = if (std.mem.startsWith(u8, trimmed, "requires("))
        .requires
    else if (std.mem.startsWith(u8, trimmed, "invariant("))
        .invariant
    else if (std.mem.startsWith(u8, trimmed, "ensures("))
        .ensures
    else
        return null;
    const prefix = switch (kind) {
        .requires => "requires(",
        .invariant => "invariant(",
        .ensures => "ensures(",
    };

    const close = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return null;
    if (close < prefix.len) return null;

    const expr = std.mem.trim(u8, trimmed[prefix.len..close], " \t");
    if (expr.len == 0) return null;

    return .{
        .kind = kind,
        .expr = expr,
    };
}

fn parseReturnExpr(trimmed: []const u8) ?[]const u8 {
    const prefix = "return ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const semi = std.mem.lastIndexOfScalar(u8, trimmed, ';') orelse return null;
    if (semi <= prefix.len) return null;
    return std.mem.trim(u8, trimmed[prefix.len..semi], " \t");
}

fn isIdentifierBoundary(text: []const u8, start: usize, end: usize) bool {
    const before_ok = start == 0 or !isIdentChar(text[start - 1]);
    const after_ok = end >= text.len or !isIdentChar(text[end]);
    return before_ok and after_ok;
}

fn appendTraitDefinition(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    name: []const u8,
    methods: TraitMethodSet,
) !void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "const ");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, " = struct {\n");
    try appendTraitVTable(allocator, out, indent, methods);
    try appendTraitDyn(allocator, out, indent, methods);
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    fn target(comptime T: type) type {\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        return switch (@typeInfo(T)) {\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            .pointer => |p| p.child,\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            else => T,\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        };\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    }\n\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    fn hasMethod(comptime T: type, comptime name: []const u8) bool {\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        switch (@typeInfo(T)) {\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            .@\"struct\", .@\"union\", .@\"enum\", .@\"opaque\" => {},\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            else => return false,\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        }\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        if (!@hasDecl(T, name)) return false;\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        return @typeInfo(@TypeOf(@field(T, name))) == .@\"fn\";\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    }\n\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    pub fn require(comptime T: type) void {\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        const U = target(T);\n");

    var i: usize = 0;
    while (i < methods.len) : (i += 1) {
        const method = methods.items[i];
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        if (!hasMethod(U, \"");
        try out.appendSlice(allocator, method.name);
        try out.appendSlice(allocator, "\")) @compileError(\"type does not implement ");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, ": missing method ");
        try out.appendSlice(allocator, method.name);
        try out.appendSlice(allocator, "\");\n");
    }

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    }\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "};\n");
}

fn appendTraitVTable(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    methods: TraitMethodSet,
) !void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    pub const VTable = struct {\n");
    var i: usize = 0;
    while (i < methods.len) : (i += 1) {
        const method = methods.items[i];
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        ");
        try out.appendSlice(allocator, method.name);
        try out.appendSlice(allocator, ": *const fn (*anyopaque");
        try appendParamTypes(allocator, out, method.params_after_self);
        try out.appendSlice(allocator, ") ");
        try appendVTableReturnType(allocator, out, method.return_type);
        try out.appendSlice(allocator, ",\n");
    }
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    };\n\n");
}

fn appendVTableReturnType(allocator: std.mem.Allocator, out: *std.ArrayList(u8), return_type: []const u8) !void {
    if (std.mem.startsWith(u8, return_type, "!")) {
        try out.appendSlice(allocator, "anyerror");
    }
    try out.appendSlice(allocator, return_type);
}

fn appendTraitDyn(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    methods: TraitMethodSet,
) !void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    pub const Dyn = struct {\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        ptr: *anyopaque,\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        vtable: *const VTable,\n\n");

    var i: usize = 0;
    while (i < methods.len) : (i += 1) {
        const method = methods.items[i];
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        pub fn ");
        try out.appendSlice(allocator, method.name);
        try out.appendSlice(allocator, "(self: Dyn");
        if (method.params_after_self.len != 0) {
            try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, method.params_after_self);
        }
        try out.appendSlice(allocator, ") ");
        try out.appendSlice(allocator, method.return_type);
        try out.appendSlice(allocator, " {\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "            ");
        if (!std.mem.eql(u8, method.return_type, "void")) {
            try out.appendSlice(allocator, "return ");
        }
        try out.appendSlice(allocator, "self.vtable.");
        try out.appendSlice(allocator, method.name);
        try out.appendSlice(allocator, "(self.ptr");
        try appendParamNames(allocator, out, method.params_after_self);
        try out.appendSlice(allocator, ");\n");
        if (std.mem.eql(u8, method.return_type, "void")) {
            try out.appendSlice(allocator, indent);
            try out.appendSlice(allocator, "            return;\n");
        }
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        }\n\n");
    }

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    };\n\n");
}

fn appendDeriveDecls(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, derives: DeriveSet) !void {
    var i: usize = 0;
    while (i < derives.len) : (i += 1) {
        const name = derives.items[i];
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "    pub const ");
        try appendLowerCamelIdentifier(allocator, out, name);
        try out.appendSlice(allocator, " = zpp.derive.");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, "(@This());\n");
    }
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "};\n");
}

fn appendLowerCamelIdentifier(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    if (name.len == 0) return;
    try out.append(allocator, std.ascii.toLower(name[0]));
    if (name.len > 1) {
        try out.appendSlice(allocator, name[1..]);
    }
}

fn lowerOwnedStruct(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, trimmed: []const u8) !bool {
    const prefix = "owned struct ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;

    const rest = trimmed[prefix.len..];
    const name_end = std.mem.indexOfAny(u8, rest, " \t{") orelse rest.len;
    if (name_end == 0) return false;

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "const ");
    try out.appendSlice(allocator, rest[0..name_end]);
    try out.appendSlice(allocator, " = struct");
    try out.appendSlice(allocator, rest[name_end..]);
    return true;
}

fn lowerUsing(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, trimmed: []const u8) !bool {
    const prefix = "using ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;

    const rest = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
        const name = std.mem.trim(u8, rest[0..eq_pos], " \t");
        const expr = std.mem.trim(u8, rest[eq_pos + 1 ..], " \t");

        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "var ");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, " = ");
        try out.appendSlice(allocator, expr);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "defer ");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, ".deinit();");
        return true;
    }

    const name = std.mem.trimRight(u8, rest, " \t;");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "defer ");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, ".deinit();");
    return true;
}

fn appendWhereRequires(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, where_bounds: WhereBoundSet) !void {
    var i: usize = 0;
    while (i < where_bounds.len) : (i += 1) {
        const item = where_bounds.items[i];
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "    comptime ");
        try out.appendSlice(allocator, item.trait_name);
        try out.appendSlice(allocator, ".require(");
        try out.appendSlice(allocator, item.type_name);
        try out.appendSlice(allocator, ");\n");
    }
}

fn appendImplRequires(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, impl_params: ImplParamSet) !void {
    var i: usize = 0;
    while (i < impl_params.len) : (i += 1) {
        const item = impl_params.items[i];
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "    comptime ");
        try out.appendSlice(allocator, item.trait_name);
        try out.appendSlice(allocator, ".require(@TypeOf(");
        try out.appendSlice(allocator, item.name);
        try out.appendSlice(allocator, "));\n");
    }
}

fn appendRewrittenSyntax(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], "own var ")) {
            try out.appendSlice(allocator, "var ");
            i += "own var ".len;
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], "impl ")) {
            try out.appendSlice(allocator, "anytype");
            i += "impl ".len;
            while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], "dyn ")) {
            i += "dyn ".len;
            const trait_start = i;
            while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
            try out.appendSlice(allocator, line[trait_start..i]);
            try out.appendSlice(allocator, ".Dyn");
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], "move ")) {
            i += "move ".len;
            continue;
        }

        try out.append(allocator, line[i]);
        i += 1;
    }
}

fn appendParamTypes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), params: []const u8) !void {
    var parts = std.mem.splitScalar(u8, params, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const param_type = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (param_type.len == 0) continue;

        try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, param_type);
    }
}

fn appendParamNames(allocator: std.mem.Allocator, out: *std.ArrayList(u8), params: []const u8) !void {
    var parts = std.mem.splitScalar(u8, params, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");
        if (name.len == 0) continue;

        try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, name);
    }
}

fn collectImplParams(line: []const u8) ImplParamSet {
    var set = ImplParamSet{};
    var cursor: usize = 0;
    while (cursor < line.len) {
        const rel = std.mem.indexOf(u8, line[cursor..], "impl ") orelse break;
        const impl_pos = cursor + rel;
        const trait_start = impl_pos + "impl ".len;
        if (trait_start >= line.len or !isIdentChar(line[trait_start])) {
            cursor = trait_start;
            continue;
        }

        var trait_end = trait_start;
        while (trait_end < line.len and isIdentChar(line[trait_end])) : (trait_end += 1) {}

        if (findParamNameBefore(line, impl_pos)) |name| {
            set.append(.{
                .name = name,
                .trait_name = line[trait_start..trait_end],
            });
        }
        cursor = trait_end;
    }
    return set;
}

fn findParamNameBefore(line: []const u8, before: usize) ?[]const u8 {
    const prefix = line[0..before];
    const colon_pos = std.mem.lastIndexOfScalar(u8, prefix, ':') orelse return null;

    var start = colon_pos;
    while (start > 0) {
        const c = line[start - 1];
        if (c == '(' or c == ',') break;
        start -= 1;
    }

    const name = std.mem.trim(u8, line[start..colon_pos], " \t");
    if (name.len == 0) return null;
    return name;
}

fn parseWhereClause(line: []const u8) ?WhereBoundSet {
    const prefix = "where ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;

    var set = WhereBoundSet{};
    var parts = std.mem.splitScalar(u8, line[prefix.len..], ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t{");
        if (trimmed.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
        const type_name = std.mem.trim(u8, trimmed[0..colon], " \t");
        const trait_name = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (!isIdentifier(type_name) or !isIdentifier(trait_name)) return null;

        set.append(.{
            .type_name = type_name,
            .trait_name = trait_name,
        });
    }

    if (set.len == 0) return null;
    return set;
}

fn parseDeriveStart(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "} derive(")) return null;
    const open = std.mem.indexOf(u8, line, ".{") orelse return null;
    return line[open + ".{".len ..];
}

fn collectDeriveNames(derives: *DeriveSet, text: []const u8) void {
    var cursor: usize = 0;
    while (cursor < text.len) {
        while (cursor < text.len and !isIdentStart(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len) break;

        const start = cursor;
        cursor += 1;
        while (cursor < text.len and isIdentChar(text[cursor])) : (cursor += 1) {}

        const name = text[start..cursor];
        if (!std.mem.eql(u8, name, "derive")) {
            derives.append(name);
        }
    }
}

fn deriveEnds(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "});") != null;
}

fn parseTraitName(line: []const u8) ?[]const u8 {
    const prefix = "trait ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;

    const rest = std.mem.trimLeft(u8, line[prefix.len..], " \t");
    if (rest.len == 0 or !isIdentStart(rest[0])) return null;

    var end: usize = 0;
    while (end < rest.len and isIdentChar(rest[end])) : (end += 1) {}
    return rest[0..end];
}

fn parseTraitMethod(line: []const u8) ?TraitMethod {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    const rest = if (std.mem.startsWith(u8, trimmed, "pub fn "))
        trimmed["pub fn ".len..]
    else if (std.mem.startsWith(u8, trimmed, "fn "))
        trimmed["fn ".len..]
    else
        return null;

    if (rest.len == 0 or !isIdentStart(rest[0])) return null;
    var end: usize = 0;
    while (end < rest.len and isIdentChar(rest[end])) : (end += 1) {}
    const name = rest[0..end];
    const open = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, rest, ')') orelse return null;
    if (close <= open) return null;

    const params = rest[open + 1 .. close];
    const params_after_self = if (std.mem.indexOfScalar(u8, params, ',')) |comma|
        std.mem.trim(u8, params[comma + 1 ..], " \t")
    else
        "";

    const after_params = std.mem.trim(u8, rest[close + 1 ..], " \t;");
    return .{
        .name = name,
        .params_after_self = params_after_self,
        .return_type = if (after_params.len == 0) "void" else after_params,
    };
}

fn braceDelta(line: []const u8) isize {
    var delta: isize = 0;
    for (line) |c| {
        if (c == '{') delta += 1;
        if (c == '}') delta -= 1;
    }
    return delta;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!isIdentStart(text[0])) return false;
    for (text[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

test "lower using binding and impl trait" {
    const source =
        \\trait Writer {
        \\    fn write(self, bytes: []const u8) !usize;
        \\}
        \\
        \\fn emit(w: impl Writer, msg: []const u8) !void {
        \\    _ = try w.write(msg);
        \\}
        \\
        \\pub fn main() !void {
        \\    using writer = try FileWriter.init("log.txt");
        \\    try emit(&writer, "hello\n");
        \\}
    ;
    const parsed = try @import("parser.zig").parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const lowered = try lower(std.testing.allocator, parsed);
    defer std.testing.allocator.free(lowered);

    try std.testing.expect(std.mem.indexOf(u8, lowered, "const Writer = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "if (!hasMethod(U, \"write\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "fn emit(w: anytype, msg: []const u8) !void") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "comptime Writer.require(@TypeOf(w));") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "var writer = try FileWriter.init(\"log.txt\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "defer writer.deinit();") != null);
}

test "lower owned struct closes as Zig declaration" {
    const source =
        \\owned struct Thing {
        \\    value: u32,
        \\}
    ;
    const parsed = try @import("parser.zig").parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const lowered = try lower(std.testing.allocator, parsed);
    defer std.testing.allocator.free(lowered);

    try std.testing.expect(std.mem.indexOf(u8, lowered, "const Thing = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "};") != null);
}

test "collect impl params" {
    const params = collectImplParams("fn copy(dst: impl Writer, src: impl Reader) !void {");

    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("dst", params.items[0].name);
    try std.testing.expectEqualStrings("Writer", params.items[0].trait_name);
    try std.testing.expectEqualStrings("src", params.items[1].name);
    try std.testing.expectEqualStrings("Reader", params.items[1].trait_name);
}

test "lower dyn trait param to explicit carrier" {
    const source =
        \\trait AudioPlugin {
        \\    fn process(self, input: []const f32, output: []f32) void;
        \\}
        \\
        \\fn render(plugin: dyn AudioPlugin, input: []const f32, output: []f32) void {
        \\    plugin.process(input, output);
        \\}
    ;
    const parsed = try @import("parser.zig").parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const lowered = try lower(std.testing.allocator, parsed);
    defer std.testing.allocator.free(lowered);

    try std.testing.expect(std.mem.indexOf(u8, lowered, "pub const VTable = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "process: *const fn (*anyopaque, []const f32, []f32) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "fn render(plugin: AudioPlugin.Dyn, input: []const f32, output: []f32) void") != null);
}

test "lower requires and invariant into function entry checks" {
    const source =
        \\fn at(xs: []const u8, i: usize) u8
        \\    requires(i < xs.len)
        \\    invariant(xs.len > 0)
        \\{
        \\    return xs[i];
        \\}
    ;
    const parsed = try @import("parser.zig").parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const lowered = try lower(std.testing.allocator, parsed);
    defer std.testing.allocator.free(lowered);

    try std.testing.expect(std.mem.indexOf(u8, lowered, "if (!(i < xs.len)) @panic(\"contract requires failed\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "if (!(xs.len > 0)) @panic(\"contract invariant failed\");") != null);
}

test "lower ensures into checked return" {
    const source =
        \\fn abs(x: i32) i32
        \\    ensures(result >= 0)
        \\{
        \\    return if (x < 0) -x else x;
        \\}
    ;
    const parsed = try @import("parser.zig").parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const lowered = try lower(std.testing.allocator, parsed);
    defer std.testing.allocator.free(lowered);

    try std.testing.expect(std.mem.indexOf(u8, lowered, "const zpp_result_0 = if (x < 0) -x else x;") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "if (!(zpp_result_0 >= 0)) @panic(\"contract ensures failed\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "return zpp_result_0;") != null);
}

test "lower multiline impl trait entry check" {
    const source =
        \\trait Writer {
        \\    fn write(self, bytes: []const u8) !usize;
        \\}
        \\
        \\fn emit(w: impl Writer, msg: []const u8) !void
        \\{
        \\    _ = try w.write(msg);
        \\}
    ;
    const parsed = try @import("parser.zig").parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const lowered = try lower(std.testing.allocator, parsed);
    defer std.testing.allocator.free(lowered);

    try std.testing.expect(std.mem.indexOf(u8, lowered, "fn emit(w: anytype, msg: []const u8) !void") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "comptime Writer.require(@TypeOf(w));") != null);
}

test "lower where trait bounds into function entry checks" {
    const source =
        \\trait Ord {
        \\    fn rank(self) u32;
        \\}
        \\
        \\fn min(comptime T: type, a: T, b: T) T
        \\    where T: Ord
        \\{
        \\    if (a.rank() < b.rank()) return a;
        \\    return b;
        \\}
    ;
    const parsed = try @import("parser.zig").parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const lowered = try lower(std.testing.allocator, parsed);
    defer std.testing.allocator.free(lowered);

    try std.testing.expect(std.mem.indexOf(u8, lowered, "// zpp: where T: Ord") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "comptime Ord.require(T);") != null);
}

test "lower derive block into visible comptime helper declarations" {
    const source =
        \\const zpp = @import("zpp");
        \\
        \\const User = struct {
        \\    id: u64,
        \\    name: []const u8,
        \\} derive(.{
        \\    Json,
        \\    Hash,
        \\    Debug,
        \\});
    ;
    const parsed = try @import("parser.zig").parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const lowered = try lower(std.testing.allocator, parsed);
    defer std.testing.allocator.free(lowered);

    try std.testing.expect(std.mem.indexOf(u8, lowered, "pub const json = zpp.derive.Json(@This());") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "pub const hash = zpp.derive.Hash(@This());") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "pub const debug = zpp.derive.Debug(@This());") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered, "} derive") == null);
}
