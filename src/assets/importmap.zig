const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const propshaft = @import("propshaft.zig");

const Pin = struct { name: []const u8, path: []const u8, preload: bool };
const Entry = struct { command: enum { pin, directory }, first: []const u8, to: ?[]const u8 = null, under: ?[]const u8 = null, preload: bool = true };

/// Mirrors crates/assets/build/importmap.rs and build.rs#importmap_tags. Missing
/// pins are skipped, package insertion order is retained, then directories expand.
pub fn tags(allocator: Allocator, scratch: Allocator, io: Io, reference: Io.Dir, paths: *const std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
    const config = try reference.readFileAlloc(io, "config/importmap.rb", scratch, .unlimited);
    var pins: std.ArrayList(Pin) = .empty;
    var directories: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |line| {
        const entry = (try parseLine(line)) orelse continue;
        if (entry.command == .pin) {
            try insert(scratch, &pins, .{ .name = entry.first, .path = entry.to orelse try std.fmt.allocPrint(scratch, "{s}.js", .{entry.first}), .preload = entry.preload });
        } else {
            var i: usize = 0;
            while (i < directories.items.len) {
                if (std.mem.eql(u8, directories.items[i].first, entry.first)) {
                    _ = directories.orderedRemove(i);
                } else i += 1;
            }
            try directories.append(scratch, entry);
        }
    }
    for (directories.items) |entry| {
        const dir = reference.openDir(io, entry.first, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var walker = try dir.walk(scratch);
        defer {
            while (walker.inner.stack.items.len > 1) walker.leave(io);
            walker.deinit();
        }
        var files: std.ArrayList([]const u8) = .empty;
        while (try walker.next(io)) |file| {
            if (std.mem.startsWith(u8, file.basename, ".")) {
                if (file.kind == .directory) walker.leave(io);
                continue;
            }
            if (file.kind == .directory) continue;
            if (std.mem.endsWith(u8, file.path, ".js") or std.mem.endsWith(u8, file.path, ".jsm")) try files.append(scratch, try scratch.dupe(u8, file.path));
        }
        std.mem.sort([]const u8, files.items, {}, lessThan);
        for (files.items) |filename| {
            const name = try moduleName(scratch, filename, entry.under);
            const prefix = entry.to orelse entry.under orelse "";
            const path = if (prefix.len == 0) filename else try std.fmt.allocPrint(scratch, "{s}/{s}", .{ prefix, filename });
            try insert(scratch, &pins, .{ .name = name, .path = path, .preload = entry.preload });
        }
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(scratch, "<script type=\"importmap\" data-turbo-track=\"reload\">{\n  \"imports\": {");
    var emitted: usize = 0;
    for (pins.items) |pin| {
        const path = paths.get(pin.path) orelse continue;
        try out.appendSlice(scratch, if (emitted == 0) "\n    " else ",\n    ");
        try jsonString(scratch, &out, pin.name);
        try out.appendSlice(scratch, ": ");
        try jsonString(scratch, &out, path);
        emitted += 1;
    }
    try out.appendSlice(scratch, if (emitted == 0) "}\n}</script>\n" else "\n  }\n}</script>\n");
    var preloaded: std.StringHashMapUnmanaged(void) = .empty;
    var preload_count: usize = 0;
    for (pins.items) |pin| {
        if (!pin.preload) continue;
        const path = paths.get(pin.path) orelse continue;
        const result = try preloaded.getOrPut(scratch, path);
        if (result.found_existing) continue;
        if (preload_count != 0) try out.append(scratch, '\n');
        try out.appendSlice(scratch, "<link rel=\"modulepreload\" href=\"");
        try htmlEscape(scratch, &out, path);
        try out.appendSlice(scratch, "\">");
        preload_count += 1;
    }
    try out.appendSlice(scratch, "\n<script type=\"module\">import \"application\"</script>");
    return allocator.dupe(u8, out.items);
}

fn insert(allocator: Allocator, pins: *std.ArrayList(Pin), pin: Pin) !void {
    for (pins.items) |*existing| {
        if (std.mem.eql(u8, existing.name, pin.name)) {
            existing.* = pin;
            return;
        }
    }
    try pins.append(allocator, pin);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn moduleName(allocator: Allocator, filename: []const u8, under: ?[]const u8) ![]const u8 {
    const ext = propshaft.extname(filename);
    var stem = filename[0 .. filename.len - ext.len];
    if (std.mem.eql(u8, stem, "index")) stem = "" else if (std.mem.endsWith(u8, stem, "/index")) stem = stem[0 .. stem.len - 6];
    if (under) |prefix| {
        // A present empty under: is retained by Ruby's compact.join.
        return if (stem.len == 0) allocator.dupe(u8, prefix) else std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, stem });
    }
    return allocator.dupe(u8, stem);
}

const Args = struct {
    rest: []const u8,

    fn string(self: *Args) ![]const u8 {
        if (self.rest.len == 0 or (self.rest[0] != '\'' and self.rest[0] != '"')) return error.InvalidImportmap;
        const end = 1 + (std.mem.indexOfScalar(u8, self.rest[1..], self.rest[0]) orelse return error.InvalidImportmap);
        const value = self.rest[1..end];
        self.rest = trim(self.rest[end + 1 ..]);
        return value;
    }
};

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c");
}

