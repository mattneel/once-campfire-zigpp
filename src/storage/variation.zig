const std = @import("std");
const Allocator = std.mem.Allocator;

/// The only transformations declared by Campfire. URL decoding converts symbol
/// values to strings; that distinction is significant in the Rails Marshal digest.
pub const Variation = struct {
    width: ?u16,
    height: ?u16,
    format: []const u8,
    symbol_format: bool = false,
    empty: bool = false,
    format_explicit: bool = true,

    pub fn avatar() Variation { return .{ .width = 512, .height = 512, .format = "webp", .symbol_format = true }; }
    pub fn logo(size: u16) !Variation {
        if (size != 512 and size != 192) return error.UnsupportedVariation;
        return .{ .width = size, .height = size, .format = "png", .symbol_format = true };
    }
    pub fn decode(allocator: Allocator, json: []const u8, default_format: []const u8) !Variation {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const v = parsed.value;
        if (v != .object or v.object.count() > 2) return error.UnsupportedVariation;
        var width: ?u16 = null;
        var height: ?u16 = null;
        var format = default_format;
        var it = v.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "format")) {
                if (entry.value_ptr.* != .string) return error.UnsupportedVariation;
                format = entry.value_ptr.string;
            } else if (std.mem.eql(u8, entry.key_ptr.*, "resize_to_limit")) {
                if (entry.value_ptr.* != .array or entry.value_ptr.array.items.len != 2) return error.UnsupportedVariation;
                const dims = entry.value_ptr.array.items;
                if (dims[0] != .integer or dims[1] != .integer) return error.UnsupportedVariation;
                width = std.math.cast(u16, dims[0].integer) orelse return error.UnsupportedVariation;
                height = std.math.cast(u16, dims[1].integer) orelse return error.UnsupportedVariation;
            } else return error.UnsupportedVariation;
        }
        var allowed_format = false;
        for ([_][]const u8{ "png", "jpg", "jpeg", "jpe", "jif", "jfif", "jfi", "gif", "webp" }) |allowed| if (std.ascii.eqlIgnoreCase(format, allowed)) { allowed_format = true; break; };
        if (!allowed_format) return error.UnsupportedVariation;
        const named = if (width) |w| if (height) |h| (w == 512 and h == 512 and (std.mem.eql(u8, format, "webp") or std.mem.eql(u8, format, "png"))) or (w == 192 and h == 192 and std.mem.eql(u8, format, "png")) or (w == 1200 and h == 800) else false else height == null and (v.object.count() == 0 or std.mem.eql(u8, format, "webp"));
        if (!named) return error.UnsupportedVariation;
        return .{ .width = width, .height = height, .format = try allocator.dupe(u8, format), .empty = v.object.count() == 0, .format_explicit = v.object.contains("format") };
    }

    /// default_to(format:) puts format first, even when the original named
    /// declaration had resize_to_limit first. Symbol table includes encoding E.
    pub fn digest(self: Variation, allocator: Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll(&.{ 4, 8, '{' });
        try rubyLong(w, if (self.width != null) 2 else 1);
        try symbol(w, "format");
        if (self.symbol_format) {
            try symbol(w, self.format);
        } else {
            try w.writeAll("I\"");
            try bytes(w, self.format);
            try rubyLong(w, 1);
            try symbol(w, "E");
            try w.writeByte('T');
        }
        if (self.width) |width| {
            try symbol(w, "resize_to_limit");
            try w.writeByte('[');
            try rubyLong(w, 2);
            try w.writeByte('i');
            try rubyLong(w, width);
            try w.writeByte('i');
            try rubyLong(w, self.height.?);
        }
        var sum: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(out.written(), &sum, .{});
        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(sum.len));
        return std.base64.standard.Encoder.encode(encoded, &sum);
    }
    pub fn contentType(self: Variation) []const u8 {
        if (std.ascii.eqlIgnoreCase(self.format, "png")) return "image/png";
        if (std.ascii.eqlIgnoreCase(self.format, "webp")) return "image/webp";
        if (std.ascii.eqlIgnoreCase(self.format, "gif")) return "image/gif";
        return "image/jpeg";
    }
};
fn bytes(w: *std.Io.Writer, value: []const u8) !void {
    try rubyLong(w, @intCast(value.len));
    try w.writeAll(value);
}
fn symbol(w: *std.Io.Writer, value: []const u8) !void { try w.writeByte(':'); try bytes(w, value); }
fn rubyLong(w: *std.Io.Writer, value: u64) !void {
    if (value == 0) return w.writeByte(0);
    if (value < 123) return w.writeByte(@intCast(value + 5));
    var n = value;
    var buf: [9]u8 = undefined;
    var len: usize = 1;
    while (n != 0) : (len += 1) { buf[len] = @truncate(n); n >>= 8; }
    buf[0] = @intCast(len - 1);
    try w.writeAll(buf[0..len]);
}

test "named variation decoding preserves strict scope and default format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try Variation.decode(a, "{\"resize_to_limit\":[1200,800]}", "jpeg");
    try std.testing.expectEqualStrings("jpeg", v.format);
    try std.testing.expectEqual(@as(?u16, 1200), v.width);
    try std.testing.expectError(error.UnsupportedVariation, Variation.decode(a, "{\"resize_to_limit\":[37,37]}", "png"));
    try std.testing.expectError(error.UnsupportedVariation, Variation.decode(a, "{\"resize_to_limit\":[-1,800]}", "png"));
    try std.testing.expectError(error.UnsupportedVariation, Variation.decode(a, "{\"rotate\":90}", "png"));
    try std.testing.expectError(error.UnsupportedVariation, Variation.decode(a, "{\"format\":\"svg\"}", "png"));
    const symbol_digest = try Variation.avatar().digest(a);
    const string_digest = try (Variation{ .width = 512, .height = 512, .format = "webp" }).digest(a);
    try std.testing.expect(!std.mem.eql(u8, symbol_digest, string_digest));
}

test "Marshal digests match canonical symbol and URL-decoded vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("6gwfjNKv9eUy9jNUtEZvQFLU0hQ=", try Variation.avatar().digest(a));
    const decoded = try Variation.decode(a, "{\"format\":\"webp\",\"resize_to_limit\":[512,512]}", "png");
    try std.testing.expectEqualStrings("3xm5qtUwCk3YQHQ55FXsVFKT908=", try decoded.digest(a));
    try std.testing.expectEqualStrings("ksXvpLsa7BuCVyHOwmQOKedbIbM=", try (try Variation.logo(512)).digest(a));
}
