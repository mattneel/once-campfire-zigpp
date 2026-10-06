const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Instant = struct { seconds: i64, nanos: u32 = 0 };

// Rails DB timestamps are UTC even when SQLite omits a timezone suffix.
pub fn parse(text: []const u8) !Instant {
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return error.InvalidTimestamp;
    const y = try number(text[0..4]);
    const m = try number(text[5..7]);
    const d = try number(text[8..10]);
    const h = try number(text[11..13]);
    const min = try number(text[14..16]);
    const sec = try number(text[17..19]);
    if (m < 1 or m > 12 or d < 1 or d > monthDays(y, m) or h > 23 or min > 59 or sec > 59) return error.InvalidTimestamp;
    var i: usize = 19;
    var nanos: u32 = 0;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            if (i - start < 9) nanos = nanos * 10 + text[i] - '0';
        }
        if (i == start) return error.InvalidTimestamp;
        var n = @min(i - start, 9);
        while (n < 9) : (n += 1) nanos *= 10;
    }
    var offset: i64 = 0;
    if (i < text.len) {
        switch (text[i]) {
            'Z' => i += 1,
            '+', '-' => {
                const sign: i64 = if (text[i] == '+') 1 else -1;
                if (text.len - i != 6 or text[i + 3] != ':') return error.InvalidTimestamp;
                const oh = try number(text[i + 1 .. i + 3]);
                const om = try number(text[i + 4 .. i + 6]);
                if (oh > 23 or om > 59) return error.InvalidTimestamp;
                offset = sign * (oh * 3600 + om * 60);
                i += 6;
            },
            else => return error.InvalidTimestamp,
        }
    }
    if (i != text.len) return error.InvalidTimestamp;
    return .{ .seconds = daysFromCivil(y, m, d) * 86400 + h * 3600 + min * 60 + sec - offset, .nanos = nanos };
}

fn number(s: []const u8) !i64 {
    for (s) |c| if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
    return std.fmt.parseInt(i64, s, 10) catch error.InvalidTimestamp;
}

fn monthDays(y: i64, m: i64) i64 {
    return switch (m) {
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

// Proleptic Gregorian civil-date conversion, with floor division for pre-epoch dates.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn unixSeconds(text: []const u8) !i64 {
    return (try parse(text)).seconds;
}
pub fn epochMilliseconds(text: []const u8) !i64 {
    const t = try parse(text);
    return t.seconds * 1000 + @divTrunc(t.nanos, 1_000_000);
}

pub fn format(allocator: Allocator, t: Instant, precision: usize, database: bool) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try write(&out.writer, t, precision, database);
    return out.toOwnedSlice();
}

pub fn write(writer: *std.Io.Writer, t: Instant, precision: usize, database: bool) !void {
    if (precision > 9) return error.InvalidPrecision;
    const days = @divFloor(t.seconds, 86400);
    const sod = @mod(t.seconds, 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = mp + @as(i64, if (mp < 10) 3 else -9);
    if (m <= 2) y += 1;
    if (y < 0 or y > 9999) return error.InvalidTimestamp;
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u16, @intCast(y)), @as(u8, @intCast(m)), @as(u8, @intCast(d)), @as(u8, if (database) ' ' else 'T'), @as(u8, @intCast(@divTrunc(sod, 3600))), @as(u8, @intCast(@divTrunc(@mod(sod, 3600), 60))), @as(u8, @intCast(@mod(sod, 60))) });
    if (precision > 0) {
        var fraction: [9]u8 = undefined;
        _ = try std.fmt.bufPrint(&fraction, "{d:0>9}", .{t.nanos});
        try writer.writeByte('.');
        try writer.writeAll(fraction[0..precision]);
    }
    if (!database) try writer.writeByte('Z');
}

pub fn iso8601(allocator: Allocator, text: []const u8, precision: usize) ![]const u8 {
    return format(allocator, try parse(text), precision, false);
}
pub fn nowText(allocator: Allocator, io: std.Io) ![]const u8 {
    const ns = std.Io.Clock.real.now(io).nanoseconds;
    return format(allocator, .{ .seconds = @intCast(@divFloor(ns, 1_000_000_000)), .nanos = @intCast(@mod(ns, 1_000_000_000)) }, 6, true);
}

test "Rails UTC precision leap days offsets and pre-epoch dates" {
    const a = std.testing.allocator;
    const s = try iso8601(a, "2026-01-01 12:00:00.123999", 3);
    defer a.free(s);
    try std.testing.expectEqualStrings("2026-01-01T12:00:00.123Z", s);
    try std.testing.expectEqual(@as(i64, -1), try unixSeconds("1969-12-31T23:59:59.999999Z"));
    try std.testing.expectEqual(@as(i64, -1), try epochMilliseconds("1969-12-31T23:59:59.999999Z"));
    try std.testing.expectEqual(try unixSeconds("2000-02-29T00:00:00Z"), try unixSeconds("2000-02-29T01:30:00+01:30"));
    try std.testing.expectError(error.InvalidTimestamp, parse("1900-02-29 00:00:00"));
    try std.testing.expectError(error.InvalidTimestamp, parse("2026-01-01 24:00:00"));
    const epoch = try format(a, .{ .seconds = -1, .nanos = 123456789 }, 9, false);
    defer a.free(epoch);
    try std.testing.expectEqualStrings("1969-12-31T23:59:59.123456789Z", epoch);
}
