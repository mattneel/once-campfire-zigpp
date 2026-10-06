//! The Rails ParamBuilder contracts used by native Campfire requests.
//! Source: crates/kit/src/params.rs; body/query maps merge shallowly, query wins.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidEncoding, ParameterType, TooDeep, TooManyParameters, BodyTooLarge, InvalidBody } || Allocator.Error;

pub const Value = union(enum) {
    null,
    string: []const u8,
    other,
    file,
    array: std.ArrayList(Value),
    object: Map,

    pub fn str(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .object => |map| map.get(key),
            else => null,
        };
    }
};

pub const Map = struct {
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,

    pub fn get(self: Map, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn str(self: Map, key: []const u8) ?[]const u8 {
        return if (self.get(key)) |value| value.str() else null;
    }

    pub fn merge(self: *Map, allocator: Allocator, other: Map) Allocator.Error!void {
        for (other.entries.keys(), other.entries.values()) |key, value| try self.entries.put(allocator, key, value);
    }
};

pub fn decode(allocator: Allocator, text: []const u8) Error![]const u8 {
    const out = try allocator.alloc(u8, text.len);
    var src: usize = 0;
    var dst: usize = 0;
    while (src < text.len) {
        switch (text[src]) {
            '+' => out[dst] = ' ',
            '%' => {
                if (text.len - src < 3) return error.InvalidEncoding;
                const hi = std.fmt.charToDigit(text[src + 1], 16) catch return error.InvalidEncoding;
                const lo = std.fmt.charToDigit(text[src + 2], 16) catch return error.InvalidEncoding;
                out[dst] = hi * 16 + lo;
                src += 2;
            },
            else => out[dst] = text[src],
        }
        src += 1;
        dst += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out[0..dst])) return error.InvalidEncoding;
    return out[0..dst];
}

pub fn form(allocator: Allocator, text: []const u8, is_body: bool) Error!Map {
    if (is_body and text.len > 4 * 1024 * 1024) return error.BodyTooLarge;
    var result: Map = .{};
    var pairs = std.mem.splitScalar(u8, text, '&');
    var count: usize = 0;
    var first = true;
    while (pairs.next()) |raw| {
        const pair = if (first) raw else std.mem.trimStart(u8, raw, " ");
        first = false;
        if (pair.len == 0) continue;
        count += 1;
        if (is_body and count > 4096) return error.TooManyParameters;
        const equal = std.mem.indexOfScalar(u8, pair, '=');
        const key = try decode(allocator, pair[0 .. equal orelse pair.len]);
        const value: Value = if (equal) |at| .{ .string = try decode(allocator, pair[at + 1 ..]) } else .null;
        _ = try store(allocator, &result, key, value, 0);
    }
    return result;
}

const Stored = union(enum) { map, nil, array: std.ArrayList(Value) };

fn childValue(child: Map, stored: Stored) Value {
    return switch (stored) {
        .map => .{ .object = child },
        .nil => .null,
        .array => |items| .{ .array = items },
    };
}

fn arraySlot(allocator: Allocator, map: *Map, key: []const u8) Error!*std.ArrayList(Value) {
    const slot = try map.entries.getOrPut(allocator, key);
    if (!slot.found_existing or slot.value_ptr.* == .null) slot.value_ptr.* = .{ .array = .empty };
    return switch (slot.value_ptr.*) {
        .array => |*array| array,
        else => error.ParameterType,
    };
}

fn hasNestedKey(map: Map, key: []const u8) bool {
    if (std.mem.indexOf(u8, key, "[]") != null) return false;
    var parts = std.mem.tokenizeAny(u8, key, "[]");
    var current: ?Map = map;
    while (parts.next()) |part| {
        const value = (current orelse return false).get(part) orelse return false;
        current = switch (value) {
            .object => |next| next,
            else => null,
        };
    }
    return true;
}

