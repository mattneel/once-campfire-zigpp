const std = @import("std");
const storage = @import("../storage.zig");
const media = @import("media.zig");
const Variation = @import("variation.zig").Variation;
const wire = @import("wire.zig");
const db = @import("../db.zig");
const compat = @import("../compat.zig");
const model = @import("../model.zig");
const c = @cImport({ @cInclude("sqlite3.h"); });
const Allocator = std.mem.Allocator;
const Io = std.Io;
fn exec(database: *db.Database, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(@ptrCast(database.writer), sql.ptr, null, null, null) != c.SQLITE_OK) return error.TestSeedFailure;
}
fn header(result: storage.Result, name: []const u8) ?[]const u8 {
    for (result.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}
fn proxyPath(a: Allocator, secrets: *compat.Secrets, id: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "/rails/active_storage/blobs/proxy/{s}/source.jpg", .{try wire.segment(a, try secrets.blobSignedId(a, id))});
}

/// Actual C-backed disk operations, signatures and SQLite variant rows. No
/// mocks, original substitution, golden-file response fixture, or external port.
test "native storage serves media and persists actual named variants across reopening" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fmt.allocPrint(a, "{s}/storage.sqlite3", .{root});
    var database = try db.Database.init(std.testing.allocator, io, path, 1);
    defer database.deinit();
    var secrets = try compat.Secrets.init(a, "deterministic-native-storage-test-secret");
    defer secrets.deinit();
    var store = try storage.Storage.init(a, io, root, &database, &secrets);
    defer store.deinit();
    const source = try Io.Dir.cwd().readFileAlloc(io, "vectors/storage/moon-thumb.jpg", a, .unlimited);
    const key = "abcdsource000000000000000000";
    try io.blocking(media.write, .{ a, store.root, key, source });
    const sql = try std.fmt.allocPrintSentinel(a, "INSERT INTO active_storage_blobs(id,key,filename,content_type,metadata,service_name,byte_size,checksum,created_at) VALUES(100,'{s}','source.jpg','image/jpeg','{{}}','local',{d},NULL,'2026-01-01 00:00:00.000000')", .{key, source.len}, 0);
    try io.blocking(exec, .{ &database, sql });
    const blob = (try database.blob(a, io, 100)).?;
    const user: model.User = .{ .id = 1, .name = "Native", .created_at = blob.created_at, .updated_at = blob.created_at, .avatar = blob };
    const now: i64 = 1_800_000_000;

    const proxy = try proxyPath(a, &secrets, 100);
    const original = (try store.handle(a, io, .{ .method = "GET", .path = proxy, .now = now })).?;
    try std.testing.expectEqual(@as(u16, 200), original.status);
    try std.testing.expectEqualSlices(u8, source, original.body);
    const conditional = (try store.handle(a, io, .{ .method = "GET", .path = proxy, .if_none_match = header(original, "ETag"), .now = now })).?;
    try std.testing.expectEqual(@as(u16, 304), conditional.status);
    try std.testing.expectEqual(@as(usize, 0), conditional.body.len);
    const ranged = (try store.handle(a, io, .{ .method = "GET", .path = proxy, .range = "bytes=0-9", .if_none_match = header(original, "ETag"), .now = now })).?;
    try std.testing.expectEqual(@as(u16, 206), ranged.status);
    try std.testing.expectEqualSlices(u8, source[0..10], ranged.body);
    const beyond = (try store.handle(a, io, .{ .method = "GET", .path = proxy, .range = "bytes=99999999999999999999999-", .now = now })).?;
    try std.testing.expectEqual(@as(u16, 416), beyond.status);
    const multi = (try store.handle(a, io, .{ .method = "GET", .path = proxy, .range = "bytes=0-1,5-8", .now = now })).?;
    try std.testing.expectEqual(@as(u16, 206), multi.status);
    try std.testing.expect(std.mem.startsWith(u8, multi.content_type, "multipart/byteranges; boundary="));
    try std.testing.expect(std.mem.indexOf(u8, multi.body, source[5..9]) != null);

    const avatar = (try store.avatar(a, io, user, now)).?;
    try std.testing.expectEqualStrings("image/webp", avatar.content_type);
    try std.testing.expect(avatar.body.len > 12);
    try std.testing.expectEqualStrings("RIFF", avatar.body[0..4]);
    try std.testing.expectEqualStrings("WEBP", avatar.body[8..12]);
    try std.testing.expect(!std.mem.eql(u8, source, avatar.body));
    const digest = try Variation.avatar().digest(a);
    const variant = (try database.existingVariant(a, io, blob.id, digest)).?;
    try std.testing.expect(variant.id != blob.id);
    try std.testing.expect(!std.mem.eql(u8, variant.key, blob.key));
    try std.testing.expectEqual(@as(i64, @intCast(avatar.body.len)), variant.byte_size);
    try std.testing.expectEqualSlices(u8, avatar.body, try io.blocking(media.read, .{ a, store.root, variant.key }));
    const dimensions = try io.blocking(media.dimensions, .{avatar.body});
    try std.testing.expect(dimensions.width > 0 and dimensions.width <= 512 and dimensions.height > 0 and dimensions.height <= 512);
    try std.testing.expectEqualStrings(try media.checksum(a, avatar.body), variant.checksum.?);
    const again = (try store.avatar(a, io, user, now)).?;
    try std.testing.expectEqualSlices(u8, avatar.body, again.body);
    const unchanged = (try database.existingVariant(a, io, blob.id, digest)).?;
    try std.testing.expectEqual(variant.id, unchanged.id);
    try std.testing.expectEqualStrings(variant.key, unchanged.key);

    const large = (try store.logo(a, io, blob, 512, now)).?;
    const small = (try store.logo(a, io, blob, 192, now)).?;
    try std.testing.expectEqualSlices(u8, &.{ 137, 'P', 'N', 'G', 13, 10, 26, 10 }, large.body[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 137, 'P', 'N', 'G', 13, 10, 26, 10 }, small.body[0..8]);
    try std.testing.expectError(error.UnsupportedVariation, store.logo(a, io, blob, 200, now));

    const url = try storage.representationPath(a, &secrets, blob, "{\"format\":\"webp\",\"resize_to_limit\":[512,512]}");
    const redirected = (try store.handle(a, io, .{ .method = "GET", .path = url, .now = now })).?;
    try std.testing.expectEqual(@as(u16, 302), redirected.status);
    const disk = header(redirected, "Location").?;
    const served = (try store.handle(a, io, .{ .method = "GET", .path = disk, .now = now })).?;
    try std.testing.expectEqual(@as(u16, 200), served.status);
    try std.testing.expectEqualStrings("image/webp", served.content_type);
    try std.testing.expect(served.body.len > 12);
    const disk_head = (try store.handle(a, io, .{ .method = "HEAD", .path = disk, .now = now })).?;
    try std.testing.expectEqual(@as(usize, 0), disk_head.body.len);
    try std.testing.expectEqualStrings(header(served, "Content-Length").?, header(disk_head, "Content-Length").?);
    const disk_conditional = (try store.handle(a, io, .{ .method = "GET", .path = disk, .if_modified_since = header(served, "Last-Modified"), .now = now })).?;
    try std.testing.expectEqual(@as(u16, 304), disk_conditional.status);
    const expired = (try store.handle(a, io, .{ .method = "GET", .path = disk, .now = now + 300 })).?;
    try std.testing.expectEqual(@as(u16, 404), expired.status);

    // The URL-decoded string-format digest is distinct from the symbol-format
    // avatar row; both actual generated files must remain attached in SQLite.
    const decoded_digest = try (Variation{ .width = 512, .height = 512, .format = "webp" }).digest(a);
    const decoded_variant = (try database.existingVariant(a, io, blob.id, decoded_digest)).?;
    try std.testing.expect(decoded_variant.id != variant.id);
    database.deinit();
    database = try db.Database.init(std.testing.allocator, io, path, 1);
    const reopened = (try database.existingVariant(a, io, blob.id, digest)).?;
    try std.testing.expectEqual(variant.id, reopened.id);
    const persisted = (try store.avatar(a, io, user, now)).?;
    try std.testing.expectEqualSlices(u8, avatar.body, persisted.body);
}

