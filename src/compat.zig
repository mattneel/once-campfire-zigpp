const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const time = @import("compat/time.zig");
pub const nowText = time.nowText;
pub const unixSeconds = time.unixSeconds;
pub const epochMilliseconds = time.epochMilliseconds;
pub const iso8601 = time.iso8601;
const Sha1 = std.crypto.auth.hmac.HmacSha1;
const Sha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const Encoding = enum { standard, url, url_padded };
const Digest = enum { sha1, sha256 };

/// Keys are derived once at boot; no request computes PBKDF2 or keeps the base secret.
pub const Secrets = struct {
    cookie_key: [64]u8,
    encrypted_key: [32]u8,
    id_key: [64]u8,
    global_key: [64]u8,
    turbo_key: [64]u8,
    storage_key: [64]u8,

    pub fn init(allocator: Allocator, secret_key_base: []const u8) !Secrets {
        _ = allocator;
        if (secret_key_base.len == 0) return error.MissingSecretKeyBase;
        var self: Secrets = undefined;
        try derive(&self.cookie_key, secret_key_base, "signed cookie");
        try derive(&self.encrypted_key, secret_key_base, "authenticated encrypted cookie");
        try derive(&self.id_key, secret_key_base, "active_record/signed_id");
        try derive(&self.global_key, secret_key_base, "signed_global_ids");
        try derive(&self.turbo_key, secret_key_base, "turbo/signed_stream_verifier_key");
        try derive(&self.storage_key, secret_key_base, "ActiveStorage");
        return self;
    }
    pub fn deinit(self: *Secrets) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    pub fn signCookie(self: *const Secrets, allocator: Allocator, name: []const u8, value: []const u8, expires_unix: ?i64) ![]const u8 {
        return self.signCookieValue(allocator, name, .{ .string = value }, expires_unix);
    }
    pub fn signCookieValue(self: *const Secrets, allocator: Allocator, name: []const u8, value: Value, expires_unix: ?i64) ![]const u8 {
        const dumped = try jsonEncode(allocator, value, true);
        defer allocator.free(dumped);
        const purpose = try std.fmt.allocPrint(allocator, "cookie.{s}", .{name});
        defer allocator.free(purpose);
        const metadata = try envelope(allocator, dumped, purpose, expires_unix, true, true);
        defer allocator.free(metadata);
        const raw = try sign(allocator, metadata, &self.cookie_key, .sha1, .standard);
        defer allocator.free(raw);
        return cookieEscape(allocator, raw);
    }
    pub fn verifyCookie(self: *const Secrets, allocator: Allocator, name: []const u8, raw_wire_value: []const u8, now_unix: i64) !?[]const u8 {
        const value = try self.verifyCookieValue(allocator, name, raw_wire_value, now_unix) orelse return null;
        return if (value == .string) value.string else null;
    }
    /// Parsed JSON and all its storage belong to the request allocator (use an arena).
    pub fn verifyCookieValue(self: *const Secrets, allocator: Allocator, name: []const u8, raw_wire_value: []const u8, now_unix: i64) !?Value {
        const raw = try cookieUnescape(allocator, raw_wire_value);
        defer allocator.free(raw);
        const bytes = verifySignature(allocator, raw, &self.cookie_key, .sha1) catch |err| return invalidOrError(err);
        defer allocator.free(bytes);
        const purpose = try std.fmt.allocPrint(allocator, "cookie.{s}", .{name});
        defer allocator.free(purpose);
        const dumped = cookieDump(allocator, bytes, purpose, now_unix, false) catch |err| return invalidOrError(err);
        defer allocator.free(dumped);
        return parseValue(allocator, dumped) catch |err| return invalidOrError(err);
    }

    pub fn encryptCookie(self: *const Secrets, allocator: Allocator, io: Io, name: []const u8, value: Value, expires_unix: ?i64) ![]const u8 {
        var iv: [12]u8 = undefined;
        try io.randomSecure(&iv);
        return self.encryptCookieWithIv(allocator, name, value, expires_unix, iv);
    }
    fn encryptCookieWithIv(self: *const Secrets, allocator: Allocator, name: []const u8, value: Value, expires_unix: ?i64, iv: [12]u8) ![]const u8 {
        const dumped = try jsonEncode(allocator, value, true);
        defer allocator.free(dumped);
        const purpose = try std.fmt.allocPrint(allocator, "cookie.{s}", .{name});
        defer allocator.free(purpose);
        const plaintext = try envelope(allocator, dumped, purpose, expires_unix, true, true);
        defer allocator.free(plaintext);
        const cipher = try allocator.alloc(u8, plaintext.len);
        defer allocator.free(cipher);
        var tag: [16]u8 = undefined;
        Gcm.encrypt(cipher, &tag, plaintext, "", iv, self.encrypted_key);
        const c64 = try base64Encode(allocator, cipher, .standard);
        defer allocator.free(c64);
        const iv64 = try base64Encode(allocator, &iv, .standard);
        defer allocator.free(iv64);
        const t64 = try base64Encode(allocator, &tag, .standard);
        defer allocator.free(t64);
        const raw = try std.fmt.allocPrint(allocator, "{s}--{s}--{s}", .{ c64, iv64, t64 });
        defer allocator.free(raw);
        return cookieEscape(allocator, raw);
    }
    pub fn decryptCookie(self: *const Secrets, allocator: Allocator, name: []const u8, raw_wire_value: []const u8, now_unix: i64) !?Value {
        const raw = try cookieUnescape(allocator, raw_wire_value);
        defer allocator.free(raw);
        if (raw.len < 44) return null;
        const tag_start = raw.len - 24;
        const iv_start = tag_start - 18;
        const cipher_end = iv_start - 2;
        if (!std.mem.eql(u8, raw[tag_start - 2 .. tag_start], "--") or !std.mem.eql(u8, raw[cipher_end..iv_start], "--")) return null;
        const cipher = base64DecodeStrict(allocator, raw[0..cipher_end]) catch |err| return invalidOrError(err);
        defer allocator.free(cipher);
        const iv = base64DecodeStrict(allocator, raw[iv_start .. tag_start - 2]) catch |err| return invalidOrError(err);
        defer allocator.free(iv);
        const tag = base64DecodeStrict(allocator, raw[tag_start..]) catch |err| return invalidOrError(err);
        defer allocator.free(tag);
        if (iv.len != 12 or tag.len != 16) return null;
        const plaintext = try allocator.alloc(u8, cipher.len);
        defer allocator.free(plaintext);
        Gcm.decrypt(plaintext, cipher, tag[0..16].*, "", iv[0..12].*, self.encrypted_key) catch return null;
        const purpose = try std.fmt.allocPrint(allocator, "cookie.{s}", .{name});
        defer allocator.free(purpose);
        const dumped = cookieDump(allocator, plaintext, purpose, now_unix, true) catch |err| return invalidOrError(err);
        defer allocator.free(dumped);
        return parseValue(allocator, dumped) catch |err| return invalidOrError(err);
    }

    pub fn signedStream(self: *const Secrets, allocator: Allocator, pieces: []const []const u8) ![]const u8 {
        const joined = try std.mem.join(allocator, ":", pieces);
        defer allocator.free(joined);
        const dumped = try jsonEncode(allocator, .{ .string = joined }, false);
        defer allocator.free(dumped);
        return sign(allocator, dumped, &self.turbo_key, .sha256, .standard);
    }
    pub fn signedId(self: *const Secrets, allocator: Allocator, model_name: []const u8, id: i64, purpose: ?[]const u8, expires_unix: ?i64) ![]const u8 {
        const combined = try combinePurposes(allocator, model_name, purpose);
        defer allocator.free(combined);
        return generateValue(allocator, .{ .integer = id }, combined, expires_unix, &self.id_key, .sha256, .url, false);
    }
    /// `purpose` is the fully combined purpose, e.g. `user/avatar`, not just `avatar`.
    pub fn verifySignedId(self: *const Secrets, allocator: Allocator, value: []const u8, purpose: []const u8, now_unix: i64) !?i64 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const v = verifyValue(a, value, purpose, now_unix, &self.id_key, .sha256, true) catch |err| switch (err) {
            error.InvalidSignature, error.InvalidMessage => verifyValue(a, value, purpose, now_unix, &self.id_key, .sha1, true) catch |fallback| return invalidOrError(fallback),
            else => return invalidOrError(err),
        };
        return integer(v);
    }
    pub fn verifyModelSignedId(self: *const Secrets, allocator: Allocator, model_name: []const u8, value: []const u8, purpose: ?[]const u8, now_unix: i64) !?i64 {
        const combined = try combinePurposes(allocator, model_name, purpose);
        defer allocator.free(combined);
        return self.verifySignedId(allocator, value, combined, now_unix);
    }
    pub fn signedUserId(self: *const Secrets, allocator: Allocator, id: i64) ![]const u8 {
        return self.signedId(allocator, "User", id, "avatar", null);
    }
    pub fn blobSignedId(self: *const Secrets, allocator: Allocator, id: i64) ![]const u8 {
        return generateValue(allocator, .{ .integer = id }, "blob_id", null, &self.storage_key, .sha1, .standard, true);
    }
    pub fn verifyBlobSignedId(self: *const Secrets, allocator: Allocator, value: []const u8, now_unix: i64) !?i64 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const v = verifyValue(arena.allocator(), value, "blob_id", now_unix, &self.storage_key, .sha1, true) catch |err| return invalidOrError(err);
        return integer(v);
    }
    /// Caller supplies compact ActiveSupport JSON in its original insertion order.
    pub fn variationKey(self: *const Secrets, allocator: Allocator, json_transformations: []const u8) ![]const u8 {
        const metadata = try envelope(allocator, json_transformations, "variation", null, false, true);
        defer allocator.free(metadata);
        return sign(allocator, metadata, &self.storage_key, .sha1, .standard);
    }
    pub fn verifyVariationKey(self: *const Secrets, allocator: Allocator, key: []const u8, now_unix: i64) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const v = verifyValue(arena.allocator(), key, "variation", now_unix, &self.storage_key, .sha1, true) catch |err| return invalidOrError(err);
        return try jsonEncode(allocator, v, true);
    }
    pub fn signDiskKey(self: *const Secrets, allocator: Allocator, ordered_compact_json: []const u8, expires_unix: i64) ![]const u8 {
        const metadata = try envelope(allocator, ordered_compact_json, "blob_key", expires_unix, false, true);
        defer allocator.free(metadata);
        return sign(allocator, metadata, &self.storage_key, .sha1, .standard);
    }
    pub fn verifyDiskKey(self: *const Secrets, allocator: Allocator, key: []const u8, now_unix: i64) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const v = verifyValue(arena.allocator(), key, "blob_key", now_unix, &self.storage_key, .sha1, true) catch |err| return invalidOrError(err);
        return try jsonEncode(allocator, v, true);
    }
    pub fn attachableSgid(self: *const Secrets, allocator: Allocator, model_name: []const u8, id: i64) ![]const u8 {
        const gid = try std.fmt.allocPrint(allocator, "gid://campfire/{s}/{d}?expires_in", .{ model_name, id });
        defer allocator.free(gid);
        return generateValue(allocator, .{ .string = gid }, "attachable", null, &self.global_key, .sha1, .url_padded, true);
    }
    pub fn locateSignedGlobalId(self: *const Secrets, allocator: Allocator, value: []const u8, purpose: []const u8, now_unix: i64) !?GlobalId {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const v = verifyValue(a, value, purpose, now_unix, &self.global_key, .sha1, true) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            const legacy = verifyValue(a, value, null, now_unix, &self.global_key, .sha1, true) catch |fallback| return invalidOrError(fallback);
            if (legacy != .object or !purposeMatches(legacy.object.get("purpose"), purpose)) return null;
            if (legacy.object.get("expires_at")) |exp| {
                if (exp != .null) {
                    if (exp != .string) return null;
                    const expires = time.parse(exp.string) catch return null;
                    if (now_unix > expires.seconds) return null;
                }
            }
            break :blk legacy.object.get("gid") orelse return null;
        };
        if (v != .string) return null;
        const gid = parseGlobalId(v.string) orelse blk: {
            const decoded = base64Decode(a, v.string) catch |err| return invalidOrError(err);
            break :blk parseGlobalId(decoded) orelse return null;
        };
        return .{ .app = try allocator.dupe(u8, gid.app), .model_name = try allocator.dupe(u8, gid.model_name), .id = try allocator.dupe(u8, gid.id) };
    }
};

