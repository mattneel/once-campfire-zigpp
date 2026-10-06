//! Native Action Text parsing/presentation. Policy sources: crates/richtext/src/{content,
//! filters,sanitizer,plain_text,attachables,autolink}.rs and reference/app/helpers/content_filters/.
const std = @import("std");
const model = @import("model.zig");
const compat = @import("compat.zig");
const db_mod = @import("db.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const c = @cImport({ @cInclude("gumbo.h"); });
const Node = c.GumboNode;

pub const MAX_TREE_DEPTH = 400;
pub const MAX_ATTRIBUTES = 400;
pub const MAX_CONTENT_ATTACHMENT_DEPTH = 8;

/// Optional request/transaction-owned lookup; plaintext never imports or opens a database.
pub const UserResolver = struct {
    context: *anyopaque,
    find: *const fn (*anyopaque, Allocator, i64) anyerror!?model.User,
};
const Context = struct {
    allocator: Allocator,
    users: ?UserResolver = null,
    secrets: ?*compat.Secrets = null,
    io: ?Io = null,
    host: []const u8 = "",
};
const Parse = struct {
    options: c.GumboOptions,
    output: *c.GumboOutput,
    fn init(body: []const u8) !Parse {
        try preflight(body);
        var options = c.kGumboDefaultOptions;
        options.fragment_context = c.GUMBO_TAG_BODY;
        options.max_errors = 0;
        const output = c.gumbo_parse_with_options(&options, body.ptr, body.len);
        if (output == null) return error.OutOfMemory;
        errdefer c.gumbo_destroy_output(&options, output);
        try validateTree(output.*.root, 0);
        return .{ .options = options, .output = output };
    }
    fn deinit(self: *Parse) void { c.gumbo_destroy_output(&self.options, self.output); }
    fn root(self: *const Parse) *Node { return self.output.root; }
};

fn eq(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
fn oneOf(value: []const u8, values: []const []const u8) bool {
    for (values) |candidate| if (eq(value, candidate)) return true;
    return false;
}
fn children(node: *const Node) []const ?*anyopaque {
    const vector = switch (node.type) {
        c.GUMBO_NODE_DOCUMENT => node.v.document.children,
        c.GUMBO_NODE_ELEMENT, c.GUMBO_NODE_TEMPLATE => node.v.element.children,
        else => return &.{},
    };
    if (vector.length == 0) return &.{};
    return vector.data[0..vector.length];
}
fn child(raw: ?*anyopaque) *Node { return @ptrCast(@alignCast(raw.?)); }
fn element(node: *const Node) bool { return node.type == c.GUMBO_NODE_ELEMENT or node.type == c.GUMBO_NODE_TEMPLATE; }
fn name(node: *const Node) []const u8 {
    if (!element(node)) return "";
    const known = std.mem.span(c.gumbo_normalized_tagname(node.v.element.tag));
    if (known.len != 0) return known;
    var piece = node.v.element.original_tag;
    c.gumbo_tag_from_original_text(&piece);
    return piece.data[0..piece.length];
}
fn named(node: *const Node, value: []const u8) bool { return std.ascii.eqlIgnoreCase(name(node), value); }
fn attr(node: *const Node, key: [:0]const u8) ?[]const u8 {
    if (!element(node)) return null;
    const value = c.gumbo_get_attribute(&node.v.element.attributes, key.ptr);
    if (value == null) return null;
    return std.mem.span(value.*.value);
}
fn textNode(node: *const Node) bool {
    return node.type == c.GUMBO_NODE_TEXT or node.type == c.GUMBO_NODE_WHITESPACE or node.type == c.GUMBO_NODE_CDATA;
}
fn voidTag(tag: []const u8) bool {
    return oneOf(tag, &.{"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"});
}
fn validateTree(node: *const Node, depth: usize) !void {
    const next_depth = depth + @as(usize, if (element(node) and !named(node, "html") and !voidTag(name(node))) 1 else 0);
    if (next_depth > MAX_TREE_DEPTH) return error.TreeDepthExceeded;
    if (element(node) and node.v.element.attributes.length > MAX_ATTRIBUTES) return error.TooManyAttributes;
    for (children(node)) |raw| try validateTree(child(raw), next_depth);
}

/// Stock libgumbo predates Nokogiri's in-parser limits. Bound open tags/attributes before invoking
/// it (quoted attributes, comments and raw-text are tokenized, never interpreted as markup).
fn preflight(body: []const u8) !void {
    var stack: [MAX_TREE_DEPTH + 1][]const u8 = undefined;
    var depth: usize = 0;
    var i: usize = 0;
    var raw_text: ?[]const u8 = null;
    while (i < body.len) {
        if (body[i] != '<') { i += 1; continue; }
        if (raw_text) |raw| {
            if (i + 2 + raw.len <= body.len and body[i + 1] == '/' and std.ascii.eqlIgnoreCase(body[i + 2 ..][0..raw.len], raw)) raw_text = null else { i += 1; continue; }
        }
        if (std.mem.startsWith(u8, body[i..], "<!--")) {
            const end = std.mem.indexOf(u8, body[i + 4 ..], "-->") orelse return;
            i += 4 + end + 3;
            continue;
        }
        i += 1;
        if (i == body.len) break;
        const closing = body[i] == '/';
        if (closing) i += 1;
        const start = i;
        while (i < body.len and (std.ascii.isAlphanumeric(body[i]) or body[i] == '-' or body[i] == ':')) i += 1;
        if (start == i) continue;
        const tag = body[start..i];
        if (closing) {
            var d = depth;
            while (d > 0) {
                d -= 1;
                if (std.ascii.eqlIgnoreCase(stack[d], tag)) { depth = d; break; }
            }
        } else if (!voidTag(tag) and !std.ascii.eqlIgnoreCase(tag, "html") and !std.ascii.eqlIgnoreCase(tag, "body") and !std.ascii.eqlIgnoreCase(tag, "head")) {
            // HTML's implied closing tags keep ordinary omitted </p>, </li>, etc. shallow.
            var d = depth;
            while (d > 0) {
                d -= 1;
                const open = stack[d];
                const close_p = std.ascii.eqlIgnoreCase(open, "p") and oneOf(tag, &.{"p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "pre", "blockquote", "table", "hr"});
                const close_same = std.ascii.eqlIgnoreCase(open, tag) and oneOf(tag, &.{"li", "dt", "dd", "option", "tr", "td", "th"});
                if (close_p or close_same) { depth = d; break; }
                if (std.ascii.eqlIgnoreCase(open, "a") and std.ascii.eqlIgnoreCase(tag, "a")) {
                    // Adoption removes the old anchor but reconstructs its formatting descendants.
                    std.mem.copyForwards([]const u8, stack[d .. depth - 1], stack[d + 1 .. depth]);
                    depth -= 1;
                    break;
                }
                if (oneOf(open, &.{"ul", "ol", "table"})) break;
            }
            if (depth >= MAX_TREE_DEPTH) return error.TreeDepthExceeded;
            stack[depth] = tag;
            depth += 1;
            if (oneOf(tag, &.{"script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"})) raw_text = tag;
        }
        var attributes: usize = 0;
        var attribute_names: [MAX_ATTRIBUTES][]const u8 = undefined;
        while (i < body.len and body[i] != '>') {
            while (i < body.len and (std.ascii.isWhitespace(body[i]) or body[i] == '/')) i += 1;
            if (i == body.len or body[i] == '>') break;
            const attribute_start = i;
            while (i < body.len and !std.ascii.isWhitespace(body[i]) and body[i] != '=' and body[i] != '>') i += 1;
            const attribute_name = body[attribute_start..i];
            var duplicate = false;
            for (attribute_names[0..attributes]) |existing| if (std.ascii.eqlIgnoreCase(existing, attribute_name)) { duplicate = true; break; };
            if (!duplicate) {
                if (attributes >= MAX_ATTRIBUTES) return error.TooManyAttributes;
                attribute_names[attributes] = attribute_name;
                attributes += 1;
            }
            while (i < body.len and std.ascii.isWhitespace(body[i])) i += 1;
            if (i < body.len and body[i] == '=') {
                i += 1;
                while (i < body.len and std.ascii.isWhitespace(body[i])) i += 1;
                if (i < body.len and (body[i] == '\'' or body[i] == '"')) {
                    const quote = body[i]; i += 1;
                    while (i < body.len and body[i] != quote) i += 1;
                    if (i < body.len) i += 1;
                } else while (i < body.len and !std.ascii.isWhitespace(body[i]) and body[i] != '>') { i += 1; }
            }
        }
        if (i < body.len) i += 1;
    }
}
fn stripped(body: []const u8) []const u8 { return std.mem.trim(u8, body, " \t\r\n\x0b\x0c\x00"); }

/// ActionText::Content.new(body).to_html before the write transaction. Errors are real parser/
/// attachment errors; the controller's documented raw-body preservation belongs to its caller.
pub fn canonicalize(allocator: Allocator, body: []const u8) ![]const u8 {
    var parsed = try Parse.init(stripped(body)); defer parsed.deinit();
    var out = Writer.Allocating.init(allocator); defer out.deinit();
    for (children(parsed.root())) |raw| try canonicalNode(allocator, child(raw), &out.writer, false);
    return out.toOwnedSlice();
}
fn canonicalNode(allocator: Allocator, node: *const Node, writer: *Writer, raw_text: bool) anyerror!void {
    if (textNode(node)) {
        if (raw_text) try writer.writeAll(std.mem.span(node.v.text.text)) else try escaped(writer, std.mem.span(node.v.text.text), false);
        return;
    }
    if (node.type == c.GUMBO_NODE_COMMENT) {
        try writer.print("<!--{s}-->", .{std.mem.span(node.v.text.text)}); return;
    }
    if (!element(node)) return;
    const tag = name(node);
    if (named(node, "action-text-attachment") or attr(node, "data-trix-attachment") != null) {
        const attachment = try Attachment.init(allocator, node); defer attachment.deinit();
        if (attr(node, "data-trix-attachment") != null and attachment.empty()) return;
        if (attr(node, "data-trix-attachment") != null) {
            if (attachment.get("sgid")) |sgid| _ = try userIdFromSgid(allocator, sgid);
        }
        try writer.writeAll("<action-text-attachment");
        for (attachment_names) |key| if (attachment.get(key)) |value| {
            try writer.print(" {s}=\"", .{key}); try escaped(writer, value, true); try writer.writeByte('"');
        };
        try writer.writeAll("></action-text-attachment>"); return;
    }
    const gallery = isGallery(node);
    try writer.print("<{s}", .{tag});
    if (!gallery) {
        const vector = node.v.element.attributes;
        for (vector.data[0..vector.length]) |raw| {
            const a: *c.GumboAttribute = @ptrCast(@alignCast(raw.?));
            try writer.print(" {s}=\"", .{std.mem.span(a.name)}); try escaped(writer, std.mem.span(a.value), true); try writer.writeByte('"');
        }
    }
    try writer.writeByte('>');
    for (children(node)) |raw| try canonicalNode(allocator, child(raw), writer, oneOf(tag, &.{"script", "style", "xmp", "iframe", "noembed", "noframes", "plaintext"}));
    if (!voidTag(tag)) try writer.print("</{s}>", .{tag});
}
fn isGallery(node: *const Node) bool {
    if (!named(node, "div")) return false;
    var count: usize = 0;
    for (children(node)) |raw| {
        const member = child(raw);
        if (textNode(member)) {
            if (std.mem.trim(u8, std.mem.span(member.v.text.text), " \n").len != 0) return false;
        } else if (named(member, "action-text-attachment") and eq(attr(member, "presentation") orelse "", "gallery")) { count += 1; }
        else return false;
    }
    return count >= 2;
}

pub fn plainText(allocator: Allocator, body: []const u8) ![]const u8 {
    return plainTextContext(.{ .allocator = allocator }, body);
}
pub fn plainTextWithUsers(allocator: Allocator, body: []const u8, users: UserResolver) ![]const u8 {
    return plainTextContext(.{ .allocator = allocator, .users = users }, body);
}
fn plainTextContext(ctx: Context, body: []const u8) ![]const u8 {
    var parsed = try Parse.init(stripped(body)); defer parsed.deinit();
    var out = Writer.Allocating.init(ctx.allocator); defer out.deinit();
    for (children(parsed.root())) |raw| try plainNode(ctx, child(raw), &out, 0, 0, false);
    chomp(&out);
    return out.toOwnedSlice();
}
fn chomp(out: *Writer.Allocating) void { chompFrom(out, 0); }
fn chompFrom(out: *Writer.Allocating, start: usize) void {
    while (out.writer.end > start and out.writer.buffer[out.writer.end - 1] == '\n') {
        out.writer.end -= 1;
        if (out.writer.end > start and out.writer.buffer[out.writer.end - 1] == '\r') out.writer.end -= 1;
    }
}
fn plainNode(ctx: Context, node: *const Node, out: *Writer.Allocating, nesting: usize, list_depth: usize, ordered: bool) anyerror!void {
    if (textNode(node)) {
        const start = out.writer.end;
        try out.writer.writeAll(std.mem.span(node.v.text.text));
        chompFrom(out, start);
        return;
    }
    if (!element(node)) return;
    const tag = name(node);
    if (oneOf(tag, &.{"script", "style", "unsupported"})) return;
    if (named(node, "action-text-attachment") or attr(node, "data-trix-attachment") != null) {
        const attachment = try Attachment.init(ctx.allocator, node); defer attachment.deinit();
        if (try attachmentUser(ctx, attachment)) |user| {
            try out.writer.writeByte('@'); try out.writer.writeAll(user.name); return;
        }
        const content_type = attachment.get("content-type") orelse "";
        if (std.mem.indexOf(u8, content_type, "opengraph-embed") != null) return;
        if (attachment.get("content")) |content| {
            if (std.mem.indexOf(u8, content_type, "html") != null and content.len != 0) {
                if (nesting >= MAX_TREE_DEPTH) return error.ContentDepthExceeded;
                var parsed = try Parse.init(content); defer parsed.deinit();
                for (children(parsed.root())) |raw| try plainNode(ctx, child(raw), out, nesting + 1, list_depth, ordered);
                return;
            }
            if (eq(content_type, "application/vnd.campfire.mention") and ctx.users == null) {
                if (nesting >= MAX_TREE_DEPTH) return error.ContentDepthExceeded;
                var parsed = try Parse.init(content); defer parsed.deinit();
                var plain = Writer.Allocating.init(ctx.allocator); defer plain.deinit();
                for (children(parsed.root())) |raw| try plainNode(ctx, child(raw), &plain, nesting + 1, 0, false);
                chomp(&plain);
                const trimmed = std.mem.trim(u8, plain.written(), " \t\n\r");
                if (trimmed.len != 0) { try out.writer.writeByte('@'); try out.writer.writeAll(trimmed); return; }
            }
        }
        if (attachment.get("url") != null and (std.mem.startsWith(u8, content_type, "image") or std.mem.startsWith(u8, content_type, "video"))) {
            try out.writer.writeByte('[');
            try out.writer.writeAll(attachment.get("caption") orelse (if (std.mem.startsWith(u8, content_type, "image")) "Image" else attachment.get("filename") orelse "Video"));
            try out.writer.writeByte(']');
        } else if (attachment.get("caption")) |caption| try out.writer.writeAll(caption);
        return;
    }
    if (eq(tag, "br")) { try out.writer.writeByte('\n'); return; }
    const list = eq(tag, "ul") or eq(tag, "ol");
    const block = eq(tag, "h1") or eq(tag, "p") or list or eq(tag, "blockquote");
    if (list and list_depth > 0) try out.writer.writeByte('\n');
    if (eq(tag, "blockquote")) {
        var quoted = Writer.Allocating.init(ctx.allocator); defer quoted.deinit();
        for (children(node)) |raw| try plainNode(ctx, child(raw), &quoted, nesting, list_depth, ordered);
        chomp(&quoted);
        const value = quoted.written();
        const trimmed = std.mem.trim(u8, value, " \t\n\r\x0b\x0c");
        if (trimmed.len == 0) { try out.writer.writeAll("“”"); return; }
        const start = @intFromPtr(trimmed.ptr) - @intFromPtr(value.ptr);
        try out.writer.writeAll(value[0..start]); try out.writer.writeAll("“"); try out.writer.writeAll(trimmed); try out.writer.writeAll("”");
        try out.writer.writeAll(value[start + trimmed.len ..]); try out.writer.writeAll("\n\n"); return;
    }
    if (eq(tag, "li")) {
        if (list_depth > 1) for (0..list_depth - 1) |_| try out.writer.writeAll("  ");
        if (ordered) {
            var index: usize = 1;
            if (node.parent != null) for (children(node.parent)) |raw| {
                const sibling = child(raw);
                if (sibling == node) break;
                if (element(sibling)) index += 1;
            };
            try out.writer.print("{d}. ", .{index});
        } else try out.writer.writeAll("• ");
    }
    if (eq(tag, "figcaption")) try out.writer.writeByte('[');
    const content_start = out.writer.end;
    for (children(node)) |raw| try plainNode(ctx, child(raw), out, nesting, list_depth + @as(usize, if (list) 1 else 0), if (list) eq(tag, "ol") else ordered);
    if (block or oneOf(tag, &.{"div", "li", "figcaption"})) chompFrom(out, content_start);
    if (block) try out.writer.writeAll("\n\n") else if (oneOf(tag, &.{"div", "li"})) try out.writer.writeByte('\n') else if (eq(tag, "figcaption")) try out.writer.writeByte(']');
}

const attachment_names: []const []const u8 = &.{"sgid", "content-type", "url", "href", "filename", "filesize", "width", "height", "previewable", "presentation", "caption", "content"};
const trix_names: []const []const u8 = &.{"sgid", "contentType", "url", "href", "filename", "filesize", "width", "height", "previewable", "presentation", "caption", "content"};
const Attachment = struct {
    allocator: Allocator,
    values: [attachment_names.len]?[]const u8 = @splat(null),
    arena: ?*std.heap.ArenaAllocator = null,
    fn init(allocator: Allocator, node: *const Node) !Attachment {
        var result: Attachment = .{ .allocator = allocator };
        errdefer result.deinit();
        if (attr(node, "data-trix-attachment")) |json| {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = .init(allocator); result.arena = arena;
            for ([_][]const u8{ json, attr(node, "data-trix-attributes") orelse "null" }) |input| {
                const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), input, .{ .allocate = .alloc_always }) catch continue;
                if (parsed.value == .null or (parsed.value == .bool and !parsed.value.bool)) continue;
                if (parsed.value != .object) return error.InvalidAttachment;
                for (trix_names, 0..) |key, index| if (parsed.value.object.get(key)) |value| {
                    result.values[index] = switch (value) {
                        .string, .number_string => |s| s,
                        .null => "", .bool => |v| if (v) "true" else "false",
                        .integer => |v| try std.fmt.allocPrint(arena.allocator(), "{d}", .{v}),
                        .float => |v| try std.fmt.allocPrint(arena.allocator(), "{d}", .{v}),
                        else => return error.InvalidAttachment,
                    };
                };
            }
        } else {
            for (attachment_names, 0..) |key, index| {
                const vector = node.v.element.attributes;
                for (vector.data[0..vector.length]) |raw| {
                    const a: *c.GumboAttribute = @ptrCast(@alignCast(raw.?));
                    if (eq(std.mem.span(a.name), key)) result.values[index] = std.mem.span(a.value);
                }
            }
        }
        return result;
    }
    fn deinit(self: Attachment) void {
        if (self.arena) |arena| { arena.deinit(); self.allocator.destroy(arena); }
    }
    fn get(self: Attachment, key: []const u8) ?[]const u8 {
        for (attachment_names, 0..) |candidate, index| if (eq(candidate, key)) return self.values[index];
        return null;
    }
    fn empty(self: Attachment) bool { for (self.values) |value| if (value != null) return false; return true; }
};

/// Campfire deliberately resolves stale/invalid mention signatures, but only extracts User GIDs;
/// Marshal is never executed. This is display compatibility, NOT authorization/signature proof.
pub fn userIdFromSgid(allocator: Allocator, sgid: []const u8) !?i64 {
    const end = std.mem.indexOf(u8, sgid, "--") orelse sgid.len;
    if (end == 0) return null;
    const decoded = try decodeBase64(allocator, sgid[0..end]); defer allocator.free(decoded);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return error.InvalidSgid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSgid;
    const rails = parsed.value.object.get("_rails") orelse return null;
    if (rails == .null) return null;
    if (rails != .object) return error.InvalidSgid;
    if (rails.object.get("data")) |data| {
        if (data != .null and !(data == .bool and !data.bool)) return if (data == .string) gidUser(data.string) else null;
    }
    if (rails.object.get("message")) |message| {
        if (message == .null or (message == .bool and !message.bool)) return null;
        if (message != .string) return error.InvalidSgid;
        const bytes = try decodeBase64(allocator, message.string); defer allocator.free(bytes);
        const start = std.mem.indexOf(u8, bytes, "gid://campfire/") orelse return null;
        const suffix = bytes[start..];
        var finish = "gid://campfire/".len;
        while (finish < suffix.len and suffix[finish] != '/') finish += 1;
        if (finish == suffix.len) return null;
        finish += 1;
        while (finish < suffix.len and std.ascii.isDigit(suffix[finish])) finish += 1;
        return gidUser(suffix[0..finish]);
    }
    return null;
}
fn gidUser(gid: []const u8) ?i64 {
    const rest = gid;
    if (!std.mem.startsWith(u8, rest, "gid://")) return null;
    const app_end = std.mem.indexOfScalar(u8, rest[6..], '/') orelse return null;
    const path = rest[6 + app_end + 1 ..];
    if (!std.mem.startsWith(u8, path, "User/")) return null;
    const id = path[5..];
    const end = std.mem.indexOfScalar(u8, id, '?') orelse id.len;
    return std.fmt.parseInt(i64, id[0..end], 10) catch null;
}
fn decodeBase64(allocator: Allocator, input: []const u8) ![]u8 {
    const unpadded = std.mem.trimEnd(u8, input, "=");
    const padding = input.len - unpadded.len;
    if (padding > 0 and (input.len % 4 != 0 or padding != (4 - unpadded.len % 4) % 4)) return error.InvalidSgid;
    const has_url = std.mem.indexOfAny(u8, unpadded, "-_") != null;
    const mixed = has_url and std.mem.indexOfAny(u8, unpadded, "+/") != null;
    const translated: ?[]u8 = if (mixed) try allocator.dupe(u8, unpadded) else null;
    defer if (translated) |buffer| allocator.free(buffer);
    if (translated) |buffer| for (buffer) |*byte| {
        if (byte.* == '-') byte.* = '+';
        if (byte.* == '_') byte.* = '/';
    };
    const source: []const u8 = if (translated) |buffer| buffer else unpadded;
    const codec = if (has_url and !mixed) std.base64.url_safe else std.base64.standard;
    const decoder = std.base64.Base64Decoder.init(codec.alphabet_chars, null);
    const size = decoder.calcSizeForSlice(source) catch return error.InvalidSgid;
    const bytes = try allocator.alloc(u8, size); errdefer allocator.free(bytes);
    decoder.decode(bytes, source) catch return error.InvalidSgid;
    return bytes;
}
fn attachmentUser(ctx: Context, attachment: Attachment) !?model.User {
    const sgid = attachment.get("sgid") orelse return null;
    const resolver = ctx.users orelse return null;
    if (try userIdFromSgid(ctx.allocator, sgid)) |id| return resolver.find(resolver.context, ctx.allocator, id);
    // Pre-_rails GlobalID envelopes only resolve through a genuine signature verification.
    if (ctx.secrets) |secrets| if (ctx.io) |io| {
        const gid = try secrets.locateSignedGlobalId(ctx.allocator, sgid, "attachable", Io.Clock.real.now(io).toSeconds()) orelse return null;
        if (!eq(gid.model_name, "User")) return null;
        const id = std.fmt.parseInt(i64, gid.id, 10) catch return null;
        return resolver.find(resolver.context, ctx.allocator, id);
    };
    return null;
}

const DatabaseLookup = struct {
    db: *db_mod.Database,
    io: Io,
    fn find(raw: *anyopaque, allocator: Allocator, id: i64) anyerror!?model.User {
        const self: *DatabaseLookup = @ptrCast(@alignCast(raw));
        return self.db.findUser(allocator, self.io, id);
    }
};
pub fn renderWithHost(allocator: Allocator, body: []const u8, db: *db_mod.Database, io: Io, secrets: *compat.Secrets, host: []const u8) ![]const u8 {
    var lookup: DatabaseLookup = .{ .db = db, .io = io };
    return renderContext(.{ .allocator = allocator, .users = .{ .context = &lookup, .find = DatabaseLookup.find }, .secrets = secrets, .io = io, .host = host }, body);
}
fn renderContext(ctx: Context, body: []const u8) ![]const u8 {
    var parsed = try Parse.init(stripped(body)); defer parsed.deinit();
    var intermediate = Writer.Allocating.init(ctx.allocator); defer intermediate.deinit();
    try intermediate.writer.writeAll("<div class=\"lexxy-content\">\n  ");
    const solo = try soloUnfurl(ctx, parsed.root());
    for (children(parsed.root())) |raw| try renderNode(ctx, child(raw), &intermediate.writer, .filter, 0, solo);
    try intermediate.writer.writeAll("\n</div>\n");
    // Final auto_link sanitization unwraps figure/attachment tags and drops their extra attributes.
    var final_dom = try Parse.init(intermediate.written()); defer final_dom.deinit();
    var out = Writer.Allocating.init(ctx.allocator); defer out.deinit();
    for (children(final_dom.root())) |raw| try autoNode(ctx, child(raw), &out.writer, false);
    return out.toOwnedSlice();
}
const Policy = enum { filter, action, final };
const default_tags: []const []const u8 = &.{"a", "abbr", "acronym", "address", "b", "big", "blockquote", "br", "cite", "code", "dd", "del", "dfn", "div", "dl", "dt", "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "pre", "samp", "small", "span", "strong", "sub", "sup", "time", "tt", "ul", "var"};
const editor_tags: []const []const u8 = &.{"s", "u", "mark", "table", "thead", "tbody", "tfoot", "tr", "th", "td"};
const default_attrs: []const []const u8 = &.{"abbr", "alt", "cite", "class", "datetime", "height", "href", "lang", "src", "title", "width", "xml:lang"};
fn allowedTag(tag: []const u8, policy: Policy) bool {
    if (oneOf(tag, default_tags) and !(policy == .filter and eq(tag, "img"))) return true;
    if (oneOf(tag, editor_tags)) return true;
    if (policy != .final and oneOf(tag, &.{"action-text-attachment", "figure", "figcaption"})) return true;
    return policy == .action and oneOf(tag, &.{"video", "audio", "source", "embed"});
}
fn allowedAttr(key: []const u8, policy: Policy) bool {
    if (oneOf(key, default_attrs) or eq(key, "data-language")) return true;
    return policy != .final and (oneOf(key, attachment_names) or oneOf(key, &.{"controls", "poster", "value", "start"}));
}
fn escaped(writer: *Writer, value: []const u8, attribute: bool) !void {
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        const replacement: ?[]const u8 = switch (byte) { '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => if (attribute) "&quot;" else null, else => null };
        if (replacement) |s| { try writer.writeAll(value[start..index]); try writer.writeAll(s); start = index + 1; }
    }
    try writer.writeAll(value[start..]);
}
fn writeAttribute(writer: *Writer, key: []const u8, value: []const u8) !void {
    try writer.print(" {s}=\"", .{key});
    if (oneOf(key, &.{"href", "src"})) {
        for (value) |byte| switch (byte) {
            ' ' => try writer.writeAll("%20"), '"' => try writer.writeAll("%22"),
            0...8, 11, 12, 14...31 => {},
            else => try escaped(writer, &.{byte}, true),
        };
    } else try escaped(writer, value, true);
    try writer.writeByte('"');
}
fn attributes(ctx: Context, node: *const Node, writer: *Writer, policy: Policy) !void {
    const vector = node.v.element.attributes;
    for (vector.data[0..vector.length]) |raw| {
        const a: *c.GumboAttribute = @ptrCast(@alignCast(raw.?));
        const key = std.mem.span(a.name); const value = std.mem.span(a.value);
        if (!allowedAttr(key, policy)) continue;
        if (oneOf(key, &.{"href", "src", "cite", "poster", "url"}) and !try allowedUri(ctx.allocator, value)) continue;
        if (eq(key, "src") and std.mem.trim(u8, value, " \t\n\r").len == 0) continue;
        try writeAttribute(writer, key, value);
    }
}
fn renderNode(ctx: Context, node: *const Node, writer: *Writer, policy: Policy, nesting: usize, solo: ?*Node) anyerror!void {
    if (textNode(node)) { try escaped(writer, std.mem.span(node.v.text.text), false); return; }
    if (!element(node)) return;
    if (node.v.element.tag_namespace != c.GUMBO_NAMESPACE_HTML) return;
    const tag = name(node);
    if (solo) |unfurl| {
        if (eq(tag, "div")) { try writer.writeAll("<div"); try attributes(ctx, node, writer, policy); try writer.writeByte('>'); try renderAttachment(ctx, unfurl, writer, nesting); try writer.writeAll("</div>"); return; }
        if (eq(tag, "p") and !containsAttachment(node)) return;
    }
    if (named(node, "action-text-attachment") or attr(node, "data-trix-attachment") != null) { try renderAttachment(ctx, node, writer, nesting); return; }
    if (isGallery(node)) {
        var count: usize = 0;
        for (children(node)) |raw| if (element(child(raw))) { count += 1; };
        try writer.print("<div class=\"attachment-gallery attachment-gallery--{d}\">\n  ", .{count});
        for (children(node)) |raw| if (element(child(raw))) try renderAttachment(ctx, child(raw), writer, nesting);
        try writer.writeAll("\n</div>");
        return;
    }
    const keep = allowedTag(tag, policy);
    if (!keep and policy == .filter) return;
    if (keep) { try writer.print("<{s}", .{tag}); try attributes(ctx, node, writer, policy); try writer.writeByte('>'); }
    for (children(node)) |raw| try renderNode(ctx, child(raw), writer, policy, nesting, null);
    if (keep and !voidTag(tag)) try writer.print("</{s}>", .{tag});
}
fn containsAttachment(node: *const Node) bool {
    if (named(node, "action-text-attachment") or attr(node, "data-trix-attachment") != null) return true;
    for (children(node)) |raw| if (containsAttachment(child(raw))) return true;
    return false;
}
fn renderAttachment(ctx: Context, node: *const Node, writer: *Writer, nesting: usize) anyerror!void {
    const attachment = try Attachment.init(ctx.allocator, node); defer attachment.deinit();
    if (attachment.empty()) {
        if (attr(node, "data-trix-attachment") != null) return;
        return error.InvalidAttachment;
    }
    if (try attachmentUser(ctx, attachment)) |user| {
        try writer.writeAll("<span class=\"mention\"><a");
        const title = if (user.bio) |bio| (if (bio.len != 0) try std.fmt.allocPrint(ctx.allocator, "{s} – {s}", .{ user.name, bio }) else try ctx.allocator.dupe(u8, user.name)) else try ctx.allocator.dupe(u8, user.name);
        defer ctx.allocator.free(title);
        try writeAttribute(writer, "title", title);
        const secrets = ctx.secrets orelse return error.MissingSigningSecrets;
        const token = try secrets.signedId(ctx.allocator, "User", user.id, "avatar", null);
        defer ctx.allocator.free(token);
        var number: [14]u8 = undefined;
        var number_len: usize = 0;
        _ = try compat.unixSeconds(user.updated_at);
        for (user.updated_at) |byte| {
            if (std.ascii.isDigit(byte) and number_len < number.len) { number[number_len] = byte; number_len += 1; }
        }
        if (number_len != number.len) return error.InvalidTimestamp;
        try writer.print(" class=\"btn avatar\" href=\"/users/{d}\"><img", .{user.id});
        const avatar = try std.fmt.allocPrint(ctx.allocator, "/users/{s}/avatar?v={s}", .{token, &number});
        defer ctx.allocator.free(avatar);
        try writeAttribute(writer, "src", avatar);
        try writer.writeAll(" width=\"48\" height=\"48\"></a> ");
        try escaped(writer, user.name, false); try writer.writeAll("</span>"); return;
    }
    const content_type = attachment.get("content-type") orelse "";
    if (std.mem.indexOf(u8, content_type, "opengraph-embed") != null) { try renderEmbed(ctx, try embedFromAttachment(ctx, attachment), writer); return; }
    if (attachment.get("content")) |content| {
        if (std.mem.indexOf(u8, content_type, "html") != null and std.mem.trim(u8, content, " \n\r\t").len != 0) {
            try writer.writeAll("<figure class=\"attachment attachment--content\">\n  ");
            if (nesting < MAX_CONTENT_ATTACHMENT_DEPTH) {
                var parsed = try Parse.init(content); defer parsed.deinit();
                for (children(parsed.root())) |raw| try renderNode(ctx, child(raw), writer, .action, nesting + 1, null);
                try writer.writeByte('\n');
            }
            try writer.writeAll("\n</figure>"); return;
        }
    }
    if (attachment.get("url")) |url| {
        if (std.mem.startsWith(u8, content_type, "image")) {
            if (url.len > 0 and url[0] != '/' and !std.ascii.startsWithIgnoreCase(url, "cid:") and !std.ascii.startsWithIgnoreCase(url, "data:")) {
                const colon = std.mem.indexOf(u8, url, "://") orelse return error.MissingAsset;
                if (colon == 0) return error.MissingAsset;
                for (url[0..colon]) |byte| if (!std.ascii.isAlphabetic(byte) and byte != '-') return error.MissingAsset;
            }
            try writer.writeAll("<figure class=\"attachment attachment--preview\">\n  <img");
            for ([_][]const u8{"width", "height"}) |key| if (attachment.get(key)) |value| try writeAttribute(writer, key, value);
            if (try allowedUri(ctx.allocator, url)) try writeAttribute(writer, "src", url);
            try writer.writeAll(">\n"); try renderCaption(attachment, writer); try writer.writeAll("</figure>"); return;
        }
        if (std.mem.startsWith(u8, content_type, "video")) {
            // auto_link's final allowlist unwraps video/source (which has no text), leaving caption.
            try writer.writeAll("<figure class=\"attachment attachment--preview attachment--video\">\n  \n    \n");
            try renderCaption(attachment, writer); try writer.writeAll("</figure>"); return;
        }
    }
    try writer.writeAll("☒");
}
fn renderCaption(attachment: Attachment, writer: *Writer) !void {
    if (attachment.get("caption")) |caption| {
        if (caption.len == 0) return;
        try writer.writeAll("    <figcaption class=\"attachment__caption\">\n      "); try escaped(writer, caption, false); try writer.writeAll("\n    </figcaption>\n");
    }
}

const Embed = struct { href: ?[]const u8 = null, url: ?[]const u8 = null, title: ?[]const u8 = null, description: ?[]const u8 = null };
fn textContent(node: *const Node, writer: *Writer) anyerror!void {
    if (textNode(node)) { try writer.writeAll(std.mem.span(node.v.text.text)); return; }
    for (children(node)) |raw| try textContent(child(raw), writer);
}
fn classed(node: *const Node, class: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, attr(node, "class") orelse "", " \t\n\r");
    while (tokens.next()) |token| if (eq(token, class)) return true;
    return false;
}
fn findClass(node: *const Node, class: []const u8) ?*const Node {
    if (classed(node, class)) return node;
    for (children(node)) |raw| if (findClass(child(raw), class)) |found| return found;
    return null;
}
fn findTag(node: *const Node, tag: []const u8) ?*const Node {
    if (named(node, tag)) return node;
    for (children(node)) |raw| if (findTag(child(raw), tag)) |found| return found;
    return null;
}
fn embedFromAttachment(ctx: Context, attachment: Attachment) !Embed {
    var result: Embed = .{};
    errdefer freeEmbed(ctx.allocator, result);
    if (attachment.get("filename")) |title| {
        if (std.mem.trim(u8, title, " \n\t\r").len != 0) {
            result.title = try ctx.allocator.dupe(u8, title);
            result.href = try webUrl(ctx, attachment.get("href"));
            result.url = try webUrl(ctx, attachment.get("url"));
            if (attachment.get("caption")) |v| result.description = try ctx.allocator.dupe(u8, v);
            return result;
        }
    }
    var parsed = try Parse.init(attachment.get("content") orelse ""); defer parsed.deinit();
    if (findClass(parsed.root(), "og-embed__title")) |title| {
        const link = findTag(title, "a");
        if (link) |a| result.href = try webUrl(ctx, attr(a, "href"));
        var out = Writer.Allocating.init(ctx.allocator); defer out.deinit();
        try textContent(link orelse title, &out.writer);
        result.title = try ctx.allocator.dupe(u8, std.mem.trim(u8, out.written(), " \n\r\t"));
    }
    if (findClass(parsed.root(), "og-embed__image")) |image| if (findTag(image, "img")) |img| { result.url = try webUrl(ctx, attr(img, "src")); };
    if (findClass(parsed.root(), "og-embed__description")) |description| {
        var out = Writer.Allocating.init(ctx.allocator); defer out.deinit();
        try textContent(description, &out.writer);
        result.description = try ctx.allocator.dupe(u8, std.mem.trim(u8, out.written(), " \n\r\t"));
    }
    return result;
}
fn freeEmbed(allocator: Allocator, embed: Embed) void {
    if (embed.href) |s| allocator.free(s); if (embed.url) |s| allocator.free(s);
    if (embed.title) |s| allocator.free(s); if (embed.description) |s| allocator.free(s);
}
fn webUrl(ctx: Context, value: ?[]const u8) !?[]const u8 {
    const url = value orelse return null;
    for (url) |byte| if (byte <= 32 or byte >= 127 or byte == '\\') return null;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    if (!std.ascii.eqlIgnoreCase(url[0..scheme_end], "http") and !std.ascii.eqlIgnoreCase(url[0..scheme_end], "https")) return null;
    const rest = url[scheme_end + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    const hostport = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
    const host = hostport[0 .. std.mem.indexOfScalar(u8, hostport, ':') orelse hostport.len];
    const trimmed = std.mem.trimEnd(u8, host, ".");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '.') == null or std.mem.indexOfScalar(u8, trimmed, '%') != null) return null;
    const label_start = (std.mem.lastIndexOfScalar(u8, trimmed, '.') orelse return null) + 1;
    const label = trimmed[label_start..];
    if (std.ascii.startsWithIgnoreCase(label, "0x")) return null;
    var alpha = false; for (label) |byte| if (std.ascii.isAlphabetic(byte)) { alpha = true; };
    if (!alpha or std.ascii.eqlIgnoreCase(trimmed, std.mem.trimEnd(u8, ctx.host, "."))) return null;
    return ctx.allocator.dupe(u8, url);
}
fn truncate(writer: *Writer, value: []const u8, limit: usize) !void {
    var iterator = (std.unicode.Utf8View.init(value) catch return error.InvalidUtf8).iterator();
    var count: usize = 0; var end: usize = 0;
    while (iterator.nextCodepointSlice()) |s| {
        count += 1;
        if (count <= limit - 1) end = iterator.i;
        _ = s;
    }
    if (count <= limit) try escaped(writer, value, false) else { try escaped(writer, value[0..end], false); try writer.writeAll("…"); }
}
fn renderEmbed(ctx: Context, embed: Embed, writer: *Writer) !void {
    defer freeEmbed(ctx.allocator, embed);
    const avatar = if (embed.url) |url| std.mem.startsWith(u8, url, "https://pbs.twimg.com/profile_images") else false;
    try writer.writeAll("<figure class=\"attachment attachment--content attachment--og\">\n  \n    <div class=\"og-embed gap ");
    if (avatar) try writer.writeAll("og-embed--twitter-avatar");
    try writer.writeAll("\">\n      <div class=\"og-embed__content\">\n        <div class=\"og-embed__title\">\n          ");
    if (embed.href) |href| {
        try writer.writeAll("<a"); try writeAttribute(writer, "href", href); try writer.writeByte('>');
        if (embed.title) |title| try truncate(writer, title, 280) else try escaped(writer, href, false);
        try writer.writeAll("</a>");
    } else if (embed.title) |title| try truncate(writer, title, 280);
    try writer.writeAll("\n        </div>\n        <div class=\"og-embed__description\">");
    try truncate(writer, embed.description orelse "", 560);
    try writer.writeAll("</div>\n      </div>\n");
    if (embed.url) |url| {
        try writer.writeAll("        <div class=\"og-embed__image\">\n          <img"); try writeAttribute(writer, "src", url);
        try writer.writeAll(" class=\"image center\" alt=\"\">\n        </div>\n");
    }
    try writer.writeAll("    </div>\n  \n</figure>");
}
fn collectUnfurls(node: *const Node, count: *usize, only: *?*Node) void {
    if (named(node, "action-text-attachment") and std.mem.indexOf(u8, attr(node, "content-type") orelse "", "opengraph-embed") != null) { count.* += 1; only.* = @constCast(node); }
    for (children(node)) |raw| collectUnfurls(child(raw), count, only);
}
fn normalizedTweet(allocator: Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, value, "x.com") == null and std.mem.indexOf(u8, value, "twitter.com") == null) return allocator.dupe(u8, value);
    const question = std.mem.indexOfScalar(u8, value, '?') orelse value.len;
    const end = std.mem.indexOfScalar(u8, value, '#') orelse value.len;
    const cut = @min(question, end);
    const base = value[0..cut];
    const prefix = "https://x.com/";
    if (std.ascii.startsWithIgnoreCase(base, prefix)) return std.fmt.allocPrint(allocator, "https://twitter.com/{s}{s}", .{base[prefix.len..], if (end < value.len) value[end..] else ""});
    return std.fmt.allocPrint(allocator, "{s}{s}", .{base, if (end < value.len) value[end..] else ""});
}
fn soloUnfurl(ctx: Context, root: *const Node) !?*Node {
    var count: usize = 0; var only: ?*Node = null; collectUnfurls(root, &count, &only);
    if (count != 1) return null;
    const attachment = try Attachment.init(ctx.allocator, only.?); defer attachment.deinit();
    const embed = try embedFromAttachment(ctx, attachment); defer freeEmbed(ctx.allocator, embed);
    const href = embed.href orelse return null;
    var plain = Writer.Allocating.init(ctx.allocator); defer plain.deinit();
    for (children(root)) |raw| try plainNode(ctx, child(raw), &plain, 0, 0, false);
    chomp(&plain);
    const left = try normalizedTweet(ctx.allocator, href); defer ctx.allocator.free(left);
    const right = try normalizedTweet(ctx.allocator, plain.written()); defer ctx.allocator.free(right);
    return if (eq(left, right)) only else null;
}

