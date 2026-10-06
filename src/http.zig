//! Native Campfire controller boundary; Rust/Rails remain comparison oracles only.
const std = @import("std");
const zix = @import("zix");
const model = @import("model.zig");
const database = @import("db.zig");
const compatibility = @import("compat.zig");
const time = @import("compat/time.zig");
const asset_module = @import("assets.zig");
const storage_module = @import("storage.zig");
const richtext = @import("richtext.zig");
const views = @import("views.zig");
const params = @import("params.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Http = zix.Http1;
const compression = zix.utils.compression;
const c = @import("c");

const Rate = struct { count: u64, expires: i64 };
pub const App = struct {
    allocator: Allocator,
    db: database.Database,
    secrets: compatibility.Secrets,
    assets: asset_module.Assets,
    storage: storage_module.Storage,
    force_ssl: bool,
    app_version: []const u8,
    vapid_public_key: ?[]const u8,
    rate_mutex: Io.Mutex = .init,
    rate_limits: std.StringArrayHashMapUnmanaged(Rate) = .empty,

    pub fn deinitRateLimits(self: *App) void {
        for (self.rate_limits.keys()) |key| self.allocator.free(key);
        self.rate_limits.deinit(self.allocator);
    }

    fn rateLimit(self: *App, io: Io, ip: []const u8, now: i64) !bool {
        try self.rate_mutex.lock(io);
        defer self.rate_mutex.unlock(io);
        var i: usize = 0;
        while (i < self.rate_limits.count()) {
            if (self.rate_limits.values()[i].expires <= now) {
                self.allocator.free(self.rate_limits.keys()[i]);
                self.rate_limits.swapRemoveAt(i);
            } else i += 1;
        }
        if (self.rate_limits.getPtr(ip)) |rate| {
            rate.count += 1;
            return rate.count > 10;
        }
        const key = try self.allocator.dupe(u8, ip);
        errdefer self.allocator.free(key);
        try self.rate_limits.put(self.allocator, key, .{ .count = 1, .expires = now + 180 });
        return false;
    }
};

// Set once before the worker fleet starts; the pointed-to app never moves.
pub var application: ?*App = null;

const Reply = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/html; charset=utf-8",
    body: []const u8 = "",
    cache_control: ?[]const u8 = "max-age=0, private, must-revalidate",
    etag: ?[]const u8 = null,
    last_modified: ?i64 = null,
    conditional: bool = true,
    content_length: ?usize = null,
    headers: []const storage_module.Header = &.{},
};

const Request = struct {
    app: *App,
    raw: *Http.Request,
    response: *Http.Response,
    allocator: Allocator,
    io: Io,
    method: []const u8,
    path: []const u8,
    base_url: []const u8,
    remote_ip: []const u8,
    secure: bool,
    now: []const u8,
    now_unix: i64,
    parameters: params.Map = .{},
    auth: ?model.AuthSession = null,

    fn get(self: *const Request) bool {
        return std.mem.eql(u8, self.method, "GET") or std.mem.eql(u8, self.method, "HEAD");
    }

    fn viewContext(self: *Request) views.Context {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .db = &self.app.db,
            .secrets = &self.app.secrets,
            .assets = &self.app.assets,
            .user = self.auth.?.user,
            .base_url = self.base_url,
            .path = self.path,
            .frame_id = self.raw.header("turbo-frame"),
            .user_agent = self.raw.header("user-agent") orelse "",
            .vapid_public_key = self.app.vapid_public_key,
            .app_version = self.app.app_version,
        };
    }

    fn redirect(self: *Request, path: []const u8) !Reply {
        const url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) path else try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        try self.response.addHeader("Location", url);
        var out = Io.Writer.Allocating.init(self.allocator);
        try out.writer.writeAll("<html><body>You are being <a href=\"");
        try compatibility.htmlEscape(&out.writer, url);
        try out.writer.writeAll("\">redirected</a>.</body></html>");
        return .{ .status = 302, .body = try out.toOwnedSlice(), .conditional = false };
    }

    fn cookie(self: *Request, name: []const u8, value: []const u8, http_only: bool, expires: ?i64) !void {
        const suffix = if (expires) |at| try std.fmt.allocPrint(self.allocator, "; expires={s}", .{try httpDate(self.allocator, at)}) else "";
        const line = try std.fmt.allocPrint(self.allocator, "{s}={s}; path=/; SameSite=Lax{s}{s}{s}", .{
            name, value, suffix, if (http_only) "; HttpOnly" else "", if (self.secure) "; Secure" else "",
        });
        try self.response.addHeader("Set-Cookie", line);
    }

    fn deleteCookie(self: *Request, name: []const u8) !void {
        try self.response.addHeader("Set-Cookie", try std.fmt.allocPrint(self.allocator, "{s}=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT; SameSite=Lax", .{name}));
    }

    fn sessionState(self: *Request) !std.json.ObjectMap {
        if (cookieValue(self.raw.header("cookie"), "_campfire_session")) |wire| {
            if (try self.app.secrets.decryptCookie(self.allocator, "_campfire_session", wire, self.now_unix)) |value| {
                if (value == .object) return value.object;
            }
        }
        return std.json.ObjectMap.init(self.allocator);
    }

    fn saveState(self: *Request, state: *std.json.ObjectMap) !void {
        if (state.count() == 0 or (state.count() == 1 and state.contains("session_id"))) return self.deleteCookie("_campfire_session");
        if (!state.contains("session_id")) {
            var bytes: [16]u8 = undefined;
            try self.io.randomSecure(&bytes);
            try state.put("session_id", .{ .string = try std.fmt.allocPrint(self.allocator, "{x}", .{&bytes}) });
        }
        const expires = try compatibility.permanentExpires(self.now_unix);
        const wire = try self.app.secrets.encryptCookie(self.allocator, self.io, "_campfire_session", .{ .object = state.* }, expires);
        return self.cookie("_campfire_session", wire, true, expires);
    }

    fn login(self: *Request, status: u16, alert: ?[]const u8) !Reply {
        if (!accepts(self.raw, "text/html")) return error.NotAcceptable;
        const account = try self.app.db.account(self.allocator, self.io);
        return .{ .status = status, .body = try views.login(self.allocator, &self.app.assets, account, alert, .{
            .base_url = self.base_url,
            .app_version = self.app.app_version,
            .vapid_public_key = self.app.vapid_public_key,
            .email_address = self.parameters.str("email_address"),
        }) };
    }
};