pub const GlobalId = struct { app: []const u8, model_name: []const u8, id: []const u8 };
pub fn parseGlobalId(uri: []const u8) ?GlobalId {
    if (!std.mem.startsWith(u8, uri, "gid://")) return null;
    const end = std.mem.indexOfScalar(u8, uri, '?') orelse uri.len;
    const rest = uri[6..end];
    const first = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, rest, first + 1, '/') orelse return null;
    if (first == 0 or second == first + 1 or second + 1 == rest.len) return null;
    return .{ .app = rest[0..first], .model_name = rest[first + 1 .. second], .id = rest[second + 1 ..] };
}
pub fn globalIdParam(allocator: Allocator, model_name: []const u8, id: i64) ![]const u8 {
    const uri = try std.fmt.allocPrint(allocator, "gid://campfire/{s}/{d}", .{ model_name, id });
    defer allocator.free(uri);
    return base64Encode(allocator, uri, .url);
}

fn derive(key: []u8, secret: []const u8, salt: []const u8) !void {
    try std.crypto.pwhash.pbkdf2(key, secret, salt, 1000, Sha256);
}
fn invalidOrError(err: anyerror) error{OutOfMemory}!@TypeOf(null) {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return null;
}
fn integer(v: Value) ?i64 {
    return switch (v) { .integer => v.integer, .string => std.fmt.parseInt(i64, std.mem.trim(u8, v.string, " \t\r\n"), 10) catch null, else => null };
}

