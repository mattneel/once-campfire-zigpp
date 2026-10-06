//! SQLite snapshots and serialized writes over the unchanged Rails schema.
const std = @import("std");
const model = @import("model.zig");
const compat = @import("compat.zig");
const richtext = @import("richtext.zig");
const schema = @import("db/schema.zig");
const words = @import("db/word_ranges.zig").ranges;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const c = @import("c");

pub const Error = error{ NotFound, Unauthorized, InvalidMessage, InvalidParam, DatabaseBusy, DatabaseConstraint, DatabaseCorrupt, DatabaseIo, DatabaseFailure, PendingMigrations };
pub const NewBlob = struct {
    key: []const u8,
    filename: []const u8,
    content_type: ?[]const u8 = null,
    byte_size: i64,
    checksum: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
    service_name: []const u8,
};
const Value = union(enum) { integer: i64, text: []const u8, null };
fn int(n: i64) Value {
    return .{ .integer = n };
}
fn text(s: []const u8) Value {
    return .{ .text = s };
}
fn optional(s: ?[]const u8) Value {
    return if (s) |v| text(v) else .null;
}
const Conn = *c.sqlite3;
const Reader = struct { conn: Conn, busy: bool = false };
const migrations = [_][]const u8{ "20231215043540", "20231220143106", "20240110071740", "20240115124901", "20240130003150", "20240130213001", "20240131105830", "20240209110503", "20250825100957", "20250825100958", "20250825100959", "20251126092013", "20251126115722", "20251126130131", "20251212154340" };
const user_columns = "u.id,u.name,u.bio,u.email_address,u.password_digest,u.role,u.status,u.created_at,u.updated_at";
const room_columns = "r.id,r.type,r.creator_id,r.name,r.created_at,r.updated_at";
const blob_columns = "b.id,b.key,b.filename,b.content_type,b.byte_size,b.checksum,b.metadata,b.service_name,b.created_at";
const message_select = "SELECT m.id,m.client_message_id,m.room_id,m.created_at,m.updated_at,COALESCE(t.body,'')," ++ user_columns ++ "," ++ room_columns ++ ",a.blob_id FROM messages m JOIN users u ON u.id=m.creator_id JOIN rooms r ON r.id=m.room_id LEFT JOIN action_text_rich_texts t ON t.record_type='Message' AND t.record_id=m.id AND t.name='body' LEFT JOIN active_storage_attachments a ON a.id=(SELECT id FROM active_storage_attachments WHERE record_type='Message' AND record_id=m.id AND name='attachment' LIMIT 1) ";