pub fn handle(raw: *Http.Request, response: *Http.Response, context: *Http.Context) !void {
    const app = application orelse return error.ApplicationUnavailable;
    const allocator = context.allocator;
    const now = try compatibility.nowText(allocator, context.io);
    const secure = app.force_ssl or isSecure(raw);
    var request: Request = .{
        .app = app,
        .raw = raw,
        .response = response,
        .allocator = allocator,
        .io = context.io,
        .method = raw.head.method,
        .path = raw.path(),
        .base_url = try baseUrl(allocator, raw, secure),
        .remote_ip = try remoteIp(allocator, raw),
        .secure = secure,
        .now = now,
        .now_unix = try compatibility.unixSeconds(now),
    };
    const reply = dispatch(&request) catch |err| failure(err);
    try finish(&request, reply);
}

fn dispatch(r: *Request) !Reply {
    if (std.mem.eql(u8, r.path, "/up") and r.get()) return .{ .content_type = "text/plain; charset=utf-8", .body = "OK", .conditional = false };
    if (r.get()) {
        if (r.app.assets.lookup(r.path)) |asset| return .{ .body = asset.body, .content_type = asset.content_type, .cache_control = "public, max-age=31536000, immutable" };
        const fullpath = if (r.raw.query().len == 0) r.path else try std.fmt.allocPrint(r.allocator, "{s}?{s}", .{ r.path, r.raw.query() });
        if (try r.app.storage.handle(r.allocator, r.io, .{ .method = r.method, .path = fullpath, .range = r.raw.header("range"), .if_none_match = r.raw.header("if-none-match"), .if_modified_since = r.raw.header("if-modified-since"), .now = r.now_unix })) |stored| return storedReply(stored);
    }
    if (!r.get() and try r.app.db.banned(r.io, r.remote_ip)) return .{ .status = 429, .conditional = false };
    if (cookieValue(r.raw.header("cookie"), "session_token")) |wire| {
        if (try r.app.secrets.verifyCookie(r.allocator, "session_token", wire, r.now_unix)) |token| {
            r.auth = try r.app.db.findSession(r.allocator, r.io, token);
        }
    }
    const session_new = std.mem.eql(u8, r.path, "/session/new") and r.get();
    const session_create = std.mem.eql(u8, r.path, "/session") and std.mem.eql(u8, r.method, "POST");
    const public_logo = std.mem.eql(u8, r.path, "/account/logo") and r.get();
    if (!session_new and !session_create and !public_logo and r.auth == null) {
        var state = try r.sessionState();
        const fullpath = if (r.raw.query().len == 0) r.path else try std.fmt.allocPrint(r.allocator, "{s}?{s}", .{ r.path, r.raw.query() });
        try state.put("return_to_after_authenticating", .{ .string = try std.fmt.allocPrint(r.allocator, "{s}{s}", .{ r.base_url, fullpath }) });
        try r.saveState(&state);
        return r.redirect("/session/new");
    }
    if (r.auth) |auth| {
        const last = try time.parse(auth.last_active_at);
        const now = try time.parse(r.now);
        if (now.seconds > last.seconds + 3600 or (now.seconds == last.seconds + 3600 and now.nanos > last.nanos)) {
            try r.app.db.refreshSession(r.io, auth.id, r.remote_ip, r.raw.header("user-agent"), r.now);
            const expires = try compatibility.permanentExpires(r.now_unix);
            const wire = try r.app.secrets.signCookie(r.allocator, "session_token", auth.token, expires);
            try r.cookie("session_token", wire, true, expires);
        }
    }
    if (!originAllowed(r.method, r.base_url, r.raw.header("origin"), r.raw.header("sec-fetch-site"), r.secure)) return error.InvalidAuthenticityToken;
    r.parameters = try requestParameters(r);
    if (std.mem.eql(u8, r.method, "POST")) {
        if (r.parameters.str("_method")) |override| {
            if (std.ascii.eqlIgnoreCase(override, "DELETE")) r.method = "DELETE" else if (std.ascii.eqlIgnoreCase(override, "PATCH")) r.method = "PATCH" else if (std.ascii.eqlIgnoreCase(override, "PUT")) r.method = "PUT";
        }
    }
    if (session_new) {
        var state = try r.sessionState();
        var alert: ?[]const u8 = null;
        if (state.get("flash")) |flash| if (flash == .object) {
            if (flash.object.get("flashes")) |flashes| {
                if (flashes == .object) alert = jsonString(flashes.object.get("alert"));
            }
            _ = state.swapRemove("flash");
            try r.saveState(&state);
        };
        return r.login(200, alert);
    }
    if (session_create) {
        if (try r.app.rateLimit(r.io, r.remote_ip, r.now_unix)) return r.login(429, "Too many requests or unauthorized.");
        const email = r.parameters.str("email_address");
        const password = r.parameters.str("password");
        var user: ?model.User = null;
        if (email != null and password != null and std.mem.trim(u8, email.?, " \t\r\n").len != 0 and password.?.len != 0) {
            user = try r.app.db.findUserByEmail(r.allocator, r.io, email.?);
            const digest = if (user) |found| found.password_digest else null;
            const verified = r.io.blocking(compatibility.checkCandidatePassword, .{ password.?, digest });
            if (!verified or (user != null and user.?.status != 0)) user = null;
        }
        if (user == null) return r.login(401, "Too many requests or unauthorized.");
        const token = try sessionToken(r.allocator, r.io);
        _ = try r.app.db.createSession(r.allocator, r.io, user.?.id, token, r.remote_ip, r.raw.header("user-agent"), r.now);
        const expires = try compatibility.permanentExpires(r.now_unix);
        try r.cookie("session_token", try r.app.secrets.signCookie(r.allocator, "session_token", token, expires), true, expires);
        var state = try r.sessionState();
        const return_to = jsonString(state.get("return_to_after_authenticating")) orelse "/";
        _ = state.swapRemove("return_to_after_authenticating");
        if (state.contains("flash")) _ = state.swapRemove("flash");
        try r.saveState(&state);
        return r.redirect(return_to);
    }
    if (public_logo) {
        const account = try r.app.db.account(r.allocator, r.io);
        const small = std.mem.eql(u8, r.parameters.str("size") orelse "", "small");
        if (account.logo) |blob| if (try r.app.storage.logo(r.allocator, r.io, blob, if (small) 192 else 512, r.now_unix)) |result| return storedReply(result);
        const path = r.app.assets.assetPath(if (small) "logos/app-icon-192.png" else "logos/app-icon.png") orelse return error.NotFound;
        const asset = r.app.assets.lookup(path) orelse return error.NotFound;
        return .{ .body = asset.body, .content_type = asset.content_type, .cache_control = "public, max-age=300, stale-while-revalidate=604800" };
    }
    const user = r.auth.?.user;
    if (std.mem.eql(u8, r.path, "/session") and std.mem.eql(u8, r.method, "DELETE")) {
        try r.app.db.deleteSession(r.io, r.auth.?.token);
        try r.deleteCookie("session_token");
        try r.deleteCookie("_campfire_session");
        return r.redirect("/");
    }
    if (std.mem.eql(u8, r.path, "/") and r.get()) {
        const room = try r.app.db.visitedRoom(r.allocator, r.io, user.id, lastRoom(r));
        if (room) |found| return r.redirect(try std.fmt.allocPrint(r.allocator, "/rooms/{d}", .{found.id}));
        var context = r.viewContext();
        return .{ .body = try views.welcome(&context) };
    }
    if (std.mem.eql(u8, r.path, "/users/me/sidebar") and r.get()) {
        if (!accepts(r.raw, "text/html")) return error.NotAcceptable;
        const page = try r.app.db.sidebar(r.allocator, r.io, user.id);
        var context = r.viewContext();
        return .{ .body = try views.sidebar(&context, page) };
    }
    if (std.mem.eql(u8, r.path, "/searches") or std.mem.eql(u8, r.path, "/searches/clear")) {
        const q = if (r.parameters.get("q")) |value| switch (value) {
            .null => null,
            .string => |s| s,
            else => return error.InvalidSearchQuery,
        } else null;
        const page = try r.app.db.search(r.allocator, r.io, user.id, q, lastRoom(r));
        if (std.mem.eql(u8, r.path, "/searches") and r.get()) {
            if (!accepts(r.raw, "text/html")) return error.NotAcceptable;
            var context = r.viewContext();
            return .{ .body = try views.search(&context, page) };
        }
        if (std.mem.eql(u8, r.path, "/searches") and std.mem.eql(u8, r.method, "POST")) {
            const recorded = q orelse return error.InvalidSearchQuery;
            const normalized = try r.app.db.recordSearch(r.allocator, r.io, user.id, recorded, r.now);
            return r.redirect(try std.fmt.allocPrint(r.allocator, "/searches?q={s}", .{try compatibility.urlEncode(r.allocator, normalized)}));
        }
        if (std.mem.eql(u8, r.path, "/searches/clear") and std.mem.eql(u8, r.method, "DELETE")) {
            try r.app.db.clearSearch(r.io, user.id);
            return r.redirect("/searches");
        }
        return error.NotFound;
    }
    if (std.mem.startsWith(u8, r.path, "/users/") and std.mem.endsWith(u8, r.path, "/avatar") and r.get()) {
        const raw_token = r.path[7 .. r.path.len - "/avatar".len];
        const token = try decodePath(r.allocator, raw_token);
        const id = try r.app.secrets.verifySignedId(r.allocator, token, "user/avatar", r.now_unix) orelse return error.NotFound;
        const avatar_user = try r.app.db.findUser(r.allocator, r.io, id) orelse return error.NotFound;
        if (try r.app.storage.avatar(r.allocator, r.io, avatar_user, r.now_unix)) |result| return storedReply(result);
        if (avatar_user.isBot()) {
            const path = r.app.assets.assetPath("default-bot-avatar.svg") orelse return error.NotFound;
            const asset = r.app.assets.lookup(path) orelse return error.NotFound;
            return .{ .body = asset.body, .content_type = asset.content_type, .cache_control = "public, max-age=1800, stale-while-revalidate=604800" };
        }
        return .{ .body = try views.avatarSvg(r.allocator, avatar_user), .content_type = "image/svg+xml; charset=utf-8", .cache_control = "public, max-age=1800, stale-while-revalidate=604800" };
    }
    if (std.mem.startsWith(u8, r.path, "/rooms/")) {
        const tail = r.path[7..];
        const slash = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
        const room_id = integerCast(tail[0..slash]) orelse return error.NotFound;
        const action = tail[slash..];
        if ((action.len == 0 or std.mem.startsWith(u8, action, "/@")) and r.get()) {
            if (!accepts(r.raw, "text/html")) return error.NotAcceptable;
            const anchor = if (action.len != 0) integerCast(action[2..]) else integerCast(r.parameters.str("message_id") orelse "");
            const page = r.app.db.roomPage(r.allocator, r.io, user.id, room_id, anchor) catch |err| {
                if (err == error.NotFound) return roomNotFound(r);
                return err;
            };
            const existing = cookieValue(r.raw.header("cookie"), "last_room");
            const room_text = try std.fmt.allocPrint(r.allocator, "{d}", .{room_id});
            if (existing == null or !std.mem.eql(u8, existing.?, room_text)) try r.cookie("last_room", room_text, false, try compatibility.permanentExpires(r.now_unix));
            var context = r.viewContext();
            return .{ .body = try views.room(&context, page) };
        }
        if (std.mem.eql(u8, action, "/messages") and r.get()) {
            if (!accepts(r.raw, "text/html")) return error.NotAcceptable;
            const before = try pageAnchor(r.parameters.get("before"));
            const after = if (before == null) try pageAnchor(r.parameters.get("after")) else null;
            const messages = try r.app.db.messagePage(r.allocator, r.io, user.id, room_id, before, after);
            if (messages.len == 0) return .{ .status = 204, .conditional = false };
            var context = r.viewContext();
            var modified: i64 = 0;
            for (messages) |message| modified = @max(modified, try compatibility.unixSeconds(message.updated_at));
            return .{ .body = try views.messages(&context, messages), .last_modified = modified };
        }
        if (std.mem.eql(u8, action, "/messages") and std.mem.eql(u8, r.method, "POST")) {
            if (!accepts(r.raw, "text/vnd.turbo-stream.html")) return error.NotAcceptable;
            const message = r.parameters.get("message") orelse return error.ParameterMissing;
            if (message == .null or (message == .string and message.string.len == 0) or (message == .object and message.object.entries.count() == 0)) return error.ParameterMissing;
            if (message != .object) return error.InvalidMessageParameter;
            if (message.get("attachment")) |attachment| {
                if (attachment == .file) return .{ .status = 501, .content_type = "text/plain; charset=utf-8", .body = "Native file uploads are not implemented.", .conditional = false };
                if (attachment != .null and (attachment != .string or attachment.string.len != 0)) return error.InvalidAttachment;
            }
            const raw_body = if (message.get("body")) |body| body.str() else null;
            const canonical: ?[]const u8 = if (raw_body) |body| richtext.canonicalize(r.allocator, body) catch try r.allocator.dupe(u8, body) else null;
            const client_id = if (message.get("client_message_id")) |id| id.str() else null;
            const created = r.app.db.createMessage(r.allocator, r.io, user.id, room_id, canonical, client_id, r.now) catch |err| {
                if (err == error.NotFound) {
                    var context = r.viewContext();
                    return .{ .body = try views.roomNotFound(&context), .conditional = false };
                }
                return err;
            };
            var context = r.viewContext();
            return .{ .body = try views.created(&context, created), .content_type = "text/vnd.turbo-stream.html; charset=utf-8", .conditional = false };
        }
    }
    if (std.mem.eql(u8, r.path, "/cable")) return .{ .status = 501, .content_type = "text/plain; charset=utf-8", .body = "Cable is outside the native leaderboard target.", .conditional = false };
    return error.NotFound;
}