fn base64Encode(allocator: Allocator, bytes: []const u8, encoding: Encoding) ![]const u8 {
    const codec = switch (encoding) { .standard => std.base64.standard.Encoder, .url => std.base64.url_safe_no_pad.Encoder, .url_padded => std.base64.url_safe.Encoder };
    const result = try allocator.alloc(u8, codec.calcSize(bytes.len));
    return codec.encode(result, bytes);
}
fn base64Decode(allocator: Allocator, encoded: []const u8) error{ OutOfMemory, InvalidSignature }![]u8 {
    // Accept both alphabets without copying the ordinary standard or URL-safe cases.
    const url = std.mem.indexOfAny(u8, encoded, "-_") != null;
    if (url and std.mem.indexOfAny(u8, encoded, "+/") != null) {
        const normalized = try allocator.dupe(u8, encoded);
        defer allocator.free(normalized);
        for (normalized) |*c| switch (c.*) { '-' => c.* = '+', '_' => c.* = '/', else => {} };
        return base64Decode(allocator, normalized);
    }
    const padded = std.mem.indexOfScalar(u8, encoded, '=') != null;
    const codec = if (url)
        (if (padded) std.base64.url_safe.Decoder else std.base64.url_safe_no_pad.Decoder)
    else
        (if (padded) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder);
    const n = codec.calcSizeForSlice(encoded) catch return error.InvalidSignature;
    const result = try allocator.alloc(u8, n);
    errdefer allocator.free(result);
    codec.decode(result, encoded) catch return error.InvalidSignature;
    return result;
}
fn base64DecodeStrict(allocator: Allocator, encoded: []const u8) ![]u8 {
    const codec = std.base64.standard.Decoder;
    const n = codec.calcSizeForSlice(encoded) catch return error.InvalidSignature;
    const result = try allocator.alloc(u8, n);
    errdefer allocator.free(result);
    codec.decode(result, encoded) catch return error.InvalidSignature;
    return result;
}
fn sign(allocator: Allocator, bytes: []const u8, key: []const u8, digest: Digest, encoding: Encoding) ![]const u8 {
    const encoded = try base64Encode(allocator, bytes, encoding);
    defer allocator.free(encoded);
    var hex: [64]u8 = undefined;
    const n = macHex(encoded, key, digest, &hex);
    return std.fmt.allocPrint(allocator, "{s}--{s}", .{ encoded, hex[0..n] });
}
fn macHex(data: []const u8, key: []const u8, digest: Digest, hex: *[64]u8) usize {
    var mac: [32]u8 = undefined;
    const n: usize = if (digest == .sha1) 20 else 32;
    switch (digest) { .sha1 => Sha1.create(mac[0..20], data, key), .sha256 => Sha256.create(&mac, data, key) }
    const alphabet = "0123456789abcdef";
    for (mac[0..n], 0..) |c, i| { hex[i * 2] = alphabet[c >> 4]; hex[i * 2 + 1] = alphabet[c & 15]; }
    return n * 2;
}
fn secureEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.crypto.timing_safe.compare(u8, a, b, .little) == .eq;
}
fn verifySignature(allocator: Allocator, raw: []const u8, key: []const u8, digest: Digest) ![]u8 {
    const n: usize = if (digest == .sha1) 40 else 64;
    if (raw.len <= n + 2) return error.InvalidSignature;
    const end = raw.len - n - 2;
    if (!std.mem.eql(u8, raw[end .. end + 2], "--") or std.mem.trim(u8, raw[0..end], " \t\r\n").len == 0) return error.InvalidSignature;
    var hex: [64]u8 = undefined;
    _ = macHex(raw[0..end], key, digest, &hex);
    if (!secureEqual(hex[0..n], raw[end + 2 ..])) return error.InvalidSignature;
    return base64Decode(allocator, raw[0..end]);
}

