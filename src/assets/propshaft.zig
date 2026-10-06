const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Source = struct { logical: []const u8, body: []const u8 };
pub const Kind = enum { css, js, other };

/// Mirrors crates/assets/build/propshaft.rs (Propshaft 1.2.1). Inputs are bytes,
/// not Unicode text, as Propshaft reads assets as ASCII-8BIT.
pub const Pipeline = struct {
    allocator: Allocator,
    sources: []const Source,
    by_logical: std.StringHashMapUnmanaged(usize),
    version: []const u8,

    pub fn kind(self: *const Pipeline, index: usize) Kind {
        const ext = extname(self.sources[index].logical);
        if (std.mem.eql(u8, ext, ".css")) return .css;
        if (std.mem.eql(u8, ext, ".js")) return .js;
        return .other;
    }

    pub fn digestedPath(self: *const Pipeline, allocator: Allocator, index: usize) ![]const u8 {
        const logical = self.sources[index].logical;
        if (alreadyDigested(logical)) return allocator.dupe(u8, logical);
        const dot = digestExtension(logical) orelse return allocator.dupe(u8, logical);
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(self.sources[index].body);
        var references: std.ArrayList(usize) = .empty;
        defer references.deinit(self.allocator);
        try self.collect(index, self.kind(index), &references);
        for (references.items) |referenced| hasher.update(self.sources[referenced].body);
        hasher.update(self.version);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);
        const hex = "0123456789abcdef";
        var short: [8]u8 = undefined;
        for (digest[0..4], 0..) |byte, i| {
            short[i * 2] = hex[byte >> 4];
            short[i * 2 + 1] = hex[byte & 15];
        }
        return std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ logical[0..dot], short, logical[dot..] });
    }

    fn collect(self: *const Pipeline, index: usize, pattern: Kind, references: *std.ArrayList(usize)) Allocator.Error!void {
        if (pattern == .other) return;
        var cursor: usize = 0;
        const source = self.sources[index];
        while (nextUrl(source.body, pattern, &cursor)) |url| {
            const resolved = try resolvePath(self.allocator, dirname(source.logical), url.path);
            defer self.allocator.free(resolved);
            if (self.by_logical.get(resolved)) |found| {
                if (std.mem.indexOfScalar(usize, references.items, found) == null) {
                    try references.append(self.allocator, found);
                    // Referenced bytes are scanned using the originating compiler's pattern.
                    try self.collect(found, pattern, references);
                }
            }
        }
    }

    pub fn compile(self: *const Pipeline, allocator: Allocator, index: usize, digested: []const []const u8) ![]const u8 {
        const source = self.sources[index];
        const pattern = self.kind(index);
        if (pattern == .other) return allocator.dupe(u8, source.body);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        var cursor: usize = 0;
        var last: usize = 0;
        while (nextUrl(source.body, pattern, &cursor)) |url| {
            try out.appendSlice(self.allocator, source.body[last..url.start]);
            if (pattern == .css) try out.appendSlice(self.allocator, "url(");
            try out.append(self.allocator, '"');
            const resolved = try resolvePath(self.allocator, dirname(source.logical), url.path);
            defer self.allocator.free(resolved);
            if (self.by_logical.get(resolved)) |found| {
                try out.appendSlice(self.allocator, "/assets/");
                try out.appendSlice(self.allocator, digested[found]);
                try out.appendSlice(self.allocator, url.tail);
            } else {
                // Propshaft drops the query/fragment when an asset cannot be resolved.
                try out.appendSlice(self.allocator, url.path);
            }
            try out.append(self.allocator, '"');
            if (pattern == .css) try out.append(self.allocator, ')');
            last = url.end;
        }
        try out.appendSlice(self.allocator, source.body[last..]);
        return self.compileSourceMap(allocator, source.logical, out.items, digested);
    }

    fn compileSourceMap(self: *const Pipeline, allocator: Allocator, logical: []const u8, body: []const u8, digested: []const []const u8) ![]const u8 {
        // SourceMappingUrls matches only a comment at the end of the entire file.
        var search: usize = 0;
        while (search < body.len) {
            const pos = std.mem.indexOfPos(u8, body, search, "# sourceMappingURL=") orelse break;
            search = pos + 1;
            if (pos < 2) continue;
            const comment = body[pos - 2 .. pos];
            if (!std.mem.eql(u8, comment, "//") and !std.mem.eql(u8, comment, "/*")) continue;
            const start = pos + "# sourceMappingURL=".len;
            const line_end = start + (std.mem.indexOfScalar(u8, body[start..], '\n') orelse (body.len - start));
            var map_end = line_end;
            while (map_end > start and !std.mem.endsWith(u8, body[start..map_end], ".map")) : (map_end -= 1) {}
            if (map_end == start) continue;
            var suffix = map_end;
            while (suffix < body.len and whitespace(body[suffix])) : (suffix += 1) {}
            var comment_end: []const u8 = "";
            if (std.mem.startsWith(u8, body[suffix..], "*/")) {
                comment_end = body[map_end .. suffix + 2];
                suffix += 2;
            }
            while (suffix < body.len and whitespace(body[suffix])) : (suffix += 1) {}
            if (suffix != body.len) continue;
            var url = body[start..map_end];
            // /^(.+\/)?\/assets\// removes the last such prefix (including a host).
            if (std.mem.lastIndexOf(u8, url, "/assets/")) |prefix| url = url[prefix + "/assets/".len ..];
            const resolved = try plus(self.allocator, dirname(logical), url);
            defer self.allocator.free(resolved);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            try out.appendSlice(self.allocator, body[0..pos]);
            if (self.by_logical.get(resolved)) |found| {
                try out.appendSlice(self.allocator, "# sourceMappingURL=/assets/");
                try out.appendSlice(self.allocator, digested[found]);
            }
            try out.appendSlice(self.allocator, comment_end);
            // The trailing \s*? stops before the last LF: Ruby's \Z (ported as
            // (?=\n?\z) in Rust) also matches there. gsub retains that unmatched LF.
            if (std.mem.endsWith(u8, body, "\n")) try out.append(self.allocator, '\n');
            return allocator.dupe(u8, out.items);
        }
        return allocator.dupe(u8, body);
    }
};

