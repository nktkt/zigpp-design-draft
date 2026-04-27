const std = @import("std");
const zpp = @import("zpp");

const max_header_bytes = 64 * 1024;
const max_payload_bytes = 16 * 1024 * 1024;

pub const HandleResult = struct {
    body: ?[]u8 = null,
    should_exit: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    while (true) {
        const payload = try readMessage(allocator, stdin) orelse return;
        defer allocator.free(payload);

        const result = try handlePayload(allocator, payload);
        defer if (result.body) |body| allocator.free(body);

        if (result.body) |body| {
            try writeFramed(allocator, stdout, body);
        }
        if (result.should_exit) return;
    }
}

pub fn handlePayload(allocator: std.mem.Allocator, payload: []const u8) !HandleResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const method = getStringField(root, "method") orelse return .{};
    const id = getField(root, "id");

    if (std.mem.eql(u8, method, "initialize")) {
        if (id) |request_id| {
            return .{ .body = try initializeResponse(allocator, request_id) };
        }
        return .{};
    }

    if (std.mem.eql(u8, method, "shutdown")) {
        if (id) |request_id| {
            return .{ .body = try shutdownResponse(allocator, request_id) };
        }
        return .{};
    }

    if (std.mem.eql(u8, method, "exit")) {
        return .{ .should_exit = true };
    }

    if (std.mem.eql(u8, method, "textDocument/didOpen") or
        std.mem.eql(u8, method, "textDocument/didChange"))
    {
        if (extractTextDocument(method, root)) |document| {
            return .{ .body = try diagnosticsNotification(allocator, document.uri, document.text) };
        }
    }

    return .{};
}

fn readMessage(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const count = try file.read(&byte);
        if (count == 0) {
            if (headers.items.len == 0) return null;
            return error.EndOfStream;
        }

        try headers.append(allocator, byte[0]);
        if (headers.items.len > max_header_bytes) return error.MessageTooLarge;

        if (std.mem.endsWith(u8, headers.items, "\r\n\r\n") or
            std.mem.endsWith(u8, headers.items, "\n\n"))
        {
            break;
        }
    }

    const content_length = parseContentLength(headers.items) orelse return error.MissingContentLength;
    if (content_length > max_payload_bytes) return error.MessageTooLarge;

    const payload = try allocator.alloc(u8, content_length);
    errdefer allocator.free(payload);

    const read_count = try file.readAll(payload);
    if (read_count != content_length) return error.EndOfStream;
    return payload;
}

fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

fn writeFramed(allocator: std.mem.Allocator, file: std.fs.File, body: []const u8) !void {
    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body.len});
    defer allocator.free(header);

    try file.writeAll(header);
    try file.writeAll(body);
}

const TextDocument = struct {
    uri: []const u8,
    text: []const u8,
};

fn extractTextDocument(method: []const u8, root: std.json.Value) ?TextDocument {
    const params = getField(root, "params") orelse return null;
    const text_document = getField(params, "textDocument") orelse return null;
    const uri = getStringField(text_document, "uri") orelse return null;

    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        const text = getStringField(text_document, "text") orelse return null;
        return .{ .uri = uri, .text = text };
    }

    const content_changes = getField(params, "contentChanges") orelse return null;
    switch (content_changes) {
        .array => |changes| {
            if (changes.items.len == 0) return null;
            const last_change = changes.items[changes.items.len - 1];
            const text = getStringField(last_change, "text") orelse return null;
            return .{ .uri = uri, .text = text };
        },
        else => return null,
    }
}

fn initializeResponse(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(allocator, &out, id);
    try out.appendSlice(allocator, ",\"result\":{\"capabilities\":{\"textDocumentSync\":1},\"serverInfo\":{\"name\":\"zpp-lsp\",\"version\":\"0.1\"}}}");

    return out.toOwnedSlice(allocator);
}

fn shutdownResponse(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(allocator, &out, id);
    try out.appendSlice(allocator, ",\"result\":null}");

    return out.toOwnedSlice(allocator);
}

fn diagnosticsNotification(allocator: std.mem.Allocator, uri: []const u8, source: []const u8) ![]u8 {
    const diags = try zpp.sema.checkSource(allocator, source);
    defer allocator.free(diags);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
    try appendJsonString(allocator, &out, uri);
    try out.appendSlice(allocator, ",\"diagnostics\":[");

    for (diags, 0..) |diag, index| {
        if (index != 0) try out.append(allocator, ',');

        const line = if (diag.line == 0) 0 else diag.line - 1;
        const character = if (diag.column == 0) 0 else diag.column - 1;

        try out.appendSlice(allocator, "{\"range\":{\"start\":{\"line\":");
        try out.writer(allocator).print("{d}", .{line});
        try out.appendSlice(allocator, ",\"character\":");
        try out.writer(allocator).print("{d}", .{character});
        try out.appendSlice(allocator, "},\"end\":{\"line\":");
        try out.writer(allocator).print("{d}", .{line});
        try out.appendSlice(allocator, ",\"character\":");
        try out.writer(allocator).print("{d}", .{character + 1});
        try out.appendSlice(allocator, "}},\"severity\":");
        try out.writer(allocator).print("{d}", .{lspSeverity(diag.severity)});
        try out.appendSlice(allocator, ",\"source\":\"zpp\",\"message\":");
        try appendJsonString(allocator, &out, diag.message);
        try out.append(allocator, '}');
    }

    try out.appendSlice(allocator, "]}}");
    return out.toOwnedSlice(allocator);
}

fn lspSeverity(severity: zpp.diagnostics.Severity) u8 {
    return switch (severity) {
        .err => 1,
        .warning => 2,
        .note => 3,
    };
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn getStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn appendJsonValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |inner| try out.appendSlice(allocator, if (inner) "true" else "false"),
        .integer => |inner| try out.writer(allocator).print("{d}", .{inner}),
        .float => |inner| try out.writer(allocator).print("{d}", .{inner}),
        .number_string => |inner| try out.appendSlice(allocator, inner),
        .string => |inner| try appendJsonString(allocator, out, inner),
        else => try out.appendSlice(allocator, "null"),
    }
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hexDigit(c >> 4));
                    try out.append(allocator, hexDigit(c & 0x0f));
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

test "handlePayload responds to initialize" {
    const result = try handlePayload(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    );
    defer if (result.body) |body| std.testing.allocator.free(body);

    try std.testing.expect(!result.should_exit);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":1},\"serverInfo\":{\"name\":\"zpp-lsp\",\"version\":\"0.1\"}}}",
        result.body.?,
    );
}

test "handlePayload publishes sema diagnostics for didOpen" {
    const result = try handlePayload(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/test.zpp\",\"text\":\"own var buf = init();\\n\"}}}",
    );
    defer if (result.body) |body| std.testing.allocator.free(body);

    try std.testing.expect(result.body != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body.?, "textDocument/publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body.?, "owned value must be paired") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body.?, "\"severity\":1") != null);
}

test "parseContentLength accepts common LSP headers" {
    try std.testing.expectEqual(@as(?usize, 17), parseContentLength("Content-Length: 17\r\n\r\n"));
    try std.testing.expectEqual(@as(?usize, 9), parseContentLength("content-length: 9\n\n"));
}