fn jsonEncode(allocator: Allocator, value: Value, escape_html: bool) ![]const u8 {
    var out = Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = true }, &out.writer);
    if (!escape_html) return out.toOwnedSlice();
    var escaped = Io.Writer.Allocating.init(allocator);
    defer escaped.deinit();
    for (out.written()) |c| switch (c) { '<' => try escaped.writer.writeAll("\\u003c"), '>' => try escaped.writer.writeAll("\\u003e"), '&' => try escaped.writer.writeAll("\\u0026"), else => try escaped.writer.writeByte(c) };
    return escaped.toOwnedSlice();
}
fn parseValue(allocator: Allocator, bytes: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = bytes.len }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidMessage;
    };
}
fn envelope(allocator: Allocator, dumped: []const u8, purpose: ?[]const u8, expires: ?i64, legacy: bool, escape_html: bool) ![]const u8 {
    if (purpose == null and expires == null) return allocator.dupe(u8, dumped);
    var out = Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll(if (legacy) "{\"_rails\":{\"message\":" else "{\"_rails\":{\"data\":");
    if (legacy) {
        const encoded = try base64Encode(allocator, dumped, .standard);
        defer allocator.free(encoded);
        try std.json.Stringify.value(encoded, .{}, &out.writer);
    } else try out.writer.writeAll(dumped);
    if (expires != null or legacy) {
        try out.writer.writeAll(",\"exp\":");
        if (expires) |seconds| {
            const date = try time.format(allocator, .{ .seconds = seconds }, 3, false);
            defer allocator.free(date);
            try std.json.Stringify.value(date, .{}, &out.writer);
        } else try out.writer.writeAll("null");
    }
    if (purpose != null or legacy) {
        try out.writer.writeAll(",\"pur\":");
        if (purpose) |p| {
            const encoded = try jsonEncode(allocator, .{ .string = p }, escape_html);
            defer allocator.free(encoded);
            try out.writer.writeAll(encoded);
        } else try out.writer.writeAll("null");
    }
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}
fn generateValue(allocator: Allocator, value: Value, purpose: ?[]const u8, expires: ?i64, key: []const u8, digest: Digest, encoding: Encoding, escape_html: bool) ![]const u8 {
    const dumped = try jsonEncode(allocator, value, escape_html);
    defer allocator.free(dumped);
    const bytes = try envelope(allocator, dumped, purpose, expires, false, escape_html);
    defer allocator.free(bytes);
    return sign(allocator, bytes, key, digest, encoding);
}
fn purposeMatches(p: ?Value, purpose: ?[]const u8) bool {
    const expected = purpose orelse "";
    const v = p orelse return expected.len == 0;
    return switch (v) { .null => expected.len == 0, .string => std.mem.eql(u8, v.string, expected), .bool => std.mem.eql(u8, if (v.bool) "true" else "false", expected), .integer => blk: { var buf: [32]u8 = undefined; const s = std.fmt.bufPrint(&buf, "{d}", .{v.integer}) catch return false; break :blk std.mem.eql(u8, s, expected); }, else => false };
}
fn checkMetadata(rails: Value, purpose: ?[]const u8, now: i64) !void {
    if (rails != .object) return error.InvalidMessage;
    if (rails.object.get("exp")) |exp| if (exp != .null) {
        if (exp != .string) return error.InvalidMessage;
        const t = time.parse(exp.string) catch return error.InvalidMessage;
        if (now > t.seconds or (now == t.seconds and t.nanos == 0)) return error.Expired;
    };
    if (!purposeMatches(rails.object.get("pur"), purpose)) return error.PurposeMismatch;
}
fn loadSerialized(allocator: Allocator, dumped: []const u8, allow_marshal: bool) !Value {
    if (std.mem.startsWith(u8, dumped, "\x04\x08")) {
        if (!allow_marshal) return error.InvalidMessage;
        const s = marshalString(dumped) orelse return error.InvalidMessage;
        return .{ .string = try allocator.dupe(u8, s) };
    }
    return parseValue(allocator, dumped);
}
fn unpackValue(allocator: Allocator, bytes: []const u8, purpose: ?[]const u8, now: i64, allow_marshal: bool) !Value {
    const v = try loadSerialized(allocator, bytes, allow_marshal);
    if (v == .object) if (v.object.get("_rails")) |rails| {
        try checkMetadata(rails, purpose, now);
        if (std.mem.startsWith(u8, bytes, "{\"_rails\":{\"message\":")) {
            const message = rails.object.get("message") orelse return error.InvalidMessage;
            if (message != .string) return error.InvalidMessage;
            const dumped = try base64Decode(allocator, message.string);
            defer allocator.free(dumped);
            return loadSerialized(allocator, dumped, allow_marshal);
        }
        return rails.object.get("data") orelse .null;
    };
    if (purpose != null) return error.PurposeMismatch;
    return v;
}
fn verifyValue(allocator: Allocator, raw: []const u8, purpose: ?[]const u8, now: i64, key: []const u8, digest: Digest, allow_marshal: bool) !Value {
    const bytes = try verifySignature(allocator, raw, key, digest);
    defer allocator.free(bytes);
    return unpackValue(allocator, bytes, purpose, now, allow_marshal);
}
fn cookieDump(allocator: Allocator, bytes: []const u8, purpose: []const u8, now: i64, strict: bool) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // NullSerializer only recognizes the legacy envelope, not arbitrary JSON objects.
    if (!std.mem.startsWith(u8, bytes, "{\"_rails\":{\"message\":")) return allocator.dupe(u8, bytes);
    const v = try parseValue(a, bytes);
    const rails = v.object.get("_rails") orelse return error.InvalidMessage;
    checkMetadata(rails, purpose, now) catch try checkMetadata(rails, null, now);
    const message = rails.object.get("message") orelse return error.InvalidMessage;
    if (message != .string) return error.InvalidMessage;
    return if (strict) base64DecodeStrict(allocator, message.string) else base64Decode(allocator, message.string);
}
fn marshalString(bytes: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, bytes, "\x04\x08")) return null;
    var i: usize = 2;
    if (i < bytes.len and bytes[i] == 'I') i += 1;
    if (bytes.len < i + 2 or bytes[i] != '"') return null;
    i += 1;
    const first: i8 = @bitCast(bytes[i]);
    i += 1;
    var n: i64 = 0;
    if (first >= 1 and first <= 4) {
        const len: usize = @intCast(first);
        if (bytes.len - i < len) return null;
        for (bytes[i..][0..len], 0..) |c, shift| n |= @as(i64, c) << @intCast(shift * 8);
        i += len;
    } else if (first >= 5) n = @as(i64, first) - 5 else if (first != 0) return null;
    if (n < 0) return null;
    const length: usize = @intCast(n);
    if (length > bytes.len - i) return null;
    return bytes[i..][0..length];
}
fn combinePurposes(allocator: Allocator, name: []const u8, purpose: ?[]const u8) ![]const u8 {
    var out = Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    for (name, 0..) |c, i| {
        if (c == ':') { if (i > 0 and name[i - 1] == ':') try out.writer.writeByte('/'); continue; }
        if (std.ascii.isUpper(c)) {
            const prev = if (i > 0) name[i - 1] else 0;
            const next = if (i + 1 < name.len) name[i + 1] else 0;
            if (std.ascii.isLower(prev) or std.ascii.isDigit(prev) or (std.ascii.isUpper(prev) and std.ascii.isLower(next))) try out.writer.writeByte('_');
            try out.writer.writeByte(std.ascii.toLower(c));
        } else try out.writer.writeByte(if (c == '-') '_' else c);
    }
    if (purpose) |p| if (std.mem.trim(u8, p, " \t\r\n").len != 0) {
        if (out.written().len != 0) try out.writer.writeByte('/');
        try out.writer.writeAll(p);
    };
    return out.toOwnedSlice();
}