const Url = struct { start: usize, end: usize, path: []const u8, tail: []const u8 };

fn whitespace(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

fn quote(c: u8) bool {
    return c == '\'' or c == '"';
}

fn nextUrl(body: []const u8, pattern: Kind, cursor: *usize) ?Url {
    const head = if (pattern == .css) "url(" else "RAILS_ASSET_URL(";
    while (cursor.* < body.len) {
        const start = std.mem.indexOfPos(u8, body, cursor.*, head) orelse {
            cursor.* = body.len;
            return null;
        };
        cursor.* = start + 1;
        var p = start + head.len;
        while (p < body.len and whitespace(body[p])) : (p += 1) {}
        if (p < body.len and quote(body[p])) p += 1;
        const path_start = p;
        const rest = body[p..];
        const excluded_css = [_][]const u8{ "#", "%23", "data:", "http:", "https:", "//" };
        const excluded_js = [_][]const u8{ "#", "%23", "data", "http", "//" };
        const excluded: []const []const u8 = if (pattern == .css) &excluded_css else &excluded_js;
        var skip = false;
        for (excluded) |prefix| if (std.mem.startsWith(u8, rest, prefix)) {
            skip = true;
            break;
        };
        if (skip) continue;
        while (p < body.len and !quote(body[p]) and !whitespace(body[p]) and body[p] != '?' and body[p] != '#' and body[p] != ')') : (p += 1) {}
        if (p == path_start) continue;
        const path_end = p;
        var tail: []const u8 = "";
        if (p < body.len and (body[p] == '?' or body[p] == '#')) {
            const tail_start = p;
            p += 1;
            while (p < body.len and !quote(body[p]) and body[p] != ')') : (p += 1) {}
            if (p == tail_start + 1) continue;
            tail = body[tail_start..p];
        }
        while (p < body.len and whitespace(body[p])) : (p += 1) {}
        if (p < body.len and quote(body[p])) p += 1;
        if (p == body.len or body[p] != ')') continue;
        cursor.* = p + 1;
        return .{ .start = start, .end = p + 1, .path = body[path_start..path_end], .tail = tail };
    }
    return null;
}

pub fn extname(path: []const u8) []const u8 {
    var base = path[(if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0)..];
    while (std.mem.startsWith(u8, base, ".")) base = base[1..];
    return if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[i..] else "";
}

fn dirname(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..i] else ".";
}

fn word(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn digestExtension(path: []const u8) ?usize {
    for (path, 0..) |c, i| {
        if (c != '.') continue;
        const suffix = path[i + 1 ..];
        if (word(suffix) or (std.mem.endsWith(u8, suffix, ".map") and word(suffix[0 .. suffix.len - 4]))) return i;
    }
    return null;
}

fn alreadyDigested(path: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, path, cursor, ".digested")) |end| {
        var start = end;
        while (start > 0 and (std.ascii.isAlphanumeric(path[start - 1]) or path[start - 1] == '_' or path[start - 1] == '-')) : (start -= 1) {}
        var dash = start;
        while (dash < end) : (dash += 1) {
            if (path[dash] == '-' and end - dash - 1 >= 7 and end - dash - 1 <= 128) return true;
        }
        cursor = end + 1;
    }
    return false;
}