pub const Database = struct {
    allocator: Allocator,
    io: Io,
    writer: Conn,
    readers: []Reader,
    writer_mutex: Io.Mutex = .init,
    pool_mutex: Io.Mutex = .init,
    available: Io.Condition = .init,

    pub fn init(allocator: Allocator, io: Io, path: []const u8, readers: usize) !Database {
        const now = try compat.nowText(allocator, io);
        defer allocator.free(now);
        return io.blocking(initIn, .{ allocator, io, path, readers, now });
    }

    fn initIn(allocator: Allocator, io: Io, path: []const u8, readers: usize, now: []const u8) !Database {
        if (readers == 0 or path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.eql(u8, path, ":memory:")) return error.InvalidParam;
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);
        const writer = try open(path_z);
        errdefer _ = c.sqlite3_close(writer);
        const filename = c.sqlite3_db_filename(writer, "main");
        if (filename == null or std.mem.span(filename).len == 0) return error.InvalidParam;
        try prepareSchema(writer, now);
        const pool = try allocator.alloc(Reader, readers);
        errdefer allocator.free(pool);
        var opened: usize = 0;
        errdefer {
            for (pool[0..opened]) |r| _ = c.sqlite3_close(r.conn);
        }
        for (pool) |*r| {
            r.* = .{ .conn = try open(path_z) };
            opened += 1;
            try exec(r.conn, "PRAGMA query_only=ON", &.{});
        }
        return .{ .allocator = allocator, .io = io, .writer = writer, .readers = pool };
    }

    /// Application must finish all requests before closing.
    pub fn deinit(self: *Database) void {
        self.io.blocking(deinitIn, .{self});
    }
    fn deinitIn(self: *Database) void {
        for (self.readers) |r| _ = c.sqlite3_close(r.conn);
        _ = c.sqlite3_close(self.writer);
        self.allocator.free(self.readers);
        self.* = undefined;
    }

    fn acquire(self: *Database, io: Io) !usize {
        try self.pool_mutex.lock(io);
        defer self.pool_mutex.unlock(io);
        while (true) {
            for (self.readers, 0..) |*r, i| {
                if (!r.busy) {
                    r.busy = true;
                    return i;
                }
            }
            try self.available.wait(io, &self.pool_mutex);
        }
    }

    fn release(self: *Database, io: Io, i: usize) void {
        self.pool_mutex.lockUncancelable(io);
        defer self.pool_mutex.unlock(io);
        self.readers[i].busy = false;
        self.available.signal(io);
    }

    pub fn account(self: *Database, allocator: Allocator, io: Io) !model.Account {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, accountIn, .{ allocator, self.readers[i].conn });
    }

    pub fn findSession(self: *Database, allocator: Allocator, io: Io, token: []const u8) !?model.AuthSession {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, sessionIn, .{ allocator, self.readers[i].conn, token });
    }

    pub fn findUserByEmail(self: *Database, allocator: Allocator, io: Io, email: []const u8) !?model.User {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, userByEmailIn, .{ allocator, self.readers[i].conn, email });
    }

    pub fn findUser(self: *Database, allocator: Allocator, io: Io, id: i64) !?model.User {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, userIn, .{ allocator, self.readers[i].conn, id });
    }

    pub fn createSession(self: *Database, allocator: Allocator, io: Io, user_id: i64, token: []const u8, remote_ip: ?[]const u8, user_agent: ?[]const u8, now: []const u8) !model.AuthSession {
        try self.writer_mutex.lock(io);
        defer self.writer_mutex.unlock(io);
        return io.blocking(createSessionIn, .{ self, allocator, user_id, token, remote_ip, user_agent, now });
    }
    fn createSessionIn(self: *Database, allocator: Allocator, user_id: i64, token: []const u8, remote_ip: ?[]const u8, user_agent: ?[]const u8, now: []const u8) !model.AuthSession {
        try exec(self.writer, "BEGIN IMMEDIATE", &.{});
        errdefer rollback(self.writer);
        try active(self.writer, user_id);
        try exec(self.writer, "INSERT INTO sessions(user_id,token,ip_address,user_agent,created_at,updated_at,last_active_at) VALUES(?,?,?,?,?,?,?)", &.{ int(user_id), text(token), optional(remote_ip), optional(user_agent), text(now), text(now), text(now) });
        const session = (try sessionIn(allocator, self.writer, token)) orelse return error.Unauthorized;
        try exec(self.writer, "COMMIT", &.{});
        return session;
    }

    pub fn deleteSession(self: *Database, io: Io, token: []const u8) !void {
        try self.writer_mutex.lock(io);
        defer self.writer_mutex.unlock(io);
        return io.blocking(deleteSessionIn, .{ self, token });
    }
    fn deleteSessionIn(self: *Database, token: []const u8) !void {
        try exec(self.writer, "BEGIN IMMEDIATE", &.{});
        errdefer rollback(self.writer);
        try exec(self.writer, "DELETE FROM sessions WHERE token=?", &.{text(token)});
        try exec(self.writer, "COMMIT", &.{});
    }

    pub fn refreshSession(self: *Database, io: Io, id: i64, remote_ip: ?[]const u8, user_agent: ?[]const u8, now: []const u8) !void {
        try self.writer_mutex.lock(io);
        defer self.writer_mutex.unlock(io);
        return io.blocking(refreshSessionIn, .{ self, id, remote_ip, user_agent, now });
    }
    fn refreshSessionIn(self: *Database, id: i64, remote_ip: ?[]const u8, user_agent: ?[]const u8, now: []const u8) !void {
        try exec(self.writer, "BEGIN IMMEDIATE", &.{});
        errdefer rollback(self.writer);
        var s = try Statement.init(self.writer, "SELECT last_active_at FROM sessions WHERE id=?", &.{int(id)});
        defer s.deinit();
        if (!try s.next()) return error.NotFound;
        const threshold = try subtractSeconds(self.allocator, now, 3600);
        defer self.allocator.free(threshold);
        if (std.mem.order(u8, s.bytes(0), threshold) == .lt) try exec(self.writer, "UPDATE sessions SET ip_address=?,user_agent=?,last_active_at=?,updated_at=? WHERE id=?", &.{ optional(remote_ip), optional(user_agent), text(now), text(now), int(id) });
        try exec(self.writer, "COMMIT", &.{});
    }

    pub fn visitedRoom(self: *Database, allocator: Allocator, io: Io, user_id: i64, last_room: ?i64) !?model.Room {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, visitedRoomIn, .{ allocator, self.readers[i].conn, user_id, last_room });
    }

    pub fn banned(self: *Database, io: Io, remote_ip: []const u8) !bool {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, exists, .{ self.readers[i].conn, "SELECT 1 FROM bans WHERE ip_address=? LIMIT 1", &.{text(remote_ip)} });
    }

    pub fn roomPage(self: *Database, allocator: Allocator, io: Io, user_id: i64, room_id: i64, around_message: ?i64) !model.RoomPage {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, roomPageIn, .{ allocator, self.readers[i].conn, user_id, room_id, around_message });
    }
    fn roomPageIn(allocator: Allocator, conn: Conn, user_id: i64, room_id: i64, around_message: ?i64) !model.RoomPage {
        try access(conn, user_id, room_id);
        const user = (try userIn(allocator, conn, user_id)) orelse return error.Unauthorized;
        const room = (try roomWhere(allocator, conn, user_id, "WHERE r.id=?", &.{int(room_id)})) orelse return error.NotFound;
        var messages: []model.Message = undefined;
        if (around_message) |anchor| {
            if (try anchorTime(allocator, conn, room_id, anchor)) |at| {
                var list: std.ArrayList(model.Message) = .empty;
                try list.appendSlice(allocator, try pageIn(allocator, conn, room_id, .before, at));
                const middle = try messageWhere(allocator, conn, "WHERE m.room_id=? AND m.id=?", &.{ int(room_id), int(anchor) }, false);
                try list.appendSlice(allocator, middle);
                try list.appendSlice(allocator, try pageIn(allocator, conn, room_id, .after, at));
                messages = try list.toOwnedSlice(allocator);
            } else messages = try pageIn(allocator, conn, room_id, .last, null);
        } else messages = try pageIn(allocator, conn, room_id, .last, null);
        const original = try exists(conn, "SELECT 1 FROM rooms WHERE id=? AND id=(SELECT id FROM rooms ORDER BY created_at ASC LIMIT 1)", &.{int(room_id)});
        const paged = try exists(conn, "SELECT 1 FROM messages WHERE room_id=? LIMIT 1 OFFSET 40", &.{int(room_id)});
        return .{ .account = try accountIn(allocator, conn), .room = room, .user = user, .messages = messages, .invitation = original and !paged };
    }

    pub fn messagePage(self: *Database, allocator: Allocator, io: Io, user_id: i64, room_id: i64, before: ?i64, after: ?i64) ![]model.Message {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, messagePageIn, .{ allocator, self.readers[i].conn, user_id, room_id, before, after });
    }
    fn messagePageIn(allocator: Allocator, conn: Conn, user_id: i64, room_id: i64, before: ?i64, after: ?i64) ![]model.Message {
        try access(conn, user_id, room_id);
        if (before orelse after) |anchor| {
            const at = (try anchorTime(allocator, conn, room_id, anchor)) orelse return error.NotFound;
            return pageIn(allocator, conn, room_id, if (before != null) .before else .after, at);
        }
        return pageIn(allocator, conn, room_id, .last, null);
    }

    pub fn sidebar(self: *Database, allocator: Allocator, io: Io, user_id: i64) !model.Sidebar {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, sidebarIn, .{ allocator, self.readers[i].conn, user_id });
    }
    fn sidebarIn(allocator: Allocator, conn: Conn, user_id: i64) !model.Sidebar {
        try active(conn, user_id);
        const user = (try userIn(allocator, conn, user_id)) orelse return error.Unauthorized;
        var s = try Statement.init(conn, "SELECT " ++ room_columns ++ ",p.involvement,p.unread_at,p.updated_at FROM memberships p JOIN rooms r ON r.id=p.room_id WHERE p.user_id=? AND p.involvement!='invisible' ORDER BY LOWER(r.name)", &.{int(user_id)});
        defer s.deinit();
        var shared: std.ArrayList(model.SidebarRoom) = .empty;
        var directs: std.ArrayList(model.SidebarRoom) = .empty;
        while (try s.next()) {
            const room = try readRoom(allocator, conn, &s, 0, user_id);
            var item: model.SidebarRoom = .{ .room = room, .involvement = try s.string(allocator, 6), .unread_at = try s.nullable(allocator, 7), .membership_updated_at = try s.string(allocator, 8) };
            if (room.kind == .direct) {
                var members = try usersInRoom(allocator, conn, room.id, user_id);
                if (members.len == 0) members = try allocator.dupe(model.User, &.{user});
                item.users = members;
                try directs.append(allocator, item);
            } else try shared.append(allocator, item);
        }
        // Rust's stable sort then reverse reverses ties too, including the initial room order.
        std.mem.sort(model.SidebarRoom, directs.items, {}, struct {
            fn less(_: void, a: model.SidebarRoom, b: model.SidebarRoom) bool {
                return std.mem.order(u8, a.room.updated_at, b.room.updated_at) == .lt;
            }
        }.less);
        std.mem.reverse(model.SidebarRoom, directs.items);
        const placeholders = try placeholderUsers(allocator, conn, user_id);
        return .{ .account = try accountIn(allocator, conn), .user = user, .shared = try shared.toOwnedSlice(allocator), .directs = try directs.toOwnedSlice(allocator), .direct_placeholder_users = placeholders };
    }

    pub fn search(self: *Database, allocator: Allocator, io: Io, user_id: i64, q: ?[]const u8, return_room_id: ?i64) !model.SearchPage {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, searchIn, .{ allocator, self.readers[i].conn, user_id, q, return_room_id });
    }
    fn searchIn(allocator: Allocator, conn: Conn, user_id: i64, q: ?[]const u8, return_room_id: ?i64) !model.SearchPage {
        try active(conn, user_id);
        const sanitized = if (q) |raw| try sanitizeQuery(allocator, raw) else null;
        const query: ?[]const u8 = if (sanitized) |v| (if (blank(v)) null else v) else null;
        var messages: []model.Message = &.{};
        if (query) |v| {
            const terms = try matchTerms(allocator, v);
            if (terms.len != 0) messages = try messageWhere(allocator, conn, "JOIN memberships p ON p.room_id=r.id JOIN message_search_index idx ON idx.rowid=m.id WHERE p.user_id=? AND idx.body MATCH ? ORDER BY m.created_at DESC LIMIT 100", &.{ int(user_id), text(terms) }, true);
        }
        var recent: std.ArrayList([]const u8) = .empty;
        var s = try Statement.init(conn, "SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC", &.{int(user_id)});
        defer s.deinit();
        while (try s.next()) try recent.append(allocator, try s.string(allocator, 0));
        var back: i64 = 0;
        if (return_room_id) |id| {
            if (try exists(conn, "SELECT 1 FROM rooms r JOIN memberships p ON p.room_id=r.id WHERE p.user_id=? AND r.id=?", &.{ int(user_id), int(id) })) back = id;
        }
        if (back == 0) {
            var r = try Statement.init(conn, "SELECT r.id FROM rooms r JOIN memberships p ON p.room_id=r.id WHERE p.user_id=? ORDER BY r.created_at ASC LIMIT 1", &.{int(user_id)});
            defer r.deinit();
            if (try r.next()) back = r.integer(0);
        }
        return .{ .account = try accountIn(allocator, conn), .user = (try userIn(allocator, conn, user_id)) orelse return error.Unauthorized, .q = if (q) |v| try allocator.dupe(u8, v) else null, .query = query, .messages = messages, .recent_searches = try recent.toOwnedSlice(allocator), .return_to_room_id = back };
    }

    pub fn recordSearch(self: *Database, allocator: Allocator, io: Io, user_id: i64, q: []const u8, now: []const u8) ![]const u8 {
        const query = try sanitizeQuery(allocator, q);
        try self.writer_mutex.lock(io);
        defer self.writer_mutex.unlock(io);
        try io.blocking(recordSearchIn, .{ self, user_id, query, now });
        return query;
    }
    fn recordSearchIn(self: *Database, user_id: i64, query: []const u8, now: []const u8) !void {
        try exec(self.writer, "BEGIN IMMEDIATE", &.{});
        errdefer rollback(self.writer);
        try active(self.writer, user_id);
        var s = try Statement.init(self.writer, "SELECT id FROM searches WHERE user_id=? AND query=? LIMIT 1", &.{ int(user_id), text(query) });
        defer s.deinit();
        if (try s.next()) {
            try exec(self.writer, "UPDATE searches SET updated_at=? WHERE id=?", &.{ text(now), int(s.integer(0)) });
        } else {
            try exec(self.writer, "INSERT INTO searches(user_id,query,created_at,updated_at) VALUES(?,?,?,?)", &.{ int(user_id), text(query), text(now), text(now) });
            try exec(self.writer, "DELETE FROM searches WHERE user_id=? AND id NOT IN (SELECT id FROM searches WHERE user_id=? ORDER BY updated_at DESC LIMIT 10)", &.{ int(user_id), int(user_id) });
        }
        try exec(self.writer, "COMMIT", &.{});
    }

    pub fn clearSearch(self: *Database, io: Io, user_id: i64) !void {
        try self.writer_mutex.lock(io);
        defer self.writer_mutex.unlock(io);
        return io.blocking(clearSearchIn, .{ self, user_id });
    }
    fn clearSearchIn(self: *Database, user_id: i64) !void {
        try exec(self.writer, "BEGIN IMMEDIATE", &.{});
        errdefer rollback(self.writer);
        try active(self.writer, user_id);
        try exec(self.writer, "DELETE FROM searches WHERE user_id=?", &.{int(user_id)});
        try exec(self.writer, "COMMIT", &.{});
    }

    pub fn createMessage(self: *Database, allocator: Allocator, io: Io, user_id: i64, room_id: i64, body: ?[]const u8, client_message_id: ?[]const u8, now: []const u8) !model.Message {
        const client_id = client_message_id orelse try uuid(allocator, io);
        try self.writer_mutex.lock(io);
        defer self.writer_mutex.unlock(io);
        return io.blocking(createMessageIn, .{ self, allocator, user_id, room_id, body, client_id, now });
    }
    fn createMessageIn(self: *Database, allocator: Allocator, user_id: i64, room_id: i64, body: ?[]const u8, client_id: []const u8, now: []const u8) !model.Message {
        const conn = self.writer;
        try exec(conn, "BEGIN IMMEDIATE", &.{});
        errdefer rollback(conn);
        try access(conn, user_id, room_id);
        // Rails accepts empty bodies; do not invent a nonempty validation.
        try exec(conn, "INSERT INTO messages(client_message_id,creator_id,room_id,created_at,updated_at) VALUES(?,?,?,?,?)", &.{ text(client_id), int(user_id), int(room_id), text(now), text(now) });
        const id = c.sqlite3_last_insert_rowid(conn);
        if (body) |html| try exec(conn, "INSERT INTO action_text_rich_texts(record_type,record_id,name,body,created_at,updated_at) VALUES('Message',?,'body',?,?,?)", &.{ int(id), text(html), text(now), text(now) });
        try exec(conn, "UPDATE rooms SET updated_at=? WHERE id=?", &.{ text(now), int(room_id) });
        const created = try messageWhere(allocator, conn, "WHERE m.id=?", &.{int(id)}, false);
        if (created.len != 1) return error.DatabaseCorrupt;
        try exec(conn, "COMMIT", &.{});
        // Source after_create_commit callbacks intentionally follow commit, in this order.
        const indexed = if (body) |html| richtext.plainTextWithUsers(allocator, html, .{ .context = conn, .find = resolveUser }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMessage,
        } else "";
        try exec(conn, "INSERT INTO message_search_index(rowid,body) VALUES(?,?)", &.{ int(id), text(indexed) });
        try exec(conn, "UPDATE memberships SET unread_at=?,updated_at=? WHERE room_id=? AND involvement!='invisible' AND (connected_at IS NULL OR connected_at<?) AND user_id!=?", &.{ text(now), text(now), int(room_id), text(try cutoff(allocator, now)), int(user_id) });
        return created[0];
    }

    pub fn avatar(self: *Database, allocator: Allocator, io: Io, user_id: i64) !?model.Blob {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, attachedBlob, .{ allocator, self.readers[i].conn, "User", user_id, "avatar" });
    }

    pub fn blob(self: *Database, allocator: Allocator, io: Io, id: i64) !?model.Blob {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, blobIn, .{ allocator, self.readers[i].conn, id });
    }

    pub fn existingVariant(self: *Database, allocator: Allocator, io: Io, blob_id: i64, digest: []const u8) !?model.Blob {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, existingVariantIn, .{ allocator, self.readers[i].conn, blob_id, digest });
    }
    fn existingVariantIn(allocator: Allocator, conn: Conn, blob_id: i64, digest: []const u8) !?model.Blob {
        const id = (try variantRecord(conn, blob_id, digest)) orelse return null;
        return attachedBlob(allocator, conn, "ActiveStorage::VariantRecord", id, "image");
    }
    pub fn existingPreview(self: *Database, allocator: Allocator, io: Io, blob_id: i64) !?model.Blob {
        const i = try self.acquire(io);
        defer self.release(io, i);
        return readCall(io, self.readers[i].conn, attachedBlob, .{ allocator, self.readers[i].conn, "ActiveStorage::Blob", blob_id, "preview_image" });
    }
    pub fn recordVariant(self: *Database, allocator: Allocator, io: Io, blob_id: i64, digest: []const u8, image: NewBlob, now: []const u8) !model.Blob {
        return self.recordImage(allocator, io, blob_id, digest, image, now);
    }
    pub fn recordPreview(self: *Database, allocator: Allocator, io: Io, blob_id: i64, image: NewBlob, now: []const u8) !model.Blob {
        return self.recordImage(allocator, io, blob_id, null, image, now);
    }
    fn recordImage(self: *Database, allocator: Allocator, io: Io, blob_id: i64, digest: ?[]const u8, image: NewBlob, now: []const u8) !model.Blob {
        try self.writer_mutex.lock(io);
        defer self.writer_mutex.unlock(io);
        return io.blocking(recordImageIn, .{ self, allocator, blob_id, digest, image, now });
    }
    fn recordImageIn(self: *Database, allocator: Allocator, blob_id: i64, digest: ?[]const u8, image: NewBlob, now: []const u8) !model.Blob {
        const conn = self.writer;
        try exec(conn, "BEGIN IMMEDIATE", &.{});
        errdefer rollback(conn);
        if (!try exists(conn, "SELECT 1 FROM active_storage_blobs WHERE id=?", &.{int(blob_id)})) return error.NotFound;
        var record_id = blob_id;
        const record_type: []const u8 = if (digest != null) "ActiveStorage::VariantRecord" else "ActiveStorage::Blob";
        const name: []const u8 = if (digest != null) "image" else "preview_image";
        if (digest) |d| {
            if (try variantRecord(conn, blob_id, d)) |id| {
                const winner = (try attachedBlob(allocator, conn, record_type, id, name)) orelse return error.NotFound;
                try exec(conn, "COMMIT", &.{});
                return winner;
            }
            try exec(conn, "INSERT INTO active_storage_variant_records(blob_id,variation_digest) VALUES(?,?)", &.{ int(blob_id), text(d) });
            record_id = c.sqlite3_last_insert_rowid(conn);
        } else if (try attachedBlob(allocator, conn, record_type, record_id, name)) |winner| {
            try exec(conn, "COMMIT", &.{});
            return winner;
        }
        try exec(conn, "INSERT INTO active_storage_blobs(key,filename,content_type,byte_size,checksum,metadata,service_name,created_at) VALUES(?,?,?,?,?,?,?,?)", &.{ text(image.key), text(image.filename), optional(image.content_type), int(image.byte_size), optional(image.checksum), optional(image.metadata), text(image.service_name), text(now) });
        const image_id = c.sqlite3_last_insert_rowid(conn);
        try exec(conn, "INSERT INTO active_storage_attachments(record_type,record_id,name,blob_id,created_at) VALUES(?,?,?,?,?)", &.{ text(record_type), int(record_id), text(name), int(image_id), text(now) });
        const recorded = (try blobIn(allocator, conn, image_id)) orelse return error.DatabaseCorrupt;
        try exec(conn, "COMMIT", &.{});
        return recorded;
    }
};