pub fn htmlEscape(writer: *Io.Writer, value: []const u8) !void {
    var start: usize = 0;
    for (value, 0..) |c, i| {
        const replacement: []const u8 = switch (c) { '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;", else => continue };
        try writer.writeAll(value[start..i]);
        try writer.writeAll(replacement);
        start = i + 1;
    }
    try writer.writeAll(value[start..]);
}
pub fn urlEncode(allocator: Allocator, value: []const u8) ![]const u8 { return percentEncode(allocator, value, false); }
pub fn cookieEscape(allocator: Allocator, value: []const u8) ![]const u8 { return percentEncode(allocator, value, true); }
fn percentEncode(allocator: Allocator, value: []const u8, cookie: bool) ![]const u8 {
    var out = Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == (if (cookie) @as(u8, '*') else @as(u8, '~'))) {
            try out.writer.writeByte(c);
        } else if (cookie and c == ' ') try out.writer.writeByte('+') else {
            const escaped = [3]u8{ '%', hex[c >> 4], hex[c & 15] };
            try out.writer.writeAll(&escaped);
        }
    }
    return out.toOwnedSlice();
}
pub fn cookieUnescape(allocator: Allocator, value: []const u8) ![]const u8 {
    var out = Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var i: usize = 0;
    while (i < value.len) : (i += 1) switch (value[i]) {
        '+' => try out.writer.writeByte(' '),
        '%' => {
            if (value.len - i < 3) return allocator.dupe(u8, value);
            const n = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return allocator.dupe(u8, value);
            try out.writer.writeByte(n);
            i += 2;
        },
        else => try out.writer.writeByte(value[i]),
    };
    return out.toOwnedSlice();
}