pub fn resolvePath(allocator: Allocator, directory: []const u8, filename: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, filename, "/")) return allocator.dupe(u8, filename[1..]);
    const joined = try plus(allocator, directory, if (std.mem.startsWith(u8, filename, "./")) filename[2..] else filename);
    if (!std.mem.startsWith(u8, filename, "../")) return joined;
    defer allocator.free(joined);
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);
    var iter = std.mem.splitScalar(u8, joined, '/');
    while (iter.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..") and components.items.len > 0 and !std.mem.eql(u8, components.items[components.items.len - 1], "..")) {
            _ = components.pop();
        } else try components.append(allocator, component);
    }
    return if (components.items.len == 0) allocator.dupe(u8, ".") else std.mem.join(allocator, "/", components.items);
}

fn plus(allocator: Allocator, left: []const u8, right: []const u8) ![]const u8 {
    var prefix: std.ArrayList([]const u8) = .empty;
    defer prefix.deinit(allocator);
    var suffix: std.ArrayList([]const u8) = .empty;
    defer suffix.deinit(allocator);
    var iter = std.mem.splitScalar(u8, left, '/');
    while (iter.next()) |part| if (part.len != 0) try prefix.append(allocator, part);
    iter = std.mem.splitScalar(u8, right, '/');
    while (iter.next()) |part| if (part.len != 0) try suffix.append(allocator, part);
    var first: usize = 0;
    while (true) {
        while (first < suffix.items.len and std.mem.eql(u8, suffix.items[first], ".")) : (first += 1) {}
        const last = prefix.pop() orelse break;
        if (std.mem.eql(u8, last, ".")) continue;
        if (std.mem.eql(u8, last, "..") or first == suffix.items.len or !std.mem.eql(u8, suffix.items[first], "..")) {
            try prefix.append(allocator, last);
            break;
        }
        first += 1;
    }
    try prefix.appendSlice(allocator, suffix.items[first..]);
    return if (prefix.items.len == 0) allocator.dupe(u8, ".") else std.mem.join(allocator, "/", prefix.items);
}

test "Pathname resolution and digestable extensions" {
    const a = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "css/sub", "../../img/icon.svg", "img/icon.svg" },
        .{ "css", "./icon.svg", "css/icon.svg" },
        .{ "css", "/icon.svg", "icon.svg" },
        .{ ".", "icon.svg", "icon.svg" },
        .{ "css", "sub/../icon.svg", "css/sub/../icon.svg" },
    };
    for (cases) |case| {
        const resolved = try resolvePath(a, case[0], case[1]);
        defer a.free(resolved);
        try std.testing.expectEqualStrings(case[2], resolved);
    }
    try std.testing.expectEqual(@as(?usize, 1), digestExtension("x.js.map"));
    try std.testing.expect(alreadyDigested("x-1234567.digested.js"));
    try std.testing.expect(!alreadyDigested("x-123456.digested.js"));
}

test "dependency digest discovery, cycles and compiler output" {
    const a = std.testing.allocator;
    const sources = [_]Source{
        .{ .logical = "a.css", .body = "url(b.css?v=1) url(missing.png#lost)" },
        .{ .logical = "b.css", .body = "url(a.css) url(icon.svg)" },
        .{ .logical = "icon.svg", .body = "<svg/>" },
        .{ .logical = "app.js", .body = "RAILS_ASSET_URL('icon.svg')\n//# sourceMappingURL=app.js.map\n" },
        .{ .logical = "app.js.map", .body = "{}" },
    };
    var pipeline: Pipeline = .{ .allocator = a, .sources = &sources, .by_logical = .empty, .version = "1.0" };
    defer pipeline.by_logical.deinit(a);
    for (sources, 0..) |source, i| try pipeline.by_logical.put(a, source.logical, i);
    var digested: [sources.len][]const u8 = undefined;
    for (sources, 0..) |_, i| digested[i] = try pipeline.digestedPath(a, i);
    defer for (digested) |path| a.free(path);
    var expected_hasher = std.crypto.hash.Sha1.init(.{});
    // b.css then the root a.css itself (cycles include it once), then icon.svg.
    for ([_][]const u8{ sources[0].body, sources[1].body, sources[0].body, sources[2].body, "1.0" }) |part| expected_hasher.update(part);
    const digest = expected_hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest[0..4].*, .lower);
    const expected_path = try std.fmt.allocPrint(a, "a-{s}.css", .{hex});
    defer a.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, digested[0]);
    const css = try pipeline.compile(a, 0, &digested);
    defer a.free(css);
    const expected_css = try std.fmt.allocPrint(a, "url(\"/assets/{s}?v=1\") url(\"missing.png\")", .{digested[1]});
    defer a.free(expected_css);
    try std.testing.expectEqualStrings(expected_css, css);
    const js = try pipeline.compile(a, 3, &digested);
    defer a.free(js);
    const expected_js = try std.fmt.allocPrint(a, "\"/assets/{s}\"\n//# sourceMappingURL=/assets/{s}\n", .{ digested[2], digested[4] });
    defer a.free(expected_js);
    try std.testing.expectEqualStrings(expected_js, js);
}

