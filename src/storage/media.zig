const std = @import("std");
const Allocator = std.mem.Allocator;
const Variation = @import("variation.zig").Variation;
pub const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("spawn.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("errno.h");
});
const Image = opaque {};
extern fn vips_init([*:0]const u8) c_int;
extern fn vips_version_string() [*:0]const u8;
extern fn vips_block_untrusted_set(c_int) void;
extern fn vips_operation_block_set([*:0]const u8, c_int) void;
extern fn vips_foreign_find_load_buffer([*]const u8, usize) ?[*:0]const u8;
extern fn vips_operation_new([*:0]const u8) ?*anyopaque;
extern fn vips_object_get_args(*anyopaque, *?[*]const [*:0]const u8, *?[*]const c_int, *c_int) c_int;
extern fn vips_image_new_from_buffer([*]const u8, usize, [*:0]const u8, ...) ?*Image;
extern fn vips_autorot(*Image, *?*Image, ...) c_int;
extern fn vips_thumbnail_image(*Image, *?*Image, c_int, ...) c_int;
extern fn vips_image_new_matrix_from_array(c_int, c_int, [*]const f64, c_int) ?*Image;
extern fn vips_image_set_double(*Image, [*:0]const u8, f64) void;
extern fn vips_conv(*Image, *?*Image, *Image, ...) c_int;
extern fn vips_image_write_to_buffer(*Image, [*:0]const u8, *?*anyopaque, *usize, ...) c_int;
extern fn vips_image_get_width(*Image) c_int;
extern fn vips_image_get_height(*Image) c_int;
extern fn vips_error_clear() void;
extern fn g_object_unref(*anyopaque) void;
extern fn g_free(*anyopaque) void;
extern var environ: [*:null]?[*:0]u8;