fn parseLine(line: []const u8) !?Entry {
    const text = trim(line);
    if (text.len == 0 or text[0] == '#') return null;
    const space = std.mem.indexOfAny(u8, text, " \t\r\n\x0b\x0c") orelse return error.InvalidImportmap;
    var args: Args = .{ .rest = trim(text[space..]) };
    var entry: Entry = .{ .command = if (std.mem.eql(u8, text[0..space], "pin")) .pin else if (std.mem.eql(u8, text[0..space], "pin_all_from")) .directory else return error.InvalidImportmap, .first = try args.string() };
    while (args.rest.len != 0 and args.rest[0] != '#') {
        if (args.rest[0] != ',') return error.InvalidImportmap;
        args.rest = trim(args.rest[1..]);
        const colon = std.mem.indexOfScalar(u8, args.rest, ':') orelse return error.InvalidImportmap;
        const key = trim(args.rest[0..colon]);
        args.rest = trim(args.rest[colon + 1 ..]);
        if (std.mem.eql(u8, key, "to")) {
            entry.to = try args.string();
        } else if (std.mem.eql(u8, key, "under")) {
            entry.under = try args.string();
        } else if (std.mem.eql(u8, key, "preload")) {
            if (std.mem.startsWith(u8, args.rest, "true")) {
                entry.preload = true;
                args.rest = trim(args.rest[4..]);
            } else if (std.mem.startsWith(u8, args.rest, "false")) {
                entry.preload = false;
                args.rest = trim(args.rest[5..]);
            } else return error.InvalidImportmap;
        } else return error.InvalidImportmap;
    }
    return entry;
}

pub fn jsonString(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    const hex = "0123456789abcdef";
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            8 => try out.appendSlice(allocator, "\\b"),
            12 => try out.appendSlice(allocator, "\\f"),
            0...7, 11, 14...31 => try out.appendSlice(allocator, &.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] }),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

fn htmlEscape(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&#39;"),
        else => try out.append(allocator, c),
    };
}

test "importmap configuration and index module names" {
    const entry = (try parseLine("pin_all_from 'app/javascript/lib', under: 'lib', preload: false # comment")).?;
    try std.testing.expect(entry.command == .directory);
    try std.testing.expect(!entry.preload);
    try std.testing.expectEqualStrings("lib", entry.under.?);
    const a = std.testing.allocator;
    const nested = try moduleName(a, "rich_text/index.js", "lib");
    defer a.free(nested);
    try std.testing.expectEqualStrings("lib/rich_text", nested);
    const root = try moduleName(a, "index.js", "initializers");
    defer a.free(root);
    try std.testing.expectEqualStrings("initializers", root);
    try std.testing.expectError(error.InvalidImportmap, parseLine("unknown 'module'"));
}

test "duplicate pins retain their original insertion position" {
    const a = std.testing.allocator;
    var pins: std.ArrayList(Pin) = .empty;
    defer pins.deinit(a);
    try insert(a, &pins, .{ .name = "a", .path = "old.js", .preload = true });
    try insert(a, &pins, .{ .name = "b", .path = "b.js", .preload = true });
    try insert(a, &pins, .{ .name = "a", .path = "new.js", .preload = false });
    try std.testing.expectEqual(@as(usize, 2), pins.items.len);
    try std.testing.expectEqualStrings("a", pins.items[0].name);
    try std.testing.expectEqualStrings("new.js", pins.items[0].path);
    try std.testing.expect(!pins.items[0].preload);
}
