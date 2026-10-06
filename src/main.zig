const std = @import("std");
const zix = @import("zix");
const http = @import("http.zig");
const db = @import("db.zig");
const assets = @import("assets.zig");
const compat = @import("compat.zig");
const storage = @import("storage.zig");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    if (comptime !@hasDecl(std.Io, "Threadz")) @compileError("Campfire requires the Zig++ compiler with std.Io.Threadz");
    if (comptime @import("builtin").os.tag != .linux) @compileError("This native Campfire target currently requires Linux");
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        var buffer: [2048]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &buffer);
        try output.interface.writeAll(
            \\campfire-zigpp server
            \\Native authenticated Campfire leaderboard target: Zig++ Threadz + Zix + SQLite.
            \\Environment:
            \\  SECRET_KEY_BASE          Required, preserved Rails signing secret
            \\  CAMPFIRE_STORAGE_PATH    Existing Campfire storage/{db,files} (default storage)
            \\  CAMPFIRE_DATABASE_PATH   Optional existing SQLite path override
            \\  CAMPFIRE_ASSET_ROOT      Source/assets root (default build source root)
            \\  HTTP_PORT                Listen port (default 3000)
            \\  HTTP_BIND                Bind address (default 127.0.0.1)
            \\  CAMPFIRE_WORKERS          Threadz/HTTP workers (default 4)
            \\  DISABLE_SSL              Set for plain HTTP same-origin policy
            \\  APP_VERSION              Version badge (default native Zig++)
            \\Unsupported: Cable, push/jobs, uploads, administration and TLS/ACME.
            \\
        );
        try output.interface.flush();
        return;
    }
    if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "server"))) return error.InvalidArguments;
    const env = init.environ_map;
    const secret = env.get("SECRET_KEY_BASE") orelse {
        std.log.err("SECRET_KEY_BASE is required; use the preserved Campfire/Rails secret", .{});
        return error.MissingSecretKeyBase;
    };
    const root = env.get("CAMPFIRE_STORAGE_PATH") orelse "storage";
    const database_path = env.get("CAMPFIRE_DATABASE_PATH") orelse try std.fs.path.join(arena, &.{ root, "db", "production.sqlite3" });
    const files_path = try std.fs.path.join(arena, &.{ root, "files" });
    const asset_root = env.get("CAMPFIRE_ASSET_ROOT") orelse build_options.source_root;
    const port = try std.fmt.parseInt(u16, env.get("HTTP_PORT") orelse "3000", 10);
    const workers = try std.fmt.parseInt(usize, env.get("CAMPFIRE_WORKERS") orelse "4", 10);
    if (port == 0 or workers == 0 or workers > 256) return error.InvalidConfiguration;

    var runtime: std.Io.Threadz = undefined;
    try runtime.init(init.gpa, .{ .thread_limit = workers - 1, .log2_ring_entries = 12, .environ = init.minimal.environ });
    defer runtime.deinit();
    const io = runtime.io();
    var app: http.App = undefined;
    app.db = try db.Database.init(init.gpa, io, database_path, workers);
    defer app.db.deinit();
    app.secrets = try compat.Secrets.init(init.gpa, secret);
    defer app.secrets.deinit();
    app.assets = try assets.Assets.init(init.gpa, io, asset_root);
    defer app.assets.deinit();
    app.preload_link = try preloadHeader(init.gpa, &app.assets);
    defer init.gpa.free(app.preload_link);
    app.storage = try storage.Storage.init(init.gpa, io, files_path, &app.db, &app.secrets);
    defer app.storage.deinit();
    app.allocator = init.gpa;
    app.force_ssl = env.get("DISABLE_SSL") == null;
    app.app_version = env.get("APP_VERSION") orelse "native Zig++";
    app.git_revision = env.get("GIT_REVISION");
    app.vapid_public_key = env.get("VAPID_PUBLIC_KEY");
    app.rate_mutex = .init;
    app.rate_limits = .empty;
    defer app.deinitRateLimits();
    http.application = &app;
    defer http.application = null;
    std.log.info("native Campfire: Threadz workers={d}, Zix HTTP/1 io_uring, SQLite={s}", .{ workers, database_path });
    var server = zix.Http1.Server.init(http.handle, .{
        .io = io,
        .ip = env.get("HTTP_BIND") orelse "127.0.0.1",
        .port = port,
        .dispatch_model = .URING,
        .workers = workers,
        .max_response_headers = .COMMON,
        // Http1 retains bodies only while they fit this buffer; never truncate a valid form.
        .max_recv_buf = 16 * 1024 * 1024 + 64 * 1024,
        .max_request_body = 16 * 1024 * 1024,
        .busy_poll_us = 0,
        // Whole-response path keys lack user identity. Never cache authenticated responses there.
        .response_cache = false,
        .compress = true,
    });
    try server.run();
}

fn preloadHeader(allocator: std.mem.Allocator, catalog: *const assets.Assets) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const suffix = ">; rel=preload; as=style; nopush";
    for (catalog.stylesheets()) |logical| {
        const path = catalog.assetPath(logical) orelse continue;
        // Rails checks before adding the separating comma; later shorter links can still fit.
        if (out.written().len + 1 + path.len + suffix.len > 1000) continue;
        if (out.written().len != 0) try out.writer.writeByte(',');
        try out.writer.print("<{s}{s}", .{ path, suffix });
    }
    return out.toOwnedSlice();
}