fn storedReply(stored: storage_module.Result) Reply {
    var length: ?usize = null;
    for (stored.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) length = std.fmt.parseInt(usize, header.value, 10) catch null;
    }
    return .{ .status = stored.status, .content_type = stored.content_type, .body = stored.body, .headers = stored.headers, .cache_control = null, .conditional = false, .content_length = length };
}

fn roomNotFound(r: *Request) !Reply {
    var state = try r.sessionState();
    var flashes = std.json.ObjectMap.init(r.allocator);
    try flashes.put("alert", .{ .string = "Room not found or inaccessible" });
    var flash = std.json.ObjectMap.init(r.allocator);
    try flash.put("discard", .{ .array = std.array_list.Managed(std.json.Value).init(r.allocator) });
    try flash.put("flashes", .{ .object = flashes });
    try state.put("flash", .{ .object = flash });
    try r.saveState(&state);
    return r.redirect("/");
}

fn requestParameters(r: *Request) !params.Map {
    var result: params.Map = .{};
    const body = try r.raw.body();
    if (!r.raw.bodyComplete()) return error.InvalidBody;
    // The engine must never discard part of a form and let the controller accept the prefix.
    if (r.raw.header("transfer-encoding") == null and r.raw.bodyReceived() != body.len) return error.BodyTooLarge;
    if (body.len != 0) {
        const content_type = r.raw.header("content-type") orelse "";
        const mime = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
        if (std.ascii.eqlIgnoreCase(mime, "application/x-www-form-urlencoded")) result = try params.form(r.allocator, body, true) else if (std.ascii.eqlIgnoreCase(mime, "application/json")) result = try params.json(r.allocator, body) else if (std.ascii.eqlIgnoreCase(mime, "multipart/form-data")) result = try params.multipart(r.allocator, content_type, body);
    }
    try result.merge(r.allocator, try params.form(r.allocator, r.raw.query(), false));
    return result;
}

