//! crates/kit/src/deflater/splice.rs: recorded fragments, dictionary-chained deflate,
//! remembered text digests and CRC composition. No path or authenticated response cache.
const std = @import("std");
const views = @import("views.zig");
const c = @import("c");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha = [32]u8;
const overhead = 128;
const text_budget = 16 << 20;
const piece_budget = 32 << 20;
const window = 32 * 1024;

const Metadata = struct { sha: Sha, crc: u32 };
const Key = struct { sha: Sha, before: Sha, glue: Sha };
const TextContext = struct {
    pub fn hash(_: TextContext, bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(0, bytes);
    }
    pub fn eql(_: TextContext, left: []const u8, right: []const u8) bool {
        // These layout keys span kilobytes. The C comparison avoids the profiled SDK
        // comparator's bytewise vector reconstruction under the shared memo lock.
        return left.len == right.len and (left.len == 0 or left.ptr == right.ptr or c.memcmp(left.ptr, right.ptr, left.len) == 0);
    }
};
const TextMap = std.HashMapUnmanaged([]const u8, Metadata, TextContext, 80);
const Piece = struct {
    allocator: Allocator,
    references: std.atomic.Value(usize) = .init(1),
    bytes: []u8,
    crc: u32,
    shift: u32,

    fn retain(self: *Piece) *Piece {
        _ = self.references.fetchAdd(1, .monotonic);
        return self;
    }
    fn release(self: *Piece) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) {
            const allocator = self.allocator;
            allocator.free(self.bytes);
            allocator.destroy(self);
        }
    }
};

pub const Cache = struct {
    allocator: Allocator,
    io: Io,
    text_mutex: Io.Mutex = .init,
    text_young: TextMap = .empty,
    text_old: TextMap = .empty,
    text_cost: usize = 0,
    piece_mutex: Io.Mutex = .init,
    piece_young: std.AutoHashMapUnmanaged(Key, *Piece) = .empty,
    piece_old: std.AutoHashMapUnmanaged(Key, *Piece) = .empty,
    piece_cost: usize = 0,

    pub fn init(allocator: Allocator, io: Io) Cache {
        return .{ .allocator = allocator, .io = io };
    }
    pub fn deinit(self: *Cache) void {
        self.clearTexts(&self.text_young);
        self.clearTexts(&self.text_old);
        self.text_young.deinit(self.allocator);
        self.text_old.deinit(self.allocator);
        self.clearPieces(&self.piece_young);
        self.clearPieces(&self.piece_old);
        self.piece_young.deinit(self.allocator);
        self.piece_old.deinit(self.allocator);
    }
    fn clearTexts(self: *Cache, map: *TextMap) void {
        var keys = map.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        map.clearRetainingCapacity();
    }
    fn clearPieces(_: *Cache, map: *std.AutoHashMapUnmanaged(Key, *Piece)) void {
        var values = map.valueIterator();
        while (values.next()) |value| value.*.release();
        map.clearRetainingCapacity();
    }
    fn rotateTexts(self: *Cache, cost: usize) void {
        if (self.text_cost + cost <= text_budget / 2) return;
        self.clearTexts(&self.text_old);
        std.mem.swap(TextMap, &self.text_young, &self.text_old);
        self.text_cost = 0;
    }
    fn rotatePieces(self: *Cache, cost: usize) void {
        if (self.piece_cost + cost <= piece_budget / 2) return;
        self.clearPieces(&self.piece_old);
        std.mem.swap(std.AutoHashMapUnmanaged(Key, *Piece), &self.piece_young, &self.piece_old);
        self.piece_cost = 0;
    }
    fn metadata(self: *Cache, bytes: []const u8) !Metadata {
        {
            try self.text_mutex.lock(self.io);
            defer self.text_mutex.unlock(self.io);
            if (self.text_young.get(bytes)) |found| return found;
            if (self.text_old.fetchRemove(bytes)) |found| {
                errdefer self.allocator.free(found.key);
                const cost = found.key.len + overhead;
                self.rotateTexts(cost);
                try self.text_young.put(self.allocator, found.key, found.value);
                self.text_cost += cost;
                return found.value;
            }
        }
        var result: Metadata = .{ .sha = undefined, .crc = std.hash.Crc32.hash(bytes) };
        std.crypto.hash.sha2.Sha256.hash(bytes, &result.sha, .{});
        if (bytes.len > text_budget / 64) return result;
        const key = try self.allocator.dupe(u8, bytes);
        var owned = true;
        defer if (owned) self.allocator.free(key);
        try self.text_mutex.lock(self.io);
        defer self.text_mutex.unlock(self.io);
        if (self.text_young.get(bytes)) |found| return found;
        if (self.text_old.get(bytes)) |found| return found;
        const cost = key.len + overhead;
        self.rotateTexts(cost);
        try self.text_young.put(self.allocator, key, result);
        owned = false;
        self.text_cost += cost;
        return result;
    }
    fn storedPiece(self: *Cache, key: Key) !?*Piece {
        try self.piece_mutex.lock(self.io);
        defer self.piece_mutex.unlock(self.io);
        if (self.piece_young.get(key)) |found| return found.retain();
        if (self.piece_old.fetchRemove(key)) |found| {
            errdefer found.value.release();
            const cost = found.value.bytes.len + overhead;
            self.rotatePieces(cost);
            try self.piece_young.put(self.allocator, found.key, found.value);
            self.piece_cost += cost;
            return found.value.retain();
        }
        return null;
    }
    fn piece(self: *Cache, part: Part, before: Sha, dictionary: []const u8) !*Piece {
        const glue_meta = try self.metadata(part.glue);
        const key: Key = .{ .sha = part.meta.sha, .before = before, .glue = glue_meta.sha };
        if (try self.storedPiece(key)) |found| return found;
        const compressed = try compress(self.allocator, dictionary, part.glue, part.body);
        errdefer self.allocator.free(compressed);
        const result = try self.allocator.create(Piece);
        const body_shift: u32 = @intCast(c.crc32_combine_gen64(@intCast(part.body.len)));
        result.* = .{
            .allocator = self.allocator,
            .bytes = compressed,
            .crc = @intCast(c.crc32_combine_op(glue_meta.crc, part.meta.crc, body_shift)),
            .shift = @intCast(c.crc32_combine_gen64(@intCast(part.body.len + part.glue.len))),
        };
        if (compressed.len > piece_budget / 64) return result;
        var kept = false;
        errdefer if (!kept) self.allocator.destroy(result);
        try self.piece_mutex.lock(self.io);
        defer self.piece_mutex.unlock(self.io);
        if (self.piece_young.get(key) orelse self.piece_old.get(key)) |existing| {
            // A racing cold render uses the first piece stored, as Rust's shared cache does.
            const found = existing.retain();
            self.allocator.free(compressed);
            self.allocator.destroy(result);
            return found;
        }
        const cost = compressed.len + overhead;
        self.rotatePieces(cost);
        try self.piece_young.put(self.allocator, key, result);
        self.piece_cost += cost;
        kept = true;
        return result.retain();
    }
};

