//! Native renderers for crates/views/templates and reference/app/views.
//! All output and helper values are owned by the request allocator.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const db = @import("db.zig");
const compat = @import("compat.zig");
const assets_module = @import("assets.zig");
const richtext = @import("richtext.zig");
const storage = @import("storage.zig");
const unicode = @import("views/unicode.zig");
const fmt = std.fmt.allocPrint;

pub const Context = struct {
    allocator: Allocator,
    io: Io,
    db: *db.Database,
    secrets: *compat.Secrets,
    assets: *assets_module.Assets,
    user: model.User,
    base_url: []const u8,
    path: []const u8,
    frame_id: ?[]const u8 = null,
    user_agent: []const u8 = "",
    vapid_public_key: ?[]const u8 = null,
    app_version: []const u8 = "native Zig++",
    avatar_urls: std.AutoHashMapUnmanaged(i64, []const u8) = .empty,
};

fn asset(ctx: *Context, logical: []const u8) ![]const u8 {
    return ctx.assets.assetPath(logical) orelse error.MissingAsset;
}
fn absolute(ctx: *Context, path: []const u8) ![]const u8 {
    return fmt(ctx.allocator, "{s}{s}", .{std.mem.trimEnd(u8, ctx.base_url, "/"),path});
}
fn image(ctx: *Context,w: *Io.Writer,logical: []const u8,attributes: []const u8) !void {
    try w.writeAll("<img");
    try w.writeAll(attributes);
    try w.writeAll(" src=\"");
    try compat.htmlEscape(w, try asset(ctx,logical));
    try w.writeAll("\" />");
}
fn messageId(a: Allocator,m: model.Message,p: []const u8) ![]const u8 {
    if (p.len == 0) return fmt(a,"message_{s}",.{m.client_message_id});
    return fmt(a,"{s}_message_{s}",.{p,m.client_message_id});
}
fn roomId(a: Allocator,r: model.Room,p: []const u8) ![]const u8 {
    if (p.len == 0) return fmt(a,"{s}_{d}",.{r.kind.paramKey(),r.id});
    return fmt(a,"{s}_{s}_{d}",.{p,r.kind.paramKey(),r.id});
}
fn title(a: Allocator,u: model.User) ![]const u8 {
    const name = std.mem.trim(u8,u.name," \t\r\n");
    const bio = std.mem.trim(u8,u.bio orelse ""," \t\r\n");
    if (bio.len == 0) return u.name;
    if (name.len == 0) return u.bio.?;
    return fmt(a,"{s} – {s}",.{u.name,u.bio.?});
}
fn avatarUrl(ctx: *Context,u: model.User) ![]const u8 {
    if(ctx.avatar_urls.get(u.id)) |url| return url;
    const token = try ctx.secrets.signedUserId(ctx.allocator,u.id);
    const iso = try compat.iso8601(ctx.allocator,u.updated_at,0);
    var number: [14]u8 = undefined;
    var n: usize = 0;
    for (iso) |c| if (std.ascii.isDigit(c) and n < number.len) { number[n]=c; n+=1; };
    if (n != number.len) return error.InvalidTimestamp;
    const url = try fmt(ctx.allocator,"/users/{s}/avatar?v={s}",.{token,number[0..n]});
    try ctx.avatar_urls.put(ctx.allocator,u.id,url);
    return url;
}
fn blobUrl(ctx: *Context,b: model.Blob,download: bool) ![]const u8 {
    return storage.blobPath(ctx.allocator,ctx.secrets,b,if(download) "attachment" else null);
}

fn initials(a: Allocator,name: []const u8) ![]const u8 {
    var out = Io.Writer.Allocating.init(a);
    defer out.deinit();
    var it = (try std.unicode.Utf8View.init(name)).iterator();
    var previous_word = false;
    while (it.nextCodepoint()) |c| {
        if (c < 128 and (std.ascii.isAlphanumeric(@intCast(c)) or c == '_') and !previous_word) try out.writer.writeByte(@intCast(c));
        previous_word = unicode.alphanumeric(c) or c == '_';
    }
    return out.toOwnedSlice();
}
fn allEmoji(value: []const u8) bool {
    if (value.len == 0) return false;
    var it = (std.unicode.Utf8View.init(value) catch return false).iterator();
    while (it.nextCodepoint()) |c| if (c != 0xfe0f and !unicode.emoji(c)) return false;
    return true;
}
const avatar_colors = [_][]const u8{"#AF2E1B", "#CC6324", "#3B4B59", "#BFA07A", "#ED8008", "#ED3F1C", "#BF1B1B", "#736B1E", "#D07B53", "#736356", "#AD1D1D", "#BF7C2A", "#C09C6F", "#698F9C", "#7C956B", "#5D618F", "#3B3633", "#67695E"};
fn avatarColor(id: i64) []const u8 {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,"{d}",.{id}) catch unreachable;
    return avatar_colors[std.hash.Crc32.hash(text) % avatar_colors.len];
}
const reactions = [_][2][]const u8{.{"👍","Thumbs up"},.{"👏","Clapping"},.{"👋","Waving hand"},.{"💪","Muscle"},.{"❤️","Red heart"},.{"😂","Face with tears of joy"},.{"🎉","Party popper"},.{"🔥","Fire"}};
const Platform = struct {
    safari: bool, chrome: bool, firefox: bool, edge: bool, ios: bool, android: bool, windows: bool, desktop: bool, browser: []const u8, operating_system: []const u8,
    fn from(ua: []const u8) Platform {
        const edge = std.mem.find(u8,ua,"Edg") != null;
        const chrome = !edge and (std.mem.find(u8,ua,"Chrome") != null or std.mem.find(u8,ua,"CriOS") != null);
        const firefox = std.mem.find(u8,ua,"Firefox") != null or std.mem.find(u8,ua,"FxiOS") != null;
        const safari = !chrome and !edge and std.mem.find(u8,ua,"Safari") != null;
        const ios = std.mem.find(u8,ua,"iPhone") != null or std.mem.find(u8,ua,"iPad") != null or std.mem.find(u8,ua,"iPod") != null;
        const android = std.mem.find(u8,ua,"Android") != null;
        const windows = std.mem.find(u8,ua,"Windows") != null;
        return .{.edge=edge,.chrome=chrome,.firefox=firefox,.safari=safari,.ios=ios,.android=android,.windows=windows,.desktop=!ios and !android,.browser=if(edge) "Edge" else if(chrome) "Chrome" else if(firefox) "Firefox" else if(safari) "Safari" else "Web browser",.operating_system=if(ios) "iOS" else if(android) "Android" else if(windows) "Windows" else if(std.mem.find(u8,ua,"Mac") != null) "macOS" else "Linux"};
    }
};

fn actions(ctx: *Context,w: *Io.Writer,m: model.Message) !void {
try w.writeAll("\n<div class=\"message__actions\" data-controller=\"soft-keyboard\">\n  <details class=\"position-relative\" data-controller=\"popup\" data-action=\"keydown.esc-&gt;popup#close toggle-&gt;popup#toggle click@document-&gt;popup#closeOnClickOutside\" data-popup-orientation-top-class=\"popup-orientation-top\">\n    <summary class=\"btn message__action-btn message__options-btn\">\n      <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "menu-dots-horizontal.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n      <span class=\"for-screen-reader\">Message options</span>\n    </summary>\n\n    <div class=\"message__actions-menu border shadow\" data-popup-target=\"menu\">\n      <div class=\"quick-boosts\">");
for (reactions) |reaction| {
try w.writeAll("\n          <form data-turbo-frame=\"");
try writeMessageId(w,m,"boosting");
try w.writeAll("\" data-action=\"popup#close\" action=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/messages/{d}/boosts", .{m.id}));
try w.writeAll("\" accept-charset=\"UTF-8\" method=\"post\">\n            <input type=\"hidden\" name=\"boost[content]\" id=\"boost_content\" value=\"");
try compat.htmlEscape(w, reaction[0]);
try w.writeAll("\" />\n            <button name=\"button\" type=\"submit\" title=\"");
try compat.htmlEscape(w, reaction[1]);
try w.writeAll("\" class=\"btn message__action-btn\" data-emoji=\"");
try compat.htmlEscape(w, reaction[0]);
try w.writeAll("\">\n              <figure class=\"margin-none boost-character\">");
try compat.htmlEscape(w, reaction[0]);
try w.writeAll("</figure>\n              <span class=\"for-screen-reader\">");
try compat.htmlEscape(w, reaction[1]);
try w.writeAll("</span>\n</button></form>");
}
try w.writeAll("\n\n        <a class=\"btn message__action-btn message__boost-btn\" data-turbo-frame=\"");
try writeMessageId(w,m,"new_boost");
try w.writeAll("\" data-action=\"soft-keyboard#open popup#close\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/messages/{d}/boosts/new", .{m.id}));
try w.writeAll("\">\n          <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "boost.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n          <span class=\"for-screen-reader\">New boost</span>\n</a>      </div>\n\n      <div class=\"flex flex-wrap border-top margin-block-start-half pad-block-start-half message__actions-grid\">\n        ");
if (m.attachment) |attachment| {
try w.writeAll("\n          <a class=\"btn message__action-btn center full-width hide-in-ios-pwa\" title=\"Download\" aria-label=\"Download\" href=\"");
try compat.htmlEscape(w, try blobUrl(ctx,attachment,true));
try w.writeAll("\">\n            <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "download.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n</a>\n          <button class=\"btn message__action-btn center full-width\" data-controller=\"web-share\" data-action=\"web-share#share\" data-web-share-files-value=\"");
try compat.htmlEscape(w, try blobUrl(ctx,attachment,false));
try w.writeAll("\" data-web-share-title-value=\"");
try compat.htmlEscape(w, attachment.filename);
try w.writeAll("\" title=\"Share\" aria-label=\"Share\">\n            <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "share.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n</button>");
} else {
try w.writeAll("\n          <button class=\"btn message__action-btn center full-width\" data-action=\"reply#reply\" title=\"Reply\" aria-label=\"Reply\">\n            <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "reply.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n</button>");
}
try w.writeAll("\n\n        <button class=\"btn message__action-btn center full-width\" title=\"Copy link\" aria-label=\"Copy link\" data-controller=\"copy-to-clipboard\" data-action=\"copy-to-clipboard#copy\" data-copy-to-clipboard-success-class=\"btn--success\" data-copy-to-clipboard-url-value=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/rooms/{d}/@{d}", .{m.room_id,m.id}));
try w.writeAll("\">\n          <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "link.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n</button>\n        <a class=\"btn message__action-btn center full-width message__edit-btn\" data-turbo-frame=\"");
try writeMessageId(w,m,"edit");
try w.writeAll("\" title=\"Edit\" aria-label=\"Edit\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/rooms/{d}/messages/{d}/edit", .{m.room_id,m.id}));
try w.writeAll("\">\n          <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "pencil.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n</a>      </div>\n    </div>\n</details></div>\n");
}

fn boost(ctx: *Context,w: *Io.Writer,b: model.Boost) !void {
try w.writeAll("\n  <div id=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "boost_{d}", .{b.id}));
try w.writeAll("\"\n      class=\"boost boost-item flex-inline postion--relative max-width align-center fill-white gap\"\n      data-controller=\"boost-delete\" data-boost-delete-perform-class=\"boost--deleting\" data-boost-delete-reveal-class=\"expanded\" data-boost-delete-booster-id-value=\"");
try w.print("{d}", .{b.booster.id});
try w.writeAll("\">\n    <figure class=\"avatar boost__avatar flex-item-no-shrink\">\n      <a title=\"");
try compat.htmlEscape(w, try title(ctx.allocator,b.booster));
try w.writeAll("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/users/{d}",.{b.booster.id}));
try w.writeAll("\"><img aria-label=\"");
try compat.htmlEscape(w, b.booster.name);
try w.writeAll(" boosted ");
try compat.htmlEscape(w, b.content);
try w.writeAll("\" src=\"");
try compat.htmlEscape(w, try avatarUrl(ctx,b.booster));
try w.writeAll("\" width=\"48\" height=\"48\" /></a>\n    </figure>\n\n    <span role=\"button\" class=\"");
if (allEmoji(b.content)) {
try w.writeAll("txt-small txt-medium");
} else {
try w.writeAll("txt-small");
}
try w.writeAll("\" data-action=\"click-&gt;boost-delete#reveal keydown.enter-&gt;boost-delete#reveal:prevent\" data-boost-delete-target=\"content\">");
try compat.htmlEscape(w, b.content);
try w.writeAll("</span>\n\n    <form class=\"button_to\" method=\"post\" action=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/messages/{d}/boosts/{d}",.{b.message_id,b.id}));
try w.writeAll("\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button data-action=\"boost-delete#perform\" data-boost-delete-target=\"button\" class=\"btn btn--negative flex-item-justify-end boost__delete\" type=\"submit\">\n      <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "minus.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n      <span class=\"for-screen-reader\">Delete this boost</span>\n</button></form>  </div>\n  <span id=\"delete_boost_accessible_label\" class=\"for-screen-reader\">Press enter to delete this boost</span>\n");
}