fn finish(r: *Request, original: Reply) !void {
    var reply = original;
    var entity = reply.body;
    var tag = reply.etag;
    if (tag == null and reply.status == 200 and reply.conditional) {
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(entity, &digest, .{});
        tag = try std.fmt.allocPrint(r.allocator, "W/\"{x}\"", .{&digest});
    }
    if (r.get() and reply.status == 200 and reply.conditional) {
        const fresh = if (r.raw.header("if-none-match")) |given| if (tag) |etag| etagMatches(given, etag) else false else if (r.raw.header("if-modified-since")) |given| if (reply.last_modified) |modified| std.mem.eql(u8, given, try httpDate(r.allocator, modified)) else false else false;
        if (fresh) {
            reply.status = 304;
            entity = "";
        }
    }
    if (reply.status == 204 or reply.status == 304) entity = "";
    const encoding = compression.negotiate(r.raw.header("accept-encoding"), &compression.supported_default) orelse {
        reply.status = 406;
        reply.content_type = "text/plain; charset=utf-8";
        entity = "Not Acceptable";
        return finishUnencoded(r, reply, entity, null, tag);
    };
    if (encoding != .IDENTITY and reply.status != 204 and reply.status != 304 and compression.shouldCompress(entity.len, reply.content_type, 256)) {
        const compressed = try compression.encode(r.allocator, encoding, entity, .DEFAULT);
        if (compressed.len < entity.len) return finishUnencoded(r, reply, compressed, encoding.contentEncoding(), tag);
    }
    try finishUnencoded(r, reply, entity, null, tag);
}

