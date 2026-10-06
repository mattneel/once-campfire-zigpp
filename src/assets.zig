const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const propshaft = @import("assets/propshaft.zig");
const importmap = @import("assets/importmap.zig");

pub const Asset = struct {
    /// Body is owned by Assets; content_type is a static MIME string.
    body: []const u8,
    content_type: []const u8,
};

/// Loads the actual frontend at boot. All returned paths, bodies and markup are
/// immutable and owned by this object until deinit; no per-request filesystem IO.
pub const Assets = struct {
    arena: std.heap.ArenaAllocator,
    paths: std.StringHashMapUnmanaged([]const u8),
    files: std.StringHashMapUnmanaged(Asset),
    stylesheet_names: []const []const u8,
    importmap_tags: []const u8,

    pub fn init(allocator: Allocator, io: Io, repo_root: []const u8) !Assets {
        const root = try Io.Dir.cwd().openDir(io, repo_root, .{});
        defer root.close(io);
        return initDir(allocator, io, root);
    }

    fn initDir(allocator: Allocator, io: Io, root: Io.Dir) !Assets {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const permanent = arena.allocator();
        var temporary = std.heap.ArenaAllocator.init(allocator);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        const reference = try root.openDir(io, "reference", .{});
        defer reference.close(io);
        const version = try assetsVersion(scratch, io, reference);
        const load_paths = try loadPaths(scratch, io, root);
        var sources: std.ArrayList(propshaft.Source) = .empty;
        var by_logical: std.StringHashMapUnmanaged(usize) = .empty;
        for (load_paths) |path| {
            const files = try scanTree(scratch, io, root, path, .pipeline);
            for (files) |logical| {
                if (by_logical.contains(logical)) continue;
                const source_path = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ path, logical });
                const body = try root.readFileAlloc(io, source_path, scratch, .unlimited);
                try by_logical.put(scratch, logical, sources.items.len);
                try sources.append(scratch, .{ .logical = logical, .body = body });
            }
        }
        const pipeline: propshaft.Pipeline = .{ .allocator = scratch, .sources = sources.items, .by_logical = by_logical, .version = version };
        const digested = try scratch.alloc([]const u8, sources.items.len);
        for (sources.items, 0..) |_, i| digested[i] = try pipeline.digestedPath(scratch, i);
        var paths: std.StringHashMapUnmanaged([]const u8) = .empty;
        var files: std.StringHashMapUnmanaged(Asset) = .empty;
        var stylesheets_list: std.ArrayList([]const u8) = .empty;
        var manifest: std.ArrayList(u8) = .empty;
        try manifest.append(scratch, '{');
        for (sources.items, 0..) |source, i| {
            const logical = try permanent.dupe(u8, source.logical);
            const url = try std.fmt.allocPrint(permanent, "/assets/{s}", .{digested[i]});
            const body = try pipeline.compile(permanent, i, digested);
            try paths.put(permanent, logical, url);
            // Rust's stable sort/dedup keeps the first file for a colliding URL.
            if (!files.contains(url)) try files.put(permanent, url, .{ .body = body, .content_type = mimeType(digested[i]) });
            if (std.mem.eql(u8, propshaft.extname(logical), ".css")) try stylesheets_list.append(permanent, logical);
            if (i != 0) try manifest.append(scratch, ',');
            try importmap.jsonString(scratch, &manifest, logical);
            try manifest.appendSlice(scratch, ":{\"digested_path\":");
            try importmap.jsonString(scratch, &manifest, digested[i]);
            try manifest.appendSlice(scratch, ",\"integrity\":null}");
        }
        try manifest.append(scratch, '}');
        try files.put(permanent, "/assets/.manifest.json", .{ .body = try permanent.dupe(u8, manifest.items), .content_type = "application/json" });
        std.mem.sort([]const u8, stylesheets_list.items, {}, lessThan);
        const tags = try importmap.tags(permanent, scratch, io, reference, &paths);
        const public_files = try scanTree(scratch, io, root, "reference/public", .public);
        for (public_files) |file| {
            const source = try std.fmt.allocPrint(scratch, "reference/public/{s}", .{file});
            const body = try root.readFileAlloc(io, source, permanent, .unlimited);
            const url = try std.fmt.allocPrint(permanent, "/{s}", .{file});
            try files.put(permanent, url, .{ .body = body, .content_type = mimeType(file) });
        }
        return .{ .arena = arena, .paths = paths, .files = files, .stylesheet_names = stylesheets_list.items, .importmap_tags = tags };
    }

    pub fn deinit(self: *Assets) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn assetPath(self: *const Assets, logical: []const u8) ?[]const u8 {
        return self.paths.get(logical);
    }

    /// Sorted logical names, matching Propshaft::Helper#all_stylesheets_paths.
    /// Resolve each name with assetPath before rendering a stylesheet link.
    pub fn stylesheets(self: *const Assets) []const []const u8 {
        return self.stylesheet_names;
    }

    pub fn importmapTags(self: *const Assets) []const u8 {
        return self.importmap_tags;
    }

    /// Exact decoded URL path, without a query. HTTP headers/ranges belong to the
    /// transport; MIME and immutable bytes come from the actual loaded resource.
    pub fn lookup(self: *const Assets, url_path: []const u8) ?Asset {
        return self.files.get(url_path);
    }
};