fn store(allocator: Allocator, map: *Map, name: []const u8, value: Value, depth: usize) Error!Stored {
    if (depth >= 100) return error.TooDeep;
    const split: struct { key: []const u8, after: []const u8 } = if (depth == 0) blk: {
        const at = if (name.len > 1) std.mem.indexOfScalarPos(u8, name, 1, '[') else null;
        break :blk if (at) |n| .{ .key = name[0..n], .after = name[n..] } else .{ .key = name, .after = "" };
    } else if (std.mem.startsWith(u8, name, "[]")) .{ .key = "[]", .after = name[2..] } else blk: {
        const at = if (std.mem.startsWith(u8, name, "[")) std.mem.indexOfScalarPos(u8, name, 1, ']') else null;
        break :blk if (at) |n| .{ .key = name[1..n], .after = name[n + 1 ..] } else .{ .key = name, .after = "" };
    };
    const key = split.key;
    const after = split.after;
    if (key.len == 0) return .nil;
    if (after.len == 0) {
        if (depth != 0 and std.mem.eql(u8, key, "[]")) {
            var items: std.ArrayList(Value) = .empty;
            if (value != .null) try items.append(allocator, value);
            return .{ .array = items };
        }
        try map.entries.put(allocator, key, value);
    } else if (std.mem.eql(u8, after, "[")) {
        try map.entries.put(allocator, name, value);
    } else if (std.mem.eql(u8, after, "[]")) {
        const items = try arraySlot(allocator, map, key);
        if (value != .null) try items.append(allocator, value);
    } else if (std.mem.startsWith(u8, after, "[]")) {
        const nested = after[2..];
        const child_key = if (nested.len > 2 and nested[0] == '[' and nested[nested.len - 1] == ']' and
            std.mem.indexOfAny(u8, nested[1 .. nested.len - 1], "[]") == null)
            nested[1 .. nested.len - 1]
        else
            nested;
        const items = try arraySlot(allocator, map, key);
        if (items.items.len != 0) {
            const last = &items.items[items.items.len - 1];
            if (last.* == .object and !hasNestedKey(last.object, child_key)) {
                _ = try store(allocator, &last.object, child_key, value, depth + 1);
                return .map;
            }
        }
        var child: Map = .{};
        const stored = try store(allocator, &child, child_key, value, depth + 1);
        try items.append(allocator, childValue(child, stored));
    } else {
        var child: Map = if (map.get(key)) |existing| switch (existing) {
            .null => .{},
            .object => |child| child,
            else => return error.ParameterType,
        } else .{};
        const stored = try store(allocator, &child, after, value, depth + 1);
        try map.entries.put(allocator, key, childValue(child, stored));
    }
    return .map;
}

fn fromJson(allocator: Allocator, value: std.json.Value, depth: usize) Error!Value {
    if (depth >= 100) return error.TooDeep;
    return switch (value) {
        .null => .null,
        .string => |s| .{ .string = s },
        .object => |object| blk: {
            var map: Map = .{};
            for (object.keys(), object.values()) |key, child| try map.entries.put(allocator, key, try fromJson(allocator, child, depth + 1));
            break :blk .{ .object = map };
        },
        .array => |array| blk: {
            var items: std.ArrayList(Value) = .empty;
            for (array.items) |child| if (child != .null) {
                try items.append(allocator, try fromJson(allocator, child, depth + 1));
            };
            break :blk .{ .array = items };
        },
        else => .other,
    };
}

pub fn json(allocator: Allocator, text: []const u8) Error!Map {
    const value = std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidBody;
    const converted = try fromJson(allocator, value.value, 0);
    if (converted == .object) return converted.object;
    var root: Map = .{};
    try root.entries.put(allocator, "_json", converted);
    return root;
}