/// The pool lease and fiber locks stay on the task; snapshot and SQLite work share one
/// blocking dispatch, including cleanup, so WAL/FS/busy waits cannot occupy Threadz workers.
fn readCall(io: Io, conn: Conn, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    const Args = std.meta.ArgsTuple(@TypeOf(function));
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    return io.blocking(struct {
        fn run(db: Conn, params: Args) Result {
            try exec(db, "BEGIN", &.{});
            defer rollback(db);
            return @call(.auto, function, params);
        }
    }.run, .{ conn, args });
}

fn userByEmailIn(allocator: Allocator, conn: Conn, email: []const u8) !?model.User {
    return userWhere(allocator, conn, "u.email_address=?", &.{text(email)});
}

fn failure(conn: Conn, code: c_int) Error {
    std.log.err("SQLite ({d}): {s}", .{ code, std.mem.span(c.sqlite3_errmsg(conn)) });
    return switch (code & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.DatabaseBusy,
        c.SQLITE_CONSTRAINT => error.DatabaseConstraint,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.DatabaseCorrupt,
        c.SQLITE_IOERR, c.SQLITE_CANTOPEN, c.SQLITE_READONLY, c.SQLITE_FULL => error.DatabaseIo,
        else => error.DatabaseFailure,
    };
}