fn allowedUri(allocator: Allocator, value: []const u8) !bool {
    // Gumbo has already decoded HTML entities once; Loofah also decodes nested numeric references.
    var out = Writer.Allocating.init(allocator); defer out.deinit();
    var i: usize = 0;
    while (i < value.len) {
        if (std.mem.startsWith(u8, value[i..], "&Tab;")) { i += 5; continue; }
        if (std.mem.startsWith(u8, value[i..], "&NewLine;")) { i += 9; continue; }
        if (std.mem.startsWith(u8, value[i..], "&colon;")) { try out.writer.writeByte(':'); i += 7; continue; }
        if (std.mem.startsWith(u8, value[i..], "&amp;")) { try out.writer.writeByte('&'); i += 5; continue; }
        if (std.mem.startsWith(u8, value[i..], "&#")) {
            var end = i + 2; const hex = end < value.len and (value[end] == 'x' or value[end] == 'X'); if (hex) end += 1;
            const start = end;
            while (end < value.len and (if (hex) std.ascii.isHex(value[end]) else std.ascii.isDigit(value[end]))) end += 1;
            if (end > start) {
                const code = std.fmt.parseInt(u21, value[start..end], if (hex) 16 else 10) catch 0xfffd;
                if (code > 0x101 and code != '`') { var buffer: [4]u8 = undefined; const length = std.unicode.utf8Encode(code, &buffer) catch 0; try out.writer.writeAll(buffer[0..length]); }
                else if (code > 32 and code < 127 and code != '`') try out.writer.writeByte(@intCast(code));
                i = end + @as(usize, if (end < value.len and value[end] == ';') 1 else 0); continue;
            }
        }
        const length = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        if (i + length > value.len) return false;
        const code = std.unicode.utf8Decode(value[i..][0..length]) catch return false;
        if (code > 32 and code != '`' and code != 127 and !(code >= 128 and code <= 257)) {
            if (length == 1) try out.writer.writeByte(std.ascii.toLower(value[i])) else try out.writer.writeAll(value[i..][0..length]);
        }
        i += length;
    }
    const uri = out.written();
    if (uri.len == 0 or !std.ascii.isAlphabetic(uri[0])) return true;
    var end: usize = 1;
    while (end < uri.len and (std.ascii.isAlphanumeric(uri[end]) or oneOf(uri[end..][0..1], &.{"+", "-", "."}))) end += 1;
    if (end == uri.len) return true;
    const separator = uri[end..];
    if (separator[0] != ':' and !std.ascii.startsWithIgnoreCase(separator, "%3a") and !std.ascii.startsWithIgnoreCase(separator, "&#37;3a")) return true;
    const scheme = uri[0..end];
    if (!oneOf(scheme, &.{"afs", "aim", "callto", "data", "ed2k", "fax", "ftp", "gopher", "http", "https", "irc", "line", "mailto", "modem", "news", "nntp", "rsync", "rtsp", "sftp", "sms", "ssh", "tag", "tel", "telnet", "urn", "webcal", "xmpp"})) return false;
    if (eq(scheme, "data")) {
        if (separator[0] != ':') return false;
        const payload = separator[1..];
        const comma = std.mem.indexOfScalar(u8, payload, ',') orelse return false;
        const semicolon = std.mem.indexOfScalar(u8, payload[0..comma], ';') orelse comma;
        return oneOf(payload[0..semicolon], &.{"image/gif", "image/jpeg", "image/png", "text/css", "text/plain"});
    }
    return true;
}
fn autoNode(ctx: Context, node: *const Node, writer: *Writer, anchored: bool) anyerror!void {
    if (textNode(node)) {
        if (anchored) try escaped(writer, std.mem.span(node.v.text.text), false) else try autoText(ctx, writer, std.mem.span(node.v.text.text));
        return;
    }
    if (!element(node) or node.v.element.tag_namespace != c.GUMBO_NAMESPACE_HTML) return;
    const tag = name(node); const keep = allowedTag(tag, .final);
    if (keep) { try writer.print("<{s}", .{tag}); try attributes(ctx, node, writer, .final); try writer.writeByte('>'); }
    for (children(node)) |raw| try autoNode(ctx, child(raw), writer, anchored or (keep and eq(tag, "a")));
    if (keep and !voidTag(tag)) try writer.print("</{s}>", .{tag});
}
const auto_schemes: []const []const u8 = &.{"ed2k", "ftp", "http", "https", "irc", "mailto", "news", "gopher", "nntp", "telnet", "webcal", "xmpp", "callto", "feed", "svn", "urn", "aim", "rsync", "tag", "ssh", "sftp", "rtsp", "afs", "file"};
fn urlStart(text: []const u8) ?bool {
    if (std.ascii.startsWithIgnoreCase(text, "www.") and text.len > 4 and (std.ascii.isAlphanumeric(text[4]) or text[4] == '_')) return false;
    const colon = std.mem.indexOfScalar(u8, text[0..@min(text.len, 12)], ':') orelse return null;
    if (colon + 3 <= text.len and eq(text[colon..][0..3], "://")) {
        for (auto_schemes) |scheme| if (std.ascii.eqlIgnoreCase(text[0..colon], scheme)) return true;
    }
    return null;
}
fn emailLocal(byte: u8) bool { return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "_.!#$%&'*/=?^`{|}~+-", byte) != null; }
fn emailLength(text: []const u8) ?usize {
    if (text.len == 0 or !(std.ascii.isAlphanumeric(text[0]) or std.mem.indexOfScalar(u8, "_.!#$%+-", text[0]) != null)) return null;
    var i: usize = 1;
    while (i < text.len and emailLocal(text[i])) i += 1;
    if (i >= text.len or text[i] != '@') return null;
    i += 1; var dots: usize = 0; var label: usize = 0;
    while (i < text.len) : (i += 1) {
        if (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '-') { label += 1; continue; }
        if (text[i] == '.' and label != 0 and i + 1 < text.len and (std.ascii.isAlphanumeric(text[i + 1]) or text[i + 1] == '_' or text[i + 1] == '-')) { dots += 1; label = 0; continue; }
        break;
    }
    return if (dots > 0 and label > 0) i else null;
}
fn autoText(ctx: Context, writer: *Writer, text: []const u8) !void {
    var i: usize = 0; var copied: usize = 0;
    while (i < text.len) {
        if (urlStart(text[i..])) |scheme| {
            var end = i;
            while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != '<' and text[end] != '"' and !(text[end] == 0xc2 and end + 1 < text.len and text[end + 1] == 0xa0)) end += 1;
            var trimmed = end;
            var openings: [3]usize = @splat(0);
            var closings: [3]usize = @splat(0);
            for (text[i..end]) |byte| switch (byte) {
                '(' => openings[0] += 1, '[' => openings[1] += 1, '{' => openings[2] += 1,
                ')' => closings[0] += 1, ']' => closings[1] += 1, '}' => closings[2] += 1,
                else => {},
            };
            while (trimmed > i) {
                const byte = text[trimmed - 1];
                if (std.ascii.isAlphanumeric(byte) or byte >= 128 or byte == '_' or byte == '/' or byte == '-' or byte == '=' or byte == ';') break;
                if (byte == ')' or byte == ']' or byte == '}') {
                    const pair: usize = if (byte == ')') 0 else if (byte == ']') 1 else 2;
                    if (openings[pair] >= closings[pair]) break;
                    closings[pair] -= 1;
                }
                trimmed -= 1;
            }
            if (trimmed > i) {
                try escaped(writer, text[copied..i], false);
                try writer.writeAll("<a target=\"_blank\" href=\"");
                if (!scheme) try writer.writeAll("http://");
                try escaped(writer, text[i..trimmed], true); try writer.writeAll("\">"); try escaped(writer, text[i..trimmed], false); try writer.writeAll("</a>");
                try escaped(writer, text[trimmed..end], false);
                i = end; copied = end; continue;
            }
        }
        if ((i == 0 or !emailLocal(text[i - 1]))) {
            if (emailLength(text[i..])) |length| {
                try escaped(writer, text[copied..i], false);
                try writer.writeAll("<a target=\"_blank\" href=\"mailto:");
                const encoded = try compat.urlEncode(ctx.allocator, text[i..][0..length]); defer ctx.allocator.free(encoded);
                var at: usize = 0;
                while (at < encoded.len) {
                    if (std.mem.startsWith(u8, encoded[at..], "%40")) { try writer.writeByte('@'); at += 3; } else { try escaped(writer, encoded[at..][0..1], true); at += 1; }
                }
                try writer.writeAll("\">"); try escaped(writer, text[i..][0..length], false); try writer.writeAll("</a>");
                i += length; copied = i; continue;
            }
        }
        i += 1;
    }
    try escaped(writer, text[copied..], false);
}