fn quotedParameter(header: []const u8, name: []const u8) ?[]const u8 {
    var pieces = std.mem.splitScalar(u8, header, ';');
    while (pieces.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        const at = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(part[0..at], name)) continue;
        const value = std.mem.trim(u8, part[at + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
        return value;
    }
    return null;
}

pub fn multipart(allocator: Allocator, content_type: []const u8, body: []const u8) Error!Map {
    const boundary = quotedParameter(content_type, "boundary") orelse return error.InvalidBody;
    if (boundary.len == 0 or boundary.len > 70 or std.mem.indexOfAny(u8, boundary, "\r\n") != null) return error.InvalidBody;
    const marker = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    const next_marker = try std.fmt.allocPrint(allocator, "\r\n{s}", .{marker});
    var position = std.mem.indexOf(u8, body, marker) orelse return error.InvalidBody;
    var result: Map = .{};
    var count: usize = 0;
    while (true) {
        position += marker.len;
        if (std.mem.startsWith(u8, body[position..], "--")) break;
        if (!std.mem.startsWith(u8, body[position..], "\r\n")) return error.InvalidBody;
        position += 2;
        const head_end = std.mem.indexOfPos(u8, body, position, "\r\n\r\n") orelse return error.InvalidBody;
        var lines = std.mem.splitSequence(u8, body[position..head_end], "\r\n");
        var disposition: ?[]const u8 = null;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidBody;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "content-disposition")) disposition = std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        const header = disposition orelse return error.InvalidBody;
        const name = quotedParameter(header, "name") orelse return error.InvalidBody;
        const data_start = head_end + 4;
        const data_end = std.mem.indexOfPos(u8, body, data_start, next_marker) orelse return error.InvalidBody;
        const value: Value = if (quotedParameter(header, "filename") != null) .file else .{ .string = body[data_start..data_end] };
        if (value == .string and !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidEncoding;
        count += 1;
        if (count > 4096) return error.TooManyParameters;
        _ = try store(allocator, &result, name, value, 0);
        position = data_end + 2;
    }
    return result;
}

test "nested message body, repeated scalars and query precedence preserve Rails parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body = try form(a, "message[body]=%3Cp%3ECoffee+%26+tea%3C%2Fp%3E&message[client_message_id]=a&q=old&q=body", true);
    const query = try form(a, "q=query", false);
    try body.merge(a, query);
    try std.testing.expectEqualStrings("query", body.str("q").?);
    try std.testing.expectEqualStrings("<p>Coffee & tea</p>", body.get("message").?.get("body").?.str().?);
    try std.testing.expectError(error.ParameterType, form(a, "message=bad&message[body]=x", true));
    try std.testing.expectError(error.InvalidEncoding, form(a, "q=%Q0", false));
}

test "arrays of parameter hashes reuse only absent keys and JSON deep munges nulls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const map = try form(a, "x[][a]=1&x[][b]=2&x[][a]=3&empty[]", false);
    const items = map.get("x").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("2", items[0].get("b").?.str().?);
    try std.testing.expectEqualStrings("3", items[1].get("a").?.str().?);
    const parsed = try json(a, "{\"x\":[null,\"a\",null,\"b\"]}");
    try std.testing.expectEqual(@as(usize, 2), parsed.get("x").?.array.items.len);
    const root_array = try json(a, "[null,\"body\"]");
    try std.testing.expectEqualStrings("body", root_array.get("_json").?.array.items[0].str().?);
}

test "multipart text fields preserve message content and identify unsupported file assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = "--abc\r\nContent-Disposition: form-data; name=\"message[body]\"\r\n\r\n<p>Hello</p>\r\n--abc\r\nContent-Disposition: form-data; name=\"message[attachment]\"; filename=\"a.png\"\r\n\r\nbytes\r\n--abc--\r\n";
    const parsed = try multipart(arena.allocator(), "multipart/form-data; boundary=abc", body);
    try std.testing.expectEqualStrings("<p>Hello</p>", parsed.get("message").?.get("body").?.str().?);
    try std.testing.expect(parsed.get("message").?.get("attachment").? == .file);
}