test "CSS compilation preserves excluded URLs and source regex boundaries" {
    const a = std.testing.allocator;
    const sources = [_]Source{
        .{ .logical = "app.css", .body = "" },
        .{ .logical = "img/icon.svg", .body = "<svg/>" },
    };
    var pipeline: Pipeline = .{ .allocator = a, .sources = &sources, .by_logical = .empty, .version = "1.0" };
    defer pipeline.by_logical.deinit(a);
    for (sources, 0..) |source, i| try pipeline.by_logical.put(a, source.logical, i);
    const digested = [_][]const u8{ "app-digest.css", "img/icon-digest.svg" };
    const cases = [_][2][]const u8{
        .{ "url(data:x) url(#x) url(%23x) url(http://host/x) url(https://host/x) url(//host/x)", "url(data:x) url(#x) url(%23x) url(http://host/x) url(https://host/x) url(//host/x)" },
        .{ "url( 'img/icon.svg?v=1#x')", "url(\"/assets/img/icon-digest.svg?v=1#x\")" },
        .{ "url( 'img/icon.svg?v=1#x' )", "url( 'img/icon.svg?v=1#x' )" },
        .{ "url(img/icon.svg \t)", "url(\"/assets/img/icon-digest.svg\")" },
        .{ "url('img/icon.svg \t')", "url(\"/assets/img/icon-digest.svg\")" },
        .{ "url(img/icon.svg?v=1 \t)", "url(\"/assets/img/icon-digest.svg?v=1 \t\")" },
        .{ "url(img/icon.svg?) url(img/icon.svg#) url()", "url(img/icon.svg?) url(img/icon.svg#) url()" },
        .{ "url(missing.png?lost#x)", "url(\"missing.png\")" },
        .{ "URL(img/icon.svg) myurl(img/icon.svg)", "URL(img/icon.svg) myurl(\"/assets/img/icon-digest.svg\")" },
        .{ "url('img/icon.svg\") url(\"img/icon.svg)", "url(\"/assets/img/icon-digest.svg\") url(\"/assets/img/icon-digest.svg\")" },
    };
    // These are compiler-visible bytes, including the regex's permissive quotes
    // and lack of a word boundary, rather than assumptions about valid CSS syntax.
    for (cases) |case| {
        const input = [_]Source{ .{ .logical = sources[0].logical, .body = case[0] }, sources[1] };
        pipeline.sources = &input;
        const compiled = try pipeline.compile(a, 0, &digested);
        defer a.free(compiled);
        try std.testing.expectEqualStrings(case[1], compiled);
    }
}

test "source map compilation retains Ruby end-anchor newline and comment delimiters" {
    const a = std.testing.allocator;
    const sources = [_]Source{
        .{ .logical = "app.js", .body = "" },
        .{ .logical = "app.js.map", .body = "{}" },
    };
    var pipeline: Pipeline = .{ .allocator = a, .sources = &sources, .by_logical = .empty, .version = "1.0" };
    defer pipeline.by_logical.deinit(a);
    for (sources, 0..) |source, i| try pipeline.by_logical.put(a, source.logical, i);
    const digested = [_][]const u8{ "app-digest.js", "app-digest.js.map" };
    const cases = [_][2][]const u8{
        .{ "code\n//# sourceMappingURL=app.js.map", "code\n//# sourceMappingURL=/assets/app-digest.js.map" },
        .{ "code\n//# sourceMappingURL=app.js.map\n", "code\n//# sourceMappingURL=/assets/app-digest.js.map\n" },
        .{ "code\n//# sourceMappingURL=app.js.map \r\n\n", "code\n//# sourceMappingURL=/assets/app-digest.js.map\n" },
        .{ "code\n//# sourceMappingURL=app.js.map \t", "code\n//# sourceMappingURL=/assets/app-digest.js.map" },
        .{ "code\n/*# sourceMappingURL=app.js.map */\n", "code\n/*# sourceMappingURL=/assets/app-digest.js.map */\n" },
        .{ "code\n//# sourceMappingURL=missing.js.map\n", "code\n//\n" },
        .{ "code\n/*# sourceMappingURL=missing.js.map */\n", "code\n/* */\n" },
        .{ "code\n//# sourceMappingURL=app.js.map\nmore", "code\n//# sourceMappingURL=app.js.map\nmore" },
    };
    for (cases) |case| {
        const input = [_]Source{ .{ .logical = sources[0].logical, .body = case[0] }, sources[1] };
        pipeline.sources = &input;
        const compiled = try pipeline.compile(a, 0, &digested);
        defer a.free(compiled);
        try std.testing.expectEqualStrings(case[1], compiled);
    }
}