const Statement = struct {
    conn: Conn,
    raw: *c.sqlite3_stmt,
    fn init(conn: Conn, sql: [:0]const u8, values: []const Value) !Statement {
        var raw: ?*c.sqlite3_stmt = null;
        const code = c.sqlite3_prepare_v2(conn, sql.ptr, @intCast(sql.len), &raw, null);
        if (code != c.SQLITE_OK) return failure(conn, code);
        const stmt = raw orelse return error.DatabaseFailure;
        errdefer _ = c.sqlite3_finalize(stmt);
        if (@as(usize, @intCast(c.sqlite3_bind_parameter_count(stmt))) != values.len) return error.InvalidParam;
        for (values, 1..) |v, i| {
            const result = switch (v) {
                .integer => |n| c.sqlite3_bind_int64(stmt, @intCast(i), n),
                // Borrowed until finalize; callers keep every bound slice alive for that scope.
                .text => |s| c.sqlite3_bind_text(stmt, @intCast(i), s.ptr, @intCast(s.len), null),
                .null => c.sqlite3_bind_null(stmt, @intCast(i)),
            };
            if (result != c.SQLITE_OK) return failure(conn, result);
        }
        return .{ .conn = conn, .raw = stmt };
    }
    fn deinit(s: *Statement) void {
        _ = c.sqlite3_finalize(s.raw);
    }
    fn next(s: *Statement) !bool {
        const result = c.sqlite3_step(s.raw);
        return switch (result) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => failure(s.conn, result),
        };
    }
    fn integer(s: *Statement, column: c_int) i64 {
        return c.sqlite3_column_int64(s.raw, column);
    }
    fn bytes(s: *Statement, column: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(s.raw, column);
        if (ptr == null) return "";
        return ptr[0..@intCast(c.sqlite3_column_bytes(s.raw, column))];
    }
    fn string(s: *Statement, allocator: Allocator, column: c_int) ![]const u8 {
        return allocator.dupe(u8, s.bytes(column));
    }
    fn nullable(s: *Statement, allocator: Allocator, column: c_int) !?[]const u8 {
        if (c.sqlite3_column_type(s.raw, column) == c.SQLITE_NULL) return null;
        return s.string(allocator, column);
    }
};

