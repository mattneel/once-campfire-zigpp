//! Only dynamic layout bytes enter the allocating writer; fragments are retained at offsets.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const FragmentLease = @import("fragment_cache.zig").FragmentLease;
pub const Part = union(enum) {
    text: []const u8,
    fragment: FragmentLease,
    pub fn bytes(self: Part) []const u8 {
        return switch (self) {
            .text => |text| text,
            .fragment => |lease| lease.bytes(),
        };
    }
};
pub const Rendered = struct {
    parts: []const Part,
    len: usize,
    pub fn materialize(self: Rendered, allocator: Allocator) ![]const u8 {
        const result = try allocator.alloc(u8, self.len);
        var offset: usize = 0;
        for (self.parts) |part| {
            const bytes = part.bytes();
            @memcpy(result[offset..][0..bytes.len], bytes);
            offset += bytes.len;
        }
        std.debug.assert(offset == result.len);
        return result;
    }
    /// Text and part storage belong to the request allocator; only leases are released here.
    pub fn deinit(self: Rendered) void {
        for (self.parts) |part| switch (part) {
            .fragment => |lease| lease.release(),
            .text => {},
        };
    }
};

pub const Recorder = struct {
    allocator: Allocator,
    out: std.Io.Writer.Allocating,
    fragments: std.ArrayListUnmanaged(Recorded) = .empty,
    const Recorded = struct { offset: usize, lease: FragmentLease };
    pub fn init(allocator: Allocator) Recorder {
        return .{ .allocator = allocator, .out = .init(allocator) };
    }
    pub fn deinit(self: *Recorder) void {
        for (self.fragments.items) |record| record.lease.release();
        self.fragments.deinit(self.allocator);
        self.out.deinit();
    }
    /// Consumes the lease on success and on error, so a caller cannot leak a hit.
    pub fn fragment(self: *Recorder, lease: FragmentLease) !void {
        errdefer lease.release();
        try self.fragments.append(self.allocator, .{ .offset = self.out.writer.end, .lease = lease });
    }
    pub fn finish(self: *Recorder) !Rendered {
        const parts = try self.allocator.alloc(Part, self.fragments.items.len * 2 + 1);
        errdefer self.allocator.free(parts);
        const text = try self.out.toOwnedSlice();
        var offset: usize = 0;
        var count: usize = 0;
        var len = text.len;
        for (self.fragments.items) |record| {
            if (record.offset != offset) {
                parts[count] = .{ .text = text[offset..record.offset] };
                count += 1;
            }
            parts[count] = .{ .fragment = record.lease };
            count += 1;
            offset = record.offset;
            len += record.lease.bytes().len;
        }
        if (offset != text.len or count == 0) {
            parts[count] = .{ .text = text[offset..] };
            count += 1;
        }
        self.fragments.clearRetainingCapacity();
        return .{ .parts = parts[0..count], .len = len };
    }
};

test "recorded fragments never enter layout text and reconstruct in source order" {
    const FragmentCache = @import("fragment_cache.zig").FragmentCache;
    var cache = try FragmentCache.init(std.testing.allocator, std.testing.io, 32 * 1024 * 1024);
    defer cache.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.out.writer.writeAll("<frame>");
    try recorder.fragment(try cache.put(@splat(1), "<message>one</message>"));
    try recorder.fragment(try cache.put(@splat(2), "<message>two</message>"));
    try recorder.out.writer.writeAll("</frame>");
    try std.testing.expectEqualStrings("<frame></frame>", recorder.out.writer.buffered());
    const rendered = try recorder.finish();
    defer rendered.deinit();
    try std.testing.expectEqual(@as(usize, 4), rendered.parts.len);
    try std.testing.expectEqualStrings("<frame><message>one</message><message>two</message></frame>", try rendered.materialize(arena.allocator()));
}

test "uncached recording and empty bodies retain all dynamic bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = Recorder.init(arena.allocator());
    defer recorder.deinit();
    const empty = try recorder.finish();
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqualStrings("", try empty.materialize(arena.allocator()));
    try recorder.out.writer.writeAll("dynamic");
    const rendered = try recorder.finish();
    defer rendered.deinit();
    try std.testing.expectEqual(@as(usize, 1), rendered.parts.len);
    try std.testing.expectEqualStrings("dynamic", try rendered.materialize(arena.allocator()));
}

test "recording allocation errors consume the lease" {
    const FragmentCache = @import("fragment_cache.zig").FragmentCache;
    var cache = try FragmentCache.init(std.testing.allocator, std.testing.io, 4096);
    defer cache.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var recorder = Recorder.init(failing.allocator());
    defer recorder.deinit();
    try std.testing.expectError(error.OutOfMemory, recorder.fragment(try cache.put(@splat(1), "fragment")));
}