fn expectPlain(body: []const u8, expected: []const u8) !void {
    const result = try plainText(std.testing.allocator, body); defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}
test "ActionText plaintext blocks lists breaks captions and preformatted content" {
    try expectPlain("<div>one<br>two</div><p>three</p><h1>Title</h1><pre>line 1\n  line 2</pre>", "one\ntwo\nthree\n\nTitle\n\nline 1\n  line 2");
    try expectPlain("<ol><li>first</li><li>second<ul><li>nested</li></ul></li></ol>", "1. first\n2. second\n  • nested");
    try expectPlain("<blockquote>words</blockquote><p>end</p>", "“words”\n\nend");
    try expectPlain("<script>bad</script><style>bad</style><p>&amp; &lt; &gt;</p>", "& < >");
}
test "native DOM sanitizer and autolinks isolate attributes and anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const ctx: Context = .{ .allocator = arena.allocator() };
    const html = try renderContext(ctx, "<p title=\"x> http://evil.test/ <img src=x onerror=alert(1)>\">see http://example.com/a?b=1&amp;c=2 and me@example.com</p><script>x()</script><img name=body src=x><a href=\"jav&#x61;script:alert(1)\" onclick=x>safe</a>");
    try std.testing.expect(std.mem.indexOf(u8, html, "<img") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "onclick") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a>safe</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a target=\"_blank\" href=\"http://example.com/a?b=1&amp;c=2\">http://example.com/a?b=1&amp;c=2</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "mailto:me@example.com") != null);
    const anchored = try renderContext(ctx, "<p><a href=\"/x\">www.example.com</a> <s>s</s><u>u</u><mark>m</mark></p><pre data-language=\"ruby\">def x<br>end</pre>");
    try std.testing.expect(std.mem.indexOf(u8, anchored, "<a href=\"/x\">www.example.com</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchored, "<pre data-language=\"ruby\">def x<br>end</pre>") != null);
}
test "URI policy rejects obfuscated executable and HTML data schemes" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{"javascript:alert(1)", " java\nscript:alert(1)", "javascript%3Aalert(1)", "jav&#97;script:alert(1)", "data:text/html,evil", "data:image/svg+xml,evil"}) |uri| try std.testing.expect(!try allowedUri(allocator, uri));
    for ([_][]const u8{"/rooms/1", "https://example.com/a", "mailto:me@example.com", "data:image/png;base64,aA=="}) |uri| try std.testing.expect(try allowedUri(allocator, uri));
}
const test_sgid = "eyJfcmFpbHMiOnsiZGF0YSI6ImdpZDovL2NhbXBmaXJlL1VzZXIvMT9leHBpcmVzX2luIiwicHVyIjoiYXR0YWNoYWJsZSJ9fQ==--invalid";
const TestUsers = struct {
    deleted: bool = false,
    fn find(raw: *anyopaque, allocator: Allocator, id: i64) anyerror!?model.User {
        _ = allocator;
        const self: *TestUsers = @ptrCast(@alignCast(raw));
        if (self.deleted or id != 1) return null;
        return .{ .id = 1, .name = "David <safe>", .bio = "Founder", .created_at = "2026-03-02 15:00:00", .updated_at = "2026-03-02 15:00:00" };
    }
};
test "stale mention IDs resolve real users and deleted mentions keep surrounding text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    var users: TestUsers = .{};
    const resolver: UserResolver = .{ .context = &users, .find = TestUsers.find };
    var secrets = try compat.Secrets.init(arena.allocator(), "native-richtext-test-secret-key-base");
    defer secrets.deinit();
    const ctx: Context = .{ .allocator = arena.allocator(), .users = resolver, .secrets = &secrets };
    const body = "<p>Hi <action-text-attachment sgid=\"" ++ test_sgid ++ "\" content-type=\"application/vnd.campfire.mention\"></action-text-attachment>, welcome</p>";
    try std.testing.expectEqual(@as(?i64, 1), try userIdFromSgid(ctx.allocator, test_sgid));
    const html = try renderContext(ctx, body);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"mention\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "David &lt;safe&gt;") != null);
    try std.testing.expectEqualStrings("Hi @David <safe>, welcome", try plainTextWithUsers(ctx.allocator, body, resolver));
    users.deleted = true;
    const missing = try renderContext(ctx, body);
    try std.testing.expect(std.mem.indexOf(u8, missing, "Hi ☒, welcome") != null);
}
test "nested content and remote image attachments sanitize actual parsed DOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const ctx: Context = .{ .allocator = arena.allocator() };
    const body = "<action-text-attachment content-type=\"text/html\" content=\"&lt;p onclick='x'&gt;inside &lt;a href='javascript:x'&gt;link&lt;/a&gt;&lt;/p&gt;\"></action-text-attachment>";
    const html = try renderContext(ctx, body);
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>inside <a>link</a></p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "onclick") == null);
    try expectPlain(body, "inside link");
    const image = try renderContext(ctx, "<action-text-attachment content-type=\"image/png\" url=\"javascript://x\" caption=\"&lt;script&gt;safe&lt;/script&gt;\"></action-text-attachment>");
    try std.testing.expect(std.mem.indexOf(u8, image, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, image, "&lt;script&gt;safe&lt;/script&gt;") != null);
    try std.testing.expectError(error.MissingAsset, renderContext(ctx, "<action-text-attachment content-type=\"image/png\" url=\"not-an-asset.png\"></action-text-attachment>"));
}
test "Gumbo parser refuses excessive nesting and per-tag attributes" {
    var out = Writer.Allocating.init(std.testing.allocator); defer out.deinit();
    for (0..401) |_| try out.writer.writeAll("<div>");
    try std.testing.expectError(error.TreeDepthExceeded, plainText(std.testing.allocator, out.written()));
    out.shrinkRetainingCapacity(0);
    try out.writer.writeAll("<b");
    for (0..401) |index| try out.writer.print(" a{d}=1", .{index});
    try out.writer.writeAll(">x</b>");
    try std.testing.expectError(error.TooManyAttributes, plainText(std.testing.allocator, out.written()));
}