fn exec(conn: Conn, sql: [:0]const u8, values: []const Value) !void {
    var s = try Statement.init(conn, sql, values);
    defer s.deinit();
    while (try s.next()) {}
}
fn rollback(conn: Conn) void {
    _ = c.sqlite3_exec(conn, "ROLLBACK", null, null, null);
}
fn exists(conn: Conn, sql: [:0]const u8, values: []const Value) !bool {
    var s = try Statement.init(conn, sql, values);
    defer s.deinit();
    return s.next();
}
fn open(path: [:0]const u8) !Conn {
    var conn: ?Conn = null;
    const code = c.sqlite3_open_v2(path.ptr, &conn, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX | c.SQLITE_OPEN_URI, null);
    const db = conn orelse return error.DatabaseIo;
    errdefer _ = c.sqlite3_close(db);
    if (code != c.SQLITE_OK) return failure(db, code);
    _ = c.sqlite3_extended_result_codes(db, 1);
    const timeout_code = c.sqlite3_busy_timeout(db, 5000);
    if (timeout_code != c.SQLITE_OK) return failure(db, timeout_code);
    for ([_][:0]const u8{ "PRAGMA foreign_keys=ON", "PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL", "PRAGMA journal_size_limit=67108864", "PRAGMA cache_size=2000" }) |sql| try exec(db, sql, &.{});
    return db;
}
fn prepareSchema(conn: Conn, now: []const u8) !void {
    if (!try exists(conn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_migrations'", &.{})) {
        try exec(conn, "BEGIN IMMEDIATE", &.{});
        errdefer rollback(conn);
        const code = c.sqlite3_exec(conn, schema.sql.ptr, null, null, null);
        if (code != c.SQLITE_OK) return failure(conn, code);
        var n = migrations.len;
        while (n > 0) {
            n -= 1;
            try exec(conn, "INSERT INTO schema_migrations(version) VALUES(?)", &.{text(migrations[n])});
        }
        try exec(conn, "INSERT INTO ar_internal_metadata(key,value,created_at,updated_at) VALUES('environment','production',?,?),('schema_sha1','f75da8dad38bfb179ffd757bd7a7c2b3f818bc29',?,?)", &.{ text(now), text(now), text(now), text(now) });
        try exec(conn, "COMMIT", &.{});
    } else {
        for (migrations) |v| if (!try exists(conn, "SELECT 1 FROM schema_migrations WHERE version=?", &.{text(v)})) return error.PendingMigrations;
    }
    try exec(conn, "CREATE INDEX IF NOT EXISTS index_messages_on_room_id_and_created_at ON messages(room_id,created_at)", &.{});
}
fn active(conn: Conn, user_id: i64) !void {
    if (!try exists(conn, "SELECT 1 FROM users WHERE id=? AND status=0", &.{int(user_id)})) return error.Unauthorized;
}
fn access(conn: Conn, user_id: i64, room_id: i64) !void {
    try active(conn, user_id);
    // Open and invisible rooms still require a real membership; administrator isn't a bypass.
    if (!try exists(conn, "SELECT 1 FROM rooms r JOIN memberships p ON p.room_id=r.id WHERE p.user_id=? AND r.id=?", &.{ int(user_id), int(room_id) })) return error.NotFound;
}
fn accountIn(allocator: Allocator, conn: Conn) !model.Account {
    var s = try Statement.init(conn, "SELECT id,name,join_code,custom_styles,settings,created_at,updated_at FROM accounts ORDER BY id ASC LIMIT 1", &.{});
    defer s.deinit();
    if (!try s.next()) return error.NotFound;
    const id = s.integer(0);
    return .{ .id = id, .name = try s.string(allocator, 1), .join_code = try s.string(allocator, 2), .custom_styles = try s.nullable(allocator, 3), .settings = try s.nullable(allocator, 4), .created_at = try s.string(allocator, 5), .updated_at = try s.string(allocator, 6), .logo = try attachedBlob(allocator, conn, "Account", id, "logo"), .help_contact = try firstAdministrator(allocator, conn) };
}
fn firstAdministrator(allocator: Allocator, conn: Conn) !?model.User {
    var s = try Statement.init(conn, "SELECT " ++ user_columns ++ " FROM users u WHERE u.role=1 ORDER BY u.id ASC LIMIT 1", &.{});
    defer s.deinit();
    if (!try s.next()) return null;
    return readUser(allocator, conn, &s, 0);
}
fn readUser(allocator: Allocator, conn: Conn, s: *Statement, offset: c_int) !model.User {
    const id = s.integer(offset);
    return .{ .id = id, .name = try s.string(allocator, offset + 1), .bio = try s.nullable(allocator, offset + 2), .email_address = try s.nullable(allocator, offset + 3), .password_digest = try s.nullable(allocator, offset + 4), .role = s.integer(offset + 5), .status = s.integer(offset + 6), .created_at = try s.string(allocator, offset + 7), .updated_at = try s.string(allocator, offset + 8), .avatar = try attachedBlob(allocator, conn, "User", id, "avatar") };
}
fn userWhere(allocator: Allocator, conn: Conn, comptime clause: []const u8, values: []const Value) !?model.User {
    var s = try Statement.init(conn, "SELECT " ++ user_columns ++ " FROM users u WHERE " ++ clause ++ " LIMIT 1", values);
    defer s.deinit();
    if (!try s.next()) return null;
    return readUser(allocator, conn, &s, 0);
}
fn userIn(allocator: Allocator, conn: Conn, id: i64) !?model.User {
    return userWhere(allocator, conn, "u.id=?", &.{int(id)});
}
fn resolveUser(context: *anyopaque, allocator: Allocator, id: i64) anyerror!?model.User {
    return userIn(allocator, @ptrCast(@alignCast(context)), id);
}
fn sessionIn(allocator: Allocator, conn: Conn, token: []const u8) !?model.AuthSession {
    var s = try Statement.init(conn, "SELECT s.id,s.token,s.created_at,s.updated_at,s.last_active_at," ++ user_columns ++ " FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND u.status=0 LIMIT 1", &.{text(token)});
    defer s.deinit();
    if (!try s.next()) return null;
    return .{ .id = s.integer(0), .token = try s.string(allocator, 1), .created_at = try s.string(allocator, 2), .updated_at = try s.string(allocator, 3), .last_active_at = try s.string(allocator, 4), .user = try readUser(allocator, conn, &s, 5) };
}
fn kind(name: []const u8) !model.RoomKind {
    if (std.mem.eql(u8, name, "Rooms::Open")) return .open;
    if (std.mem.eql(u8, name, "Rooms::Closed")) return .closed;
    if (std.mem.eql(u8, name, "Rooms::Direct")) return .direct;
    return error.DatabaseCorrupt;
}
fn readRoom(allocator: Allocator, conn: Conn, s: *Statement, offset: c_int, user_id: i64) !model.Room {
    var room: model.Room = .{ .id = s.integer(offset), .kind = try kind(s.bytes(offset + 1)), .creator_id = s.integer(offset + 2), .name = try s.nullable(allocator, offset + 3), .created_at = try s.string(allocator, offset + 4), .updated_at = try s.string(allocator, offset + 5), .display_name = "" };
    room.display_name = room.name orelse "";
    if (room.kind == .direct) {
        const users = try usersInRoom(allocator, conn, room.id, user_id);
        var name: std.ArrayList(u8) = .empty;
        for (users, 0..) |u, i| {
            if (i > 0) try name.appendSlice(allocator, if (users.len == 2) " and " else if (i == users.len - 1) ", and " else ", ");
            try name.appendSlice(allocator, u.name);
        }
        room.display_name = try name.toOwnedSlice(allocator);
        if (blank(room.display_name)) room.display_name = if (try userIn(allocator, conn, user_id)) |u| u.name else "";
    }
    return room;
}
fn roomWhere(allocator: Allocator, conn: Conn, user_id: i64, comptime clause: []const u8, values: []const Value) !?model.Room {
    var s = try Statement.init(conn, "SELECT " ++ room_columns ++ " FROM rooms r " ++ clause, values);
    defer s.deinit();
    if (!try s.next()) return null;
    return readRoom(allocator, conn, &s, 0, user_id);
}
fn visitedRoomIn(allocator: Allocator, conn: Conn, user_id: i64, last_room: ?i64) !?model.Room {
    try active(conn, user_id);
    if (last_room) |id| {
        if (try roomWhere(allocator, conn, user_id, "JOIN memberships p ON p.room_id=r.id WHERE p.user_id=? AND r.id=? LIMIT 1", &.{ int(user_id), int(id) })) |room| return room;
    }
    return roomWhere(allocator, conn, user_id, "JOIN memberships p ON p.room_id=r.id WHERE p.user_id=? ORDER BY r.created_at ASC LIMIT 1", &.{int(user_id)});
}
fn usersInRoom(allocator: Allocator, conn: Conn, room_id: i64, excluding: i64) ![]model.User {
    var s = try Statement.init(conn, "SELECT " ++ user_columns ++ " FROM users u JOIN memberships p ON p.user_id=u.id WHERE p.room_id=? AND u.id!=?", &.{ int(room_id), int(excluding) });
    defer s.deinit();
    var list: std.ArrayList(model.User) = .empty;
    while (try s.next()) try list.append(allocator, try readUser(allocator, conn, &s, 0));
    return list.toOwnedSlice(allocator);
}
fn placeholderUsers(allocator: Allocator, conn: Conn, user_id: i64) ![]model.User {
    var s = try Statement.init(conn, "SELECT DISTINCT p.user_id FROM memberships p JOIN rooms r ON r.id=p.room_id WHERE r.type='Rooms::Direct' AND r.id IN(SELECT room_id FROM memberships WHERE user_id=?)", &.{int(user_id)});
    defer s.deinit();
    var count: i64 = 1;
    while (try s.next()) count += 1;
    var u = try Statement.init(conn, "SELECT " ++ user_columns ++ " FROM users u WHERE u.status=0 AND u.id!=? AND u.id NOT IN(SELECT p.user_id FROM memberships p JOIN rooms r ON r.id=p.room_id WHERE r.type='Rooms::Direct' AND r.id IN(SELECT room_id FROM memberships WHERE user_id=?)) ORDER BY u.created_at ASC LIMIT ?", &.{ int(user_id), int(user_id), int(@max(20 - count, 0)) });
    defer u.deinit();
    var list: std.ArrayList(model.User) = .empty;
    while (try u.next()) try list.append(allocator, try readUser(allocator, conn, &u, 0));
    return list.toOwnedSlice(allocator);
}
fn readBlob(allocator: Allocator, s: *Statement) !model.Blob {
    return .{ .id = s.integer(0), .key = try s.string(allocator, 1), .filename = try s.string(allocator, 2), .content_type = try s.nullable(allocator, 3), .byte_size = s.integer(4), .checksum = try s.nullable(allocator, 5), .metadata = try s.nullable(allocator, 6), .service_name = try s.string(allocator, 7), .created_at = try s.string(allocator, 8) };
}
fn blobIn(allocator: Allocator, conn: Conn, id: i64) !?model.Blob {
    var s = try Statement.init(conn, "SELECT " ++ blob_columns ++ " FROM active_storage_blobs b WHERE b.id=? LIMIT 1", &.{int(id)});
    defer s.deinit();
    if (!try s.next()) return null;
    return readBlob(allocator, &s);
}
fn variantRecord(conn: Conn, blob_id: i64, digest: []const u8) !?i64 {
    var s = try Statement.init(conn, "SELECT id FROM active_storage_variant_records WHERE blob_id=? AND variation_digest=? LIMIT 1", &.{ int(blob_id), text(digest) });
    defer s.deinit();
    if (!try s.next()) return null;
    return s.integer(0);
}
fn attachedBlob(allocator: Allocator, conn: Conn, record_type: []const u8, id: i64, name: []const u8) !?model.Blob {
    var s = try Statement.init(conn, "SELECT " ++ blob_columns ++ " FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type=? AND a.record_id=? AND a.name=? LIMIT 1", &.{ text(record_type), int(id), text(name) });
    defer s.deinit();
    if (!try s.next()) return null;
    return readBlob(allocator, &s);
}
fn messageWhere(allocator: Allocator, conn: Conn, comptime clause: []const u8, values: []const Value, reverse: bool) ![]model.Message {
    var s = try Statement.init(conn, message_select ++ clause, values);
    defer s.deinit();
    var list: std.ArrayList(model.Message) = .empty;
    while (try s.next()) {
        const id = s.integer(0);
        const room_kind = try kind(s.bytes(16));
        const creator = found: {
            for (list.items) |previous| if (previous.creator.id == s.integer(6)) break :found previous.creator;
            break :found try readUser(allocator, conn, &s, 6);
        };
        const attachment = if (c.sqlite3_column_type(s.raw, 21) == c.SQLITE_NULL) null else try blobIn(allocator, conn, s.integer(21));
        const room_name = found: {
            for (list.items) |previous| if (previous.room_id == s.integer(2)) break :found previous.room_name;
            if (room_kind == .direct) break :found (try readRoom(allocator, conn, &s, 15, -1)).display_name;
            break :found (try s.nullable(allocator, 18)) orelse "";
        };
        try list.append(allocator, .{ .id = id, .client_message_id = try s.string(allocator, 1), .room_id = s.integer(2), .created_at = try s.string(allocator, 3), .updated_at = try s.string(allocator, 4), .body = try s.string(allocator, 5), .creator = creator, .room_kind = room_kind, .room_name = room_name, .attachment = attachment });
    }
    try loadBoosts(allocator, conn, list.items);
    if (reverse) std.mem.reverse(model.Message, list.items);
    return list.toOwnedSlice(allocator);
}
fn loadBoosts(allocator: Allocator, conn: Conn, messages: []model.Message) !void {
    if (messages.len == 0) return;
    // All public page shapes are bounded by100. Bind the actual snapshot IDs, not another
    // pagination query whose tie order could choose a different set of rows.
    if (messages.len > 100) return error.DatabaseCorrupt;
    const prefix = "SELECT x.id,x.message_id,x.content,x.created_at,x.updated_at," ++ user_columns ++ " FROM boosts x JOIN users u ON u.id=x.booster_id WHERE x.message_id IN(";
    const suffix = ") ORDER BY x.created_at ASC";
    var sql: [prefix.len + 200 + suffix.len + 1]u8 = undefined;
    @memcpy(sql[0..prefix.len], prefix);
    var length = prefix.len;
    var params: [100]Value = undefined;
    for (messages, 0..) |message, i| {
        if (i > 0) {
            sql[length] = ',';
            length += 1;
        }
        sql[length] = '?';
        length += 1;
        params[i] = int(message.id);
    }
    @memcpy(sql[length..][0..suffix.len], suffix);
    length += suffix.len;
    sql[length] = 0;
    var s = try Statement.init(conn, sql[0..length :0], params[0..messages.len]);
    defer s.deinit();
    var lists: [100]std.ArrayList(model.Boost) = @splat(.empty);
    while (try s.next()) {
        const booster = found: {
            for (messages) |message| if (message.creator.id == s.integer(5)) break :found message.creator;
            for (lists[0..messages.len]) |list| for (list.items) |boost| if (boost.booster.id == s.integer(5)) break :found boost.booster;
            break :found try readUser(allocator, conn, &s, 5);
        };
        for (messages, 0..) |message, i| if (message.id == s.integer(1)) {
            try lists[i].append(allocator, .{ .id = s.integer(0), .message_id = s.integer(1), .content = try s.string(allocator, 2), .created_at = try s.string(allocator, 3), .updated_at = try s.string(allocator, 4), .booster = booster });
            break;
        };
    }
    for (messages, 0..) |*message, i| message.boosts = try lists[i].toOwnedSlice(allocator);
}
fn anchorTime(allocator: Allocator, conn: Conn, room_id: i64, id: i64) !?[]const u8 {
    var s = try Statement.init(conn, "SELECT created_at FROM messages WHERE room_id=? AND id=? LIMIT 1", &.{ int(room_id), int(id) });
    defer s.deinit();
    if (!try s.next()) return null;
    return s.string(allocator, 0);
}
const Page = enum { last, before, after };
fn pageIn(allocator: Allocator, conn: Conn, room_id: i64, page: Page, at: ?[]const u8) ![]model.Message {
    return switch (page) {
        .last => messageWhere(allocator, conn, "WHERE m.room_id=? ORDER BY m.created_at DESC LIMIT 40", &.{int(room_id)}, true),
        .before => messageWhere(allocator, conn, "WHERE m.room_id=? AND m.created_at<? ORDER BY m.created_at DESC LIMIT 40", &.{ int(room_id), text(at.?) }, true),
        .after => messageWhere(allocator, conn, "WHERE m.room_id=? AND m.created_at>? ORDER BY m.created_at ASC LIMIT 40", &.{ int(room_id), text(at.?) }, false),
    };
}
fn cutoff(allocator: Allocator, now: []const u8) ![]const u8 {
    return subtractSeconds(allocator, now, 60);
}
fn subtractSeconds(allocator: Allocator, now: []const u8, seconds_ago: i64) ![]const u8 {
    var epoch: c.time_t = @intCast((try compat.unixSeconds(now)) - seconds_ago);
    var calendar: c.struct_tm = undefined;
    if (c.gmtime_r(&epoch, &calendar) == null) return error.InvalidParam;
    const fraction = if (std.mem.indexOfScalar(u8, now, '.')) |dot| now[dot..] else "";
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}{s}", .{ calendar.tm_year + 1900, calendar.tm_mon + 1, calendar.tm_mday, calendar.tm_hour, calendar.tm_min, calendar.tm_sec, fraction });
}
fn uuid(allocator: Allocator, io: Io) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}
fn word(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = words.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = words[mid];
        if (cp < range[0]) hi = mid else if (cp > range[1]) lo = mid + 1 else return true;
    }
    return false;
}
fn whitespace(cp: u21) bool {
    return switch (cp) {
        9...13, 32, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}
fn blank(value: []const u8) bool {
    var view = std.unicode.Utf8View.init(value) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (!whitespace(cp)) return false;
    return true;
}
fn sanitizeQuery(allocator: Allocator, raw: []const u8) ![]const u8 {
    var view = std.unicode.Utf8View.init(raw) catch return error.InvalidParam;
    var it = view.iterator();
    var result: std.ArrayList(u8) = .empty;
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidParam;
        if (word(cp)) try result.appendSlice(allocator, slice) else try result.append(allocator, ' ');
    }
    return result.toOwnedSlice(allocator);
}
fn matchTerms(allocator: Allocator, query: []const u8) ![]const u8 {
    var view = std.unicode.Utf8View.init(query) catch return error.InvalidParam;
    var it = view.iterator();
    var result: std.ArrayList(u8) = .empty;
    var in_word = false;
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidParam;
        if (cp == 0 or whitespace(cp)) {
            if (in_word) {
                try result.append(allocator, '"');
                in_word = false;
            }
        } else {
            if (!in_word) {
                if (result.items.len != 0) try result.append(allocator, ' ');
                try result.append(allocator, '"');
                in_word = true;
            }
            if (cp == '"') try result.append(allocator, '"');
            try result.appendSlice(allocator, slice);
        }
    }
    if (in_word) try result.append(allocator, '"');
    return result.toOwnedSlice(allocator);
}