fn finishUnencoded(r: *Request, reply: Reply, entity: []const u8, encoding: ?[]const u8, tag: ?[]const u8) !void {
    var header = Io.Writer.Allocating.init(r.allocator);
    try header.writer.print("HTTP/1.1 {d} {s}\r\n", .{ reply.status, reason(reply.status) });
    try header.writer.print("Content-Type: {s}\r\n", .{reply.content_type});
    try header.writer.print("Content-Length: {d}\r\n", .{reply.content_length orelse entity.len});
    try header.writer.print("Date: {s}\r\n", .{try httpDate(r.allocator, r.now_unix)});
    try header.writer.writeAll("X-Content-Type-Options: nosniff\r\nX-Frame-Options: SAMEORIGIN\r\nReferrer-Policy: strict-origin-when-cross-origin\r\n");
    if (reply.cache_control) |cache| try header.writer.print("Cache-Control: {s}\r\n", .{cache});
    if (tag) |etag| try header.writer.print("ETag: {s}\r\n", .{etag});
    if (reply.last_modified) |at| try header.writer.print("Last-Modified: {s}\r\n", .{try httpDate(r.allocator, at)});
    if (encoding) |coding| try header.writer.print("Content-Encoding: {s}\r\nVary: Accept-Encoding\r\n", .{coding});
    if (r.response.extra_buf) |headers| for (headers[0..r.response.extra_len]) |h| try header.writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    for (reply.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-length") or std.ascii.eqlIgnoreCase(h.name, "content-type")) continue;
        try header.writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    if (r.raw.header("connection")) |connection| if (std.ascii.eqlIgnoreCase(connection, "close")) try header.writer.writeAll("Connection: close\r\n");
    try header.writer.writeAll("\r\n");
    r.response.status = @fromBackingInt(@intCast(reply.status));
    try r.response.sendRaw(header.written());
    if (!std.mem.eql(u8, r.method, "HEAD") and reply.status != 204 and reply.status != 304) try Http.writeAllFD(r.response.fd, entity);
    r.response.bytes_written = if (std.mem.eql(u8, r.method, "HEAD")) 0 else entity.len;
}

fn failure(err: anyerror) Reply {
    return switch (err) {
        error.NotFound => .{ .status = 404, .content_type = "text/plain; charset=utf-8", .body = "Not Found", .conditional = false },
        error.Unauthorized => .{ .status = 403, .content_type = "text/plain; charset=utf-8", .body = "Forbidden", .conditional = false },
        error.NotAcceptable => .{ .status = 406, .content_type = "text/plain; charset=utf-8", .body = "Not Acceptable", .conditional = false },
        error.InvalidAuthenticityToken => .{ .status = 422, .content_type = "text/plain; charset=utf-8", .body = "Invalid authenticity token", .conditional = false },
        error.BodyTooLarge => .{ .status = 413, .content_type = "text/plain; charset=utf-8", .body = "Payload Too Large", .conditional = false },
        error.ParameterMissing, error.InvalidEncoding, error.ParameterType, error.TooDeep, error.TooManyParameters, error.InvalidBody => .{ .status = 400, .content_type = "text/plain; charset=utf-8", .body = "Bad Request", .conditional = false },
        else => blk: {
            std.log.err("native Campfire request: {s}", .{@errorName(err)});
            break :blk .{ .status = 500, .content_type = "text/plain; charset=utf-8", .body = "Internal Server Error", .conditional = false };
        },
    };
}

fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        204 => "No Content",
        206 => "Partial Content",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        406 => "Not Acceptable",
        413 => "Payload Too Large",
        416 => "Range Not Satisfiable",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        501 => "Not Implemented",
        else => "Internal Server Error",
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    return if (value) |v| if (v == .string) v.string else null else null;
}