test "native disk rejects signed traversal invalid purpose and expired tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var database = try db.Database.init(std.testing.allocator, io, try std.fmt.allocPrint(a, "{s}/storage.sqlite3", .{root}), 1);
    defer database.deinit();
    var secrets = try compat.Secrets.init(a, "deterministic-native-storage-test-secret");
    defer secrets.deinit();
    var store = try storage.Storage.init(a, io, root, &database, &secrets);
    defer store.deinit();
    const now: i64 = 1_800_000_000;
    const payload = "{\"key\":\"../outside\",\"disposition\":\"inline\",\"content_type\":\"image/png\",\"service_name\":\"local\"}";
    const signed = try secrets.signDiskKey(a, payload, now + 60);
    const url = try std.fmt.allocPrint(a, "/rails/active_storage/disk/{s}/file.png", .{try wire.segment(a, signed)});
    try std.testing.expectEqual(@as(u16, 404), (try store.handle(a, io, .{ .method = "GET", .path = url, .now = now })).?.status);
    const wrong = try secrets.variationKey(a, payload);
    const wrong_url = try std.fmt.allocPrint(a, "/rails/active_storage/disk/{s}/file.png", .{try wire.segment(a, wrong)});
    try std.testing.expectEqual(@as(u16, 404), (try store.handle(a, io, .{ .method = "GET", .path = wrong_url, .now = now })).?.status);
    const blob_token = try secrets.blobSignedId(a, 1);
    const blob_disk_url = try std.fmt.allocPrint(a, "/rails/active_storage/disk/{s}/file.png", .{try wire.segment(a, blob_token)});
    try std.testing.expectEqual(@as(u16, 404), (try store.handle(a, io, .{ .method = "GET", .path = blob_disk_url, .now = now })).?.status);
    try std.testing.expect((try store.handle(a, io, .{ .method = "GET", .path = "/not-storage", .now = now })) == null);
    const bad = (try store.handle(a, io, .{ .method = "GET", .path = "/rails/active_storage/blobs/proxy/bad%/x", .now = now })).?;
    try std.testing.expectEqual(@as(u16, 404), bad.status);

    const real_key = "abcdsymlink00000000000000000";
    const symlink = try std.fmt.allocPrintSentinel(a, "{s}/ab", .{root}, 0);
    try std.testing.expectEqual(@as(c_int, 0), media.c.symlink("/tmp", symlink.ptr));
    try std.testing.expectError(error.UnsafeStorageKey, io.blocking(media.read, .{ a, store.root, real_key }));
}

