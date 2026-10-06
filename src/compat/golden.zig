const std = @import("std");
const compat = @import("../compat.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub fn load(allocator: Allocator, path: []const u8) !Value {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSliceLeaky(Value, allocator, bytes, .{ .allocate = .alloc_always });
}
fn field(v: Value, key: []const u8) Value { return v.object.get(key).?; }
fn text(v: Value) []const u8 { return v.string; }
fn optionalText(v: Value) ?[]const u8 { return if (v == .string) v.string else null; }
fn expiry(v: Value) !?i64 { return if (v == .null) null else try compat.unixSeconds(text(v)); }
fn expectJson(a: Allocator, expected: Value, actual: Value) !void {
    const x = try std.json.Stringify.valueAlloc(a, expected, .{});
    const y = try std.json.Stringify.valueAlloc(a, actual, .{});
    try std.testing.expectEqualStrings(x, y);
}

test "native key derivation Rack cookie escaping and signing golden vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vectors = try load(a, "vectors/rails_compat.json");
    var secrets = try compat.Secrets.init(a, text(field(vectors, "secret_key_base")));
    defer secrets.deinit();
    for (field(vectors, "key_generator").array.items) |c| {
        const n: usize = @intCast(field(c, "length").integer);
        const key = try a.alloc(u8, n);
        try std.crypto.pwhash.pbkdf2(key, text(field(vectors, "secret_key_base")), text(field(c, "salt")), 1000, std.crypto.auth.hmac.sha2.HmacSha256);
        const hex = try a.alloc(u8, key.len * 2);
        for (key, 0..) |byte, i| {
            hex[i * 2] = "0123456789abcdef"[byte >> 4];
            hex[i * 2 + 1] = "0123456789abcdef"[byte & 15];
        }
        try std.testing.expectEqualStrings(text(field(c, "key_hex")), hex);
    }
    for (field(vectors, "cookie_escaping").array.items) |c| {
        if (field(c, "raw") == .string) try std.testing.expectEqualStrings(text(field(c, "wire")), try compat.cookieEscape(a, text(field(c, "raw"))));
        try std.testing.expectEqualStrings(text(field(c, "parsed")), try compat.cookieUnescape(a, text(field(c, "wire"))));
    }
    const cookies = field(vectors, "signed_cookies");
    for (field(cookies, "generate").array.items) |c| {
        const wire = try secrets.signCookieValue(a, text(field(c, "name")), field(c, "value"), try expiry(field(c, "expires_at")));
        try std.testing.expectEqualStrings(try compat.cookieEscape(a, text(field(c, "raw"))), wire);
    }
    for (field(cookies, "verify").array.items) |c| {
        const result = try secrets.verifyCookieValue(a, text(field(c, "name")), try compat.cookieEscape(a, text(field(c, "raw"))), try compat.unixSeconds(text(field(c, "now"))));
        const expected = field(c, "expected");
        if (expected == .null) try std.testing.expect(result == null) else try expectJson(a, expected, result.?);
    }
}

test "native AES256 GCM reads Rails session cookies purpose tamper expiry and legacy vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vectors = try load(a, "vectors/rails_compat.json");
    var secrets = try compat.Secrets.init(a, text(field(vectors, "secret_key_base")));
    defer secrets.deinit();
    const cookies = field(vectors, "encrypted_cookies");
    for (field(cookies, "verify").array.items) |c| {
        const result = try secrets.decryptCookie(a, text(field(c, "name")), try compat.cookieEscape(a, text(field(c, "raw"))), try compat.unixSeconds(text(field(c, "now"))));
        const expected = field(c, "expected");
        if (expected == .null) try std.testing.expect(result == null) else try expectJson(a, expected, result.?);
    }
    for (field(cookies, "generate").array.items) |c| {
        const expires = try expiry(field(c, "expires_at"));
        const wire = try secrets.encryptCookie(a, std.testing.io, text(field(c, "name")), field(c, "value"), expires);
        const result = try secrets.decryptCookie(a, text(field(c, "name")), wire, try compat.unixSeconds(text(field(vectors, "now"))));
        try expectJson(a, field(c, "value"), result.?);
    }
}

test "native signed ID global ID Turbo stream golden vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vectors = try load(a, "vectors/rails_compat.json");
    var secrets = try compat.Secrets.init(a, text(field(vectors, "secret_key_base")));
    defer secrets.deinit();
    const ids = field(vectors, "signed_ids");
    for (field(ids, "generate").array.items) |c| {
        const result = try secrets.signedId(a, text(field(c, "model")), field(c, "id").integer, optionalText(field(c, "purpose")), try expiry(field(c, "expires_at")));
        try std.testing.expectEqualStrings(text(field(c, "signed_id")), result);
    }
    for (field(ids, "verify").array.items) |c| {
        const result = try secrets.verifyModelSignedId(a, text(field(c, "model")), text(field(c, "signed_id")), optionalText(field(c, "purpose")), try compat.unixSeconds(text(field(c, "now"))));
        const expected = field(c, "expected");
        const numeric: ?i64 = switch (expected) { .null => null, .integer => expected.integer, .string => try std.fmt.parseInt(i64, expected.string, 10), else => unreachable };
        try std.testing.expectEqual(numeric, result);
    }
    for (field(vectors, "global_ids").array.items) |c| {
        const result = try compat.globalIdParam(a, text(field(c, "model_name")), try std.fmt.parseInt(i64, text(field(c, "id")), 10));
        try std.testing.expectEqualStrings(text(field(c, "param")), result);
    }
    const sgids = field(vectors, "sgids");
    for (field(sgids, "generate").array.items) |c| {
        if (!std.mem.eql(u8, text(field(c, "purpose")), "attachable") or field(c, "expires_at") != .null) continue;
        const gid = compat.parseGlobalId(text(field(c, "data"))).?;
        const result = try secrets.attachableSgid(a, gid.model_name, try std.fmt.parseInt(i64, gid.id, 10));
        try std.testing.expectEqualStrings(text(field(c, "sgid")), result);
    }
    for (field(sgids, "verify").array.items) |c| {
        const result = try secrets.locateSignedGlobalId(a, text(field(c, "sgid")), text(field(c, "purpose")), try compat.unixSeconds(text(field(c, "now"))));
        const expected = field(c, "expected");
        if (expected == .null) try std.testing.expect(result == null) else {
            const gid = compat.parseGlobalId(text(expected)).?;
            try std.testing.expectEqualStrings(gid.app, result.?.app);
            try std.testing.expectEqualStrings(gid.model_name, result.?.model_name);
            try std.testing.expectEqualStrings(gid.id, result.?.id);
        }
    }
    const streams = field(vectors, "turbo_stream_names");
    for (field(streams, "generate").array.items) |c| {
        var parts: std.ArrayList([]const u8) = .empty;
        for (field(c, "parts").array.items) |p| try parts.append(a, text(p));
        const result = try secrets.signedStream(a, parts.items);
        try std.testing.expectEqualStrings(text(field(c, "signed")), result);
    }
}