const TestDatabase = struct {
    dir: std.testing.TmpDir,
    path: []const u8,
    db: Database,

    fn init() !TestDatabase {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try dir.dir.realPath(std.testing.io, &buffer);
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/native.sqlite3", .{buffer[0..n]});
        errdefer std.testing.allocator.free(path);
        var db = try Database.init(std.testing.allocator, std.testing.io, path, 2);
        errdefer db.deinit();
        try seed(db.writer);
        return .{ .dir = dir, .path = path, .db = db };
    }
    fn deinit(t: *TestDatabase) void {
        t.db.deinit();
        std.testing.allocator.free(t.path);
        t.dir.cleanup();
    }
};

fn seed(conn: Conn) !void {
    const sql =
        \\INSERT INTO accounts(id,name,join_code,created_at,updated_at) VALUES(1,'Native Campfire','join-code','2026-01-01 00:00:00','2026-01-01 00:00:00');
        \\INSERT INTO users(id,name,email_address,password_digest,role,status,created_at,updated_at) VALUES
        \\(1,'David','david@example.test','digest',1,0,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(2,'Jason','jason@example.test',NULL,0,0,'2026-01-02 00:00:00','2026-01-01 00:00:00'),
        \\(3,'Kevin',NULL,NULL,0,0,'2026-01-03 00:00:00','2026-01-01 00:00:00'),
        \\(4,'Inactive',NULL,NULL,0,1,'2026-01-04 00:00:00','2026-01-01 00:00:00'),
        \\(5,'Connected',NULL,NULL,0,0,'2026-01-05 00:00:00','2026-01-01 00:00:00'),
        \\(6,'Invisible',NULL,NULL,0,0,'2026-01-06 00:00:00','2026-01-01 00:00:00'),
        \\(7,'No involvement',NULL,NULL,0,0,'2026-01-07 00:00:00','2026-01-01 00:00:00'),
        \\(8,'Nothing',NULL,NULL,0,0,'2026-01-08 00:00:00','2026-01-01 00:00:00');
        \\INSERT INTO rooms(id,type,creator_id,name,created_at,updated_at) VALUES
        \\(1,'Rooms::Open',1,'Zulu','2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(2,'Rooms::Closed',2,'alpha','2026-01-02 00:00:00','2026-01-01 00:00:00'),
        \\(3,'Rooms::Direct',1,NULL,'2026-01-03 00:00:00','2026-01-03 00:00:00'),
        \\(4,'Rooms::Direct',1,NULL,'2026-01-04 00:00:00','2026-01-04 00:00:00');
        \\INSERT INTO memberships(room_id,user_id,involvement,connected_at,created_at,updated_at) VALUES
        \\(1,1,'mentions',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(1,2,'mentions',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(1,3,'mentions','2026-01-10 11:58:59.999999','2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(1,5,'everything','2026-01-10 11:59:00','2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(1,6,'invisible',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(1,7,NULL,NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(1,8,'nothing',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(2,2,'mentions',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(3,1,'everything',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(3,2,'everything',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00'),
        \\(4,1,'everything',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00');
        \\INSERT INTO bans(user_id,ip_address,created_at,updated_at) VALUES(4,'192.0.2.4','2026-01-01 00:00:00','2026-01-01 00:00:00');
        \\INSERT INTO active_storage_blobs(id,key,filename,byte_size,content_type,service_name,created_at) VALUES(1,'avatar-key','avatar.png',123,'image/png','local','2026-01-01 00:00:00'),(2,'logo-key','logo.svg',40,'image/svg+xml','local','2026-01-01 00:00:00');
        \\INSERT INTO active_storage_attachments(record_type,record_id,name,blob_id,created_at) VALUES('User',1,'avatar',1,'2026-01-01 00:00:00'),('Account',1,'logo',2,'2026-01-01 00:00:00');
    ;
    const code = c.sqlite3_exec(conn, sql, null, null, null);
    if (code != c.SQLITE_OK) return failure(conn, code);
}

test "membership reachability includes invisible but never grants administrators access" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try std.testing.expectError(error.NotFound, t.db.roomPage(a, io, 1, 2, null));
    try std.testing.expectError(error.NotFound, t.db.messagePage(a, io, 3, 2, null, null));
    try std.testing.expectError(error.Unauthorized, t.db.roomPage(a, io, 4, 1, null));
    const invisible = try t.db.roomPage(a, io, 6, 1, null);
    try std.testing.expectEqual(@as(i64, 1), invisible.room.id);
    const original = (try t.db.visitedRoom(a, io, 1, null)).?;
    try std.testing.expectEqual(@as(i64, 1), original.id);
    try std.testing.expectEqual(@as(i64, 1), (try t.db.visitedRoom(a, io, 1, 2)).?.id);
    try std.testing.expectEqual(@as(i64, 3), (try t.db.visitedRoom(a, io, 1, 3)).?.id);
    try std.testing.expect(try t.db.banned(io, "192.0.2.4"));
    try std.testing.expect(!try t.db.banned(io, "192.0.2.40"));
    try std.testing.expect((try t.db.blob(a, io, 999)) == null);
    try std.testing.expectEqual(@as(i64, 1), (try t.db.avatar(a, io, 1)).?.id);
    const account_page = try t.db.account(a, io);
    try std.testing.expectEqual(@as(i64, 2), account_page.logo.?.id);
    try std.testing.expectEqual(@as(i64, 1), account_page.help_contact.?.id);
}

test "source pagination strict timestamps last40 around81 foreign anchor fallback and before precedence" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    for (0..100) |i| {
        const now = try std.fmt.allocPrint(a, "2026-01-10 12:{d:0>2}:{d:0>2}", .{ i / 60, i % 60 });
        try exec(t.db.writer, "INSERT INTO messages(id,client_message_id,creator_id,room_id,created_at,updated_at) VALUES(?,?,1,1,?,?)", &.{ int(@intCast(i + 1)), text("paged"), text(now), text(now) });
    }
    const last = try t.db.messagePage(a, io, 1, 1, null, null);
    try std.testing.expectEqual(@as(usize, 40), last.len);
    try std.testing.expectEqual(@as(i64, 61), last[0].id);
    try std.testing.expectEqual(@as(i64, 100), last[39].id);
    const before = try t.db.messagePage(a, io, 1, 1, 51, 99);
    try std.testing.expectEqual(@as(usize, 40), before.len);
    try std.testing.expectEqual(@as(i64, 11), before[0].id);
    try std.testing.expectEqual(@as(i64, 50), before[39].id);
    const after = try t.db.messagePage(a, io, 1, 1, null, 51);
    try std.testing.expectEqual(@as(i64, 52), after[0].id);
    try std.testing.expectEqual(@as(i64, 91), after[39].id);
    const around = try t.db.roomPage(a, io, 1, 1, 51);
    try std.testing.expectEqual(@as(usize, 81), around.messages.len);
    try std.testing.expectEqual(@as(i64, 11), around.messages[0].id);
    try std.testing.expectEqual(@as(i64, 51), around.messages[40].id);
    try std.testing.expectEqual(@as(i64, 91), around.messages[80].id);
    try std.testing.expect(!around.invitation);
    try std.testing.expectEqual(@as(usize, 0), (try t.db.messagePage(a, io, 1, 1, 1, null)).len);
    try std.testing.expectEqual(@as(usize, 0), (try t.db.messagePage(a, io, 1, 1, null, 100)).len);
    try exec(t.db.writer, "INSERT INTO messages(id,client_message_id,creator_id,room_id,created_at,updated_at) VALUES(101,'foreign',2,2,'2026-01-10 12:00:50','2026-01-10 12:00:50'),(102,'tie',1,1,'2026-01-10 12:00:50','2026-01-10 12:00:50')", &.{});
    try std.testing.expectError(error.NotFound, t.db.messagePage(a, io, 1, 1, 101, null));
    try std.testing.expectError(error.NotFound, t.db.messagePage(a, io, 1, 1, null, 101));
    const fallback = try t.db.roomPage(a, io, 1, 1, 101);
    try std.testing.expectEqual(@as(i64, 61), fallback.messages[0].id);
    const strict = try t.db.messagePage(a, io, 1, 1, null, 51);
    for (strict) |m| try std.testing.expect(m.id != 102);
    try std.testing.expectError(error.NotFound, t.db.messagePage(a, io, 1, 1, 999, null));
}

test "native insertion persists richtext FTS room touch and exact visible disconnected unread transitions" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const now = "2026-01-10 12:00:00";
    const posted = try t.db.createMessage(a, io, 1, 1, "Hello <span>there</span>", "real-client-id", now);
    try std.testing.expectEqualStrings("real-client-id", posted.client_message_id);
    try std.testing.expectEqualStrings(now, posted.created_at);
    const page = try t.db.roomPage(a, io, 1, 1, null);
    try std.testing.expectEqualStrings(posted.body, page.messages[0].body);
    try std.testing.expectEqualStrings(now, page.room.updated_at);
    var body = try Statement.init(t.db.writer, "SELECT body,record_type,name FROM action_text_rich_texts WHERE record_id=?", &.{int(posted.id)});
    defer body.deinit();
    try std.testing.expect(try body.next());
    try std.testing.expectEqualStrings(posted.body, body.bytes(0));
    try std.testing.expectEqualStrings("Message", body.bytes(1));
    try std.testing.expectEqualStrings("body", body.bytes(2));
    var unread = try Statement.init(t.db.writer, "SELECT user_id,unread_at,updated_at FROM memberships WHERE room_id=1 ORDER BY user_id", &.{});
    defer unread.deinit();
    while (try unread.next()) {
        const id = unread.integer(0);
        const marked = id == 2 or id == 3 or id == 8;
        try std.testing.expectEqual(marked, c.sqlite3_column_type(unread.raw, 1) != c.SQLITE_NULL);
        try std.testing.expectEqualStrings(if (marked) now else "2026-01-01 00:00:00", unread.bytes(2));
    }
    const found = try t.db.search(a, io, 1, "there", null);
    try std.testing.expectEqual(@as(usize, 1), found.messages.len);
    try std.testing.expectEqual(posted.id, found.messages[0].id);
    try std.testing.expectEqual(@as(usize, 0), (try t.db.search(a, io, 1, "span", null)).messages.len);
    try std.testing.expectEqual(@as(usize, 1), (try t.db.search(a, io, 6, "there", null)).messages.len);
    try std.testing.expectEqual(@as(usize, 0), (try t.db.search(a, io, 2, "unfindable", null)).messages.len);
    var reopened = try Database.init(std.testing.allocator, io, t.path, 1);
    defer reopened.deinit();
    try std.testing.expectEqual(posted.id, (try reopened.search(a, io, 1, "there", null)).messages[0].id);
    const empty = try t.db.createMessage(a, io, 1, 1, "", null, "2026-01-10 12:01:00");
    try std.testing.expectEqual(@as(usize, 36), empty.client_message_id.len);
    try std.testing.expectEqual(@as(u8, '4'), empty.client_message_id[14]);
}

test "foreign room writes roll back and database failures differ from missing records" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try std.testing.expectError(error.NotFound, t.db.createMessage(a, io, 1, 2, "not allowed", null, "2026-01-10 12:00:00"));
    try std.testing.expect(!try exists(t.db.writer, "SELECT 1 FROM messages", &.{}));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(t.db.writer));
    try std.testing.expectError(error.DatabaseConstraint, exec(t.db.writer, "INSERT INTO messages(client_message_id,creator_id,room_id,created_at,updated_at) VALUES('bad',999,1,'2026-01-01','2026-01-01')", &.{}));
    try std.testing.expect((try t.db.findUser(a, io, 999)) == null);
    try exec(t.db.writer, "DELETE FROM accounts", &.{});
    try std.testing.expectError(error.NotFound, t.db.account(a, io));
    try std.testing.expectError(error.InvalidParam, Database.init(std.testing.allocator, io, t.path, 0));
    try exec(t.db.writer, "DELETE FROM schema_migrations WHERE version='20251212154340'", &.{});
    try std.testing.expectError(error.PendingMigrations, Database.init(std.testing.allocator, io, t.path, 1));
}

test "sessions active user bans bound token and strict hourly microsecond resume" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const session = try t.db.createSession(a, io, 1, "token' OR 1=1--", "192.0.2.1", "ua1", "2026-01-10 12:00:00");
    try std.testing.expectEqual(@as(i64, 1), (try t.db.findSession(a, io, session.token)).?.user.id);
    try std.testing.expect((try t.db.findSession(a, io, "invalid")) == null);
    try std.testing.expectEqual(@as(i64, 1), (try t.db.findUserByEmail(a, io, "david@example.test")).?.id);
    try std.testing.expect((try t.db.findUserByEmail(a, io, "' OR 1=1--")) == null);
    try std.testing.expectError(error.Unauthorized, t.db.createSession(a, io, 4, "inactive", null, null, "2026-01-10 12:00:00"));
    try std.testing.expectError(error.DatabaseConstraint, t.db.createSession(a, io, 1, session.token, null, null, "2026-01-10 12:00:00"));
    try t.db.refreshSession(io, session.id, "192.0.2.2", "ua2", "2026-01-10 13:00:00");
    try std.testing.expectEqualStrings("2026-01-10 12:00:00", (try t.db.findSession(a, io, session.token)).?.last_active_at);
    try t.db.refreshSession(io, session.id, "192.0.2.2", "ua2", "2026-01-10 13:00:00.000001");
    const updated = (try t.db.findSession(a, io, session.token)).?;
    try std.testing.expectEqualStrings("2026-01-10 13:00:00.000001", updated.last_active_at);
    var fields = try Statement.init(t.db.writer, "SELECT ip_address,user_agent FROM sessions WHERE id=?", &.{int(session.id)});
    defer fields.deinit();
    try std.testing.expect(try fields.next());
    try std.testing.expectEqualStrings("192.0.2.2", fields.bytes(0));
    try std.testing.expectEqualStrings("ua2", fields.bytes(1));
    try exec(t.db.writer, "UPDATE users SET status=2 WHERE id=1", &.{});
    try std.testing.expect((try t.db.findSession(a, io, session.token)) == null);
    try t.db.deleteSession(io, session.token);
    try t.db.deleteSession(io, session.token);
    try std.testing.expectError(error.NotFound, t.db.refreshSession(io, 999, null, null, "2026-01-10 13:00:00"));
}

test "sidebar visible alphabetical shared recent direct order names self fallback and placeholders" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try exec(t.db.writer, "INSERT INTO memberships(user_id,room_id,involvement,created_at,updated_at) VALUES(1,2,'mentions','2026-01-01','2026-01-01')", &.{});
    const sidebar_page = try t.db.sidebar(a, io, 1);
    try std.testing.expectEqual(@as(usize, 2), sidebar_page.shared.len);
    try std.testing.expectEqualStrings("alpha", sidebar_page.shared[0].room.display_name);
    try std.testing.expectEqualStrings("Zulu", sidebar_page.shared[1].room.display_name);
    try std.testing.expectEqual(@as(i64, 4), sidebar_page.directs[0].room.id);
    try std.testing.expectEqualStrings("David", sidebar_page.directs[0].room.display_name);
    try std.testing.expectEqual(@as(i64, 1), sidebar_page.directs[0].users[0].id);
    try std.testing.expectEqualStrings("Jason", sidebar_page.directs[1].room.display_name);
    try std.testing.expectEqual(@as(i64, 2), sidebar_page.directs[1].users[0].id);
    for (sidebar_page.direct_placeholder_users) |u| try std.testing.expect(u.id != 1 and u.id != 2 and u.status == 0);
    try std.testing.expectEqual(@as(usize, 5), sidebar_page.direct_placeholder_users.len);
    try std.testing.expectEqual(@as(usize, 0), (try t.db.sidebar(a, io, 6)).shared.len);
    try std.testing.expectEqual(@as(usize, 0), (try t.db.sidebar(a, io, 7)).shared.len);
    try exec(t.db.writer, "UPDATE rooms SET updated_at='2026-01-01' WHERE id IN(3,4)", &.{});
    const tied = try t.db.sidebar(a, io, 1);
    try std.testing.expectEqual(@as(i64, 4), tied.directs[0].room.id);
}

test "literal search sanitized Unicode chronological last100 reachability and history only on POST" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    for (0..105) |i| {
        const now = try std.fmt.allocPrint(a, "2026-01-10 12:{d:0>2}:{d:0>2}", .{ i / 60, i % 60 });
        _ = try t.db.createMessage(a, io, 1, 1, "Do NOT feed the eel OR shark", null, now);
    }
    _ = try t.db.createMessage(a, io, 2, 2, "eel NOT secret shark", null, "2026-01-10 13:00:00");
    const found = try t.db.search(a, io, 1, "NOT eel", 2);
    try std.testing.expectEqual(@as(usize, 100), found.messages.len);
    try std.testing.expectEqual(@as(i64, 6), found.messages[0].id);
    try std.testing.expectEqual(@as(i64, 105), found.messages[99].id);
    try std.testing.expectEqual(@as(i64, 1), found.return_to_room_id);
    try std.testing.expectEqual(@as(usize, 0), found.recent_searches.len);
    try std.testing.expectEqual(@as(usize, 0), (try t.db.search(a, io, 1, "secret", null)).messages.len);
    try std.testing.expectEqual(@as(usize, 1), (try t.db.search(a, io, 2, "secret", 2)).messages.len);
    try std.testing.expect((try t.db.search(a, io, 1, "\"*\"", null)).query == null);
    try std.testing.expectEqualStrings("héllo  café_1 日本 ‿ a b  ", try sanitizeQuery(a, "héllo, café_1 日本 ‿ a-b ❤"));
    try std.testing.expectEqualStrings("\"eel\" \"shark\"", try matchTerms(a, "eel\\x00shark"));
    try std.testing.expectEqualStrings("\"a\"\"b\"", try matchTerms(a, "a\"b"));
    for (0..12) |i| {
        const query = try std.fmt.allocPrint(a, "query {d}", .{i});
        const now = try std.fmt.allocPrint(a, "2026-01-11 12:00:{d:0>2}", .{i});
        _ = try t.db.recordSearch(a, io, 1, query, now);
    }
    _ = try t.db.recordSearch(a, io, 1, "query 5", "2026-01-11 13:00:00");
    const history = try t.db.search(a, io, 1, null, null);
    try std.testing.expectEqual(@as(usize, 10), history.recent_searches.len);
    try std.testing.expectEqualStrings("query 5", history.recent_searches[0]);
    _ = try t.db.recordSearch(a, io, 1, "hello, world", "2026-01-11 14:00:00");
    try std.testing.expectEqualStrings("hello  world", (try t.db.search(a, io, 1, null, null)).recent_searches[0]);
    try t.db.clearSearch(io, 1);
    try std.testing.expectEqual(@as(usize, 0), (try t.db.search(a, io, 1, null, null)).recent_searches.len);
}

test "failed richtext insertion rolls back message room and callback-visible writes" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try exec(t.db.writer, "CREATE TRIGGER reject_body BEFORE INSERT ON action_text_rich_texts BEGIN SELECT RAISE(ABORT,'rejected body'); END", &.{});
    try std.testing.expectError(error.DatabaseConstraint, t.db.createMessage(a, io, 1, 1, "rejected", null, "2026-01-10 12:00:00"));
    try std.testing.expect(!try exists(t.db.writer, "SELECT 1 FROM messages", &.{}));
    try std.testing.expect(!try exists(t.db.writer, "SELECT 1 FROM message_search_index", &.{}));
    try std.testing.expect(!try exists(t.db.writer, "SELECT 1 FROM memberships WHERE unread_at IS NOT NULL", &.{}));
    try std.testing.expectEqualStrings("2026-01-01 00:00:00", (try t.db.roomPage(a, io, 1, 1, null)).room.updated_at);
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(t.db.writer));
}

test "view snapshots hydrate stored message attachment boosts and all-member direct room labels" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const posted = try t.db.createMessage(a, io, 1, 3, "body with media", "media", "2026-01-10 12:00:00");
    try exec(t.db.writer, "INSERT INTO active_storage_attachments(record_type,record_id,name,blob_id,created_at) VALUES('Message',?,'attachment',1,'2026-01-10 12:00:00')", &.{int(posted.id)});
    try exec(t.db.writer, "INSERT INTO boosts(message_id,booster_id,content,created_at,updated_at) VALUES(?,2,'first','2026-01-10 12:01:00','2026-01-10 12:01:00'),(?,1,'second','2026-01-10 12:02:00','2026-01-10 12:02:00')", &.{ int(posted.id), int(posted.id) });
    const message = (try t.db.messagePage(a, io, 1, 3, null, null))[0];
    try std.testing.expectEqualStrings("David and Jason", message.room_name);
    try std.testing.expectEqualStrings("avatar.png", message.attachment.?.filename);
    try std.testing.expectEqual(@as(usize, 2), message.boosts.len);
    try std.testing.expectEqualStrings("first", message.boosts[0].content);
    try std.testing.expectEqualStrings("second", message.boosts[1].content);
    try std.testing.expectEqual(@as(i64, 2), message.boosts[0].booster.id);
    try std.testing.expectEqual(@as(i64, 1), message.boosts[1].booster.avatar.?.id);
}

test "storage associations persist winner without orphan staged metadata across DB instances" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try std.testing.expect((try t.db.existingVariant(a, io, 1, "digest")) == null);
    try std.testing.expect((try t.db.existingPreview(a, io, 1)) == null);
    const first: NewBlob = .{ .key = "first-variant", .filename = "variant.png", .content_type = "image/png", .byte_size = 42, .checksum = "checksum", .metadata = "{\"identified\":true,\"analyzed\":true}", .service_name = "local" };
    const other: NewBlob = .{ .key = "losing-staged", .filename = "other.png", .content_type = "image/png", .byte_size = 43, .service_name = "local" };
    const recorded = try t.db.recordVariant(a, io, 1, "digest", first, "2026-01-10 12:00:00");
    try std.testing.expectEqualStrings(first.key, recorded.key);
    var reopened = try Database.init(std.testing.allocator, io, t.path, 1);
    defer reopened.deinit();
    try std.testing.expectEqual(recorded.id, (try reopened.existingVariant(a, io, 1, "digest")).?.id);
    const winner = try reopened.recordVariant(a, io, 1, "digest", other, "2026-01-10 12:01:00");
    try std.testing.expectEqual(recorded.id, winner.id);
    try std.testing.expect(!try exists(t.db.writer, "SELECT 1 FROM active_storage_blobs WHERE key='losing-staged'", &.{}));
    var preview = first;
    preview.key = "preview";
    const frame = try t.db.recordPreview(a, io, 1, preview, "2026-01-10 12:00:00");
    try std.testing.expectEqual(frame.id, (try reopened.existingPreview(a, io, 1)).?.id);
    try std.testing.expectEqual(frame.id, (try reopened.recordPreview(a, io, 1, other, "2026-01-10 12:01:00")).id);
    try std.testing.expectError(error.NotFound, t.db.recordVariant(a, io, 999, "missing", other, "2026-01-10 12:00:00"));
    try std.testing.expectError(error.DatabaseConstraint, t.db.recordVariant(a, io, 1, "rollback", first, "2026-01-10 12:00:00"));
    try std.testing.expect((try variantRecord(t.db.writer, 1, "rollback")) == null);
    try exec(t.db.writer, "INSERT INTO active_storage_variant_records(blob_id,variation_digest) VALUES(1,'dangling')", &.{});
    try std.testing.expectError(error.NotFound, t.db.recordVariant(a, io, 1, "dangling", other, "2026-01-10 12:00:00"));
}

