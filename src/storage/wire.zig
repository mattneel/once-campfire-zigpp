const std = @import("std");
const Allocator = std.mem.Allocator;
const entries = @import("approximations.zig").entries;

pub fn sanitize(allocator: Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c\x00");
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var i: usize = 0;
    while (i < trimmed.len) {
        const len = std.unicode.utf8ByteSequenceLength(trimmed[i]) catch {
            try out.writer.writeAll("\xef\xbf\xbd");
            i += 1;
            continue;
        };
        if (i + len > trimmed.len) {
            try out.writer.writeAll("\xef\xbf\xbd");
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(trimmed[i..][0..len]) catch {
            try out.writer.writeAll("\xef\xbf\xbd");
            i += 1;
            continue;
        };
        if (cp == 0x202e or (cp < 128 and std.mem.indexOfScalar(u8, "%$|:;/<>?*\"\t\r\n\\", @intCast(cp)) != null)) try out.writer.writeByte('-') else try out.writer.writeAll(trimmed[i..][0..len]);
        i += len;
    }
    return out.toOwnedSlice();
}
const Escape = enum { segment, path, traditional, rfc5987 };
fn escape(allocator: Allocator, raw: []const u8, mode: Escape) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (raw) |b| {
        const allowed = std.ascii.isAlphanumeric(b) or switch (mode) {
            .segment => std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@", b) != null,
            .path => std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@/", b) != null,
            .traditional => std.mem.indexOfScalar(u8, " !#$+.^_`|~-", b) != null,
            .rfc5987 => std.mem.indexOfScalar(u8, "!#$&+.^_`|~-", b) != null,
        };
        if (allowed) try out.writer.writeByte(b) else {
            const hex = "0123456789ABCDEF";
            try out.writer.writeAll(&.{ '%', hex[b >> 4], hex[b & 15] });
        }
    }
    return out.toOwnedSlice();
}
pub fn segment(allocator: Allocator, raw: []const u8) ![]const u8 {
    return escape(allocator, raw, .segment);
}
pub fn filenamePath(allocator: Allocator, raw: []const u8) ![]const u8 {
    const clean = try sanitize(allocator, raw);
    defer allocator.free(clean);
    return escape(allocator, clean, .path);
}
pub fn decodeSegment(allocator: Allocator, raw: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%') {
            if (raw.len - i < 3) return error.InvalidUrlEncoding;
            const b = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.InvalidUrlEncoding;
            try out.writer.writeByte(b);
            i += 2;
        } else try out.writer.writeByte(raw[i]);
    }
    return out.toOwnedSlice();
}
pub fn disposition(allocator: Allocator, kind: []const u8, raw: []const u8) ![]const u8 {
    const clean = try sanitize(allocator, raw);
    defer allocator.free(clean);
    var ascii: std.Io.Writer.Allocating = .init(allocator);
    defer ascii.deinit();
    var iter = (try std.unicode.Utf8View.init(clean)).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp < 128) {
            try ascii.writer.writeByte(@intCast(cp));
            continue;
        }
        var replacement: []const u8 = "?";
        // Tiny immutable table; binary search avoids work proportional to table size.
        var lo: usize = 0;
        var hi: usize = entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (entries[mid].codepoint < cp) lo = mid + 1 else hi = mid;
        }
        if (lo < entries.len and entries[lo].codepoint == cp) replacement = entries[lo].replacement;
        try ascii.writer.writeAll(replacement);
    }
    const traditional = try escape(allocator, ascii.written(), .traditional);
    defer allocator.free(traditional);
    const extended = try escape(allocator, clean, .rfc5987);
    defer allocator.free(extended);
    return std.fmt.allocPrint(allocator, "{s}; filename=\"{s}\"; filename*=UTF-8''{s}", .{ kind, traditional, extended });
}