test "canonical storage converts Trix JSON and drops attachment inner HTML" {
    const allocator = std.testing.allocator;
    const html = try canonicalize(allocator, " <figure data-trix-attachment='{\"contentType\":\"image/png\",\"url\":\"https://example.com/x.png\",\"caption\":\"Example\"}'><img src=x></figure><action-text-attachment caption=\"missing\"><script>not saved</script></action-text-attachment> ");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<action-text-attachment content-type=\"image/png\" url=\"https://example.com/x.png\" caption=\"Example\"></action-text-attachment><action-text-attachment caption=\"missing\"></action-text-attachment>", html);
}

test "solo unfurls rebuild validated details rather than accepting content markup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const ctx: Context = .{ .allocator = arena.allocator(), .host = "once.campfire.test" };
    const body = "<p><a href=\"https://example.com/launch\">https://example.com/launch</a></p><action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" content=\"&lt;actiontext-opengraph-embed data-controller='evil'&gt;&lt;div class='og-embed__title'&gt;&lt;a href='https://example.com/launch'&gt;Spring launch&lt;/a&gt;&lt;/div&gt;&lt;div class='og-embed__description'&gt;Launch details&lt;/div&gt;&lt;div class='og-embed__image'&gt;&lt;img src='https://example.com/launch.png' onerror='evil'&gt;&lt;/div&gt;&lt;/actiontext-opengraph-embed&gt;\"></action-text-attachment>";
    const html = try renderContext(ctx, body);
    try std.testing.expect(std.mem.indexOf(u8, html, ">https://example.com/launch</a>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Spring launch</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"og-embed__description\">Launch details") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-controller") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "onerror") == null);
    try std.testing.expectEqual(@as(?[]const u8, null), try webUrl(ctx, "https://once.campfire.test/rooms/1"));
    try std.testing.expectEqual(@as(?[]const u8, null), try webUrl(ctx, "http://127.0.0.1/avatar"));
}