pub const Part = struct {
    body: []const u8,
    glue: []const u8 = "",
    meta: Metadata,
    fragment: bool,
};
pub const Page = struct {
    parts: []const Part,
    len: usize,

    pub fn etag(self: Page, allocator: Allocator) ![]const u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.parts) |part| {
            hash.update(if (part.fragment) "F" else "T");
            if (part.fragment) {
                var glue_len: [8]u8 = undefined;
                std.mem.writeInt(u64, &glue_len, part.glue.len, .little);
                hash.update(&glue_len);
                hash.update(part.glue);
            }
            var body_len: [8]u8 = undefined;
            std.mem.writeInt(u64, &body_len, part.body.len, .little);
            hash.update(&body_len);
            hash.update(&part.meta.sha);
        }
        var digest: Sha = undefined;
        hash.final(&digest);
        return std.fmt.allocPrint(allocator, "W/\"{x}\"", .{digest[0..16]});
    }
    pub fn gzip(self: Page, cache: *Cache, allocator: Allocator, mtime: u32) ![]const u8 {
        var out = Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll(&.{ 0x1f, 0x8b, 8, 0 });
        var time: [4]u8 = undefined;
        std.mem.writeInt(u32, &time, mtime, .little);
        try out.writer.writeAll(&time);
        try out.writer.writeAll(&.{ 0, 3 });
        var before: Sha = @splat(0);
        var dictionary: []const u8 = "";
        var crc: u32 = 0;
        for (self.parts) |part| {
            const piece = try cache.piece(part, before, dictionary);
            defer piece.release();
            try out.writer.writeAll(piece.bytes);
            crc = @intCast(c.crc32_combine_op(crc, piece.crc, piece.shift));
            before = part.meta.sha;
            dictionary = part.body;
        }
        try out.writer.writeAll(&.{ 0x03, 0x00 });
        var footer: [8]u8 = undefined;
        std.mem.writeInt(u32, footer[0..4], crc, .little);
        std.mem.writeInt(u32, footer[4..8], @truncate(self.len), .little);
        try out.writer.writeAll(&footer);
        return out.toOwnedSlice();
    }
};

