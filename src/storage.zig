const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const model = @import("model.zig");
const db = @import("db.zig");
const Database = db.Database;
const compat = @import("compat.zig");
const Secrets = compat.Secrets;
const media = @import("storage/media.zig");
const wire = @import("storage/wire.zig");
const Variation = @import("storage/variation.zig").Variation;

pub const Request = struct {
    method: []const u8,
    /// Raw encoded full path, including query (ETag and disposition need it).
    path: []const u8,
    range: ?[]const u8 = null,
    if_none_match: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
    now: i64,
};
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Result = struct { status: u16, content_type: []const u8, body: []const u8, headers: []const Header = &.{} };
const prefix = "/rails/active_storage/";
var init_mutex: Io.Mutex = .init;
var vips_initialized = false;

pub const Storage = struct {
    allocator: Allocator,
    io: Io,
    root: c_int,
    database: *Database,
    secrets: *Secrets,
    /// Serialize missing-media processing, not file reads or DB operations. No
    /// connection is held across C calls; a second lookup avoids duplicate work.
    media_mutex: Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: Io, root_files_path: []const u8, database: *Database, secrets: *Secrets) !Storage {
        try init_mutex.lock(io);
        defer init_mutex.unlock(io);
        if (!vips_initialized) {
            try io.blocking(media.init, .{});
            vips_initialized = true;
        }
        const root = try io.blocking(media.openRoot, .{ allocator, root_files_path });
        return .{ .allocator = allocator, .io = io, .root = root, .database = database, .secrets = secrets };
    }
    pub fn deinit(self: *Storage) void {
        _ = self.io.blocking(media.c.close, .{self.root});
    }
    pub fn vipsVersion() []const u8 {
        return media.version();
    }

    pub fn avatar(self: *Storage, allocator: Allocator, io: Io, user: model.User, now: i64) !?Result {
        const blob = user.avatar orelse try self.database.avatar(allocator, io, user.id) orelse return null;
        if (!variable(blob)) return null;
        const image = try self.variant(allocator, io, blob, Variation.avatar(), now);
        return try self.file(allocator, io, image, .{ .method = "GET", .path = "", .now = now }, false, "inline");
    }
    pub fn logo(self: *Storage, allocator: Allocator, io: Io, blob: model.Blob, size: u16, now: i64) !?Result {
        if (!variable(blob)) return null;
        const variation = try Variation.logo(size);
        const image = try self.variant(allocator, io, blob, variation, now);
        return try self.file(allocator, io, image, .{ .method = "GET", .path = "", .now = now }, false, "inline");
    }

    pub fn handle(self: *Storage, allocator: Allocator, io: Io, request: Request) !?Result {
        var result = try self.handleInner(allocator, io, request) orelse return null;
        if (std.mem.startsWith(u8, request.path, prefix ++ "disk/")) {
            for (result.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "Cache-Control")) return result;
            const headers = try allocator.alloc(Header, result.headers.len + 1);
            @memcpy(headers[0..result.headers.len], result.headers);
            headers[result.headers.len] = .{ .name = "Cache-Control", .value = "max-age=3600, public" };
            result.headers = headers;
        }
        return result;
    }

    fn handleInner(self: *Storage, allocator: Allocator, io: Io, request: Request) !?Result {
        if (!std.mem.startsWith(u8, request.path, prefix)) return null;
        const q = std.mem.indexOfScalar(u8, request.path, '?') orelse request.path.len;
        var segments = std.mem.splitScalar(u8, request.path[prefix.len..q], '/');
        const family = segments.next() orelse return notFound();
        if (!std.mem.eql(u8, request.method, "GET") and !std.mem.eql(u8, request.method, "HEAD") and !(std.mem.eql(u8, family, "disk") and std.mem.eql(u8, request.method, "OPTIONS"))) return .{ .status = 405, .content_type = "text/plain", .body = "" };
        if (std.mem.eql(u8, family, "disk")) {
            const token = segments.next() orelse return notFound();
            if (segments.next() == null) return notFound();
            const decoded = wire.decodeSegment(allocator, token) catch |err| return try invalidOrError(err);
            const json = try self.secrets.verifyDiskKey(allocator, decoded, request.now) orelse return notFound();
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{ .allocate = .alloc_always }) catch |err| return try invalidOrError(err);
            defer parsed.deinit();
            if (parsed.value != .object) return notFound();
            const key = jsonString(parsed.value, "key") orelse return notFound();
            const service = jsonString(parsed.value, "service_name") orelse return notFound();
            const disposition = jsonString(parsed.value, "disposition") orelse return notFound();
            const ct = jsonString(parsed.value, "content_type") orelse "application/octet-stream";
            if (!std.mem.eql(u8, service, "local") or !media.validKey(key) or !safeHeader(disposition) or !safeHeader(ct)) return notFound();
            return try self.disk(allocator, io, key, ct, disposition, request);
        }
        const is_representation = std.mem.eql(u8, family, "representations");
        if (!is_representation and !std.mem.eql(u8, family, "blobs")) return notFound();
        const action = segments.next() orelse return notFound();
        const redirect = std.mem.eql(u8, action, "redirect");
        if (!redirect and !std.mem.eql(u8, action, "proxy")) return notFound();
        const signed = segments.next() orelse return notFound();
        const decoded_id = wire.decodeSegment(allocator, signed) catch |err| return try invalidOrError(err);
        const id = try self.secrets.verifyBlobSignedId(allocator, decoded_id, request.now) orelse return notFound();
        var blob = try self.database.blob(allocator, io, id) orelse return notFound();
        if (!media.validKey(blob.key)) return notFound();
        if (is_representation) {
            const raw_variation = segments.next() orelse return notFound();
            const key = wire.decodeSegment(allocator, raw_variation) catch |err| return try invalidOrError(err);
            const json = try self.secrets.verifyVariationKey(allocator, key, request.now) orelse return notFound();
            const variation = Variation.decode(allocator, json, defaultVariantFormat(blob)) catch |err| return try invalidOrError(err);
            blob = self.representation(allocator, io, blob, variation, request.now) catch |err| switch (err) {
                error.Unrepresentable, error.FileNotFound, error.UnsafeStorageKey => return notFound(),
                else => return err,
            };
        }
        if (segments.next() == null) return notFound();
        const disposition = try requestedDisposition(allocator, request.path[q..]);
        if (redirect) {
            const path = try self.diskPath(allocator, blob, disposition, request.now);
            const headers = try allocator.alloc(Header, 2);
            headers[0] = .{ .name = "Location", .value = path };
            headers[1] = .{ .name = "Cache-Control", .value = "max-age=300, private" };
            return .{ .status = 302, .content_type = "text/html; charset=utf-8", .body = "", .headers = headers };
        }
        return try self.file(allocator, io, blob, request, true, disposition);
    }

    fn representation(self: *Storage, allocator: Allocator, io: Io, source: model.Blob, variation: Variation, now: i64) !model.Blob {
        if (video(source)) {
            const image = try self.preview(allocator, io, source, now);
            if (variation.empty) return image;
            var preview_variation = variation;
            if (!variation.format_explicit) preview_variation.format = defaultVariantFormat(image);
            return self.variant(allocator, io, image, preview_variation, now);
        }
        if (!variable(source)) return error.Unrepresentable;
        return self.variant(allocator, io, source, variation, now);
    }
    fn variant(self: *Storage, allocator: Allocator, io: Io, source: model.Blob, variation: Variation, now: i64) !model.Blob {
        const digest = try variation.digest(allocator);
        if (try self.database.existingVariant(allocator, io, source.id, digest)) |existing| return existing;
        try self.media_mutex.lock(io);
        defer self.media_mutex.unlock(io);
        if (try self.database.existingVariant(allocator, io, source.id, digest)) |existing| return existing;
        const bytes = try self.verifiedSource(allocator, io, source);
        defer allocator.free(bytes);
        const output = try io.blocking(media.transform, .{ allocator, bytes, variation });
        defer allocator.free(output.bytes);
        const key = try randomKey(allocator, io);
        try io.blocking(media.write, .{ allocator, self.root, key, output.bytes });
        errdefer io.blocking(media.remove, .{ allocator, self.root, key });
        const image = try self.newBlob(allocator, source, key, output, variation.format, variation.contentType());
        const recorded = try self.database.recordVariant(allocator, io, source.id, digest, image, try timestamp(allocator, now));
        if (!std.mem.eql(u8, recorded.key, key)) io.blocking(media.remove, .{ allocator, self.root, key });
        return recorded;
    }
    fn preview(self: *Storage, allocator: Allocator, io: Io, source: model.Blob, now: i64) !model.Blob {
        if (try self.database.existingPreview(allocator, io, source.id)) |existing| return existing;
        try self.media_mutex.lock(io);
        defer self.media_mutex.unlock(io);
        if (try self.database.existingPreview(allocator, io, source.id)) |existing| return existing;
        const bytes = try self.verifiedSource(allocator, io, source);
        defer allocator.free(bytes);
        // Like Blob.open, process a checksum-verified private copy, never a
        // source path that could change between validation and FFmpeg opening it.
        const private_input = try randomKey(allocator, io);
        try io.blocking(media.write, .{ allocator, self.root, private_input, bytes });
        defer io.blocking(media.remove, .{ allocator, self.root, private_input });
        const temp = try randomKey(allocator, io);
        const output = try io.blocking(media.preview, .{ allocator, self.root, private_input, temp });
        defer allocator.free(output.bytes);
        const key = try randomKey(allocator, io);
        try io.blocking(media.write, .{ allocator, self.root, key, output.bytes });
        errdefer io.blocking(media.remove, .{ allocator, self.root, key });
        const image = try self.newBlob(allocator, source, key, output, "jpg", "image/jpeg");
        const recorded = try self.database.recordPreview(allocator, io, source.id, image, try timestamp(allocator, now));
        if (!std.mem.eql(u8, recorded.key, key)) io.blocking(media.remove, .{ allocator, self.root, key });
        return recorded;
    }
    fn verifiedSource(self: *Storage, allocator: Allocator, io: Io, blob: model.Blob) ![]const u8 {
        const bytes = try io.blocking(media.read, .{ allocator, self.root, blob.key });
        errdefer allocator.free(bytes);
        if (blob.checksum) |expected| {
            const actual = try media.checksum(allocator, bytes);
            defer allocator.free(actual);
            if (!std.mem.eql(u8, expected, actual)) return error.StorageIntegrity;
        }
        return bytes;
    }
    fn newBlob(self: *Storage, allocator: Allocator, source: model.Blob, key: []const u8, output: media.Generated, format: []const u8, content_type: []const u8) !db.NewBlob {
        _ = self;
        const base = filenameBase(source.filename);
        const lower_format = try allocator.dupe(u8, format);
        defer allocator.free(lower_format);
        for (lower_format) |*ch| ch.* = std.ascii.toLower(ch.*);
        return .{
            .key = key,
            .filename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, lower_format }),
            .content_type = content_type,
            .byte_size = @intCast(output.bytes.len),
            .checksum = try media.checksum(allocator, output.bytes),
            .metadata = try std.fmt.allocPrint(allocator, "{{\"identified\":true,\"width\":{d},\"height\":{d},\"analyzed\":true}}", .{ output.width, output.height }),
            .service_name = "local",
        };
    }
    fn diskPath(self: *Storage, allocator: Allocator, blob: model.Blob, requested: []const u8, now: i64) ![]const u8 {
        const disposition = try wire.disposition(allocator, forcedDisposition(blob) orelse if (std.mem.eql(u8, requested, "attachment")) "attachment" else "inline", blob.filename);
        const payload = try jsonDiskPayload(allocator, blob.key, disposition, servingType(blob));
        const token = try self.secrets.signDiskKey(allocator, payload, now + 300);
        return std.fmt.allocPrint(allocator, "/rails/active_storage/disk/{s}/{s}", .{ try wire.segment(allocator, token), try wire.filenamePath(allocator, blob.filename) });
    }
    fn file(self: *Storage, allocator: Allocator, io: Io, blob: model.Blob, request: Request, forever: bool, requested: []const u8) !Result {
        const content_type = servingType(blob);
        // send_file defaults its filename to the disk basename on avatar/logo
        // routes; blob proxy controllers explicitly use the blob's filename.
        const filename = if (!forever and request.path.len == 0) blob.key else blob.filename;
        const disposition = try wire.disposition(allocator, forcedDisposition(blob) orelse requested, filename);
        // Blob proxies give range requests precedence over forever-cache freshness.
        const has_range = request.range != null and std.mem.trim(u8, request.range.?, " \t").len != 0 and std.mem.indexOf(u8, request.path, "/blobs/proxy/") != null;
        const etag = try pathEtag(allocator, request.path);
        if (forever and !has_range and fresh(request.if_none_match, etag)) return .{ .status = 304, .content_type = content_type, .body = "", .headers = try cacheHeaders(allocator, etag) };
        const data = io.blocking(media.read, .{ allocator, self.root, blob.key }) catch |err| switch (err) {
            error.FileNotFound, error.UnsafeStorageKey => return notFound(),
            else => return err,
        };
        const ranged = if (has_range) try wire.ranges(allocator, request.range, data.len) else null;
        if (has_range and (ranged == null or ranged.?.len == 0)) return .{ .status = 416, .content_type = content_type, .body = "" };
        var headers: std.ArrayList(Header) = .empty;
        if (forever and !has_range) try headers.appendSlice(allocator, try cacheHeaders(allocator, etag));
        try headers.append(allocator, .{ .name = "Content-Disposition", .value = disposition });
        try headers.append(allocator, .{ .name = "Accept-Ranges", .value = "bytes" });
        var body: []const u8 = data;
        var response_type = content_type;
        var status: u16 = 200;
        if (ranged) |ranges| {
            status = 206;
            if (ranges.len == 1) {
                const range = ranges[0];
                body = data[range.start .. range.end + 1];
                try headers.append(allocator, .{ .name = "Content-Range", .value = try std.fmt.allocPrint(allocator, "bytes {d}-{d}/{d}", .{ range.start, range.end, data.len }) });
            } else {
                var random: [16]u8 = undefined;
                try io.randomSecure(&random);
                const boundary = std.fmt.bytesToHex(random, .lower);
                body = try multipart(allocator, data, ranges, &boundary, content_type, false);
                response_type = try std.fmt.allocPrint(allocator, "multipart/byteranges; boundary={s}", .{boundary});
            }
        }
        try headers.append(allocator, .{ .name = "Content-Length", .value = try std.fmt.allocPrint(allocator, "{d}", .{body.len}) });
        return .{ .status = status, .content_type = response_type, .body = if (std.mem.eql(u8, request.method, "HEAD")) "" else body, .headers = try headers.toOwnedSlice(allocator) };
    }
    fn disk(self: *Storage, allocator: Allocator, io: Io, key: []const u8, content_type: []const u8, disposition: []const u8, request: Request) !Result {
        var headers: std.ArrayList(Header) = .empty;
        try headers.append(allocator, .{ .name = "Cache-Control", .value = "max-age=3600, public" });
        try headers.append(allocator, .{ .name = "Content-Disposition", .value = try allocator.dupe(u8, disposition) });
        const owned_type = try allocator.dupe(u8, content_type);
        if (std.mem.eql(u8, request.method, "OPTIONS")) {
            try headers.append(allocator, .{ .name = "Allow", .value = "GET, HEAD, OPTIONS" });
            try headers.append(allocator, .{ .name = "Content-Length", .value = "0" });
            return .{ .status = 200, .content_type = owned_type, .body = "", .headers = try headers.toOwnedSlice(allocator) };
        }
        const mtime = io.blocking(media.modified, .{ self.root, allocator, key }) catch |err| switch (err) {
            error.FileNotFound, error.UnsafeStorageKey => return notFound(),
            else => return err,
        };
        const modified = try httpDate(allocator, mtime);
        if (request.if_modified_since) |conditional| if (std.mem.eql(u8, modified, conditional)) return .{ .status = 304, .content_type = owned_type, .body = "", .headers = try headers.toOwnedSlice(allocator) };
        const data = try io.blocking(media.read, .{ allocator, self.root, key });
        const ranges = try wire.ranges(allocator, request.range, data.len);
        if (ranges != null and ranges.?.len == 0) {
            const body = "Byte range unsatisfiable\n";
            try headers.append(allocator, .{ .name = "Content-Range", .value = try std.fmt.allocPrint(allocator, "bytes */{d}", .{data.len}) });
            try headers.append(allocator, .{ .name = "Content-Length", .value = "25" });
            return .{ .status = 416, .content_type = owned_type, .body = if (std.mem.eql(u8, request.method, "HEAD")) "" else body, .headers = try headers.toOwnedSlice(allocator) };
        }
        try headers.append(allocator, .{ .name = "Last-Modified", .value = modified });
        var body: []const u8 = data;
        var status: u16 = 200;
        if (ranges) |rs| {
            status = 206;
            if (rs.len == 1) {
                body = data[rs[0].start .. rs[0].end + 1];
                try headers.append(allocator, .{ .name = "Content-Range", .value = try std.fmt.allocPrint(allocator, "bytes {d}-{d}/{d}", .{ rs[0].start, rs[0].end, data.len }) });
            } else {
                // Rack's fixed boundary and text/plain part type are intentional.
                // ActiveStorage overwrites outer Content-Type with the signed type.
                body = try multipart(allocator, data, rs, "AaB03x", "text/plain", true);
            }
        }
        try headers.append(allocator, .{ .name = "Content-Length", .value = try std.fmt.allocPrint(allocator, "{d}", .{body.len}) });
        return .{ .status = status, .content_type = owned_type, .body = if (std.mem.eql(u8, request.method, "HEAD")) "" else body, .headers = try headers.toOwnedSlice(allocator) };
    }
};