test "adoption agency input is bounded and duplicate attributes are not unique" {
    var out = Writer.Allocating.init(std.testing.allocator); defer out.deinit();
    for (0..401) |_| try out.writer.writeAll("<a><b>");
    try std.testing.expectError(error.TreeDepthExceeded, plainText(std.testing.allocator, out.written()));
    out.shrinkRetainingCapacity(0);
    try out.writer.writeAll("<p");
    for (0..1000) |_| try out.writer.writeAll(" a=1");
    try out.writer.writeAll(">text</p>");
    try expectPlain(out.written(), "text");
}

test "base64 mention envelopes reject noncanonical padding and unused bits" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidSgid, decodeBase64(allocator, "QQ="));
    try std.testing.expectError(error.InvalidSgid, decodeBase64(allocator, "QR"));
    try std.testing.expectError(error.InvalidSgid, decodeBase64(allocator, "QQ======"));
}

test "nested content renders exactly eight levels without trusting its attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const allocator = arena.allocator();
    var body: []const u8 = "";
    var level: usize = 12;
    while (level > 0) : (level -= 1) {
        const content = try std.fmt.allocPrint(allocator, "<p>level {d}</p>{s}", .{level, body});
        var out = Writer.Allocating.init(allocator); defer out.deinit();
        try out.writer.writeAll("<action-text-attachment content-type=\"text/html\" content=\"");
        try escaped(&out.writer, content, true);
        try out.writer.writeAll("\"></action-text-attachment>");
        body = try out.toOwnedSlice();
    }
    const html = try renderContext(.{ .allocator = allocator }, body);
    for (1..13) |index| {
        const marker = try std.fmt.allocPrint(allocator, "level {d}<", .{index});
        try std.testing.expectEqual(index <= MAX_CONTENT_ATTACHMENT_DEPTH, std.mem.indexOf(u8, html, marker) != null);
    }
}