pub fn prepare(cache: *Cache, allocator: Allocator, rendered: views.Rendered) !Page {
    var parts: std.ArrayList(Part) = .empty;
    var gaps: std.ArrayList([]const u8) = .empty;
    for (rendered.parts) |part| {
        switch (part) {
            .text => |bytes| if (bytes.len != 0) {
                try gaps.append(allocator, bytes);
            },
            .fragment => |fragment| {
                const bytes = fragment.bytes();
                if (bytes.len < 1024) {
                    try gaps.append(allocator, bytes);
                    continue;
                }
                const gap = try takeGap(allocator, &gaps);
                const follows_fragment = parts.items.len != 0 and parts.items[parts.items.len - 1].fragment;
                var glue: []const u8 = "";
                if (follows_fragment and gap.len <= 256) {
                    glue = gap;
                } else if (gap.len != 0) {
                    try parts.append(allocator, .{ .body = gap, .meta = try cache.metadata(gap), .fragment = false });
                }
                try parts.append(allocator, .{ .body = bytes, .glue = glue, .meta = .{ .sha = fragment.sha256(), .crc = fragment.crc32() }, .fragment = true });
            },
        }
    }
    const rest = try takeGap(allocator, &gaps);
    if (rest.len != 0) try parts.append(allocator, .{ .body = rest, .meta = try cache.metadata(rest), .fragment = false });
    return .{ .parts = try parts.toOwnedSlice(allocator), .len = rendered.len };
}
fn takeGap(allocator: Allocator, gaps: *std.ArrayList([]const u8)) ![]const u8 {
    const result = switch (gaps.items.len) {
        0 => "",
        1 => gaps.items[0],
        else => try std.mem.concat(allocator, u8, gaps.items),
    };
    gaps.clearRetainingCapacity();
    return result;
}

fn compress(allocator: Allocator, dictionary: []const u8, glue: []const u8, body: []const u8) ![]u8 {
    return compressChunked(allocator, dictionary, glue, body, std.math.maxInt(c.uInt));
}

fn compressChunked(allocator: Allocator, dictionary: []const u8, glue: []const u8, body: []const u8, chunk_limit: c.uInt) ![]u8 {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.deflateInit2_(&stream, c.Z_DEFAULT_COMPRESSION, c.Z_DEFLATED, -15, 8, c.Z_DEFAULT_STRATEGY, c.ZLIB_VERSION, @sizeOf(c.z_stream)) != c.Z_OK) return error.CompressionFailure;
    defer _ = c.deflateEnd(&stream);
    if (dictionary.len != 0) {
        const tail = dictionary[dictionary.len - @min(dictionary.len, window) ..];
        if (c.deflateSetDictionary(&stream, tail.ptr, @intCast(tail.len)) != c.Z_OK) return error.CompressionFailure;
    }
    const bound: usize = @intCast(c.deflateBound(&stream, @intCast(body.len + glue.len)) + 64);
    const buffer = try allocator.alloc(u8, bound);
    errdefer allocator.free(buffer);
    var written: usize = 0;
    if (glue.len != 0) try deflateInput(&stream, buffer, &written, glue, c.Z_NO_FLUSH, chunk_limit);
    try deflateInput(&stream, buffer, &written, body, c.Z_SYNC_FLUSH, chunk_limit);
    return allocator.realloc(buffer, written);
}

fn deflateInput(stream: *c.z_stream, buffer: []u8, written: *usize, input: []const u8, flush: c_int, chunk_limit: c.uInt) !void {
    var consumed: usize = 0;
    while (true) {
        const input_len = @min(input.len - consumed, chunk_limit);
        const output_len = @min(buffer.len - written.*, chunk_limit);
        if (output_len == 0) return error.CompressionFailure;
        stream.next_in = @constCast(input[consumed..].ptr);
        stream.avail_in = @intCast(input_len);
        stream.next_out = buffer[written.*..].ptr;
        stream.avail_out = @intCast(output_len);
        const result = c.deflate(stream, if (consumed + input_len == input.len) flush else c.Z_NO_FLUSH);
        const read = input_len - stream.avail_in;
        const produced = output_len - stream.avail_out;
        consumed += read;
        written.* += produced;
        if (result != c.Z_OK and result != c.Z_BUF_ERROR) return error.CompressionFailure;
        if (consumed == input.len and (flush == c.Z_NO_FLUSH or stream.avail_out != 0)) return;
        if (read == 0 and produced == 0) return error.CompressionFailure;
    }
}