extern var environ: [*:null]?[*:0]u8;
fn makeVideo(allocator: Allocator, path: []const u8) !void {
    const target = try allocator.dupeZ(u8, path);
    defer allocator.free(target);
    const argv = [_:null]?[*:0]const u8{
        "ffmpeg", "-f", "lavfi", "-i", "color=c=blue:s=64x48:r=10",
        "-t", "0.4", "-c:v", "mpeg4", "-threads", "1", "-y", target.ptr,
    };
    var actions: media.c.posix_spawn_file_actions_t = undefined;
    if (media.c.posix_spawn_file_actions_init(&actions) != 0) return error.TestVideoGeneration;
    defer _ = media.c.posix_spawn_file_actions_destroy(&actions);
    for ([_]c_int{ 0, 1, 2 }) |fd| if (media.c.posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", if (fd == 0) media.c.O_RDONLY else media.c.O_WRONLY, 0) != 0) return error.TestVideoGeneration;
    var pid: media.c.pid_t = undefined;
    if (media.c.posix_spawnp(&pid, "ffmpeg", &actions, null, @ptrCast(@constCast(&argv)), @ptrCast(environ)) != 0) return error.TestVideoGeneration;
    var status: c_int = 0;
    while (media.c.waitpid(pid, &status, 0) < 0) if (media.c.__errno_location().* != media.c.EINTR) return error.TestVideoGeneration;
    if (status != 0) return error.TestVideoGeneration;
}

test "native FFmpeg poster is a real persisted JPEG preview and WebP variant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const video_path = try std.fmt.allocPrint(a, "{s}/blue.mp4", .{root});
    try io.blocking(makeVideo, .{ a, video_path });
    const video_bytes = try Io.Dir.cwd().readFileAlloc(io, video_path, a, .unlimited);
    var database = try db.Database.init(std.testing.allocator, io, try std.fmt.allocPrint(a, "{s}/storage.sqlite3", .{root}), 1);
    defer database.deinit();
    var secrets = try compat.Secrets.init(a, "deterministic-native-storage-test-secret");
    defer secrets.deinit();
    var store = try storage.Storage.init(a, io, root, &database, &secrets);
    defer store.deinit();
    const key = "abcdvideo0000000000000000000";
    try io.blocking(media.write, .{ a, store.root, key, video_bytes });
    const sql = try std.fmt.allocPrintSentinel(a, "INSERT INTO active_storage_blobs(id,key,filename,content_type,metadata,service_name,byte_size,checksum,created_at) VALUES(200,'{s}','blue.mp4','video/mp4','{{}}','local',{d},NULL,'2026-01-01 00:00:00.000000')", .{ key, video_bytes.len }, 0);
    try io.blocking(exec, .{ &database, sql });
    const blob = (try database.blob(a, io, 200)).?;
    const now: i64 = 1_800_000_000;
    const path = try storage.representationPath(a, &secrets, blob, "{\"format\":\"webp\",\"resize_to_limit\":[1200,800]}");
    const redirected = (try store.handle(a, io, .{ .method = "GET", .path = path, .now = now })).?;
    try std.testing.expectEqual(@as(u16, 302), redirected.status);
    const preview = (try database.existingPreview(a, io, blob.id)).?;
    try std.testing.expectEqualStrings("image/jpeg", preview.content_type.?);
    const jpeg = try io.blocking(media.read, .{ a, store.root, preview.key });
    try std.testing.expectEqualSlices(u8, &.{ 255, 216, 255 }, jpeg[0..3]);
    try std.testing.expectEqualStrings(try media.checksum(a, jpeg), preview.checksum.?);
    const digest = try (Variation{ .width = 1200, .height = 800, .format = "webp" }).digest(a);
    const poster = (try database.existingVariant(a, io, preview.id, digest)).?;
    const served = (try store.handle(a, io, .{ .method = "GET", .path = header(redirected, "Location").?, .now = now })).?;
    try std.testing.expectEqualStrings("image/webp", served.content_type);
    try std.testing.expectEqualStrings("RIFF", served.body[0..4]);
    try std.testing.expectEqualStrings("WEBP", served.body[8..12]);
    const dimensions = try io.blocking(media.dimensions, .{served.body});
    try std.testing.expectEqual(@as(i32, 64), dimensions.width);
    try std.testing.expectEqual(@as(i32, 48), dimensions.height);
    try std.testing.expectEqualSlices(u8, served.body, try io.blocking(media.read, .{ a, store.root, poster.key }));
    const repeat = (try store.handle(a, io, .{ .method = "GET", .path = path, .now = now })).?;
    try std.testing.expectEqual(@as(u16, 302), repeat.status);
    try std.testing.expectEqual(preview.id, (try database.existingPreview(a, io, blob.id)).?.id);
    try std.testing.expectEqual(poster.id, (try database.existingVariant(a, io, preview.id, digest)).?.id);
}