const Scan = enum { pipeline, public };

fn scanTree(allocator: Allocator, io: Io, root: Io.Dir, path: []const u8, mode: Scan) ![]const []const u8 {
    const directory = root.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer {
        // std0.17 Walker.deinit frees the stack, not still-open nested handles.
        while (walker.inner.stack.items.len > 1) walker.leave(io);
        walker.deinit();
    }
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (mode == .public and std.mem.eql(u8, entry.path, "assets")) {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        if (entry.kind == .directory) continue;
        // Propshaft ignores dotfiles, but includes files inside dot-directories.
        if (mode == .pipeline and std.mem.startsWith(u8, entry.basename, ".")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    return files.items;
}

fn loadPaths(allocator: Allocator, io: Io, root: Io.Dir) ![]const []const u8 {
    const config = try root.readFileAlloc(io, "crates/assets/vendor/LOAD_PATH", allocator, .unlimited);
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(allocator, "crates/assets/overrides");
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidLoadPath;
        const origin = line[0..colon];
        const directory = line[colon + 1 ..];
        const prefix = if (std.mem.eql(u8, origin, "reference")) "reference" else if (std.mem.eql(u8, origin, "vendor")) "crates/assets/vendor" else return error.InvalidLoadPath;
        try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, directory }));
    }
    return dedupPaths(allocator, paths.items);
}