pub const Range = struct { start: usize, end: usize };
/// Rack 3.2 semantics: null means full response; empty means unsatisfiable.
/// Ruby String#to_i intentionally accepts non-numeric fields as zero.
pub fn ranges(allocator: Allocator, raw: ?[]const u8, size: usize) !?[]const Range {
    if (size == 0) return null;
    const header = raw orelse return null;
    var rest = header;
    var spec: ?[]const u8 = null;
    while (std.mem.indexOf(u8, rest, "bytes=")) |at| {
        rest = rest[at + 6 ..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        if (end != 0) {
            spec = rest[0..end];
            break;
        }
    }
    const value = spec orelse return null;
    if (std.mem.count(u8, value, ",") >= 100) return null;
    var list: std.ArrayList(Range) = .empty;
    errdefer list.deinit(allocator);
    var total: u128 = 0;
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, value, ","), ',');
    var first = true;
    while (parts.next()) |p| {
        const part = if (first) p else std.mem.trimStart(u8, p, " \t");
        first = false;
        const dash = std.mem.indexOfScalar(u8, part, '-') orelse {
            list.deinit(allocator);
            return null;
        };
        const rhs = part[dash + 1 ..];
        const rhs_end = std.mem.indexOfScalar(u8, rhs, '-') orelse rhs.len;
        const left = part[0..dash];
        const right = rhs[0..rhs_end];
        var start: u128 = 0;
        var end: u128 = size - 1;
        if (left.len == 0) {
            if (rhs.len == 0 or std.mem.trim(u8, rhs, "-").len == 0) {
                list.deinit(allocator);
                return null;
            }
            const suffix = rubyInteger(right);
            start = size -| suffix;
        } else {
            start = rubyInteger(left);
            if (right.len != 0) {
                end = rubyInteger(right);
                if (end < start) {
                    list.deinit(allocator);
                    return null;
                }
                end = @min(end, size - 1);
            }
        }
        if (start <= end) {
            try list.append(allocator, .{ .start = @intCast(start), .end = @intCast(end) });
            total += end - start + 1;
        }
    }
    if (total > size) list.clearRetainingCapacity();
    return try list.toOwnedSlice(allocator);
}
fn rubyInteger(raw: []const u8) u128 {
    var s = std.mem.trimStart(u8, raw, " \t\r\n\x0b\x0c");
    if (std.mem.startsWith(u8, s, "+")) s = s[1..];
    if (std.mem.startsWith(u8, s, "0d") or std.mem.startsWith(u8, s, "0D")) s = s[2..];
    var result: u128 = 0;
    var digit = false;
    var underscore = false;
    for (s) |b| {
        if (b >= '0' and b <= '9') {
            result = result *| 10 +| (b - '0');
            digit = true;
            underscore = false;
        } else if (b == '_' and digit and !underscore) underscore = true else break;
    }
    return result;
}

test "filename formatting retains canonical sanitization and transliteration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("inline; filename=\"Lodz x.pdf\"; filename*=UTF-8''%C5%81%C3%B3d%C5%BA%20%C3%97.pdf", try disposition(a, "inline", "Łódź ×.pdf"));
    try std.testing.expectEqualStrings("a-b-c--.png", try sanitize(a, " a/b:c\"?.png "));
    try std.testing.expectEqualStrings("file%20(1).png", try filenamePath(a, "file (1).png"));
    try std.testing.expectEqualStrings("a+b/c", try decodeSegment(a, "a+b%2Fc"));
    try std.testing.expectError(error.InvalidUrlEncoding, decodeSegment(a, "broken%"));
}
test "Rack byte ranges cover suffix bounds malformed fields and overlaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const normal = (try ranges(a, "bytes=0-4", 10)).?;
    try std.testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 4 }}, normal);
    const suffix = (try ranges(a, "bytes=-30", 10)).?;
    try std.testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 9 }}, suffix);
    try std.testing.expectEqual(@as(usize, 0), (try ranges(a, "bytes=10-", 10)).?.len);
    try std.testing.expectEqual(@as(usize, 0), (try ranges(a, "bytes=0-4,5-9,0-0", 10)).?.len);
    try std.testing.expect((try ranges(a, "bytes=1-0", 10)) == null);
    try std.testing.expect((try ranges(a, "bytes=0-1,,2-3", 10)) == null);
    try std.testing.expect((try ranges(a, "bytes=0-4", 0)) == null);
    const permissive = (try ranges(a, "bytes=a-b", 10)).?;
    try std.testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 0 }}, permissive);
}
