//! Rust fragment_cache.rs: versioned immutable fragments, byte accounting and LRU pruning.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const default_max_bytes = 32 * 1024 * 1024;
pub const Key = [32]u8;
const overhead = 240;

const Entry = struct {
    allocator: Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    key: Key,
    payload: []const u8,
    sha: [32]u8,
    crc: u32,
    older: ?*Entry = null,
    newer: ?*Entry = null,

    fn cost(self: *const Entry) usize {
        return self.payload.len + self.key.len + overhead;
    }
    fn retain(self: *Entry) FragmentLease {
        _ = self.refs.fetchAdd(1, .monotonic);
        return .{ .entry = self };
    }
};

/// A lease owns one reference. Transfer it into a Part or release it exactly once.
/// It remains valid after eviction and even after its cache is deinitialized.
pub const FragmentLease = struct {
    entry: *Entry,
    pub fn bytes(self: FragmentLease) []const u8 {
        return self.entry.payload;
    }
    pub fn sha256(self: FragmentLease) [32]u8 {
        return self.entry.sha;
    }
    pub fn crc32(self: FragmentLease) u32 {
        return self.entry.crc;
    }
    pub fn release(self: FragmentLease) void {
        const e = self.entry;
        if (e.refs.fetchSub(1, .acq_rel) == 1) {
            const a = e.allocator;
            a.free(e.payload);
            a.destroy(e);
        }
    }
};

pub const FragmentCache = struct {
    allocator: Allocator,
    io: Io,
    max_bytes: usize,
    mutex: Io.Mutex = .init,
    entries: std.AutoHashMapUnmanaged(Key, *Entry) = .empty,
    oldest: ?*Entry = null,
    newest: ?*Entry = null,
    total_bytes: usize = 0,

    pub fn init(allocator: Allocator, io: Io, max_bytes: usize) !FragmentCache {
        return .{ .allocator = allocator, .io = io, .max_bytes = max_bytes };
    }
    /// No new operations may start during deinit; outstanding leases need not be released yet.
    pub fn deinit(self: *FragmentCache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.oldest) |e| self.evict(e);
        self.entries.deinit(self.allocator);
    }
    pub fn get(self: *FragmentCache, key: Key) ?FragmentLease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const e = self.entries.get(key) orelse return null;
        self.touch(e);
        return e.retain();
    }
    /// Rendering happens unlocked. Racing cold misses return the first stored value.
    /// Oversized fragments are leased but not retained by the store (Rust's quarter-limit rule).
    pub fn put(self: *FragmentCache, key: Key, bytes: []const u8) !FragmentLease {
        const e = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(e);
        const payload = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(payload);
        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &sha, .{});
        e.* = .{ .allocator = self.allocator, .key = key, .payload = payload, .sha = sha, .crc = std.hash.Crc32.hash(payload) };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entries.get(key)) |stored| {
            self.touch(stored);
            (FragmentLease{ .entry = e }).release();
            return stored.retain();
        }
        if (e.cost() > self.max_bytes / 4) return .{ .entry = e };
        try self.entries.put(self.allocator, key, e);
        self.append(e);
        self.total_bytes += e.cost();
        const lease = e.retain();
        if (self.total_bytes > self.max_bytes) {
            const target = self.max_bytes / 4 * 3;
            while (self.total_bytes > target) self.evict(self.oldest orelse break);
        }
        return lease;
    }
    fn unlink(self: *FragmentCache, e: *Entry) void {
        if (e.older) |older| older.newer = e.newer else self.oldest = e.newer;
        if (e.newer) |newer| newer.older = e.older else self.newest = e.older;
    }
    fn append(self: *FragmentCache, e: *Entry) void {
        e.older = self.newest;
        e.newer = null;
        if (self.newest) |newest| newest.newer = e else self.oldest = e;
        self.newest = e;
    }
    fn touch(self: *FragmentCache, e: *Entry) void {
        if (self.newest == e) return;
        self.unlink(e);
        self.append(e);
    }
    fn evict(self: *FragmentCache, e: *Entry) void {
        self.unlink(e);
        _ = self.entries.remove(e.key);
        self.total_bytes -= e.cost();
        (FragmentLease{ .entry = e }).release();
    }
};

test "versioned fragments are immutable and duplicate cold misses return the first value" {
    var cache = try FragmentCache.init(std.testing.allocator, std.testing.io, default_max_bytes);
    defer cache.deinit();
    const key: Key = @splat(1);
    const first = try cache.put(key, "first");
    defer first.release();
    const duplicate = try cache.put(key, "second");
    defer duplicate.release();
    try std.testing.expectEqualStrings("first", duplicate.bytes());
    const changed = try cache.put(@splat(2), "second");
    defer changed.release();
    try std.testing.expectEqualStrings("second", changed.bytes());
}

test "LRU pruning bounds bytes while eviction and cache teardown preserve active leases" {
    var cache = try FragmentCache.init(std.testing.allocator, std.testing.io, 4096);
    const payload: [500]u8 = @splat('x');
    const held = try cache.put(@splat(0), &payload);
    defer held.release();
    for (1..6) |i| {
        const lease = try cache.put(@splat(@intCast(i)), &payload);
        lease.release();
        try std.testing.expect(cache.total_bytes <= cache.max_bytes);
    }
    try std.testing.expect(cache.get(@splat(0)) == null);
    try std.testing.expectEqualStrings(&payload, held.bytes());
    const hot = cache.get(@splat(5)).?;
    defer hot.release();
    cache.deinit();
    try std.testing.expectEqualStrings(&payload, held.bytes());
    try std.testing.expectEqualStrings(&payload, hot.bytes());
}

test "reads refresh recency and fragments over one quarter are returned without retention" {
    var cache = try FragmentCache.init(std.testing.allocator, std.testing.io, 4096);
    defer cache.deinit();
    const payload: [500]u8 = @splat('x');
    for (0..5) |i| {
        const lease = try cache.put(@splat(@intCast(i)), &payload);
        lease.release();
    }
    const used = cache.get(@splat(0)).?;
    defer used.release();
    const added = try cache.put(@splat(5), &payload);
    defer added.release();
    try std.testing.expect(cache.get(@splat(1)) == null);
    const kept = cache.get(@splat(0)).?;
    kept.release();
    const before = cache.total_bytes;
    const huge: [1024]u8 = @splat('h');
    const lease = try cache.put(@splat(99), &huge);
    defer lease.release();
    try std.testing.expectEqual(before, cache.total_bytes);
    try std.testing.expect(cache.get(@splat(99)) == null);
    try std.testing.expectEqualStrings(&huge, lease.bytes());
}

test "failed payload or map allocations do not leave retained entries" {
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var cache = try FragmentCache.init(failing.allocator(), std.testing.io, default_max_bytes);
        defer cache.deinit();
        try std.testing.expectError(error.OutOfMemory, cache.put(@splat(1), "payload"));
        try std.testing.expectEqual(@as(usize, 0), cache.total_bytes);
        try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
    }
}