/// Propshaft sorts with '/' below every other byte, excludes string-prefixed
/// descendants, then retains surviving paths in the original precedence order.
fn dedupPaths(allocator: Allocator, paths: []const []const u8) ![]const []const u8 {
    const sorted = try allocator.dupe([]const u8, paths);
    std.mem.sort([]const u8, sorted, {}, pathLessThan);
    var survivors: std.StringHashMapUnmanaged(void) = .empty;
    defer survivors.deinit(allocator);
    var previous: ?[]const u8 = null;
    for (sorted) |path| {
        if (previous) |last| if (std.mem.startsWith(u8, path, last)) continue;
        try survivors.put(allocator, path, {});
        previous = path;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (paths) |path| if (survivors.fetchRemove(path) != null) try out.append(allocator, path);
    allocator.free(sorted);
    return out.toOwnedSlice(allocator);
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |ac, bc| {
        const aa: u8 = if (ac == '/') 0 else ac;
        const bb: u8 = if (bc == '/') 0 else bc;
        if (aa != bb) return aa < bb;
    }
    return a.len < b.len;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn assetsVersion(allocator: Allocator, io: Io, reference: Io.Dir) ![]const u8 {
    const config = reference.readFileAlloc(io, "config/initializers/assets.rb", allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return "1",
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trimStart(u8, line, " \t\r");
        if (std.mem.startsWith(u8, text, "#")) continue;
        const pos = std.mem.indexOf(u8, line, "config.assets.version") orelse continue;
        const rest = std.mem.trimStart(u8, line[pos + "config.assets.version".len ..], " \t\r");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        const value = std.mem.trim(u8, rest[1..], " \t\r");
        return std.mem.trim(u8, value, "\"'");
    }
    return "1";
}

fn mimeType(path: []const u8) []const u8 {
    const ext = propshaft.extname(path);
    const entries = .{
        .{ ".avif", "image/avif" }, .{ ".css", "text/css" }, .{ ".csv", "text/csv" },
        .{ ".gif", "image/gif" }, .{ ".gz", "application/x-gzip" }, .{ ".htm", "text/html" },
        .{ ".html", "text/html" }, .{ ".ico", "image/vnd.microsoft.icon" }, .{ ".jpeg", "image/jpeg" },
        .{ ".jpg", "image/jpeg" }, .{ ".js", "text/javascript" }, .{ ".mjs", "text/javascript" },
        .{ ".json", "application/json" }, .{ ".m4a", "audio/mp4a-latm" }, .{ ".mp3", "audio/mpeg" },
        .{ ".mp4", "video/mp4" }, .{ ".ogg", "application/ogg" }, .{ ".otf", "font/otf" },
        .{ ".pdf", "application/pdf" }, .{ ".png", "image/png" }, .{ ".svg", "image/svg+xml" },
        .{ ".ttf", "font/ttf" }, .{ ".txt", "text/plain" }, .{ ".wav", "audio/x-wav" },
        .{ ".webm", "video/webm" }, .{ ".webp", "image/webp" }, .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" }, .{ ".xml", "application/xml" }, .{ ".zip", "application/zip" },
    };
    inline for (entries) |entry| if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    return "text/plain";
}

test "load path string-prefix dedup retains precedence" {
    const a = std.testing.allocator;
    const paths = [_][]const u8{ "b", "a/sub", "a", "b", "ab", "c" };
    const deduped = try dedupPaths(a, &paths);
    defer a.free(deduped);
    try std.testing.expectEqual(@as(usize, 3), deduped.len);
    try std.testing.expectEqualStrings("b", deduped[0]);
    try std.testing.expectEqualStrings("a", deduped[1]);
    try std.testing.expectEqualStrings("c", deduped[2]);
}

test "native boot loads overrides, dependency digests, importmap and original public files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directories = [_][]const u8{
        "reference/config/initializers", "reference/app/javascript/lib/.hidden", "reference/app/assets/stylesheets",
        "reference/app/assets/images/.nested", "reference/public/assets", "crates/assets/overrides/lib", "crates/assets/vendor",
    };
    for (directories) |directory| try tmp.dir.createDirPath(io, directory);
    const fixtures = [_][2][]const u8{
        .{ "crates/assets/vendor/LOAD_PATH", "reference:app/javascript\nreference:app/assets/stylesheets\nreference:app/assets/images\n" },
        .{ "reference/config/initializers/assets.rb", "# config.assets.version = 'ignored'\nRails.application.config.assets.version = '1.0'\n" },
        .{ "reference/config/importmap.rb", "pin 'application'\npin 'duplicate', to: 'application.js'\npin 'missing'\npin_all_from 'app/javascript/lib', under: 'lib'\n" },
        .{ "reference/app/javascript/application.js", "import 'lib'" },
        .{ "reference/app/javascript/lib/index.js", "original" },
        .{ "reference/app/javascript/lib/.hidden/invisible.js", "hidden module" },
        .{ "crates/assets/overrides/lib/index.js", "real override" },
        .{ "reference/app/assets/stylesheets/z.css", "body { background: url(icon.svg?v=1) }" },
        .{ "reference/app/assets/stylesheets/a.css", "h1 { color: red }" },
        .{ "reference/app/assets/images/icon.svg", "<svg/>" },
        .{ "reference/app/assets/images/.ignored", "dotfile" },
        .{ "reference/app/assets/images/.nested/icon.svg", "nested" },
        .{ "reference/public/robots.txt", "User-agent: *\n" },
        .{ "reference/public/assets/stale.js", "must not serve" },
    };
    for (fixtures) |fixture| try tmp.dir.writeFile(io, .{ .sub_path = fixture[0], .data = fixture[1] });
    var assets = try Assets.initDir(std.testing.allocator, io, tmp.dir);
    defer assets.deinit();
    const lib_path = assets.assetPath("lib/index.js").?;
    try std.testing.expectEqualStrings("real override", assets.lookup(lib_path).?.body);
    try std.testing.expectEqualStrings("text/javascript", assets.lookup(lib_path).?.content_type);
    try std.testing.expect(assets.assetPath(".ignored") == null);
    try std.testing.expect(assets.assetPath(".nested/icon.svg") != null);
    try std.testing.expect(assets.assetPath("lib/.hidden/invisible.js") != null);
    const names = assets.stylesheets();
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("a.css", names[0]);
    try std.testing.expectEqualStrings("z.css", names[1]);
    const expected_css = try std.fmt.allocPrint(std.testing.allocator, "body {{ background: url(\"{s}?v=1\") }}", .{assets.assetPath("icon.svg").?});
    defer std.testing.allocator.free(expected_css);
    try std.testing.expectEqualStrings(expected_css, assets.lookup(assets.assetPath("z.css").?).?.body);
    const tags = assets.importmapTags();
    try std.testing.expect(std.mem.indexOf(u8, tags, "\"lib\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, tags, "\"missing\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, tags, "hidden") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, tags, "<link rel=\"modulepreload\""));
    try std.testing.expectEqualStrings("User-agent: *\n", assets.lookup("/robots.txt").?.body);
    try std.testing.expect(assets.lookup("/assets/stale.js") == null);
    try std.testing.expect(assets.lookup("/assets/.manifest.json") != null);
}