/// All entry points in this module perform blocking C/filesystem/process work.
/// Storage calls them exclusively through io.blocking, without a DB connection.
pub fn init() !void {
    if (vips_init("campfire-zigpp") != 0) return error.VipsInit;
    vips_block_untrusted_set(1);
    vips_operation_block_set("VipsForeignLoadOpenslide", 1);
}
pub fn version() []const u8 { return std.mem.span(vips_version_string()); }
pub fn openRoot(allocator: Allocator, path: []const u8) !c_int {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = c.open(z.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return error.StorageRootUnavailable;
    return fd;
}
pub fn validKey(key: []const u8) bool {
    if (key.len < 4 or key.len > 255) return false;
    for (key) |b| if (!std.ascii.isAlphanumeric(b) and b != '-' and b != '_') return false;
    return true;
}
fn folder(root: c_int, key: []const u8, create: bool) !c_int {
    if (!validKey(key)) return error.UnsafeStorageKey;
    const a: [3:0]u8 = .{ key[0], key[1], 0 };
    const b: [3:0]u8 = .{ key[2], key[3], 0 };
    if (create and c.mkdirat(root, &a, 0o700) != 0 and c.__errno_location().* != c.EEXIST) return error.StorageWrite;
    const first = c.openat(root, &a, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (first < 0) return fileError();
    defer _ = c.close(first);
    if (create and c.mkdirat(first, &b, 0o700) != 0 and c.__errno_location().* != c.EEXIST) return error.StorageWrite;
    const second = c.openat(first, &b, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (second < 0) return fileError();
    return second;
}
fn fileError() anyerror {
    return switch (c.__errno_location().*) { c.ENOENT => error.FileNotFound, c.ELOOP, c.ENOTDIR => error.UnsafeStorageKey, else => error.StorageRead };
}
pub fn openKey(allocator: Allocator, root: c_int, key: []const u8) !c_int {
    const dir = try folder(root, key, false);
    defer _ = c.close(dir);
    const z = try allocator.dupeZ(u8, key);
    defer allocator.free(z);
    const fd = c.openat(dir, z.ptr, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return fileError();
    errdefer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.StorageRead;
    if ((stat.st_mode & c.S_IFMT) != c.S_IFREG) return error.UnsafeStorageKey;
    return fd;
}
pub fn read(allocator: Allocator, root: c_int, key: []const u8) ![]const u8 {
    const fd = try openKey(allocator, root, key);
    defer _ = c.close(fd);
    return readFd(allocator, fd);
}
fn readFd(allocator: Allocator, fd: c_int) ![]const u8 {
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_size < 0) return error.StorageRead;
    const len = std.math.cast(usize, stat.st_size) orelse return error.FileTooLarge;
    const data = try allocator.alloc(u8, len);
    errdefer allocator.free(data);
    var pos: usize = 0;
    while (pos < data.len) {
        const n = c.pread(fd, data.ptr + pos, data.len - pos, @intCast(pos));
        if (n < 0) { if (c.__errno_location().* == c.EINTR) continue; return error.StorageRead; }
        if (n == 0) return error.StorageRead;
        pos += @intCast(n);
    }
    return data;
}
pub fn write(allocator: Allocator, root: c_int, key: []const u8, bytes: []const u8) !void {
    const fd = try create(allocator, root, key);
    defer _ = c.close(fd);
    errdefer remove(allocator, root, key);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = c.write(fd, bytes.ptr + pos, bytes.len - pos);
        if (n < 0) { if (c.__errno_location().* == c.EINTR) continue; return error.StorageWrite; }
        if (n == 0) return error.StorageWrite;
        pos += @intCast(n);
    }
    if (c.fsync(fd) != 0) return error.StorageWrite;
}
fn create(allocator: Allocator, root: c_int, key: []const u8) !c_int {
    const dir = try folder(root, key, true);
    defer _ = c.close(dir);
    const z = try allocator.dupeZ(u8, key);
    defer allocator.free(z);
    const fd = c.openat(dir, z.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.StorageWrite;
    return fd;
}
pub fn remove(allocator: Allocator, root: c_int, key: []const u8) void {
    const dir = folder(root, key, false) catch return;
    defer _ = c.close(dir);
    const z = allocator.dupeZ(u8, key) catch return;
    defer allocator.free(z);
    _ = c.unlinkat(dir, z.ptr, 0);
}
pub fn modified(root: c_int, allocator: Allocator, key: []const u8) !i64 {
    const fd = try openKey(allocator, root, key);
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.StorageRead;
    return @intCast(stat.st_mtim.tv_sec);
}
pub fn checksum(allocator: Allocator, data: []const u8) ![]const u8 {
    var sum: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &sum, .{});
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(sum.len));
    return std.base64.standard.Encoder.encode(out, &sum);
}

pub const Generated = struct { bytes: []const u8, width: i32, height: i32 };
pub fn transform(allocator: Allocator, source: []const u8, variation: Variation) !Generated {
    const input = try load(source);
    defer g_object_unref(input);
    var rotated: ?*Image = null;
    if (vips_autorot(input, &rotated, @as(?[*:0]const u8, null)) != 0) return error.InvalidImage;
    const image = rotated orelse return error.InvalidImage;
    defer g_object_unref(image);
    if (variation.width) |width| {
        var thumb: ?*Image = null;
        if (vips_thumbnail_image(image, &thumb, @as(c_int, width), "height", @as(c_int, variation.height.?), "size", @as(c_int, 2), "no_rotate", @as(c_int, 1), @as(?[*:0]const u8, null)) != 0) return error.VipsTransform;
        const thumbnail = thumb orelse return error.VipsTransform;
        defer g_object_unref(thumbnail);
        const mask_values = [_]f64{ -1, -1, -1, -1, 32, -1, -1, -1, -1 };
        const mask = vips_image_new_matrix_from_array(3, 3, &mask_values, 9) orelse return error.VipsTransform;
        defer g_object_unref(mask);
        vips_image_set_double(mask, "scale", 24);
        vips_image_set_double(mask, "offset", 0);
        var sharp: ?*Image = null;
        if (vips_conv(thumbnail, &sharp, mask, "precision", @as(c_int, 0), @as(?[*:0]const u8, null)) != 0) return error.VipsTransform;
        const sharpened = sharp orelse return error.VipsTransform;
        defer g_object_unref(sharpened);
        return encode(allocator, sharpened, variation.format);
    }
    return encode(allocator, image, variation.format);
}
fn encode(allocator: Allocator, image: *Image, format: []const u8) !Generated {
    const suffix = try std.fmt.allocPrintSentinel(allocator, ".{s}", .{format}, 0);
    defer allocator.free(suffix);
    var output: ?*anyopaque = null;
    var len: usize = 0;
    if (vips_image_write_to_buffer(image, suffix.ptr, &output, &len, @as(?[*:0]const u8, null)) != 0) return error.VipsTransform;
    const data: [*]const u8 = @ptrCast(output orelse return error.VipsTransform);
    defer g_free(output.?);
    return .{ .bytes = try allocator.dupe(u8, data[0..len]), .width = vips_image_get_width(image), .height = vips_image_get_height(image) };
}
pub fn dimensions(data: []const u8) !struct { width: i32, height: i32 } {
    const image = vips_image_new_from_buffer(data.ptr, data.len, "", @as(?[*:0]const u8, null)) orelse return error.InvalidImage;
    defer g_object_unref(image);
    var rotated: ?*Image = null;
    if (vips_autorot(image, &rotated, @as(?[*:0]const u8, null)) != 0) return error.InvalidImage;
    const oriented = rotated orelse return error.InvalidImage;
    defer g_object_unref(oriented);
    return .{ .width = vips_image_get_width(oriented), .height = vips_image_get_height(oriented) };
}

fn load(source: []const u8) !*Image {
    var accepts_page = false;
    if (vips_foreign_find_load_buffer(source.ptr, source.len)) |loader| {
        if (vips_operation_new(loader)) |operation| {
            defer g_object_unref(operation);
            var names: ?[*]const [*:0]const u8 = null;
            var flags: ?[*]const c_int = null;
            var count: c_int = 0;
            if (vips_object_get_args(operation, &names, &flags, &count) == 0 and names != null and flags != null) {
                var i: usize = 0;
                while (i < @as(usize, @intCast(@max(count, 0)))) : (i += 1) {
                    const f = flags.?[i];
                    const required = f & 1 != 0 and f & 64 == 0;
                    if (std.mem.eql(u8, std.mem.span(names.?[i]), "page") and f & 2 != 0 and f & 16 != 0 and !required) accepts_page = true;
                }
            }
        }
    }
    return (if (accepts_page)
        vips_image_new_from_buffer(source.ptr, source.len, "", "page", @as(c_int, 0), @as(?[*:0]const u8, null))
    else
        vips_image_new_from_buffer(source.ptr, source.len, "", @as(?[*:0]const u8, null))) orelse error.InvalidImage;
}

/// posix_spawn, not fork or a shell: path/key bytes cannot become shell syntax.
/// Same relevant-frame filter and image2/JPEG defaults as the canonical pipeline.
/// A parent-held fd becomes child fd3, preserving the no-symlink source boundary.
pub fn preview(allocator: Allocator, root: c_int, source_key: []const u8, temp_key: []const u8) !Generated {
    const input = try openKey(allocator, root, source_key);
    defer _ = c.close(input);
    const output = try create(allocator, root, temp_key);
    defer _ = c.close(output);
    defer remove(allocator, root, temp_key);
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.PreviewSpawn;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    // stdout first, in case one of the open descriptors is fd3.
    if (c.posix_spawn_file_actions_adddup2(&actions, output, 1) != 0 or c.posix_spawn_file_actions_adddup2(&actions, input, 3) != 0 or c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", c.O_RDONLY, 0) != 0 or c.posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", c.O_WRONLY, 0) != 0) return error.PreviewSpawn;
    const args = [_:null]?[*:0]const u8{ "ffmpeg", "-i", "/proc/self/fd/3", "-vf", "select=eq(n\\,0)+eq(key\\,1)+gt(scene\\,0.015),loop=loop=-1:size=2,trim=start_frame=1", "-frames:v", "1", "-f", "image2", "-" };
    var pid: c.pid_t = undefined;
    if (c.posix_spawnp(&pid, "ffmpeg", &actions, null, @ptrCast(@constCast(&args)), @ptrCast(environ)) != 0) return error.PreviewSpawn;
    var reaped = false;
    defer if (!reaped) { _ = c.kill(pid, c.SIGKILL); var status: c_int = 0; while (c.waitpid(pid, &status, 0) < 0 and c.__errno_location().* == c.EINTR) {} };
    var started: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &started) != 0) return error.PreviewSpawn;
    while (true) {
        var status: c_int = 0;
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited == pid) {
            reaped = true;
            if (status != 0) return error.PreviewFailed;
            break;
        }
        if (waited < 0 and c.__errno_location().* != c.EINTR) return error.PreviewFailed;
        var now: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return error.PreviewFailed;
        if (now.tv_sec - started.tv_sec >= 60) return error.PreviewTimeout;
        const pause: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 5_000_000 };
        _ = c.nanosleep(&pause, null);
    }
    const bytes = try read(allocator, root, temp_key);
    errdefer allocator.free(bytes);
    if (bytes.len == 0) return error.PreviewFailed;
    const size = try dimensions(bytes);
    return .{ .bytes = bytes, .width = size.width, .height = size.height };
}

test "disk keys cannot escape preserved ActiveStorage layout" {
    for ([_][]const u8{ "", "abc", "../outside", "abcd/../../etc/passwd", "abcd\\file", "ab%2fcd", "/absolute", "abcd\x00tail", "ab.cd" }) |key| try std.testing.expect(!validKey(key));
    try std.testing.expect(validKey("abcdef0123456789"));
    try std.testing.expect(validKey("abcd-safe_key"));
}