fn gunzip(allocator: Allocator, bytes: []const u8, expected_len: usize) ![]u8 {
    const out = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(out);
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.inflateInit2_(&stream, 31, c.ZLIB_VERSION, @sizeOf(c.z_stream)) != c.Z_OK) return error.CompressionFailure;
    defer _ = c.inflateEnd(&stream);
    stream.next_in = @constCast(bytes.ptr);
    stream.avail_in = @intCast(bytes.len);
    stream.next_out = out.ptr;
    stream.avail_out = @intCast(out.len);
    if (c.inflate(&stream, c.Z_FINISH) != c.Z_STREAM_END or stream.total_out != expected_len or stream.avail_in != 0) return error.CompressionFailure;
    return out;
}

test "gzip pieces retain correct dictionary and CRC after reordered predecessors and glue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cache = Cache.init(std.testing.allocator, std.testing.io);
    defer cache.deinit();
    var first_output = Io.Writer.Allocating.init(allocator);
    var second_output = Io.Writer.Allocating.init(allocator);
    for (0..1200) |_| try first_output.writer.writeAll("<button>boost</button> message alpha ");
    for (0..1300) |_| try second_output.writer.writeAll("<button>boost</button> message beta ");
    const first = try first_output.toOwnedSlice();
    const second = try second_output.toOwnedSlice();
    const a: Part = .{ .body = first, .meta = try cache.metadata(first), .fragment = true };
    const b: Part = .{ .body = second, .glue = "\n<article>", .meta = try cache.metadata(second), .fragment = true };
    for ([_][2]Part{ .{ a, b }, .{ b, a }, .{ a, b } }) |ordered| {
        const expected = try std.mem.concat(allocator, u8, &.{ ordered[0].glue, ordered[0].body, ordered[1].glue, ordered[1].body });
        const page: Page = .{ .parts = &ordered, .len = expected.len };
        const decoded = try gunzip(allocator, try page.gzip(&cache, allocator, 1), expected.len);
        try std.testing.expectEqualStrings(expected, decoded);
    }
}

test "part ETags change when bytes, order or glue changes and ignore gzip timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cache = Cache.init(std.testing.allocator, std.testing.io);
    defer cache.deinit();
    const a: Part = .{ .body = "alpha", .meta = try cache.metadata("alpha"), .fragment = true };
    const b: Part = .{ .body = "beta", .meta = try cache.metadata("beta"), .fragment = true };
    const ab: Page = .{ .parts = &.{ a, b }, .len = 9 };
    const ba: Page = .{ .parts = &.{ b, a }, .len = 9 };
    var changed = b;
    changed.glue = "!";
    const glued: Page = .{ .parts = &.{ a, changed }, .len = 10 };
    const tag = try ab.etag(allocator);
    try std.testing.expect(!std.mem.eql(u8, tag, try ba.etag(allocator)));
    try std.testing.expect(!std.mem.eql(u8, tag, try glued.etag(allocator)));
    try std.testing.expectEqualStrings(try gunzip(allocator, try ab.gzip(&cache, allocator, 1), 9), try gunzip(allocator, try ab.gzip(&cache, allocator, 2), 9));
}

test "gzip retains all bytes across bounded zlib input and output chunks" {
    const allocator = std.testing.allocator;
    var body: [513]u8 = undefined;
    for (&body, 0..) |*byte, i| byte.* = @truncate(i * 73 + i / 7);
    for ([_]usize{ 0, 63, 64, 65, 128, 129, body.len }) |len| {
        const expected = try std.mem.concat(allocator, u8, &.{ "[prefix]", body[0..len] });
        defer allocator.free(expected);
        const raw = try compressChunked(allocator, "", "[prefix]", body[0..len], 64);
        defer allocator.free(raw);
        var output = Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try output.writer.writeAll(&.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 });
        try output.writer.writeAll(raw);
        try output.writer.writeAll(&.{ 0x03, 0x00 });
        var footer: [8]u8 = undefined;
        std.mem.writeInt(u32, footer[0..4], @intCast(c.crc32_z(0, expected.ptr, expected.len)), .little);
        std.mem.writeInt(u32, footer[4..8], @intCast(expected.len), .little);
        try output.writer.writeAll(&footer);
        const decoded = try gunzip(allocator, output.written(), expected.len);
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings(expected, decoded);
    }
}