test "native bcrypt password golden vectors including UTF8 and 72 byte truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vectors = try load(arena.allocator(), "vectors/rails_compat.json");
    for (field(field(vectors, "passwords"), "checks").array.items) |c| {
        try std.testing.expectEqual(field(c, "expected").bool, compat.verifyPassword(text(field(c, "password")), text(field(c, "digest"))));
    }
    try std.testing.expect(!compat.verifyPassword("secret", "bad digest"));
    try std.testing.expect(!compat.checkCandidatePassword("", null));
    try std.testing.expect(!compat.checkCandidatePassword("secret", null));
}

test "native HTML URI escaping permanent calendar expiry integer cookies and seeded signed cookies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = std.Io.Writer.Allocating.init(a);
    try compat.htmlEscape(&out.writer, "<&>\"'x é");
    try std.testing.expectEqualStrings("&lt;&amp;&gt;&quot;&#39;x é", out.written());
    try std.testing.expectEqualStrings("a%2A~%20b-._%2B%C3%A9", try compat.urlEncode(a, "a*~ b-._+é"));
    const leap = try compat.permanentExpires(try compat.unixSeconds("2080-02-29T12:00:00Z"));
    try std.testing.expectEqual(try compat.unixSeconds("2100-02-28T12:00:00Z"), leap);
    const vectors = try load(a, "vectors/rails_compat.json");
    var secrets = try compat.Secrets.init(a, text(field(vectors, "secret_key_base")));
    defer secrets.deinit();
    const now = try compat.unixSeconds(text(field(vectors, "now")));
    const cookie = try secrets.signCookieValue(a, "integer_vector", .{ .integer = 5 }, null);
    const last = (try secrets.verifyCookieValue(a, "integer_vector", cookie, now)).?;
    try std.testing.expectEqual(@as(i64, 5), last.integer);
    try std.testing.expect((try secrets.verifyCookieValue(a, "session_token", cookie, now)) == null);
    const seed = try load(a, "vectors/campfire_sessions.json");
    for (field(seed, "sessions").array.items) |c| {
        const token = (try secrets.verifyCookie(a, "session_token", text(field(c, "cookie_value")), now)).?;
        try std.testing.expectEqualStrings(text(field(c, "token")), token);
    }
    for (field(seed, "blobs").array.items) |c| {
        try std.testing.expectEqual(@as(?i64, field(c, "blob_id").integer), try secrets.verifyBlobSignedId(a, text(field(c, "signed_id")), now));
    }
    const blob = try secrets.blobSignedId(a, 42);
    try std.testing.expectEqualStrings("eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6ImJsb2JfaWQifX0=--c252dc1b14dd0e8cd599eb40203378880bafed1f", blob);
    const transforms = "{\"format\":\"webp\",\"resize_to_limit\":[320,320]}";
    const variation = try secrets.variationKey(a, transforms);
    try std.testing.expectEqualStrings(transforms, (try secrets.verifyVariationKey(a, variation, now)).?);
    try std.testing.expect((try secrets.verifyBlobSignedId(a, variation, now)) == null);
}

test "native ActiveStorage disk key signing and verification golden vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vectors = try load(a, "vectors/rails_compat.json");
    var secrets = try compat.Secrets.init(a, text(field(vectors, "secret_key_base")));
    defer secrets.deinit();
    const app = field(vectors, "app_verifiers");
    for (field(app, "generate").array.items) |c| {
        const purpose = optionalText(field(c, "purpose")) orelse continue;
        if (!std.mem.eql(u8, purpose, "blob_key")) continue;
        const key = try secrets.signDiskKey(a, text(field(c, "data_json")), (try expiry(field(c, "expires_at"))).?);
        try std.testing.expectEqualStrings(text(field(c, "message")), key);
    }
    for (field(app, "verify").array.items) |c| {
        const purpose = optionalText(field(c, "purpose")) orelse continue;
        if (!std.mem.eql(u8, purpose, "blob_key")) continue;
        const actual = try secrets.verifyDiskKey(a, text(field(c, "message")), try compat.unixSeconds(text(field(c, "now"))));
        const expected = field(c, "expected_json");
        if (expected == .null) try std.testing.expect(actual == null)
        else try std.testing.expectEqualStrings(text(expected), actual.?);
    }
}