/// bcrypt-ruby accepts 2a/2b/2y and truncates byte strings after 72 bytes.
/// CPU-blocking: HTTP must call this after releasing the DB connection in its dirty pool.
pub fn verifyPassword(password: []const u8, digest: []const u8) bool {
    if (digest.len != 60 or digest[0] != '$' or digest[1] != '2' or (digest[2] != 'a' and digest[2] != 'b' and digest[2] != 'y')) return false;
    const cost = std.fmt.parseInt(u6, digest[4..6], 10) catch return false;
    if (cost < 4 or cost > 31) return false;
    var normalized: [60]u8 = digest[0..60].*;
    normalized[2] = 'b';
    std.crypto.pwhash.bcrypt.strVerify(&normalized, password[0..@min(password.len, 72)], .{ .silently_truncate_password = true }) catch return false;
    return true;
}
pub fn checkCandidatePassword(password: []const u8, digest: ?[]const u8) bool {
    if (password.len == 0) return false;
    if (digest) |d| return verifyPassword(password, d);
    // crates/db/src/models/user.rs::User.authenticated: never authenticate a missing user.
    _ = verifyPassword(password, "$2a$12$FiKmSp4UhLvSB4Sd/ZUjQunyKP6.NjDRHdr5LnKUVk.BUn4Mq12WS");
    return false;
}
pub fn permanentExpires(now_unix: i64) !i64 {
    var buf: [32]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    try time.write(&writer, .{ .seconds = now_unix }, 0, true);
    const date = writer.buffered();
    const year = try std.fmt.parseInt(u16, date[0..4], 10);
    if (year > 9979) return error.InvalidTimestamp;
    _ = try std.fmt.bufPrint(buf[0..4], "{d:0>4}", .{year + 20});
    // Rails advances calendar years and clamps February 29 if the destination isn't leap.
    if (std.mem.eql(u8, date[5..10], "02-29")) {
        const y = year + 20;
        if (y % 4 != 0 or (y % 100 == 0 and y % 400 != 0)) buf[9] = '8';
    }
    return time.unixSeconds(buf[0..date.len]);
}

test { _ = @import("compat/golden.zig"); }

test "native deterministic AES GCM generation matches Rails ciphertext vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vectors = try @import("compat/golden.zig").load(a, "vectors/rails_compat.json");
    var secrets = try Secrets.init(a, vectors.object.get("secret_key_base").?.string);
    defer secrets.deinit();
    const cookies = vectors.object.get("encrypted_cookies").?;
    for (cookies.object.get("generate").?.array.items) |c| {
        const raw = c.object.get("raw").?.string;
        const iv_start = raw.len - 42;
        const iv = try base64DecodeStrict(a, raw[iv_start .. iv_start + 16]);
        const expires = c.object.get("expires_at").?;
        const seconds: ?i64 = if (expires == .null) null else try unixSeconds(expires.string);
        const wire = try secrets.encryptCookieWithIv(a, c.object.get("name").?.string, c.object.get("value").?, seconds, iv[0..12].*);
        try std.testing.expectEqualStrings(try cookieEscape(a, raw), wire);
    }
}