fn cookieValue(header: ?[]const u8, name: []const u8) ?[]const u8 {
    var cookies = std.mem.splitScalar(u8, header orelse return null, ';');
    while (cookies.next()) |raw| {
        const cookie = std.mem.trim(u8, raw, " \t");
        const equal = std.mem.indexOfScalar(u8, cookie, '=') orelse continue;
        if (std.mem.eql(u8, cookie[0..equal], name)) return cookie[equal + 1 ..];
    }
    return null;
}

fn lastRoom(r: *Request) ?i64 {
    return integerCast(cookieValue(r.raw.header("cookie"), "last_room") orelse "");
}

fn integerCast(input: []const u8) ?i64 {
    const text = std.mem.trimStart(u8, input, " \t\r\n\x0b\x0c");
    var end: usize = if (text.len != 0 and (text[0] == '+' or text[0] == '-')) 1 else 0;
    const start = end;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, text[0..end], 10) catch null;
}

fn pageAnchor(value: ?params.Value) !?i64 {
    const v = value orelse return null;
    return switch (v) {
        .null => null,
        .string => |text| if (std.mem.trim(u8, text, " \t\r\n").len == 0) null else integerCast(text) orelse error.NotFound,
        else => error.NotFound,
    };
}

fn sessionToken(allocator: Allocator, io: Io) ![]const u8 {
    const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    const token = try allocator.alloc(u8, 24);
    var at: usize = 0;
    while (at < token.len) {
        var random: [32]u8 = undefined;
        try io.randomSecure(&random);
        for (random) |byte| {
            if (byte >= 232) continue; // rejection avoids modulo bias
            token[at] = alphabet[byte % 58];
            at += 1;
            if (at == token.len) break;
        }
    }
    return token;
}

