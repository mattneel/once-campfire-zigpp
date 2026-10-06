//! Request-owned snapshots of Campfire's existing SQLite records.
//! Field names preserve the Rails schema; rendering never keeps a SQLite row borrowed.

pub const User = struct {
    id: i64,
    name: []const u8,
    bio: ?[]const u8 = null,
    email_address: ?[]const u8 = null,
    password_digest: ?[]const u8 = null,
    role: i64 = 0,
    status: i64 = 0,
    created_at: []const u8,
    updated_at: []const u8,
    avatar: ?Blob = null,

    pub fn isAdministrator(self: User) bool {
        return self.role == 1;
    }

    pub fn isBot(self: User) bool {
        return self.role == 2;
    }
};

pub const Account = struct {
    id: i64,
    name: []const u8,
    join_code: []const u8,
    custom_styles: ?[]const u8 = null,
    settings: ?[]const u8 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const AuthSession = struct {
    id: i64,
    token: []const u8,
    user: User,
    created_at: []const u8,
    updated_at: []const u8,
    last_active_at: []const u8,
};

pub const RoomKind = enum {
    open,
    closed,
    direct,

    pub fn paramKey(self: RoomKind) []const u8 {
        return switch (self) {
            .open => "rooms_open",
            .closed => "rooms_closed",
            .direct => "rooms_direct",
        };
    }

    pub fn className(self: RoomKind) []const u8 {
        return switch (self) {
            .open => "Rooms::Open",
            .closed => "Rooms::Closed",
            .direct => "Rooms::Direct",
        };
    }
};

pub const Room = struct {
    id: i64,
    kind: RoomKind,
    creator_id: i64,
    name: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    display_name: []const u8,
};

pub const Blob = struct {
    id: i64,
    key: []const u8,
    filename: []const u8,
    content_type: ?[]const u8,
    byte_size: i64,
    checksum: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
    service_name: []const u8,
    created_at: []const u8,
};

pub const Boost = struct {
    id: i64,
    message_id: i64,
    content: []const u8,
    booster: User,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Message = struct {
    id: i64,
    client_message_id: []const u8,
    room_id: i64,
    room_kind: RoomKind,
    room_name: []const u8,
    creator: User,
    created_at: []const u8,
    updated_at: []const u8,
    body: []const u8,
    attachment: ?Blob = null,
    boosts: []const Boost = &.{},
};

pub const RoomPage = struct {
    account: Account,
    room: Room,
    user: User,
    messages: []const Message,
    invitation: bool,
};

pub const SidebarRoom = struct {
    room: Room,
    involvement: []const u8,
    unread_at: ?[]const u8,
    users: []const User = &.{},
};

pub const Sidebar = struct {
    account: Account,
    user: User,
    shared: []const SidebarRoom,
    directs: []const SidebarRoom,
};

pub const SearchPage = struct {
    account: Account,
    user: User,
    q: ?[]const u8,
    query: ?[]const u8,
    messages: []const Message,
    recent_searches: []const []const u8,
    return_to_room_id: i64,
};