fn boosts(ctx: *Context,w: *Io.Writer,m: model.Message) !void {
try w.writeAll("\n<turbo-frame id=\"");
try writeMessageId(w,m,"boosting");
try w.writeAll("\">\n  <div class=\"boosts flex flex-wrap align-center gap full-width\" style=\"--column-gap: 0.4ch; --row-gap: 0\"\n      data-controller=\"turbo-streaming\" data-action=\"turbo:submit-start->turbo-streaming#unsubscribe\">\n    <div class=\"flex-inline flex-wrap gap\" id=\"");
try writeMessageId(w,m,"boosts");
try w.writeAll("\" data-turbo-streaming-target=\"container\">");
for (m.boosts) |b| { try boost(ctx,w,b);
try w.writeAll("\n      ");
}
try w.writeAll("\n    </div>\n\n    <turbo-frame id=\"");
try writeMessageId(w,m,"new_boost");
try w.writeAll("\">\n      <div class=\"flex-inline message__boost-inline\" data-controller=\"soft-keyboard\">\n        <a class=\"boost__action txt-small btn\" action=\"soft-keyboard#open\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/messages/{d}/boosts/new", .{m.id}));
try w.writeAll("\">\n          <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "boost.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n          <span class=\"for-screen-reader\">Add a boost</span>\n</a>      </div>\n</turbo-frame>  </div>\n</turbo-frame>\n");
}

fn messageTemplate(ctx: *Context,w: *Io.Writer,u: model.User) !void {
try w.writeAll("\n<script type=\"text/template\" data-messages-target=\"template\">\n  <div class=\"message message--me $messageClasses$\"\n      id=\"message_$clientMessageId$\"\n      data-format-message-target=\"message\"\n      data-user-id=\"");
try w.print("{d}", .{u.id});
try w.writeAll("\"\n      data-message-timestamp=\"$messageTimestamp$\"\n      data-messages-target=\"message\">\n    <div class=\"message__day-separator\"><time class=\"message__timestamp\" datetime=\"$messageDatetime$\" data-local-time-target=\"date\"></time></div>\n\n    <figure class=\"avatar message__avatar\">\n      <a title=\"");
try compat.htmlEscape(w, try title(ctx.allocator, u));
try w.writeAll("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/users/{d}", .{u.id}));
try w.writeAll("\"><img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try avatarUrl(ctx, u));
try w.writeAll("\" width=\"48\" height=\"48\" /></a>\n    </figure>\n\n    <div class=\"message__body\">\n      <div class=\"message__body-content\">\n        <div class=\"message__meta\">\n          <h3 class=\"message__heading\">\n            <span class=\"message__author\"><strong>");
try compat.htmlEscape(w, u.name);
try w.writeAll("</strong></span>\n            <span class=\"message__permalink\"><time class=\"message__timestamp\" datetime=\"$messageDatetime$\" data-local-time-target=\"time\"></time></span>\n          </h3>\n          <div class=\"message__actions\">\n            <div class=\"position-relative\">\n              <span class=\"btn message__action-btn message__options-btn\">\n                <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "menu-dots-horizontal.svg"));
try w.writeAll("\" />\n                <span class=\"for-screen-reader\">Message options</span>\n              </span>\n            </div class=\"position-relative\">\n          </div>\n        </div>\n        $body$\n      </div>\n    </div>\n  </div>\n</script>\n");
}

fn nav(ctx: *Context,w: *Io.Writer,r: model.Room,account: model.Account) !void {
if (account.logo != null) {
try w.writeAll("\n  ");
try accountLogo(ctx,w,account,"");
}
try w.writeAll("\n\n  <span class=\"btn btn--reversed btn--faux room--current\">\n    <h1 class=\"room__contents txt-medium overflow-ellipsis\">");
if (r.kind == .direct) {
try w.writeAll("\n        <span class=\"for-screen-reader\">Ping with</span>");
}
try w.writeAll("\n\n      ");
try compat.htmlEscape(w, r.display_name);
try w.writeAll("\n    </h1>\n</span>\n\n  <a class=\"btn\" style=\"view-transition-name: edit-room-");
try w.print("{d}", .{r.id});
try w.writeAll("\" data-room-id=\"");
try w.print("{d}", .{r.id});
try w.writeAll("\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/rooms/{s}/{d}/edit",.{switch(r.kind){.open=>"opens",.closed=>"closeds",.direct=>"directs"},r.id}));
try w.writeAll("\">\n    <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "menu-dots-horizontal.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n    <span class=\"for-screen-reader\">Settings for this ");
try compat.htmlEscape(w, if (r.kind == .direct) "Ping" else "room");
try w.writeAll("</span>\n</a>\n\n  ");
try bell(ctx,w,r);
try w.writeAll("\n");
}

fn composer(ctx: *Context,w: *Io.Writer,r: model.Room) !void {
try w.writeAll("\n  <div class=\"composer flex align-end gap position-relative\"\n      data-controller=\"typing-notifications\" data-typing-notifications-active-class=\"typing-indicator--active\">\n    <a class=\"btn flex-item-no-shrink margin-block-end composer__context-btn\" style=\"view-transition-name: input-switcher\" href=\"");
try w.writeAll("/searches");
try w.writeAll("\">\n      <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "search.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n      <span class=\"for-screen-reader\">Search</span>\n</a>\n    <turbo-frame id=\"composer-frame\">\n      <form id=\"composer\" class=\"margin-block flex-item-grow contain\" data-controller=\"composer drop-target\" data-action=\"dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop drop-target:drop@window-&gt;composer#dropFiles lexxy:file-accept-&gt;composer#preventAttachment refresh-room:online@window-&gt;composer#online typing-notifications#stop paste-&gt;composer#pasteFiles turbo:submit-end-&gt;composer#submitEnd refresh-room:offline@window-&gt;composer#offline\" data-composer-messages-outlet=\"#message-area\" data-composer-toolbar-class=\"composer--rich-text\" data-composer-room-id-value=\"");
try w.print("{d}", .{r.id});
try w.writeAll("\" action=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/rooms/{d}/messages",.{r.id}));
try w.writeAll("\" accept-charset=\"UTF-8\" method=\"post\">\n        <fieldset data-composer-target=\"fields\" contents>\n          <div class=\"flex flex-column\">\n            <div class=\"composer__filelist flex flex--align-center gap flex-wrap\" data-composer-target=\"fileList\"></div>\n\n            <div class=\"flex composer__input input input--actor fill-white min-width\" style=\"--input-border-radius: 1.3rem\">\n              <div class=\"flex align-end gap full-width\">\n                <img aria-hidden=\"true\" class=\"composer__input-hint colorize--black\" style=\"view-transition-name: input-btn;\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "messages-outlined.svg"));
try w.writeAll("\" width=\"22\" height=\"22\" />\n\n                <div class=\"flex flex-column flex-item-grow min-width gap\">\n                  <lexxy-editor rows=\"1\" class=\"input lexxy-content\" style=\"order: -1\" aria-multiline=\"true\" aria-label=\"Write a message\" permitted-attachment-types=\"application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed\" data-controller=\"unfurl\" data-action=\"lexxy:change-&gt;typing-notifications#start keydown-&gt;composer#submitByKeyboard:capture lexxy:change-&gt;composer#saveDraft lexxy:insert-link-&gt;unfurl#unfurl\" data-composer-target=\"text\" data-direct-upload-url=\"");
try compat.htmlEscape(w, try absolute(ctx,"/rails/active_storage/direct_uploads"));
try w.writeAll("\" data-blob-url-template=\"");
try compat.htmlEscape(w, try absolute(ctx,"/rails/active_storage/blobs/redirect/:signed_id/:filename"));
try w.writeAll("\" id=\"message_body\" input=\"message_body_trix_input_message\" name=\"message[body]\">\n                    <lexxy-prompt trigger=\"@\" name=\"mention\" src=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/autocompletable/users?room_id={d}",.{r.id}));
try w.writeAll("\" remote-filtering=\"true\" empty-results=\"No matches\"></lexxy-prompt>\n</lexxy-editor>                </div>\n\n                <label class=\"btn btn--borderless txt-small flex-item-no-shrink composer__attachment-btn input--file\">\n                  <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "attachment.svg"));
try w.writeAll("\" width=\"22\" height=\"22\" />\n                  <input type=\"file\" data-action=\"composer#filePicked\" multiple />\n                  <span class=\"for-screen-reader\">Attach a file</span>\n                </label>\n\n                <button class=\"btn btn--borderless txt-small flex-item-no-shrink composer__rich-text-btn\" type=\"button\" data-action=\"composer#toggleToolbar\">\n                  <img class=\"colorize--black\" aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "text-options.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n                  <span class=\"for-screen-reader\">Rich text</span>\n                </button>\n\n                <button name=\"send\" type=\"submit\" data-action=\"composer#submit\" class=\"btn btn--reversed flex-item-no-shrink txt-small\">\n                  <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "arrow-up.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n                  <span class=\"for-screen-reader\">Send Message</span>\n</button>              </div>\n            </div>\n          </div>\n        </fieldset>\n\n        <div class=\"typing-indicator gap txt-small align-center flex-inline\" data-typing-notifications-target=\"indicator\">\n          <div class=\"typing-indicator__author spinner\" data-typing-notifications-target=\"author\"></div>\n        </div>\n\n        <input data-composer-target=\"clientid\" type=\"hidden\" name=\"message[client_message_id]\" id=\"message_client_message_id\" />\n</form>    </turbo-frame>\n  </div>\n");
}