fn originAllowed(method: []const u8, base: []const u8, origin: ?[]const u8, fetch_site: ?[]const u8, secure: bool) bool {
    if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) return true;
    if (origin) |given| if (std.mem.eql(u8, given, "null") or !std.mem.eql(u8, given, base)) return false;
    if (fetch_site) |site| return std.mem.eql(u8, site, "same-origin") or std.mem.eql(u8, site, "same-site");
    return !secure;
}

fn accepts(raw: *Http.Request, mime: []const u8) bool {
    const accept = raw.header("accept") orelse return true;
    if (accept.len == 0 or std.mem.indexOf(u8, accept, "*/*") != null) return true;
    var types = std.mem.splitScalar(u8, accept, ',');
    while (types.next()) |part| {
        const bare = std.mem.trim(u8, part[0 .. std.mem.indexOfScalar(u8, part, ';') orelse part.len], " \t");
        if (std.ascii.eqlIgnoreCase(bare, mime)) return true;
    }
    return false;
}

fn isSecure(raw: *Http.Request) bool {
    if (raw.header("x-forwarded-ssl")) |value| if (std.mem.eql(u8, value, "on")) return true;
    for ([_][]const u8{ "x-forwarded-proto", "x-forwarded-scheme" }) |name| {
        if (raw.header(name)) |value| {
            var parts = std.mem.tokenizeAny(u8, value, ", \t");
            var last: ?[]const u8 = null;
            while (parts.next()) |part| if (std.mem.eql(u8, part, "http") or std.mem.eql(u8, part, "https") or std.mem.eql(u8, part, "ws") or std.mem.eql(u8, part, "wss")) {
                last = part;
            };
            if (last) |scheme| return std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "wss");
        }
    }
    return false;
}

fn baseUrl(allocator: Allocator, raw: *Http.Request, secure: bool) ![]const u8 {
    var host = raw.header("host") orelse return error.InvalidBody;
    if (raw.header("x-forwarded-host")) |forwarded| {
        var values = std.mem.tokenizeAny(u8, forwarded, ", \t");
        while (values.next()) |value| host = value;
    }
    if (host.len == 0 or std.mem.indexOfAny(u8, host, "\r\n \t/\\@#?\x00") != null) return error.InvalidBody;
    return std.fmt.allocPrint(allocator, "{s}://{s}", .{ if (secure) "https" else "http", host });
}

fn remoteIp(allocator: Allocator, raw: *Http.Request) ![]const u8 {
    var address: std.Io.Threaded.PosixAddress = undefined;
    var length: std.posix.socklen_t = @sizeOf(@TypeOf(address));
    try std.posix.getpeername(raw.fd, &address.any, &length);
    const peer = std.Io.Threaded.addressFromPosix(&address);
    var forwarded: std.ArrayList(Io.net.IpAddress) = .empty;
    var client: std.ArrayList(Io.net.IpAddress) = .empty;
    if (raw.header("x-forwarded-for")) |value| try parseIps(allocator, &forwarded, value);
    if (raw.header("client-ip")) |value| try parseIps(allocator, &client, value);
    if (forwarded.items.len != 0 and client.items.len != 0) {
        var included = false;
        for (forwarded.items) |ip| if (ip.eql(&client.items[0])) {
            included = true;
            break;
        };
        if (!included) return error.IpSpoofAttack;
    }
    var chosen: ?Io.net.IpAddress = null;
    var i = forwarded.items.len;
    while (i > 0) {
        i -= 1;
        if (!trusted(forwarded.items[i])) {
            chosen = forwarded.items[i];
            break;
        }
    }
    if (chosen == null) {
        i = client.items.len;
        while (i > 0) {
            i -= 1;
            if (!trusted(client.items[i])) {
                chosen = client.items[i];
                break;
            }
        }
    }
    if (chosen == null and !trusted(peer)) chosen = peer;
    if (chosen == null) chosen = if (client.items.len != 0) client.items[0] else if (forwarded.items.len != 0) forwarded.items[0] else peer;
    var out = Io.Writer.Allocating.init(allocator);
    switch (chosen.?) {
        .ip4 => |ip| try out.writer.print("{d}.{d}.{d}.{d}", .{ ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3] }),
        .ip6 => |ip| {
            var no_port = ip;
            no_port.port = 0;
            try no_port.format(&out.writer);
        },
    }
    return out.toOwnedSlice();
}