test {
    _ = propshaft;
    _ = importmap;
}

test "actual frontend manifest, compiled bytes and importmap match Rails golden fixtures" {
    // Run from the repository root with its reference submodule checked out.
    const io = std.testing.io;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var assets = try Assets.init(a, io, ".");
    defer assets.deinit();
    const root = Io.Dir.cwd();
    const manifest_bytes = try root.readFileAlloc(io, "crates/assets/tests/reference/manifest.json", scratch, .unlimited);
    const compiled_bytes = try root.readFileAlloc(io, "crates/assets/tests/reference/compiled_sha256.json", scratch, .unlimited);
    const reference_tags = try root.readFileAlloc(io, "crates/assets/tests/reference/javascript_importmap_tags.html", scratch, .unlimited);
    const manifest = try std.json.parseFromSlice(std.json.Value, scratch, manifest_bytes, .{});
    defer manifest.deinit();
    const compiled = try std.json.parseFromSlice(std.json.Value, scratch, compiled_bytes, .{});
    defer compiled.deinit();
    const overrides = try scanTree(scratch, io, root, "crates/assets/overrides", .pipeline);
    var overridden: std.StringHashMapUnmanaged(void) = .empty;
    for (overrides) |logical| try overridden.put(scratch, logical, {});
    var normalized_tags = assets.importmapTags();
    var entries = manifest.value.object.iterator();
    while (entries.next()) |entry| {
        const logical = entry.key_ptr.*;
        const expected = entry.value_ptr.object.get("digested_path").?.string;
        const path = assets.assetPath(logical) orelse return error.TestMissingAsset;
        const expected_url = try std.fmt.allocPrint(scratch, "/assets/{s}", .{expected});
        if (overridden.contains(logical)) {
            try std.testing.expect(!std.mem.eql(u8, path, expected_url));
            normalized_tags = try std.mem.replaceOwned(u8, scratch, normalized_tags, path, expected_url);
            continue;
        }
        try std.testing.expectEqualStrings(expected_url, path);
        const asset = assets.lookup(path) orelse return error.TestMissingCompiledAsset;
        const expected_sha = compiled.value.object.get(expected).?.string;
        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(asset.body, &sha, .{});
        const actual_sha = std.fmt.bytesToHex(sha, .lower);
        try std.testing.expectEqualStrings(expected_sha, &actual_sha);
    }
    var added: usize = 0;
    for (overrides) |logical| if (!manifest.value.object.contains(logical)) {
        try std.testing.expect(assets.assetPath(logical) != null);
        added += 1;
    };
    try std.testing.expectEqual(manifest.value.object.count() + added, assets.paths.count());
    try std.testing.expectEqualStrings(reference_tags, normalized_tags);
}