test "absent message body stays absent while explicitly empty body creates richtext" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const absent = try t.db.createMessage(a, io, 1, 1, null, "absent", "2026-01-10 12:00:00");
    try std.testing.expectEqualStrings("", absent.body);
    try std.testing.expect(!try exists(t.db.writer, "SELECT 1 FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'", &.{int(absent.id)}));
    try std.testing.expect(try exists(t.db.writer, "SELECT 1 FROM message_search_index WHERE rowid=? AND body=''", &.{int(absent.id)}));
    const explicit = try t.db.createMessage(a, io, 1, 1, "", "explicit", "2026-01-10 12:01:00");
    try std.testing.expect(try exists(t.db.writer, "SELECT 1 FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body' AND body=''", &.{int(explicit.id)}));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(t.db.writer));
}

test "sidebar carries membership timestamp independently of room activity order" {
    var t = try TestDatabase.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try exec(t.db.writer, "UPDATE memberships SET updated_at='2026-02-01 01:02:03.123456' WHERE room_id=3 AND user_id=1", &.{});
    const page = try t.db.sidebar(a, io, 1);
    try std.testing.expectEqual(@as(i64, 4), page.directs[0].room.id);
    try std.testing.expectEqual(@as(i64, 3), page.directs[1].room.id);
    try std.testing.expectEqualStrings("2026-02-01 01:02:03.123456", page.directs[1].membership_updated_at);
    try std.testing.expectEqualStrings("2026-01-03 00:00:00", page.directs[1].room.updated_at);
}