pub fn representationPath(allocator: Allocator, secrets: *const Secrets, blob: model.Blob, ordered_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/rails/active_storage/representations/redirect/{s}/{s}/{s}", .{ try wire.segment(allocator, try secrets.blobSignedId(allocator, blob.id)), try wire.segment(allocator, try secrets.variationKey(allocator, ordered_json)), try wire.filenamePath(allocator, blob.filename) });
}
pub fn blobPath(allocator: Allocator, secrets: *const Secrets, blob: model.Blob, disposition: ?[]const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/rails/active_storage/blobs/redirect/{s}/{s}", .{ try wire.segment(allocator, try secrets.blobSignedId(allocator, blob.id)), try wire.filenamePath(allocator, blob.filename) });
    if (disposition) |kind| return std.fmt.allocPrint(allocator, "{s}?disposition={s}", .{ path, try compat.urlEncode(allocator, kind) });
    return path;
}
pub fn defaultVariantFormat(blob: model.Blob) []const u8 {
    const ct = blob.content_type orelse return "png";
    const base = std.fs.path.basename(std.mem.trimEnd(u8, blob.filename, "/"));
    const extension = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[dot + 1 ..] else "";
    if (std.mem.eql(u8, ct, "image/jpeg")) {
        for ([_][]const u8{ "jpg", "jpeg", "jpe", "jif", "jfif", "jfi" }) |alias| if (std.ascii.eqlIgnoreCase(extension, alias)) return extension;
        return "jpg";
    }
    for ([_][]const u8{ "png", "gif", "webp" }, [_][]const u8{ "image/png", "image/gif", "image/webp" }) |format, mime| {
        if (std.mem.eql(u8, ct, mime)) return if (std.ascii.eqlIgnoreCase(extension, format)) extension else format;
    }
    return "png";
}
fn variable(blob: model.Blob) bool {
    const ct = blob.content_type orelse return false;
    for ([_][]const u8{ "image/png", "image/gif", "image/jpeg", "image/tiff", "image/webp", "image/avif", "image/heic", "image/heif" }) |supported| if (std.mem.eql(u8, ct, supported)) return true;
    return false;
}
fn video(blob: model.Blob) bool {
    return std.mem.startsWith(u8, blob.content_type orelse "", "video/");
}
fn forcedDisposition(blob: model.Blob) ?[]const u8 {
    const ct = blob.content_type orelse "application/octet-stream";
    for ([_][]const u8{ "image/webp", "image/avif", "image/png", "image/gif", "image/jpeg", "image/tiff", "image/bmp", "image/vnd.adobe.photoshop", "image/vnd.microsoft.icon", "application/pdf" }) |allowed| if (std.mem.eql(u8, ct, allowed)) return null;
    return "attachment";
}
fn servingType(blob: model.Blob) []const u8 {
    const ct = blob.content_type orelse "application/octet-stream";
    for ([_][]const u8{ "text/html", "image/svg+xml", "application/postscript", "application/x-shockwave-flash", "text/xml", "application/xml", "application/xhtml+xml", "application/mathml+xml", "text/cache-manifest" }) |binary| if (std.mem.eql(u8, ct, binary)) return "application/octet-stream";
    return ct;
}
fn filenameBase(raw: []const u8) []const u8 {
    const base = std.fs.path.basename(std.mem.trimEnd(u8, raw, "/"));
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (std.mem.trim(u8, base[0..dot], ".").len == 0) return base;
    return base[0..dot];
}
fn randomKey(allocator: Allocator, io: Io) ![]const u8 {
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
    const key = try allocator.alloc(u8, 28);
    errdefer allocator.free(key);
    var i: usize = 0;
    while (i < key.len) {
        var random: [32]u8 = undefined;
        try io.randomSecure(&random);
        for (random) |b| {
            if (b >= 252) continue;
            key[i] = alphabet[b % 36];
            i += 1;
            if (i == key.len) break;
        }
    }
    return key;
}
fn timestamp(allocator: Allocator, now: i64) ![]const u8 {
    return @import("compat/time.zig").format(allocator, .{ .seconds = now }, 6, true);
}
fn jsonString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn safeHeader(value: []const u8) bool {
    for (value) |b| if (b < 32 or b == 127) return false;
    return true;
}
fn jsonDiskPayload(allocator: Allocator, key: []const u8, disposition: []const u8, content_type: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"key\":");
    try std.json.Stringify.value(key, .{ .emit_null_optional_fields = true }, &out.writer);
    try out.writer.writeAll(",\"disposition\":");
    try std.json.Stringify.value(disposition, .{}, &out.writer);
    try out.writer.writeAll(",\"content_type\":");
    try std.json.Stringify.value(content_type, .{}, &out.writer);
    try out.writer.writeAll(",\"service_name\":\"local\"}");
    var escaped: Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    for (out.written()) |ch| switch (ch) {
        '<' => try escaped.writer.writeAll("\\u003c"),
        '>' => try escaped.writer.writeAll("\\u003e"),
        '&' => try escaped.writer.writeAll("\\u0026"),
        else => try escaped.writer.writeByte(ch),
    };
    return escaped.toOwnedSlice();
}
fn requestedDisposition(allocator: Allocator, query: []const u8) ![]const u8 {
    if (query.len == 0) return "inline";
    var parts = std.mem.splitScalar(u8, query[1..], '&');
    while (parts.next()) |part| if (std.mem.startsWith(u8, part, "disposition=")) {
        const encoded = try allocator.dupe(u8, part[12..]);
        defer allocator.free(encoded);
        for (encoded) |*ch| if (ch.* == '+') {
            ch.* = ' ';
        };
        const value = try wire.decodeSegment(allocator, encoded);
        if (!safeHeader(value)) return error.InvalidDisposition;
        return value;
    };
    return "inline";
}
fn pathEtag(allocator: Allocator, path: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return std.fmt.allocPrint(allocator, "W/\"{s}\"", .{hex});
}
fn fresh(header: ?[]const u8, etag: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, header orelse return false, ',');
    while (tokens.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (std.mem.eql(u8, t, "*") or std.mem.eql(u8, t, etag) or std.mem.eql(u8, t, etag[2..])) return true;
    }
    return false;
}
fn cacheHeaders(allocator: Allocator, etag: []const u8) ![]const Header {
    const headers = try allocator.alloc(Header, 3);
    headers[0] = .{ .name = "ETag", .value = etag };
    headers[1] = .{ .name = "Cache-Control", .value = "max-age=3155695200, public, immutable" };
    headers[2] = .{ .name = "Last-Modified", .value = "Sat, 01 Jan 2011 00:00:00 GMT" };
    return headers;
}
fn httpDate(allocator: Allocator, seconds: i64) ![]const u8 {
    const t: media.c.time_t = @intCast(seconds);
    var tm: media.c.struct_tm = undefined;
    if (media.c.gmtime_r(&t, &tm) == null) return error.InvalidTimestamp;
    var buffer: [64]u8 = undefined;
    const len = media.c.strftime(&buffer, buffer.len, "%a, %d %b %Y %H:%M:%S GMT", &tm);
    if (len == 0) return error.InvalidTimestamp;
    return allocator.dupe(u8, buffer[0..len]);
}
fn multipart(allocator: Allocator, data: []const u8, ranges: []const wire.Range, boundary: []const u8, content_type: []const u8, rack: bool) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (ranges) |range| {
        try out.writer.print("\r\n--{s}\r\n{s}: {s}\r\n{s}: bytes {d}-{d}/{d}\r\n\r\n", .{ boundary, if (rack) "content-type" else "Content-Type", content_type, if (rack) "content-range" else "Content-Range", range.start, range.end, data.len });
        try out.writer.writeAll(data[range.start .. range.end + 1]);
    }
    try out.writer.print("\r\n--{s}--\r\n", .{boundary});
    return out.toOwnedSlice();
}
fn notFound() Result {
    return .{ .status = 404, .content_type = "text/plain", .body = "" };
}
fn invalidOrError(err: anyerror) !Result {
    if (err == error.OutOfMemory) return err;
    return notFound();
}

test {
    _ = @import("storage/variation.zig");
    _ = @import("storage/wire.zig");
    _ = @import("storage/media.zig");
}
test {
    _ = @import("storage/tests.zig");
}