fn parseIps(allocator: Allocator, ips: *std.ArrayList(Io.net.IpAddress), value: []const u8) !void {
    var parts = std.mem.tokenizeAny(u8, value, ", \t");
    while (parts.next()) |part| {
        const ip = Io.net.IpAddress.parse(std.mem.trim(u8, part, "[]"), 0) catch continue;
        try ips.append(allocator, ip);
    }
}

fn trusted(ip: Io.net.IpAddress) bool {
    return switch (ip) {
        .ip4 => |v| v.bytes[0] == 127 or v.bytes[0] == 10 or (v.bytes[0] == 172 and v.bytes[1] >= 16 and v.bytes[1] <= 31) or (v.bytes[0] == 192 and v.bytes[1] == 168) or (v.bytes[0] == 169 and v.bytes[1] == 254),
        .ip6 => |v| (std.mem.allEqual(u8, v.bytes[0..15], 0) and v.bytes[15] == 1) or (v.bytes[0] & 0xfe) == 0xfc or (v.bytes[0] == 0xfe and (v.bytes[1] & 0xc0) == 0x80),
    };
}

fn decodePath(allocator: Allocator, text: []const u8) ![]const u8 {
    // A path '+' is literal, not the form-encoded space handled by ParamBuilder.
    const escaped = try std.mem.replaceOwned(u8, allocator, text, "+", "%2B");
    return params.decode(allocator, escaped);
}

fn httpDate(allocator: Allocator, seconds: i64) ![]const u8 {
    var stamp: c.time_t = @intCast(seconds);
    var tm: c.struct_tm = undefined;
    if (c.gmtime_r(&stamp, &tm) == null) return error.InvalidTimestamp;
    var buffer: [40]u8 = undefined;
    const length = c.strftime(&buffer, buffer.len, "%a, %d %b %Y %H:%M:%S GMT", &tm);
    if (length == 0) return error.InvalidTimestamp;
    return allocator.dupe(u8, buffer[0..length]);
}

fn etagMatches(header: []const u8, tag: []const u8) bool {
    var values = std.mem.splitScalar(u8, header, ',');
    const expected = if (std.mem.startsWith(u8, tag, "W/")) tag[2..] else tag;
    while (values.next()) |raw| {
        const value = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, value, "*")) return true;
        const candidate = if (std.mem.startsWith(u8, value, "W/")) value[2..] else value;
        if (std.mem.eql(u8, candidate, expected)) return true;
    }
    return false;
}

test "header-only CSRF rejects hostile origins and secure requests missing Fetch Metadata" {
    try std.testing.expect(originAllowed("GET", "http://campfire.test", "null", "cross-site", false));
    try std.testing.expect(originAllowed("POST", "http://campfire.test", "http://campfire.test", null, false));
    try std.testing.expect(!originAllowed("POST", "https://campfire.test", "https://campfire.test", null, true));
    try std.testing.expect(!originAllowed("POST", "http://campfire.test", "null", "same-origin", false));
    try std.testing.expect(!originAllowed("POST", "http://campfire.test", "http://evil.test", "same-origin", false));
    try std.testing.expect(!originAllowed("POST", "http://campfire.test", null, "cross-site", false));
    try std.testing.expect(originAllowed("POST", "https://campfire.test", "https://campfire.test", "same-origin", true));
}

test "pagination present malformed anchors fail instead of silently falling back to last page" {
    try std.testing.expectEqual(@as(?i64, null), try pageAnchor(.{ .string = " " }));
    try std.testing.expectEqual(@as(?i64, 123), try pageAnchor(.{ .string = "123tail" }));
    try std.testing.expectError(error.NotFound, pageAnchor(.{ .string = "bad" }));
    try std.testing.expectError(error.NotFound, pageAnchor(.{ .object = .{} }));
    try std.testing.expect(etagMatches("\"other\", W/\"same\"", "\"same\""));
    try std.testing.expect(!etagMatches("W/\"other\"", "W/\"same\""));
}