fn bell(ctx: *Context,w: *Io.Writer,r: model.Room) !void {
const p = Platform.from(ctx.user_agent);
try w.writeAll("\n<span>\n  <span class=\"button_to_change_notifying\"\n      data-controller=\"notifications\" data-notifications-subscriptions-url-value=\"");
try w.writeAll("/users/me/push_subscriptions");
try w.writeAll("\" data-notifications-attention-class=\"btn--pulsing\">\n    <turbo-frame data-controller=\"turbo-frame\" data-action=\"notifications:ready@window-&gt;turbo-frame#load\" data-turbo-frame-url-param=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/rooms/{d}/involvement",.{r.id}));
try w.writeAll("\" id=\"");
try writeRoomId(w,r,"involvement");
try w.writeAll("\">\n      <button class=\"btn\" data-action=\"click->notifications#attemptToSubscribe\" data-notifications-target=\"bell\">\n        <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "notification-bell-loading.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n        <img aria-hidden=\"true\" hidden=\"hidden\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "notification-bell-alert.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n        <span class=\"for-screen-reader\">Notification settings for this ");
try compat.htmlEscape(w, if (r.kind == .direct) "Ping" else "room");
try w.writeAll("</span>\n      </button>\n</turbo-frame>\n    <dialog data-notifications-target=\"notAllowedNotice\" class=\"dialog pad center center-block border-radius border shadow\" style=\"--inline-space: var(--block-space)\">\n      <div class=\"flex flex-column txt-align-center\">\n        <span class=\"btn btn--faux center txt-x-large\">\n          <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "notification-bell-alert.svg"));
try w.writeAll("\" width=\"48\" height=\"48\" />\n          <span class=\"for-screen-reader\">Notifications alert</span>\n        </span>\n\n        <section>\n          <h1 class=\"txt-large margin-none\">Notifications aren’t allowed</h1>\n          <div class=\"txt-align-start margin-block-start\">\n            ");
if (!((p.safari || p.chrome) && p.ios)) {
try w.writeAll("  <details class=\"notifications-help\" data-notifications-target=\"details\">\n    <summary class=\"btn\">\n      ");
try image(ctx,w,"external/web.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("\n      <strong>Check your ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(" settings</strong>\n      ");
try image(ctx,w,"disclosure.svg"," class=\"disclosure\" width=\"10\" height=\"10\" aria-hidden=\"true\"");
try w.writeAll("\n    </summary>\n\n");
if (p.firefox && p.android) {
try w.writeAll("        <ol>\n          <li>Tap <em>");
try image(ctx,w,"lock.svg"," alt=\"the View site information button\" width=\"20\" height=\"20\"");
try w.writeAll("</em> in the address bar.</li>\n          <li>Tap <em>Notification</em> to change to <em>Allowed</em>.</li>\n        </ol>\n");
} else if (p.edge && p.desktop) {
try w.writeAll("        <h2 class=\"txt-normal txt-medium margin-block-start\">Turn on notifications for this website.</h2>\n        <ol>\n          <li>Click <em>");
try image(ctx,w,"lock.svg"," alt=\"the View site information button\" width=\"20\" height=\"20\"");
try w.writeAll("</em> left of the address bar.</li>\n          <li>Under <em>Permissions for this site &gt; Notifications</em>, choose <em>Allow</em>.</li>\n        </ol>\n        <h2 class=\"txt-normal txt-medium margin-block-start\">Turn on notifications for ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(".</h2>\n        <ol>\n");
if (p.windows) {
try w.writeAll("            <li>Click <em>Start</em>, then <em>Settings</em>.</li>\n            <li>Go to <em>System &gt; Notification</em>.</li>\n            <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> <em>ON</em> for ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(".</li>\n");
} else {
try w.writeAll("            <li>Click <em aria-label=\"the Apple menu\"></em> in the top left.</li>\n            <li>Click <em>System Settings…</em>.</li>\n            <li>Click <em>Notifications</em>.</li>\n            <li>Click <em>");
try compat.htmlEscape(w, p.browser);
try w.writeAll("</em>.</li>\n            <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow notifications</em>.</li>\n");
}
try w.writeAll("        </ol>\n");
} else if (p.firefox && p.desktop) {
try w.writeAll("        <h2 class=\"txt-normal txt-medium margin-block-start\">Turn on notifications for this website.</h2>\n        <ol>\n          <li>Click <em>");
try compat.htmlEscape(w, p.browser);
try w.writeAll("</em> in the top left.</li>\n          <li>Click <em>Settings…</em>.</li>\n          <li>Click <em>Privacy & Security</em> in the sidebar.</li>\n          <li>Scroll down to <em>Permissions</em>.</li>\n          <li>Click <em>Settings</em> next to <em>Notifications</em>.</li>\n          <li>Select <em>Allow</em> next to <em>");
try compat.htmlEscape(w, try absolute(ctx,"/"));
try w.writeAll("</em>.</li>\n        </ol>\n\n        <h2 class=\"txt-normal txt-medium margin-block-start\">Turn on notifications for ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(".</h2>\n        <ol>\n");
if (p.windows) {
try w.writeAll("            <li>Click <em>Start</em>, then <em>Settings</em>.</li>\n            <li>Go to <em>System &gt; Notification</em>.</li>\n            <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the toggle button\" width=\"22\" height=\"22\"");
try w.writeAll("</em> <em>ON</em> for ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(".</li>\n");
} else {
try w.writeAll("            <li>Click <em aria-label=\"the Apple menu\"></em> in the top left.</li>\n            <li>Click <em>System Settings…</em>.</li>\n            <li>Click <em>Notifications</em>.</li>\n            <li>Click <em>");
try compat.htmlEscape(w, p.browser);
try w.writeAll("</em>.</li>\n            <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow notifications</em>.</li>\n");
}
try w.writeAll("        </ol>\n");
} else if (p.chrome && p.desktop) {
try w.writeAll("        <h2 class=\"txt-normal txt-medium margin-block-start\">Turn on notifications for this website.</h2>\n        <ol>\n          <li>Click the <em>");
try image(ctx,w,"external/sliders.svg"," alt=\"View site information\" width=\"20\" height=\"20\"");
try w.writeAll("</em> icon in the address bar.</li>\n          <li>Click <em>Site Settings</em>.</li>\n          <li>Ensure notifications are <em>Allowed</em>.</li>\n        </ol>\n\n        <h2 class=\"txt-normal txt-medium margin-block-start\">Turn on notifications for ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(".</h2>\n        <ol>\n");
if (p.windows) {
try w.writeAll("            <li>Click <em>Start</em>, then <em>Settings</em>.</li>\n            <li>Go to <em>System &gt; Notification</em>.</li>\n            <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> <em>ON</em> for ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(".</li>\n");
} else {
try w.writeAll("            <li>Click <em aria-label=\"the Apple menu\"></em> in the top left.</li>\n            <li>Click <em>System Settings…</em>.</li>\n            <li>Click <em>Notifications</em>.</li>\n            <li>Click <em>");
try compat.htmlEscape(w, p.browser);
try w.writeAll("</em>.</li>\n            <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow notifications</em>.</li>\n");
}
try w.writeAll("        </ol>\n");
} else if (p.chrome && p.android) {
try w.writeAll("        <ol>\n          <li>Tap the <em>");
try image(ctx,w,"menu-dots-vertical.svg"," alt=\"More options\" width=\"16\" height=\"16\"");
try w.writeAll("</em> menu button.</li>\n          <li>Tap <em>Settings</em>.</li>\n          <li>Tap <em>Notifications</em>.</li>\n          <li>Tap <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(" notifications</em>.</li>\n          <li>Tap <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> next to <em>Web apps</em>.</li>\n          <li>Tap <em>");
try image(ctx,w,"notification-bell-alert.svg"," alt=\"the notification bell\" width=\"16\" height=\"16\"");
try w.writeAll("</em> and select <em>Allow</em>.</li>\n        </ol>\n");
} else if (p.safari && p.desktop) {
try w.writeAll("        <ol>\n          <li>Click <em>");
try compat.htmlEscape(w, p.browser);
try w.writeAll("</em> in the top left.</li>\n          <li>Click <em>Settings…</em>.</li>\n          <li>Click the <em>Websites</em> tab.</li>\n          <li>Click <em>Notifications</em> in the sidebar.</li>\n          <li>Click <em>");
try compat.htmlEscape(w, try absolute(ctx,"/"));
try w.writeAll("</em> in the list.</li>\n          <li>Select <em>Allow</em>.</li>\n        </ol>\n");
} else {
try w.writeAll("        <p>Ensure notifications are enabled for <em>");
try compat.htmlEscape(w, try absolute(ctx,"/"));
try w.writeAll("</em> in your web browser settings.</p>\n");
}
try w.writeAll("  </details>\n");
}
try w.writeAll("\n");
try w.writeAll("\n            ");
try w.writeAll("<details class=\"notifications-help hide-in-browser\" data-notifications-target=\"details\">\n  <summary class=\"btn\">\n    ");
try image(ctx,w,"external/gear.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("\n    <strong>Check your ");
try compat.htmlEscape(w, p.operating_system);
try w.writeAll(" settings</strong>\n    ");
try image(ctx,w,"disclosure.svg"," class=\"disclosure\" width=\"10\" height=\"10\" aria-hidden=\"true\"");
try w.writeAll("\n  </summary>\n\n");
if (p.firefox && p.android) {
try w.writeAll("      <ol>\n        <li>Tap the <em>");
try image(ctx,w,"menu-dots-vertical.svg"," alt=\"More options\" width=\"16\" height=\"16\"");
try w.writeAll("</em> menu button.</li>\n        <li>Tap <em>Settings</em>.</li>\n        <li>Tap <em>Notifications</em>.</li>\n        <li>Tap <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the toggle button\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(" notifications</em>.</li>\n      </ol>\n");
} else if (p.edge && p.desktop) {
try w.writeAll("      <ol>\n        <li>Click <em>Start</em>, then <em>Settings</em>.</li>\n        <li>Go to <em>System &gt; Notification</em>.</li>\n        <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the toggle button\" width=\"22\" height=\"22\"");
try w.writeAll("</em> <em>ON</em> for Campfire.</li>\n      </ol>\n");
} else if ((p.firefox || p.chrome) && p.desktop) {
try w.writeAll("      <ol>\n");
if (p.windows) {
try w.writeAll("          <li>Click <em>Start</em>, then <em>Settings</em>.</li>\n          <li>Go to <em>System &gt; Notification</em>.</li>\n          <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the toggle button\" width=\"22\" height=\"22\"");
try w.writeAll("</em> <em>ON</em> for Campfire.</li>\n");
} else {
try w.writeAll("          <li>Click <em aria-label=\"the Apple menu\"></em> in the top left.</li>\n          <li>Click <em>System Settings…</em>.</li>\n          <li>Click <em>Notifications</em>.</li>\n          <li>Click <em>Campfire</em>.</li>\n          <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the allow notifications switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow notifications</em>.</li>\n");
}
try w.writeAll("      </ol>\n");
} else if (p.safari && p.desktop) {
try w.writeAll("      <ol>\n        <li>Click <em aria-label=\"the Apple menu\"></em> in the top left.</li>\n        <li>Click <em>System Settings…</em>.</li>\n        <li>Click <em>Notifications</em>.</li>\n        <li>Click <em>Campfire</em>.</li>\n        <li>Click <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the allow notifications switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow notifications</em>.</li>\n      </ol>\n");
} else if ((p.safari || p.chrome) && p.ios) {
try w.writeAll("      <ol>\n        <li>Open the <em>");
try image(ctx,w,"external/gear.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("</em> Settings app.</li>\n        <li>Scroll to and tap <em>Campfire</em>.</li>\n        <li>Tap <em>Notifications</em>.</li>\n        <li>Tap <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the allow notifications switch button\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow Notifications</em>.</li>\n      </ol>\n");
} else if (p.chrome && p.android) {
try w.writeAll("      <ol>\n        <li>Open the <em>");
try image(ctx,w,"external/gear.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("</em> Settings app.</li>\n        <li>Tap <em>Notifications</em>.</li>\n        <li>Tap <em>App notifications</em>.</li>\n        <li>Scroll to <em>Campfire</em>.</li>\n        <li>Tap <em>");
try image(ctx,w,"external/switch.svg"," alt=\"the switch\" width=\"22\" height=\"22\"");
try w.writeAll("</em> to <em>Allow Notifications</em>.</li>\n      </ol>\n");
} else {
try w.writeAll("      <p>Ensure notifications are allowed for ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(" in your system settings.</p>\n");
}
try w.writeAll("</details>\n\n");
try w.writeAll("\n            ");
if (!(p.chrome || (p.firefox && !p.android))) {
try w.writeAll("  <details class=\"notifications-help pwa__instructions hide-in-pwa\" data-controller=\"pwa-install\" data-pwa-install-prompting-class=\"pwa--can-install\" data-notifications-target=\"details\">\n    <summary class=\"btn\">\n      ");
try image(ctx,w,"external/install.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("\n      <strong>Install Campfire as a web app.</strong>\n      ");
try image(ctx,w,"disclosure.svg"," class=\"disclosure\" width=\"10\" height=\"10\" aria-hidden=\"true\"");
try w.writeAll("\n    </summary>\n\n");
if (p.edge) {
try w.writeAll("        <ol>\n          <li>Click <em>");
try image(ctx,w,"install-edge.svg"," alt=\"the app available - install Campfire chat button\" width=\"16\" height=\"16\"");
try w.writeAll("</em>in the address bar.</li>\n          <li>Click <em>Install</em>.</li>\n        </ol>\n");
} else if (p.chrome && p.android) {
try w.writeAll("        <ol>\n          <li>Tap the <em>");
try image(ctx,w,"menu-dots-vertical.svg"," alt=\"More options\" width=\"16\" height=\"16\"");
try w.writeAll("</em> menu button.</li>\n          <li>Tap <em>Install app</em> in the menu.</li>\n        </ol>\n");
} else if (p.firefox && p.android) {
try w.writeAll("        <ol>\n          <li>Tap the <em>");
try image(ctx,w,"menu-dots-vertical.svg"," alt=\"More options\" width=\"16\" height=\"16\"");
try w.writeAll("</em> menu button.</li>\n          <li>Tap <em>Install</em> in the menu.</li>\n        </ol>\n");
} else if (p.safari && p.desktop) {
try w.writeAll("        <ol>\n          <li>Click <em>File</em> in the top left.</li>\n          <li>Click <em>Add to Dock…</em>.</li>\n        </ol>\n");
} else if ((p.safari || p.chrome) && p.ios) {
try w.writeAll("        <p>To receive push notifications in ");
try compat.htmlEscape(w, p.browser);
try w.writeAll(" for ");
try compat.htmlEscape(w, p.operating_system);
try w.writeAll(", you must install Campfire as a web app.</p>\n        <ol>\n          <li>Tap <em>");
try image(ctx,w,"external/share.svg"," alt=\"the share button\" width=\"20\" height=\"20\"");
try w.writeAll("</em></li>\n          <li>Tap <em>Add to Home Screen</em>.</li>\n        </ol>\n");
} else {
try w.writeAll("        <p>Some platforms require you to install Campfire as a web app to receive push notifications.</p>\n");
}
try w.writeAll("\n    <div class=\"margin-block-start txt-align-center pwa__installer\">\n      <hr class=\"separator margin-block\">\n      <button class=\"btn btn--reversed center\" data-action=\"pwa-install#promptInstall\">\n        ");
try image(ctx,w,"external/install.svg"," aria-hidden=\"true\"");
try w.writeAll("\n        Install now\n      </button>\n    </div>\n  </details>\n");
}
try w.writeAll("\n");
try w.writeAll("\n          </div>\n        </section>\n\n        <form method=\"dialog\" class=\"flex align-center gap center\">\n          <button class=\"btn dialog__close\" autofocus=\"true\">\n            <span class=\"for-screen-reader\">Close</span>\n            <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "remove.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n          </button>\n        </form>\n      </div>\n    </dialog>\n  </span>\n</span>\n");
}
fn layoutHead(ctx: *Context,w: *Io.Writer,account: model.Account,page_title: []const u8,body_class: []const u8,extra_head: []const u8) !void {
    try w.writeAll("<!DOCTYPE html><html><head><title>");
    try compat.htmlEscape(w,page_title);
    try w.writeAll("</title><meta name=\"viewport\" content=\"width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content\"><meta name=\"view-transition\" content=\"same-origin\"><meta name=\"color-scheme\" content=\"light dark\"><meta name=\"theme-color\" content=\"#ffffff\" media=\"(prefers-color-scheme: light)\"><meta name=\"theme-color\" content=\"#000000\" media=\"(prefers-color-scheme: dark)\"><meta name=\"apple-mobile-web-app-capable\" content=\"yes\">");
    try w.print("<meta name=\"current-user-id\" content=\"{d}\" /><meta name=\"current-user-name\" content=\"",.{ctx.user.id});
    try compat.htmlEscape(w,ctx.user.name);
    try w.writeAll("\" /><meta name=\"action-cable-url\" content=\"");
    const cable_base = std.mem.trimEnd(u8,ctx.base_url,"/");
    if (std.mem.startsWith(u8,cable_base,"https://")) { try w.writeAll("wss://"); try compat.htmlEscape(w,cable_base[8..]); }
    else if (std.mem.startsWith(u8,cable_base,"http://")) { try w.writeAll("ws://"); try compat.htmlEscape(w,cable_base[7..]); }
    else return error.InvalidBaseUrl;
    try w.writeAll("/cable\"><meta name=\"vapid-public-key\"");
    if (ctx.vapid_public_key) |key| { try w.writeAll(" content=\"");try compat.htmlEscape(w,key);try w.writeAll("\""); }
    try w.writeAll("><meta name=\"turbo-prefetch\" content=\"true\"><link rel=\"manifest\" href=\"/webmanifest.json\"><link rel=\"icon\" href=\"");
    const logo_url = try accountLogoUrl(ctx.allocator,account);
    try compat.htmlEscape(w,logo_url);
    try w.writeAll("\" type=\"image/png\"><link rel=\"apple-touch-icon\" href=\"");try compat.htmlEscape(w,logo_url);try w.writeAll("\">");
    for (ctx.assets.stylesheets()) |logical| { try w.writeAll("<link rel=\"stylesheet\" href=\"");try compat.htmlEscape(w,try asset(ctx,logical));try w.writeAll("\" data-turbo-track=\"reload\" />"); }
    if (account.custom_styles) |styles| {try w.writeAll("<style data-turbo-track=\"reload\">");try w.writeAll(styles);try w.writeAll("</style>");}
    try w.writeAll(ctx.assets.importmapTags());
    try w.writeAll(extra_head);
    try w.writeAll("</head><body class=\"");try compat.htmlEscape(w,body_class);
    if (ctx.user.isAdministrator()) try w.writeAll(if(body_class.len != 0) " admin" else "admin");
    if (account.logo != null) try w.writeAll(if(body_class.len != 0 or ctx.user.isAdministrator()) " account-has-logo" else "account-has-logo");
    try w.writeAll("\" data-controller=\"local-time lightbox\"><a href=\"#main-content\" class=\"skip-navigation btn\">Skip to main content</a><nav id=\"nav\">");
}
fn frameHead(w: *Io.Writer,head: []const u8) !void {try w.writeAll("<html><head>");try w.writeAll(head);try w.writeAll("</head><body>");}
fn accountLogo(ctx: *Context,w: *Io.Writer,account: model.Account,style: []const u8) !void {
    try w.writeAll("<figure class=\"account-logo avatar ");try compat.htmlEscape(w,style);try w.writeAll("\"><img alt=\"Account logo\" width=\"300\" height=\"300\" src=\"");
    try compat.htmlEscape(w,try accountLogoUrl(ctx.allocator,account));try w.writeAll("\" /></figure>");
}
fn sidebarFrame(w: *Io.Writer,src: ?[]const u8) !void {
    try w.writeAll("<turbo-frame id=\"user_sidebar\" target=\"_top\" data-turbo-permanent=\"true\" data-controller=\"rooms-list read-rooms turbo-frame\" data-rooms-list-unread-class=\"unread\" data-action=\"presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload\"");
    if (src) |s| {try w.writeAll(" src=\"");try compat.htmlEscape(w,s);try w.writeAll("\"");}
    try w.writeAll(">");
}

fn layoutFoot(ctx: *Context,w: *Io.Writer) !void {
try w.writeAll("<dialog class=\"lightbox\" aria-label=\"Image Viewer (Press escape to close)\" data-lightbox-target=\"dialog\" data-action=\"close->lightbox#reset\">\n  <img src=\"\" class=\"lightbox__image\" data-lightbox-target=\"zoomedImage\" />\n\n  <form method=\"dialog\" class=\"lightbox__btn\">\n    <button class=\"btn\">\n      ");
try image(ctx,w,"remove.svg"," aria-hidden=\"true\"");
try w.writeAll("\n      <span class=\"for-screen-reader\">Close image viewer</span>\n    </button>\n  </form>\n\n  <a href=\"\" class=\"lightbox__btn--download btn hide-in-ios-pwa\" data-lightbox-target=\"download\">\n    ");
try image(ctx,w,"download.svg"," aria-hidden=\"true\"");
try w.writeAll("\n    <span class=\"for-screen-reader\">Download file</span>\n  </a>\n\n  <button class=\"lightbox__btn--share btn\"\n      data-controller=\"web-share\"\n      data-action=\"web-share#share\"\n      data-web-share-files-value=\"\"\n      data-lightbox-target=\"share\">\n    ");
try image(ctx,w,"share.svg"," aria-hidden=\"true\"");
try w.writeAll("\n    <span class=\"for-screen-reader\">Share file</span>\n  </button>\n</dialog>\n\n");
try w.writeAll("<a href=\"https://once.com\" id=\"app-logo\" target=\"_blank\" aria-label=\"Once software from 37signals home page\">");
try image(ctx,w,"campfire-icon.png"," alt="Campfire logo" width="256" height="216"");
try w.writeAll("</a></body></html>");
}
const Sound = struct { name: []const u8,text: ?[]const u8,image: ?[]const u8,width: u32,height: u32 };
const sounds = [_]Sound{.{.name="56k",.text=null,.image="sounds/56k.webp",.width=79,.height=33},.{.name="bell",.text="🔔",.image=null,.width=0,.height=0},.{.name="bezos",.text="😆💭",.image=null,.width=0,.height=0},.{.name="bueller",.text="anyone?",.image=null,.width=0,.height=0},.{.name="butts",.text="👐 🚬",.image=null,.width=0,.height=0},.{.name="clowntown",.text=null,.image="sounds/clowntown.webp",.width=210,.height=150},.{.name="cottoneyejoe",.text="🎶🙉🎶 ",.image=null,.width=0,.height=0},.{.name="crickets",.text="hears crickets chirping",.image=null,.width=0,.height=0},.{.name="curb",.text=null,.image="sounds/curb.webp",.width=150,.height=101},.{.name="dadgummit",.text="dad gummit!! 🎣",.image=null,.width=0,.height=0},.{.name="dangerzone",.text=null,.image="sounds/dangerzone.webp",.width=157,.height=32},.{.name="danielsan",.text="🎆 🏆 🎆",.image=null,.width=0,.height=0},.{.name="deeper",.text=null,.image="sounds/top.webp",.width=188,.height=80},.{.name="ballmer",.text="developers!",.image=null,.width=0,.height=0},.{.name="donotwant",.text=null,.image="sounds/donotwant.webp",.width=150,.height=150},.{.name="drama",.text=null,.image="sounds/drama.webp",.width=300,.height=16},.{.name="flawless",.text="#flawless",.image=null,.width=0,.height=0},.{.name="glados",.text="🤖💢",.image=null,.width=0,.height=0},.{.name="gogogo",.text="Go, go, go!",.image=null,.width=0,.height=0},.{.name="greatjob",.text=null,.image="sounds/greatjob.webp",.width=79,.height=16},.{.name="greyjoy",.text="😖🎺",.image=null,.width=0,.height=0},.{.name="guarantee",.text="guarantees it 👌",.image=null,.width=0,.height=0},.{.name="heygirl",.text="✨💁✨",.image=null,.width=0,.height=0},.{.name="honk",.text="HONK",.image=null,.width=0,.height=0},.{.name="horn",.text="🐶 ✂️ 🐱",.image=null,.width=0,.height=0},.{.name="horror",.text="💀 💀 💀 💀 💀 💀 💀",.image=null,.width=0,.height=0},.{.name="inconceivable",.text="doesn't think it means what you think it means…",.image=null,.width=0,.height=0},.{.name="letitgo",.text="❄️👩❄️⛄️❄️",.image=null,.width=0,.height=0},.{.name="live",.text="is DOING IT LIVE",.image=null,.width=0,.height=0},.{.name="loggins",.text=null,.image="sounds/loggins.webp",.width=200,.height=151},.{.name="makeitso",.text="make it so 👉",.image=null,.width=0,.height=0},.{.name="noooo",.text="👸💀😒",.image=null,.width=0,.height=0},.{.name="nyan",.text=null,.image="sounds/nyan.webp",.width=36,.height=15},.{.name="ohmy",.text="raises an eyebrow 😏",.image=null,.width=0,.height=0},.{.name="ohyeah",.text="isn't playing by the rules",.image=null,.width=0,.height=0},.{.name="pushit",.text=null,.image="sounds/pushit.webp",.width=104,.height=15},.{.name="rimshot",.text="plays a rimshot",.image=null,.width=0,.height=0},.{.name="rollout",.text="is rolling out 🚗",.image=null,.width=0,.height=0},.{.name="rumble",.text=null,.image="sounds/rumble.webp",.width=220,.height=150},.{.name="sax",.text="🌇🎷🎶",.image=null,.width=0,.height=0},.{.name="secret",.text="found a secret area 🔑",.image=null,.width=0,.height=0},.{.name="sexyback",.text="🔞",.image=null,.width=0,.height=0},.{.name="story",.text="and now you know…",.image=null,.width=0,.height=0},.{.name="tada",.text="plays a fanfare 🎏",.image=null,.width=0,.height=0},.{.name="tmyk",.text="✨ ⭐️ The More You Know ✨ ⭐️",.image=null,.width=0,.height=0},.{.name="totes",.text="😁👍",.image=null,.width=0,.height=0},.{.name="trololo",.text="трололо",.image=null,.width=0,.height=0},.{.name="trombone",.text="plays a sad trombone",.image=null,.width=0,.height=0},.{.name="unix",.text="knows this 💻",.image=null,.width=0,.height=0},.{.name="vuvuzela",.text="======<() ~ ♪ ~♫",.image=null,.width=0,.height=0},.{.name="what",.text=null,.image="sounds/what.webp",.width=100,.height=131},.{.name="whoomp",.text="👏‼️😎",.image=null,.width=0,.height=0},.{.name="wups",.text="wups!",.image=null,.width=0,.height=0},.{.name="yay",.text=null,.image="sounds/yay.webp",.width=103,.height=50},.{.name="yeah",.text=null,.image="sounds/yeah.webp",.width=104,.height=15},.{.name="yodel",.text="📣🗻🙉",.image=null,.width=0,.height=0}};
fn findSound(plain: []const u8) ?Sound {
    if (!std.mem.startsWith(u8,plain,"/play ")) return null;
    const name = plain[6..];
    for (sounds) |s| if (std.mem.eql(u8,s.name,name)) return s;
    return null;
}
fn presentation(ctx: *Context,w: *Io.Writer,m: model.Message,rendered: []const u8) !void {
    try w.writeAll("<div id=\"");try writeMessageId(w,m,"presentation");
    try w.writeAll("\" dir=\"auto\" data-reply-target=\"body\" data-messages-target=\"body\">");
    try w.writeAll(rendered);
    try w.writeAll("</div>");
}
fn content(ctx: *Context,m: model.Message,plain: []const u8,detached: bool) ![]const u8 {
    var out = Io.Writer.Allocating.init(ctx.allocator);
    defer out.deinit();
    const w = &out.writer;
    if (m.attachment) |b| { try attachment(ctx,w,b); }
    else if (findSound(plain)) |s| {
        try w.writeAll("<div class=\"sound\" data-controller=\"sound\" data-action=\"messages:play-&gt;sound#play\" data-sound-url-value=\"");
        try compat.htmlEscape(w,try asset(ctx,try fmt(ctx.allocator,"{s}.mp3",.{s.name})));
        try w.writeAll("\"><button class=\"btn btn--plain\" data-action=\"sound#play\">🔊</button>");
        if (s.image) |logical| {try w.print("<img width=\"{d}\" height=\"{d}\" class=\"align--middle\" src=\"",.{s.width,s.height});try compat.htmlEscape(w,try asset(ctx,logical));try w.writeAll("\" />");}
        else if (s.text) |text| try compat.htmlEscape(w,text);
        try w.writeAll("</div>");
    } else {
        const uri = try std.Uri.parse(ctx.base_url);
        return richtext.renderWithHost(ctx.allocator,m.body,ctx.db,ctx.io,ctx.secrets,if(detached) "" else if(uri.host) |host| try host.toRawMaybeAlloc(ctx.allocator) else "");
    }
    return out.toOwnedSlice();
}
fn renderMessage(ctx: *Context,w: *Io.Writer,m: model.Message,detached: bool) !void {
    const plain = richtext.plainText(ctx.allocator,m.body) catch |err| switch (err) {error.OutOfMemory => return err,else => {try w.writeAll("<div class=\"message message--formatted message--failed center\"><div class=\"message__body\"><div class=\"message__body-content txt-align-center\">Failed to load message content</div></div></div>");return;}};
    const created_epoch=try compat.epochMilliseconds(m.created_at);
    const updated_epoch=try compat.epochMilliseconds(m.updated_at);
    const created_iso=try compat.iso8601(ctx.allocator,m.created_at,0);
    const rendered = content(ctx,m,plain,detached) catch |err| switch (err) {error.OutOfMemory => return err,else => {try w.writeAll("<div class=\"message message--formatted message--failed center\"><div class=\"message__body\"><div class=\"message__body-content txt-align-center\">Failed to load message content</div></div></div>");return;}};
try w.writeAll("  <div id=\"");
try writeMessageId(w,m,"");
try w.writeAll("\" class=\"message ");
if (allEmoji(plain)) {
try w.writeAll("message--emoji");
}
try w.writeAll("\" data-controller=\"reply\" data-user-id=\"");
try w.print("{d}", .{m.creator.id});
try w.writeAll("\" data-message-id=\"");
try w.print("{d}", .{m.id});
try w.writeAll("\" data-message-timestamp=\"");
try w.print("{d}", .{created_epoch});
try w.writeAll("\" data-message-updated-at=\"");
try w.print("{d}", .{updated_epoch});
try w.writeAll("\" data-sort-value=\"");
try w.print("{d}", .{created_epoch});
try w.writeAll("\" data-messages-target=\"message\" data-search-results-target=\"message\" data-refresh-room-target=\"message\" data-reply-composer-outlet=\"#composer\">\n    <h2 class=\"message__day-separator\"><time datetime=\"");
try compat.htmlEscape(w, created_iso);
try w.writeAll("\" data-local-time-target=\"date\"></time></h2>\n\n    <figure class=\"avatar message__avatar\">\n      <a title=\"");
try compat.htmlEscape(w, try title(ctx.allocator, m.creator));
try w.writeAll("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/users/{d}", .{m.creator.id}));
try w.writeAll("\"><img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try avatarUrl(ctx, m.creator));
try w.writeAll("\" width=\"48\" height=\"48\" /></a>\n    </figure>\n\n    <turbo-frame id=\"");
try writeMessageId(w,m,"edit");
try w.writeAll("\">\n      <div class=\"message__body\">\n        <div class=\"message__body-content\">\n          <div class=\"message__meta\">\n            <h3 class=\"message__heading\">\n              <span class=\"message__author\" title=\"");
try compat.htmlEscape(w, try title(ctx.allocator, m.creator));
try w.writeAll("\">\n                <strong data-reply-target=\"author\">");
try compat.htmlEscape(w, m.creator.name);
try w.writeAll("</strong>\n              </span>\n              <a target=\"_top\" class=\"message__permalink\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/rooms/{d}/@{d}", .{m.room_id,m.id}));
try w.writeAll("\"><time class=\"message__timestamp\" datetime=\"");
try compat.htmlEscape(w, created_iso);
try w.writeAll("\" data-local-time-target=\"time\"></time></a>\n              <span class=\"message__room\">\n                <a target=\"_top\" data-reply-target=\"link\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator, "/rooms/{d}/@{d}", .{m.room_id,m.id}));
try w.writeAll("\">");
try compat.htmlEscape(w, m.room_name);
try w.writeAll("</a>\n              </span>\n            </h3>\n            ");
try actions(ctx,w,m);
try w.writeAll("\n          </div>\n          ");
try presentation(ctx,w,m, rendered);
try w.writeAll("\n          ");
try boosts(ctx,w,m);
try w.writeAll("\n        </div>\n      </div>\n    </turbo-frame>\n</div>\n");
}
fn representationUrl(ctx: *Context,b: model.Blob,video: bool) ![]const u8 {
    const format=if(video) "webp" else storage.defaultVariantFormat(b);
    const transforms=try fmt(ctx.allocator,"{{\"format\":\"{s}\",\"resize_to_limit\":[1200,800]}}",.{format});
    return storage.representationPath(ctx.allocator,ctx.secrets,b,transforms);
}

const Dimension = union(enum) {
    integer: i64,
    float: f64,
    fn number(self: Dimension) f64 {return switch(self){.integer=>|v| @floatFromInt(v),.float=>|v|v};}
    fn write(self: Dimension,w: *Io.Writer) !void {switch(self){.integer=>|v|try w.print("{d}",.{v}),.float=>|v|{try w.print("{d}",.{v});if (v == @trunc(v)) try w.writeAll(".0");}}}
    fn half(self: Dimension) Dimension {return switch(self){.integer=>|v|.{.integer=@divFloor(v,2)},.float=>|v|.{.float=v/2}};}
};
const Dimensions = struct {width: Dimension,height: Dimension};
fn dimension(value: ?std.json.Value) ?Dimension {
    const v = value orelse return null;
    return switch(v){.integer=>|n|.{.integer=n},.float=>|n|.{.float=n},else=>null};
}
fn dimensions(a: Allocator,b: model.Blob) !?Dimensions {
    const text = b.metadata orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value,a,text,.{}) catch |err| switch(err){error.OutOfMemory=>return err,else=>return null};
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const width = dimension(parsed.value.object.get("width")) orelse return null;
    const height = dimension(parsed.value.object.get("height")) orelse return null;
    const wf = width.number();const hf = height.number();
    if (wf <= 1200 and hf <= 800) return .{.width=width,.height=height};
    const scale = @min(1200/wf,800/hf);
    return .{.width=.{.float=wf*scale},.height=.{.float=hf*scale}};
}
fn attachment(ctx: *Context,w: *Io.Writer,b: model.Blob) !void {
    const ct = b.content_type orelse "";
    const video = std.mem.startsWith(u8,ct,"video");
    const variable = for ([_][]const u8{"image/png","image/gif","image/jpeg","image/tiff","image/webp","image/avif","image/heic","image/heif"}) |t| {if(std.mem.eql(u8,t,ct)) break true;} else false;
    const url = try blobUrl(ctx,b,false);const download = try blobUrl(ctx,b,true);
    if (video or variable) {
        const size = try dimensions(ctx.allocator,b);
        try w.writeAll("<div class=\"max-inline-size center ");
        if (size) |s| {try w.writeAll("flex overflow-clip\" style=\"width: ");try s.width.half().write(w);try w.writeAll("px; aspect-ratio: ");try (Dimension{.float=s.width.number()/s.height.number()}).write(w);try w.writeAll(";\">");}
        else try w.writeAll("overflow-clip\">");
        if (video) {
            try w.writeAll("<video src=\"");try compat.htmlEscape(w,url);try w.writeAll("\" poster=\"");try compat.htmlEscape(w,try representationUrl(ctx,b,true));try w.writeAll("\" controls=\"controls\" preload=\"none\" width=\"100%\" height=\"100%\" class=\"message__attachment\"></video>");
        } else {
            try w.writeAll("<a class=\"flex\" data-lightbox-target=\"image\" data-action=\"lightbox#open\" data-lightbox-url-value=\"");try compat.htmlEscape(w,download);try w.writeAll("\" href=\"");try compat.htmlEscape(w,url);try w.writeAll("\"><img");
            if(size) |s| {try w.writeAll(" width=\"");try s.width.write(w);try w.writeAll("\" height=\"");try s.height.write(w);try w.writeAll("\"");}
            try w.writeAll(" class=\"message__attachment\" loading=\"lazy\" src=\"");try compat.htmlEscape(w,try representationUrl(ctx,b,false));try w.writeAll("\" /></a>");
        }
        try w.writeAll("</div>");
    } else {
        try w.writeAll("<div class=\"flex-inline align-center gap-half\">");try image(ctx,w,"common-file-text.svg"," class=\"colorize--black\" aria-hidden=\"true\" width=\"22\" height=\"22\"");try w.writeAll("<span>");try compat.htmlEscape(w,b.filename);try w.writeAll("</span><a class=\"btn message__action-btn hide-in-ios-pwa\" style=\"--width: auto;\" href=\"");try compat.htmlEscape(w,download);try w.writeAll("\">");try image(ctx,w,"download.svg"," aria-hidden=\"true\" width=\"20\" height=\"20\"");try w.writeAll("<span class=\"for-screen-reader\">Download ");try compat.htmlEscape(w,b.filename);try w.writeAll("</span></a><button class=\"btn message__action-btn\" style=\"--width: auto;\" data-controller=\"web-share\" data-action=\"web-share#share\" data-web-share-files-value=\"");try compat.htmlEscape(w,download);try w.writeAll("\">");try image(ctx,w,"share.svg"," aria-hidden=\"true\" width=\"20\" height=\"20\"");try w.writeAll("<span class=\"for-screen-reader\">Share ");try compat.htmlEscape(w,b.filename);try w.writeAll("</span></button></div>");
    }
}
fn timestampNumber(a: Allocator,text: []const u8) ![]const u8 {
    const iso = try compat.iso8601(a,text,0);
    const result = try a.alloc(u8,14);
    var n: usize = 0;
    for(iso) |c| if(std.ascii.isDigit(c) and n < result.len) {result[n]=c;n+=1;};
    if(n != 14) return error.InvalidTimestamp;
    return result;
}
fn accountLogoUrl(a: Allocator,account: model.Account) ![]const u8 {
    return fmt(a,"/account/logo?v={s}",.{try timestampNumber(a,account.updated_at)});
}
pub fn search(ctx: *Context,page: model.SearchPage) ![]const u8 {
    var out=Io.Writer.Allocating.init(ctx.allocator);defer out.deinit();const w=&out.writer;
    if(ctx.frame_id != null) {
        try frameHead(w,"");
try w.writeAll("\n<div id=\"message-area\" class=\"message-area\">\n  <div class=\"message-area--empty min-width center\">\n    <figure class=\"center pad\">\n      <img aria-hidden=\"true\" class=\"colorize--black translucent\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "search.svg"));
try w.writeAll("\" />\n    </figure>\n  </div>\n\n  <div id=\"search-results\" class=\"messages searches__results\" data-controller=\"search-results\" data-search-results-target=\"messages\" data-search-results-me-class=\"message--me\" data-search-results-threaded-class=\"message--threaded\" data-search-results-mentioned-class=\"message--mentioned\" data-search-results-formatted-class=\"message--formatted\">");
for (page.messages) |m| {
try w.writeAll("\n    ");
try renderMessage(ctx,w,m,false);
}
try w.writeAll("\n  </div></div>\n");
try w.writeAll("</body></html>");

    } else {
        try layoutHead(ctx,w,page.account,"Search","sidebar searches","");
if (page.query) |query| {
try w.writeAll("\n    <div class=\"searches__query flex align-center gap pad-block-start-half\">\n      <div class=\"btn btn--reversed btn--faux align-center gap txt-nowrap\">\n        <span class=\"overflow-ellipsis\">“");
try compat.htmlEscape(w, query);
try w.writeAll("”</span>\n        <span class=\"flex-item-no-shrink\">");
try w.print("{d}", .{page.messages.len});
try w.writeAll("</span>\n</div>    </div>");
}
try w.writeAll("\n\n  <div class=\"searches__recents align-center gap pad-block-half overflow-y overflow-hide-scrollbar\">\n    ");
for (page.recent_searches) |recent| {
try w.writeAll("\n      <a class=\"align-center gap room btn txt-nowrap\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/searches?q={s}",.{try queryEncode(ctx.allocator,recent)}));
try w.writeAll("\">\n        <span class=\"overflow-ellipsis\">“");
try compat.htmlEscape(w, recent);
try w.writeAll("”</span>\n</a>");
}
if (page.recent_searches.len != 0) {
try w.writeAll("\n      <form class=\"button_to\" method=\"post\" action=\"");
try compat.htmlEscape(w, try absolute(ctx,"/searches/clear"));
try w.writeAll("\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn searches__btn\" data-turbo-confirm=\"Are you sure you want to clear your recent searches?\" type=\"submit\">\n        <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "broom.svg"));
try w.writeAll("\" />\n        <span class=\"for-screen-reader\">Clear recent searches</span>\n</button></form>");
}
try w.writeAll("\n");
try w.writeAll("\n  </div>\n");
try w.writeAll("</nav><main id=\"main-content\">");
try w.writeAll("\n<div id=\"message-area\" class=\"message-area\">\n  <div class=\"message-area--empty min-width center\">\n    <figure class=\"center pad\">\n      <img aria-hidden=\"true\" class=\"colorize--black translucent\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "search.svg"));
try w.writeAll("\" />\n    </figure>\n  </div>\n\n  <div id=\"search-results\" class=\"messages searches__results\" data-controller=\"search-results\" data-search-results-target=\"messages\" data-search-results-me-class=\"message--me\" data-search-results-threaded-class=\"message--threaded\" data-search-results-mentioned-class=\"message--mentioned\" data-search-results-formatted-class=\"message--formatted\">");
for (page.messages) |m| {
try w.writeAll("\n    ");
try renderMessage(ctx,w,m,false);
}
try w.writeAll("\n  </div></div>\n");
try w.writeAll("<footer id=\"footer\">");
try w.writeAll("\n  <div class=\"composer flex align-end gap\">\n    <a class=\"btn flex-item-no-shrink margin-block-end\" style=\"view-transition-name: input-switcher; --btn-border-radius: 0.5em\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/rooms/{d}",.{page.return_to_room_id}));
try w.writeAll("\">\n      <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "arrow-left.svg"));
try w.writeAll("\" />\n      <span class=\"for-screen-reader\">Exit search </span>\n</a>\n    <form class=\"margin-block flex-item-grow contain flex align-center gap\" data-controller=\"form\" data-action=\"keydown.esc-&gt;form#cancel\" action=\"");
try w.writeAll("/searches");
try w.writeAll("\" accept-charset=\"UTF-8\" method=\"post\">\n      <div class=\"composer__input flex align-center flex-item-grow gap full-width input input--actor min-width\">\n        <img aria-hidden=\"true\" class=\"composer__input-hint colorize--black\" style=\"view-transition-name: input-btn;\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "search.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" />\n\n        <input");
if (page.q) |q| {
try w.writeAll(" value=\"");
try compat.htmlEscape(w, q);
try w.writeAll("\"");
}
try w.writeAll(" class=\"searches__input input flex-item-grow\" role=\"searchbox\" aria-label=\"search\" autofocus=\"autofocus\" required=\"required\" type=\"text\" name=\"q\" id=\"q\" />\n\n        <a data-form-target=\"cancel\" role=\"button\" class=\"searches__reset\" href=\"");
try w.writeAll("/searches");
try w.writeAll("\">\n          <img aria-hidden=\"true\" class=\"colorize--black\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "remove.svg"));
try w.writeAll("\" width=\"14\" height=\"14\" />\n          <span class=\"for-screen-reader\">Clear search field</span>\n</a>\n        <button name=\"button\" type=\"submit\" class=\"btn btn--reversed flex-item-no-shrink txt-small\" style=\"--btn-border-radius: 0.5em\">\n          <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "arrow-up.svg"));
try w.writeAll("\" />\n          <span class=\"for-screen-reader\">Search</span>\n</button>      </div>\n</form>  </div>\n");
try w.writeAll("</footer></main><aside id=\"sidebar\" data-controller=\"toggle-class\" data-toggle-class-toggle-class=\"open\">");
try w.writeAll("\n  <div class=\"rooms position-relative flex flex-column gap overflow-y overflow-hide-scrollbar\">\n    ");
for (page.recent_searches) |recent| {
try w.writeAll("\n      <a class=\"align-center gap room btn txt-nowrap\" href=\"");
try compat.htmlEscape(w, try fmt(ctx.allocator,"/searches?q={s}",.{try queryEncode(ctx.allocator,recent)}));
try w.writeAll("\">\n        <span class=\"overflow-ellipsis\">“");
try compat.htmlEscape(w, recent);
try w.writeAll("”</span>\n</a>");
}
if (page.recent_searches.len != 0) {
try w.writeAll("\n      <form class=\"button_to\" method=\"post\" action=\"");
try compat.htmlEscape(w, try absolute(ctx,"/searches/clear"));
try w.writeAll("\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn searches__btn\" data-turbo-confirm=\"Are you sure you want to clear your recent searches?\" type=\"submit\">\n        <img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "broom.svg"));
try w.writeAll("\" />\n        <span class=\"for-screen-reader\">Clear recent searches</span>\n</button></form>");
}
try w.writeAll("\n");
try w.writeAll("\n  </div>\n");
try w.writeAll("</aside>");
try layoutFoot(ctx,w);
}
return out.toOwnedSlice();
}
fn queryEncode(a: Allocator,text: []const u8) ![]const u8 {
    var out=Io.Writer.Allocating.init(a);defer out.deinit();
    for(text) |c| {
        if(std.ascii.isAlphanumeric(c) or c=='_' or c=='-' or c=='.' or c=='~') try out.writer.writeByte(c)
        else if(c==' ') try out.writer.writeByte('+')
        else try out.writer.print("%{X:0>2}",.{c});
    }
    return out.toOwnedSlice();
}
const Translations = struct {key: []const u8,items: []const [2][]const u8};
const translations = [_]Translations{
.{.key="email_address",.items=&.{.{"🇺🇸","Enter your email address"},.{"🇪🇸","Introduce tu correo electrónico"},.{"🇫🇷","Entrez votre adresse courriel"},.{"🇮🇳","अपना ईमेल पता दर्ज करें"},.{"🇩🇪","Geben Sie Ihre E-Mail-Adresse ein"},.{"🇧🇷","Insira seu endereço de email"},.{"🇯🇵","メールアドレスを入力してください"}}},
.{.key="password",.items=&.{.{"🇺🇸","Enter your password"},.{"🇪🇸","Introduce tu contraseña"},.{"🇫🇷","Saisissez votre mot de passe"},.{"🇮🇳","अपना पासवर्ड दर्ज करें"},.{"🇩🇪","Geben Sie Ihr Passwort ein"},.{"🇧🇷","Insira sua senha"},.{"🇯🇵","パスワードを入力してください"}}},
.{.key="invite_message",.items=&.{.{"🇺🇸","Welcome to Campfire. To invite some people to chat with you, share the join link below."},.{"🇪🇸","Bienvenido a Campfire. Para invitar a algunas personas a chatear contigo, comparte el enlace de unión que se encuentra a continuación."},.{"🇫🇷","Bienvenue sur Campfire. Pour inviter des personnes à discuter avec vous, partagez le lien pour rejoindre ci-dessous."},.{"🇮🇳","Campfire में आपका स्वागत है। अधिक लोगों को चैट के लिए आमंत्रित करने के लिए, नीचे जुड़ने का लिंक साझा करें।"},.{"🇩🇪","Willkommen bei Campfire. Um einige Personen zum Chatten einzuladen, teilen Sie den unten stehenden Beitrittslink."},.{"🇧🇷","Boas vindas ao Campfire. Para convidar pessoas para conversarem com você, compartilhe o link de convite abaixo."},.{"🇯🇵","Campfireへようこそ。他の人をチャットに招待するには、下記の参加リンクを共有してください。"}}},
};
fn translation(ctx: *Context,w: *Io.Writer,key: []const u8) !void {
    try translationFor(ctx.assets,w,key);
}
fn translationFor(a: *assets_module.Assets,w: *Io.Writer,key: []const u8) !void {
    try w.writeAll("<details class=\"position-relative\" data-controller=\"popup\" data-action=\"keydown.esc-&gt;popup#close toggle-&gt;popup#toggle click@document-&gt;popup#closeOnClickOutside\" data-popup-orientation-top-class=\"popup-orientation-top\"><summary class=\"btn\" tabindex=\"-1\">");
    try imageFor(a,w,"globe.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\" class=\"color-icon\"");
    try w.writeAll("<span class=\"for-screen-reader\">Translate</span></summary><div class=\"language-list-menu shadow\" data-popup-target=\"menu\"><dl class=\"language-list\">");
    for(translations) |t| if(std.mem.eql(u8,t.key,key)) {for(t.items) |item| {try w.writeAll("<dt>");try compat.htmlEscape(w,item[0]);try w.writeAll("</dt><dd class=\"margin-none\">");try compat.htmlEscape(w,item[1]);try w.writeAll("</dd>");}break;};
    try w.writeAll("</dl></div></details>");
}
fn imageFor(a: *assets_module.Assets,w: *Io.Writer,logical: []const u8,attributes: []const u8) !void {
    try w.writeAll("<img");try w.writeAll(attributes);try w.writeAll(" src=\"");try compat.htmlEscape(w,a.assetPath(logical) orelse return error.MissingAsset);try w.writeAll("\" />");
}

fn invitation(ctx: *Context,w: *Io.Writer,page: model.RoomPage) !void {
const url=try absolute(ctx,try fmt(ctx.allocator,"/join/{s}",.{page.account.join_code}));
const encoder=std.base64.url_safe.Encoder;
const qr_bytes=try ctx.allocator.alloc(u8,encoder.calcSize(url.len));
_ = encoder.encode(qr_bytes,url);
const qr=try fmt(ctx.allocator,"/qr_code/{s}",.{qr_bytes});
try w.writeAll("\n  <div id=\"system_welcome\" class=\"message message--formatted txt-align-center center\">\n    <div class=\"message__body center\">\n      <div class=\"message__body-content position-relative\">\n        ");
try accountLogo(ctx,w,page.account,"center margin-block-end txt-large");
try w.writeAll("\n        <div class=\"flex align-center gap\">\n          <div class=\"system-welcome--translation\">\n            ");
try translation(ctx,w,"invite_message");
try w.writeAll("\n          </div>\n          <p>\n            <strong>Welcome to Campfire</strong><br>\n            To invite people to chat, share the join link below.\n          </p>\n        </div>\n        ");
try w.writeAll("<div class=\"flex flex-column align-center gap\">\n\n  <label class=\"flex flex-column gap full-width\" style=\"--row-gap: 0.5em\">\n    <strong id=\"invite_label\" class=\"invite-label\">Share to invite more people</strong>\n    <span class=\"flex align-center gap input input--actor fill-white\">\n      ");
try image(ctx,w,"person-add.svg"," class=\"colorize--black\" width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("\n      <input type=\"text\" class=\"input\" id=\"invite_url\" value=\"");
try compat.htmlEscape(w, url);
try w.writeAll("\" aria-labelledby=\"invite_label\" readonly>\n    </span>\n  </label>\n\n  <div class=\"flex align-center gap\">\n    <a class=\"btn\" data-lightbox-target=\"image\" data-action=\"lightbox#open\" href=\"");
try compat.htmlEscape(w, qr);
try w.writeAll("\">\n      <span class=\"for-screen-reader\">Show join link QR code</span>\n      ");
try image(ctx,w,"qr-code.svg"," class=\"colorize--black\" width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("\n</a>\n    <button class=\"btn\" data-controller=\"copy-to-clipboard\" data-action=\"copy-to-clipboard#copy\" data-copy-to-clipboard-success-class=\"btn--success\" data-copy-to-clipboard-url-value=\"");
try compat.htmlEscape(w, url);
try w.writeAll("\">\n      <span class=\"for-screen-reader\">Copy join link</span>\n      ");
try image(ctx,w,"copy-paste.svg"," class=\"colorize--black\" width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("\n</button>\n    <button class=\"btn\" data-controller=\"web-share\" data-action=\"web-share#share\" data-web-share-url-value=\"");
try compat.htmlEscape(w, url);
try w.writeAll("\" data-web-share-title-value=\"Link to join Campfire\" data-web-share-text-value=\"Hit this link to join me in Campfire and start chatting.\">\n      <span class=\"for-screen-reader\">Share join link</span>\n      ");
try image(ctx,w,"share.svg"," class=\"colorize--black\" width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("\n</button>\n");
if(ctx.user.isAdministrator()) {
try w.writeAll("      <form class=\"button_to\" method=\"post\" action=\"/account/join_code\"><button class=\"btn btn--regenerate\" type=\"submit\">\n        ");
try image(ctx,w,"refresh.svg"," class=\"colorize--black\" width=\"20\" height=\"20\" aria-hidden=\"true\"");
try w.writeAll("\n        <span class=\"for-screen-reader\">Regenerate join link</span>\n</button></form>");
}
try w.writeAll("  </div>\n</div>\n\n");
try w.writeAll("\n      </div>\n    </div>\n  </div>\n");
}
pub fn room(ctx: *Context,page: model.RoomPage) ![]const u8 {
    var out=Io.Writer.Allocating.init(ctx.allocator);defer out.deinit();const w=&out.writer;
    const gid=try compat.globalIdParam(ctx.allocator,page.room.kind.className(),page.room.id);
    const stream=try ctx.secrets.signedStream(ctx.allocator,&.{gid,"messages"});
    const head=try fmt(ctx.allocator,"<meta name=\"turbo-cache-control\" content=\"no-preview\"><meta name=\"current-room-id\" content=\"{d}\">",.{page.room.id});
    if(ctx.frame_id != null) {
        try frameHead(w,head);
try w.writeAll("\n<div id=\"message-area\" class=\"message-area\" contents=\"true\" data-controller=\"messages presence drop-target\" data-action=\"turbo:before-stream-render@document-&gt;messages#beforeStreamRender keydown.up@document-&gt;messages#editMyLastMessage dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop visibilitychange@document-&gt;presence#visibilityChanged\" data-messages-first-of-day-class=\"message--first-of-day\" data-messages-formatted-class=\"message--formatted\" data-messages-me-class=\"message--me\" data-messages-mentioned-class=\"message--mentioned\" data-messages-threaded-class=\"message--threaded\" data-messages-page-url-value=\"");
try compat.htmlEscape(w, try absolute(ctx,try fmt(ctx.allocator,"/rooms/{d}/messages",.{page.room.id})));
try w.writeAll("\">");
try w.writeAll("\n  ");
try messageTemplate(ctx,w,page.user);
try w.writeAll("\n\n  <div id=\"");
try writeRoomId(w,page.room,"messages");
try w.writeAll("\" class=\"messages\" data-controller=\"maintain-scroll refresh-room\" data-action=\"turbo:before-stream-render@document-&gt;maintain-scroll#beforeStreamRender visibilitychange@document-&gt;refresh-room#visibilityChanged online@window-&gt;refresh-room#online\" data-messages-target=\"messages\" data-refresh-room-loaded-at-value=\"");
try w.print("{d}", .{try compat.epochMilliseconds(page.room.updated_at)});
try w.writeAll("\" data-refresh-room-url-value=\"");
try compat.htmlEscape(w, try absolute(ctx,try fmt(ctx.allocator,"/rooms/{d}/refresh",.{page.room.id})));
try w.writeAll("\">");
if(page.invitation) {
try w.writeAll("\n    ");
try invitation(ctx,w,page);
}
for(page.messages) |m| {
try w.writeAll("\n    ");
try renderMessage(ctx,w,m,false);
}
try w.writeAll("\n  </div>\n\n  <turbo-cable-stream-source channel=\"RoomMessagesChannel\" signed-stream-name=\"");
try compat.htmlEscape(w, stream);
try w.writeAll("\"></turbo-cable-stream-source>\n  <button class=\"message-area__return-to-latest btn\" data-action=\"messages#returnToLatest\" data-messages-target=\"latest\" hidden=\"hidden\"><img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "arrow-down.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" /><span class=\"for-screen-reader\">Jump to newest message</span></button>\n</div>\n");
try w.writeAll("</body></html>");

    } else {
        try layoutHead(ctx,w,page.account,page.room.display_name,"sidebar",head);
        try nav(ctx,w,page.room,page.account);
try w.writeAll("</nav><main id=\"main-content\">");
try w.writeAll("\n<div id=\"message-area\" class=\"message-area\" contents=\"true\" data-controller=\"messages presence drop-target\" data-action=\"turbo:before-stream-render@document-&gt;messages#beforeStreamRender keydown.up@document-&gt;messages#editMyLastMessage dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop visibilitychange@document-&gt;presence#visibilityChanged\" data-messages-first-of-day-class=\"message--first-of-day\" data-messages-formatted-class=\"message--formatted\" data-messages-me-class=\"message--me\" data-messages-mentioned-class=\"message--mentioned\" data-messages-threaded-class=\"message--threaded\" data-messages-page-url-value=\"");
try compat.htmlEscape(w, try absolute(ctx,try fmt(ctx.allocator,"/rooms/{d}/messages",.{page.room.id})));
try w.writeAll("\">");
try w.writeAll("\n  ");
try messageTemplate(ctx,w,page.user);
try w.writeAll("\n\n  <div id=\"");
try writeRoomId(w,page.room,"messages");
try w.writeAll("\" class=\"messages\" data-controller=\"maintain-scroll refresh-room\" data-action=\"turbo:before-stream-render@document-&gt;maintain-scroll#beforeStreamRender visibilitychange@document-&gt;refresh-room#visibilityChanged online@window-&gt;refresh-room#online\" data-messages-target=\"messages\" data-refresh-room-loaded-at-value=\"");
try w.print("{d}", .{try compat.epochMilliseconds(page.room.updated_at)});
try w.writeAll("\" data-refresh-room-url-value=\"");
try compat.htmlEscape(w, try absolute(ctx,try fmt(ctx.allocator,"/rooms/{d}/refresh",.{page.room.id})));
try w.writeAll("\">");
if(page.invitation) {
try w.writeAll("\n    ");
try invitation(ctx,w,page);
}
for(page.messages) |m| {
try w.writeAll("\n    ");
try renderMessage(ctx,w,m,false);
}
try w.writeAll("\n  </div>\n\n  <turbo-cable-stream-source channel=\"RoomMessagesChannel\" signed-stream-name=\"");
try compat.htmlEscape(w, stream);
try w.writeAll("\"></turbo-cable-stream-source>\n  <button class=\"message-area__return-to-latest btn\" data-action=\"messages#returnToLatest\" data-messages-target=\"latest\" hidden=\"hidden\"><img aria-hidden=\"true\" src=\"");
try compat.htmlEscape(w, try asset(ctx, "arrow-down.svg"));
try w.writeAll("\" width=\"20\" height=\"20\" /><span class=\"for-screen-reader\">Jump to newest message</span></button>\n</div>\n");
try w.writeAll("<footer id=\"footer\">");
try composer(ctx,w,page.room);
try w.writeAll("</footer></main><aside id=\"sidebar\" data-controller=\"toggle-class\" data-toggle-class-toggle-class=\"open\">");
try sidebarFrame(w,"/users/me/sidebar");
try w.writeAll("</turbo-frame></aside>");
try layoutFoot(ctx,w);
}
return out.toOwnedSlice();
}
pub fn messages(ctx: *Context,items: []const model.Message) ![]const u8 {
    var out=Io.Writer.Allocating.init(ctx.allocator);defer out.deinit();
    for(items) |m| try renderMessage(ctx,&out.writer,m,false);
    return out.toOwnedSlice();
}
pub fn created(ctx: *Context,m: model.Message) ![]const u8 {
    var out=Io.Writer.Allocating.init(ctx.allocator);defer out.deinit();const w=&out.writer;
    try w.writeAll("<turbo-stream action=\"append\" target=\"");
    try w.print("messages_{s}_{d}",.{m.room_kind.paramKey(),m.room_id});
    try w.writeAll("\"><template>");try renderMessage(ctx,w,m,true);try w.writeAll("</template></turbo-stream>");
    return out.toOwnedSlice();
}
fn roomLinkStart(ctx: *Context,w: *Io.Writer,membership: model.SidebarRoom,direct: bool) !void {
    const r=membership.room;
    try w.writeAll("<a id=\"");try writeRoomId(w,r,"list");
    try w.writeAll("\" class=\"");
    try w.writeAll(if(direct) "direct" else "align-center gap room btn txt-nowrap");
    if(membership.unread_at != null) try w.writeAll(" unread");
    try w.writeAll("\"");
    if(direct) try w.print(" data-sorted-list-number=\"{d}\"",.{try compat.epochMilliseconds(membership.membership_updated_at)})
    else {try w.writeAll(" data-sorted-list-name=\"");try compat.htmlEscape(w,r.name orelse "");try w.writeAll("\" style=\"--column-gap: 0.5em\"");}
    try w.print(" data-rooms-list-target=\"room\" data-room-id=\"{d}\" data-badge-dot-target=\"unread\" data-sorted-list-target=\"item\" href=\"/rooms/{d}\">",.{r.id,r.id});
}
fn firstName(name: []const u8) []const u8 {
    var it=std.mem.tokenizeAny(u8,name," \t\r\n\x0b\x0c");return it.next() orelse "";
}
fn directInitials(a: Allocator,users: []const model.User) ![]const u8 {
    var out=Io.Writer.Allocating.init(a);defer out.deinit();
    for(users,0..) |u,i| {
        if(i != 0) try out.writer.writeAll(if(users.len == 2) "+" else if(i == users.len-1) ", and " else ", ");
        var parts=std.mem.tokenizeAny(u8,u.name," \t\r\n\x0b\x0c");var n: usize=0;
        while(parts.next()) |part| {if(n == 3) break;n+=1;var it=(try std.unicode.Utf8View.init(part)).iterator();if(it.nextCodepoint()) |c| try unicode.uppercase(&out.writer,c);}
    }
    return out.toOwnedSlice();
}
fn directRoom(ctx: *Context,w: *Io.Writer,m: model.SidebarRoom) !void {
    try roomLinkStart(ctx,w,m,true);
    if(m.users.len > 1) {
        try w.writeAll("<div class=\"avatar__group\">");
        for(m.users[0..@min(4,m.users.len)]) |u| {try w.writeAll("<span class=\"avatar\"><img width=\"20\" height=\"20\" aria-hidden=\"true\" src=\"");try compat.htmlEscape(w,try avatarUrl(ctx,u));try w.writeAll("\" /></span>");}
        try w.writeAll("</div>");
    } else {
        const u=if(m.users.len != 0) m.users[0] else ctx.user;
        try w.writeAll("<span class=\"avatar\"><img width=\"48\" height=\"48\" aria-hidden=\"true\" src=\"");try compat.htmlEscape(w,try avatarUrl(ctx,u));try w.writeAll("\" /></span>");
    }
    try w.writeAll("<span class=\"direct__author flex align-center gap max-width min-width border-radius txt-small\"><span class=\"txt-nowrap overflow-ellipsis\"><span class=\"for-screen-reader\">Ping with</span>");
    try compat.htmlEscape(w,if(m.users.len > 1) try directInitials(ctx.allocator,m.users) else firstName(if(m.users.len != 0) m.users[0].name else ctx.user.name));
    try w.writeAll("</span></span></a>");
}
fn placeholder(ctx: *Context,w: *Io.Writer,u: model.User) !void {
    try w.print("<form class=\"button_to\" method=\"post\" action=\"/rooms/directs?user_ids%5B%5D={d}\"><button class=\"direct borderless fill-transparent unpad\" type=\"submit\"><span class=\"avatar\"><img aria-hidden=\"true\" src=\"",.{u.id});
    try compat.htmlEscape(w,try avatarUrl(ctx,u));
    try w.writeAll("\" /></span><span class=\"direct__author flex align-center gap max-width min-width border-radius txt-small\"><span class=\"txt-nowrap overflow-ellipsis\"><span class=\"for-screen-reader\">Start a ping with</span>");try compat.htmlEscape(w,firstName(u.name));try w.writeAll("</span></span></button></form>");
}
fn restrictCreation(a: Allocator,account: model.Account) !bool {
    const text=account.settings orelse return false;
    const parsed=std.json.parseFromSlice(std.json.Value,a,text,.{}) catch |err| switch(err){error.OutOfMemory=>return err,else=>return false};defer parsed.deinit();
    if(parsed.value != .object) return false;
    const v=parsed.value.object.get("restrict_room_creation_to_administrators") orelse return false;
    return switch(v){.null=>false,.bool=>|b|b,.string=>|s|std.mem.trim(u8,s," \t\r\n\x0b\x0c").len != 0,.array=>|s|s.items.len != 0,.object=>|o|o.count() != 0,else=>true};
}
fn streamSource(w: *Io.Writer,signed: []const u8) !void {
    try w.writeAll("<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"");try compat.htmlEscape(w,signed);try w.writeAll("\"></turbo-cable-stream-source>");
}
fn sidebarContent(ctx: *Context,w: *Io.Writer,page: model.Sidebar) !void {
    try sidebarFrame(w,null);
    try streamSource(w,try ctx.secrets.signedStream(ctx.allocator,&.{"rooms"}));
    try streamSource(w,try ctx.secrets.signedStream(ctx.allocator,&.{try compat.globalIdParam(ctx.allocator,"User",page.user.id),"rooms"}));
    try w.writeAll("<div class=\"sidebar__container overflow-y overflow-hide-scrollbar\" data-controller=\"badge-dot\" data-badge-dot-unread-class=\"unread\" data-action=\"rooms-list:unread@window-&gt;badge-dot#update rooms-list:read@window-&gt;badge-dot#update turbo:submit-start-&gt;turbo-frame#unpermanize\"><turbo-frame id=\"direct_rooms_control\" target=\"_top\"><div class=\"directs gap overflow-x overflow-hide-scrollbar\"><a class=\"direct direct__new\" data-turbo-frame=\"_self\" href=\"/rooms/directs/new\"><span class=\"avatar avatar--icon\">");try image(ctx,w,"messages-add.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\" class=\"colorize--black\"");try w.writeAll("</span><span class=\"direct__author flex max-width min-width border-radius pad-inline-half\"><span class=\"for-screen-reader\">New</span><span class=\"txt-small overflow-clip\">Ping</span></span></a><div id=\"direct_rooms\" contents data-controller=\"sorted-list\" data-action=\"rooms-list:unread@window-&gt;sorted-list#updateItem\">");
    for(page.directs) |m| try directRoom(ctx,w,m);
    try w.writeAll("</div><div contents>");for(page.direct_placeholder_users) |u| try placeholder(ctx,w,u);
    try w.writeAll("</div></div></turbo-frame><div class=\"rooms position-relative flex flex-column gap\"><div id=\"shared_rooms\" contents data-controller=\"sorted-list\">");
    for(page.shared) |m| {try roomLinkStart(ctx,w,m,false);try w.writeAll("<span class=\"overflow-ellipsis\">");try compat.htmlEscape(w,m.room.name orelse "");try w.writeAll("</span></a>");}
    try w.writeAll("</div>");
    if(page.user.isAdministrator() or !(try restrictCreation(ctx.allocator,page.account))) {try w.writeAll("<a class=\"rooms__new-btn btn room align-center gap txt-reversed\" aria-label=\"New Chat Room\" href=\"/rooms/opens/new\">");try image(ctx,w,"add.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\" style=\"view-transition-name: new-room\"");try w.writeAll("</a>");}
    try w.writeAll("</div><button class=\"btn sidebar__toggle\" data-action=\"toggle-class#toggle\">");try image(ctx,w,"menu.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\"");try w.writeAll("<span class=\"for-screen-reader\">Open menu</span></button></div><div class=\"flex align-end sidebar__tools gap justify-end\"><a class=\"btn avatar flex-item-no-shrink sidebar__tool\" href=\"/users/me/profile\"><img width=\"48\" height=\"48\" aria-hidden=\"true\" style=\"view-transition-name: avatar-");try w.print("{d}\" src=\"",.{page.user.id});try compat.htmlEscape(w,try avatarUrl(ctx,page.user));try w.writeAll("\" /><span class=\"for-screen-reader\">My Settings</span></a><a class=\"btn align-center gap txt-reversed sidebar__tool\" href=\"/account/edit\">");try image(ctx,w,"settings.svg"," width=\"20\" height=\"20\" aria-hidden=\"true\" style=\"view-transition-name: account-settings\"");try w.writeAll("<span class=\"for-screen-reader\">Account Settings</span></a></div></turbo-frame>");
}
pub fn sidebar(ctx: *Context,page: model.Sidebar) ![]const u8 {
    var out=Io.Writer.Allocating.init(ctx.allocator);defer out.deinit();const w=&out.writer;
    if(ctx.frame_id != null) {try frameHead(w,"");try sidebarContent(ctx,w,page);try w.writeAll("</body></html>");}
    else {try layoutHead(ctx,w,page.account,"Campfire","","");try w.writeAll("</nav><main id=\"main-content\">");try sidebarContent(ctx,w,page);try w.writeAll("<footer id=\"footer\"></footer></main><aside id=\"sidebar\" data-controller=\"toggle-class\" data-toggle-class-toggle-class=\"open\"></aside>");try layoutFoot(ctx,w);}
    return out.toOwnedSlice();
}
pub const LoginOptions = struct {base_url: []const u8,app_version: []const u8="native Zig++",vapid_public_key: ?[]const u8=null,email_address: ?[]const u8=null};
pub fn login(allocator: Allocator,a: *assets_module.Assets,account: model.Account,alert: ?[]const u8,options: LoginOptions) ![]const u8 {
    var out=Io.Writer.Allocating.init(allocator);defer out.deinit();const w=&out.writer;
    try w.writeAll("<!DOCTYPE html><html><head><title>Sign in</title><meta name=\"viewport\" content=\"width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content\"><meta name=\"view-transition\" content=\"same-origin\"><meta name=\"color-scheme\" content=\"light dark\"><meta name=\"theme-color\" content=\"#ffffff\" media=\"(prefers-color-scheme: light)\"><meta name=\"theme-color\" content=\"#000000\" media=\"(prefers-color-scheme: dark)\"><meta name=\"apple-mobile-web-app-capable\" content=\"yes\"><meta name=\"action-cable-url\" content=\"");
try cableUrl(w,options.base_url);try w.writeAll("\"><meta name=\"vapid-public-key\"");
if(options.vapid_public_key) |key| {try w.writeAll(" content=\"");try compat.htmlEscape(w,key);try w.writeAll("\"");}
try w.writeAll("><meta name=\"turbo-prefetch\" content=\"true\"><link rel=\"manifest\" href=\"/webmanifest.json\"><link rel=\"icon\" href=\"");

    const logo=try accountLogoUrl(allocator,account);
    try compat.htmlEscape(w,logo);try w.writeAll("\" type=\"image/png\"><link rel=\"apple-touch-icon\" href=\"");try compat.htmlEscape(w,logo);try w.writeAll("\">");
    for(a.stylesheets()) |logical| {try w.writeAll("<link rel=\"stylesheet\" href=\"");try compat.htmlEscape(w,a.assetPath(logical) orelse return error.MissingAsset);try w.writeAll("\" data-turbo-track=\"reload\" />");}
    if(account.custom_styles) |styles| {try w.writeAll("<style data-turbo-track=\"reload\">");try w.writeAll(styles);try w.writeAll("</style>");}
    try w.writeAll(a.importmapTags());try w.writeAll("<meta name=\"turbo-visit-control\" content=\"reload\"></head><body class=\"");
    if(account.logo != null) try w.writeAll("account-has-logo");
    try w.writeAll("\" data-controller=\"local-time lightbox\"><a href=\"#main-content\" class=\"skip-navigation btn\">Skip to main content</a><nav id=\"nav\"></nav>");
    if(alert) |value| {try w.writeAll("<div class=\"flash\" data-controller=\"element-removal\" data-action=\"animationend-&gt;element-removal#remove\"><div class=\"flash__inner shadow\" style=\"--flash-background: var(--color-negative)\">");try imageFor(a,w,"alert.svg"," width=\"24\" height=\"24\" aria-hidden=\"true\" class=\"colorize--white\"");try w.writeAll("</span></div><span class=\"for-screen-reader\" role=\"alert\" aria-atomic=\"true\">");try compat.htmlEscape(w,value);try w.writeAll("</span></div>");}
    try w.writeAll("<main id=\"main-content\">");
try w.writeAll("<section class=\"txt-align-center\">\n  <div class=\"panel ");
if(alert != null) {
try w.writeAll("shake");
}
try w.writeAll("\">\n    ");
try loginLogo(allocator,a,w,account);
try w.writeAll("\n\n    <form class=\"flex flex-column gap\" action=\"/session\" accept-charset=\"UTF-8\" method=\"post\">\n      <fieldset class=\"flex flex-column gap center-block upad\">\n        <legend class=\"txt-large txt-align-center\"><strong>");
try compat.htmlEscape(w, account.name);
try w.writeAll("</strong></legend>\n\n        <div class=\"flex align-center gap\">\n          ");
try translationFor(a,w,"email_address");
try w.writeAll("\n          <label class=\"flex align-center gap input input--actor txt-large\">\n            <input type=\"email\" name=\"email_address\" id=\"email_address\" required=\"required\" class=\"input\" autofocus=\"autofocus\" autocomplete=\"username\" placeholder=\"Enter your email address\"");
if(options.email_address) |email| {try w.writeAll(" value=\"");try compat.htmlEscape(w,email);try w.writeAll("\"");}
try w.writeAll(" />\n            ");

try imageFor(a,w,"email.svg"," class=\"colorize--black\" width=\"24\" height=\"24\" aria-hidden=\"true\"");
try w.writeAll("\n          </label>\n        </div>\n\n        <div class=\"flex align-center gap\">\n          ");
try translationFor(a,w,"password");
try w.writeAll("\n          <label class=\"flex align-center gap input input--actor txt-large\">\n            <input type=\"password\" name=\"password\" id=\"password\" required=\"required\" class=\"input\" autocomplete=\"current-password\" placeholder=\"Enter your password\" maxlength=\"72\" />\n            ");
try imageFor(a,w,"password.svg"," class=\"colorize--black\" width=\"24\" height=\"24\" aria-hidden=\"true\"");
try w.writeAll("\n          </label>\n        </div>\n\n        <button name=\"log_in\" type=\"submit\" class=\"btn btn--reversed center txt-large\">\n          ");
try imageFor(a,w,"arrow-right.svg"," aria-hidden=\"true\"");
try w.writeAll("\n          <span class=\"for-screen-reader\">Go</span>\n</button>      </fieldset>\n</form>  </div>\n\n  ");
try helpContact(a,w,account,options.app_version);
try w.writeAll("\n</section>\n");
try w.writeAll("<footer id=\"footer\"></footer></main><aside id=\"sidebar\" data-controller=\"toggle-class\" data-toggle-class-toggle-class=\"open\"></aside>");
try w.writeAll("<dialog class=\"lightbox\" aria-label=\"Image Viewer (Press escape to close)\" data-lightbox-target=\"dialog\" data-action=\"close->lightbox#reset\">\n  <img src=\"\" class=\"lightbox__image\" data-lightbox-target=\"zoomedImage\" />\n\n  <form method=\"dialog\" class=\"lightbox__btn\">\n    <button class=\"btn\">\n      ");
try imageFor(a,w,"remove.svg"," aria-hidden=\"true\"");
try w.writeAll("\n      <span class=\"for-screen-reader\">Close image viewer</span>\n    </button>\n  </form>\n\n  <a href=\"\" class=\"lightbox__btn--download btn hide-in-ios-pwa\" data-lightbox-target=\"download\">\n    ");
try imageFor(a,w,"download.svg"," aria-hidden=\"true\"");
try w.writeAll("\n    <span class=\"for-screen-reader\">Download file</span>\n  </a>\n\n  <button class=\"lightbox__btn--share btn\"\n      data-controller=\"web-share\"\n      data-action=\"web-share#share\"\n      data-web-share-files-value=\"\"\n      data-lightbox-target=\"share\">\n    ");
try imageFor(a,w,"share.svg"," aria-hidden=\"true\"");
try w.writeAll("\n    <span class=\"for-screen-reader\">Share file</span>\n  </button>\n</dialog>\n\n");
try w.writeAll("<a href=\"https://once.com\" id=\"app-logo\" target=\"_blank\" aria-label=\"Once software from 37signals home page\">");
try imageFor(a,w,"campfire-icon.png"," alt="Campfire logo" width="256" height="216"");
try w.writeAll("</a></body></html>");
return out.toOwnedSlice();
}
fn loginLogo(allocator: Allocator,a: *assets_module.Assets,w: *Io.Writer,account: model.Account) !void {
    _=a;
    try w.writeAll("<figure class=\"account-logo avatar center margin-block-end txt-xx-large\"><img alt=\"Account logo\" width=\"300\" height=\"300\" src=\"");try compat.htmlEscape(w,try accountLogoUrl(allocator,account));try w.writeAll("\" /></figure>");
}
fn helpContact(a: *assets_module.Assets,w: *Io.Writer,account: model.Account,version: []const u8) !void {
    if(account.help_contact) |owner| {
        const email=owner.email_address orelse "";
        try w.writeAll("<div class=\"txt-align-center margin-block-double full-width\"><a class=\"btn center\" title=\"Email ");try compat.htmlEscape(w,owner.name);try w.writeAll("\" href=\"mailto:&quot;");try compat.htmlEscape(w,owner.name);try w.writeAll("&quot; &lt;");try compat.htmlEscape(w,email);try w.writeAll("&gt;\">");try imageFor(a,w,"lifebuoy.svg"," aria-hidden=\"true\"");try w.writeAll("<span>");try compat.htmlEscape(w,email);try w.writeAll("</span></a><div class=\"txt-align-center center margin-block txt-subtle\">Campfire&trade; version <span class=\"version-badge\">");
try compat.htmlEscape(w,version);
try w.writeAll("</span></div></div>");

    }
}

pub fn avatarSvg(allocator: Allocator,user: model.User) ![]const u8 {
var out=Io.Writer.Allocating.init(allocator);defer out.deinit();const w=&out.writer;
const letters=try initials(allocator,user.name);
try w.writeAll("<svg version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"\n  viewBox=\"0 0 512 512\" class=\"avatar\" aria-hidden=\"true\">\n  <defs>\n    <clipPath id=\"porthole\">\n      <circle cx=\"50%\" cy=\"50%\" r=\"50%\" />\n    </clipPath>\n  </defs>\n\n  <g>\n    <rect width=\"100%\" height=\"100%\" rx=\"50\" fill=\"");
try compat.htmlEscape(w, avatarColor(user.id));
try w.writeAll("\" />\n\n    <text x=\"50%\" y=\"50%\" fill=\"#FFFFFF\"\n      text-anchor=\"middle\" dy=\"0.35em\"\n      ");
if(letters.len >= 3) {
try w.writeAll("textLength=\"85%\" lengthAdjust=\"spacingAndGlyphs\"");
}
try w.writeAll("\n      font-family=\"-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif\"\n      font-size=\"230\"\n      font-weight=\"800\"\n      letter-spacing=\"-5\">\n      ");
try compat.htmlEscape(w, letters);
try w.writeAll("\n    </text>\n  </g>\n</svg>\n\n");
return out.toOwnedSlice();
}

test "Rails message DOM IDs use the client key, never database ID" {
    var arena=std.heap.ArenaAllocator.init(std.testing.allocator);defer arena.deinit();const a=arena.allocator();
    const u=model.User{.id=1,.name="A",.created_at="2024-01-01 00:00:00",.updated_at="2024-01-01 00:00:00"};
    const m=model.Message{.id=99,.client_message_id="browser-client-key",.room_id=2,.room_kind=.closed,.room_name="HQ",.creator=u,.created_at=u.created_at,.updated_at=u.updated_at,.body="hello"};
    try std.testing.expectEqualStrings("message_browser-client-key",try messageId(a,m,""));
    try std.testing.expectEqualStrings("edit_message_browser-client-key",try messageId(a,m,"edit"));
    const r=model.Room{.id=2,.kind=.closed,.creator_id=1,.name="HQ",.display_name="HQ",.created_at=u.created_at,.updated_at=u.updated_at};
    try std.testing.expectEqualStrings("messages_rooms_closed_2",try roomId(a,r,"messages"));
}
test "Ruby initials see Unicode word boundaries but capture ASCII word characters" {
    var arena=std.heap.ArenaAllocator.init(std.testing.allocator);defer arena.deinit();const a=arena.allocator();
    try std.testing.expectEqualStrings("JL",try initials(a,"Jamie Lovelace"));
    try std.testing.expectEqualStrings("AB",try initials(a,"alice-bob"));
    try std.testing.expectEqualStrings("",try initials(a,"Élodie"));
    try std.testing.expectEqualStrings("A_3",try initials(a,"Ada _Smith 3"));
}
test "Emoji classification excludes whitespace joiners digits and empty content" {
    try std.testing.expect(allEmoji("👍"));try std.testing.expect(allEmoji("❤️"));try std.testing.expect(allEmoji("🇺🇸"));
    try std.testing.expect(!allEmoji("hi 👍"));try std.testing.expect(!allEmoji("👍 👋"));try std.testing.expect(!allEmoji("👩‍💻"));try std.testing.expect(!allEmoji("1"));try std.testing.expect(!allEmoji(""));
}
test "Initials avatars use stable CRC32 palette entries" {
    try std.testing.expectEqualStrings("#BF7C2A",avatarColor(1));try std.testing.expectEqualStrings("#698F9C",avatarColor(2));try std.testing.expectEqualStrings("#D07B53",avatarColor(42));try std.testing.expectEqualStrings("#BFA07A",avatarColor(1000));
    var arena=std.heap.ArenaAllocator.init(std.testing.allocator);defer arena.deinit();const a=arena.allocator();
    const u=model.User{.id=42,.name="Ada Lovelace Byron",.created_at="2024-01-01 00:00:00",.updated_at="2024-01-01 00:00:00"};
    const svg=try avatarSvg(a,u);
    try std.testing.expect(std.mem.find(u8,svg,"textLength=\"85%\"") != null);
    try std.testing.expect(std.mem.find(u8,svg,"ALB") != null);
}
test "Direct member names use first three initials and English sentence connectors" {
    var arena=std.heap.ArenaAllocator.init(std.testing.allocator);defer arena.deinit();const a=arena.allocator();
    const u=model.User{.id=1,.name="jamie van lovelace ignored",.created_at="2024-01-01 00:00:00",.updated_at="2024-01-01 00:00:00"};
    const v=model.User{.id=2,.name="mike",.created_at=u.created_at,.updated_at=u.updated_at};
    try std.testing.expectEqualStrings("JVL+M",try directInitials(a,&.{u,v}));
    try std.testing.expectEqualStrings("JVL, M, and M",try directInitials(a,&.{u,v,v}));
}
test "Dimensions preserve integer halves and bound oversized thumbnails" {
    var arena=std.heap.ArenaAllocator.init(std.testing.allocator);defer arena.deinit();const a=arena.allocator();
    var b=model.Blob{.id=1,.key="k",.filename="x.png",.content_type="image/png",.byte_size=1,.service_name="local",.created_at="2024-01-01 00:00:00",.metadata="{\"width\":801,\"height\":600}"};
    const small=(try dimensions(a,b)).?;try std.testing.expectEqual(@as(i64,400),small.width.half().integer);
    b.metadata="{\"width\":2400,\"height\":1600}";
    const large=(try dimensions(a,b)).?;try std.testing.expectEqual(@as(f64,1200),large.width.float);try std.testing.expectEqual(@as(f64,800),large.height.float);
    b.metadata="{}";try std.testing.expect((try dimensions(a,b)) == null);
}
test "Search history escapes spaces as plus and untrusted query bytes" {
    const a=std.testing.allocator;
    const value=try queryEncode(a,"a*~ +&<>é");defer a.free(value);
    try std.testing.expectEqualStrings("a%2A~+%2B%26%3C%3E%C3%A9",value);
}
test "Sounds require an exact slash-play body and catalog entry" {
    try std.testing.expect(findSound("/play tada") != null);
    try std.testing.expect(findSound("/play not-a-sound") == null);
    try std.testing.expect(findSound("/play tada\n") == null);
}
fn writeMessageId(w: *Io.Writer,m: model.Message,prefix_value: []const u8) !void {
    if(prefix_value.len != 0) {try w.writeAll(prefix_value);try w.writeByte('_');}
    try w.writeAll("message_");try compat.htmlEscape(w,m.client_message_id);
}
fn writeRoomId(w: *Io.Writer,r: model.Room,prefix_value: []const u8) !void {
    if(prefix_value.len != 0) {try w.writeAll(prefix_value);try w.writeByte('_');}
    try w.print("{s}_{d}",.{r.kind.paramKey(),r.id});
}
fn cableUrl(w: *Io.Writer,base: []const u8) !void {
    const value=std.mem.trimEnd(u8,base,"/");
    if(std.mem.startsWith(u8,value,"https://")) {try w.writeAll("wss://");try compat.htmlEscape(w,value[8..]);}
    else if(std.mem.startsWith(u8,value,"http://")) {try w.writeAll("ws://");try compat.htmlEscape(w,value[7..]);}
    else return error.InvalidBaseUrl;
    try w.writeAll("/cable");
}
