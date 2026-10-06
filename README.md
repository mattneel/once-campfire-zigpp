# Campfire in native Zig++

This branch adds a **leaderboard-first native Zig++ target**, not a complete application port.
`zig-out/bin/campfire-zigpp` serves the five workloads below without invoking, linking or proxying
the Rust application. The original Rust implementation remains here as the compatibility oracle.

## Native stack and scope

- Zig++ `0.17.0-dev.2469+zigpp.04926fc36`, `std.Io.Threadz`, and pinned
  [Zix](https://github.com/mattneel/zix) HTTP/1 over Linux `io_uring`; four workers by default.
- Existing SQLite schema and storage layout; pooled read transactions, 256 prepared statements
  per connection, batched attachment associations and a serialized writer. Bounded reads execute
  on the calling worker; database-wide search remains offloaded.
- Native Rails-compatible signing/encryption, real bcrypt login, session refresh/logout,
  room membership checks and same-origin write policy.
- Native full/frame room, message pagination, sidebar and reachable-only FTS search rendering;
  actual Turbo message responses, persisted ActionText/plain text, room touch and unread callbacks.
- Gumbo rich-text parsing/sanitization, Propshaft-compatible assets and import maps, and existing
  Active Storage files/variants. Native transformations use libvips and FFmpeg.

**Not implemented:** Action Cable/WebSocket delivery, push/jobs, upload creation, edit/delete/boost
mutations, administration, TLS/ACME, and the remaining application screens. This is not a drop-in
production replacement. Posting exercises real persistence and rendering but **omits broadcast,
push and webhook delivery work**; its timing is not complete-app POST parity.

The upstream frontend's connectivity monitor requires Cable and eventually disables the room
composer without it. Browser login, room/sidebar navigation, infinite scroll and search work;
authenticated browser-origin HTTP POST, persisted reload and search read-back were exercised.
Normal composer Send-button operation is not yet supported.

The measured build requires Linux. On Debian/Ubuntu, install `pkg-config`, `libsqlite3-dev`,
`libgumbo-dev`, `libvips-dev`, `zlib1g-dev` and `ffmpeg`. This host uses libvips 8.15.1 / FFmpeg 6.1.1 rather than
the reference's 8.16.1 / 7.1.5: generated-media byte parity is not claimed.

## Native build and run

Use the Zig++ compiler, not stock Zig. Set `ZIG_LIB_DIR` to its matching SDK when the compiler
installation does not locate it automatically.

```sh
ZIG_ANY=off zig build -Doptimize=ReleaseFast
ZIG_ANY=off zig build test -- --io=threadz
ZIG_ANY=off zig build test -- --io=threaded

# Canonical reference fixtures; generation requires Docker.
parity/bin/reference build
parity/bin/seed build default

# Always run against an isolated writable copy, never the canonical fixture database.
storage="$(mktemp -d)"
cp -a parity/.seed/default/db "$storage/db"
cp -a parity/.seed/default/storage "$storage/files"
set -a
. parity/.env.reference
set +a
CAMPFIRE_STORAGE_PATH="$storage" DISABLE_SSL=1 HTTP_PORT=4410 \
  CAMPFIRE_WORKERS=4 zig-out/bin/campfire-zigpp server
```

Fixture login: `david@37signals.com` / `secret123456`. `--help` lists the native environment
settings. `SECRET_KEY_BASE` must match the original installation. `CAMPFIRE_ASSET_ROOT` overrides
the build-time source root; keep `reference/`, `vendor/` and the port-owned asset files available.

## Native conformance

The native module suite consumes existing compatibility vectors and exercises actual SQLite,
rich-text, assets and media behavior. `parity/native-contract.py` additionally compares live native
and Rust responses/state against source-anchored five-path contracts: authentication, access,
full/frame DOM, exact pagination, sidebar ordering, reachable search/history, persisted Turbo
writes, FTS/unread callbacks and unsafe-message read-back.

Both servers must start on **fresh, separate copies** of `parity/.seed/default`, with matching
`parity/.env.reference` settings. Use the Rust oracle at
`ccece30e8e160d8c3e05bf395ee55ee35962093b`:

```sh
python3 parity/native-contract.py \
  --base http://127.0.0.1:4410 --oracle http://127.0.0.1:4400 \
  --seed parity/.seed/default \
  --db /path/to/native/storage/db/production.sqlite3 \
  --oracle-db /path/to/rust/storage/db/production.sqlite3 \
  --output /tmp/campfire-native-contract.json
```

This gate is deliberately a compatibility **subset**, not a claim that the entire Campfire suite
passes. Its JSON records `whole_campfire_suite_passed: false` and lists uncovered behavior.
Throughput measurements require this gate, real browser workflows and gzip content checks first.

## Native hot paths

The render/encoding path follows the optimized Rust mechanisms in
`crates/views/src/fragment_cache.rs`, `crates/views/src/recorded.rs` and
`crates/kit/src/deflater/splice.rs`, rather than rebuilding and recompressing a whole page:

- A byte-bounded 32 MiB LRU retains immutable message, boost and direct-membership HTML fragments.
  Keys include source record versions and native template/database/signing/assets identity;
  host versus detached message rendering and viewing-user membership context remain separate.
- Recorded responses retain fragment leases and layout gaps, not a flattened page copy. SHA-256
  and CRC metadata are retained with fragments; ETags combine part digests and layout content.
- Gzip splices cached raw level-6 deflate pieces using the preceding part's final 32 KiB as
  dictionary, with at most 256 bytes of layout glue. CRC composition and the final trailer cover
  the actual ordered response. Text metadata and compressed pieces have bounded caches.
- Session and room-membership checks still run before rendering. There is no authenticated
  full-response/path cache; version changes and permission revocation remain observable.

The native database still eagerly hydrates message models before a fragment hit. It does not
yet reproduce Rust's presenter-level lazy association reads or dedicated writer/checkpointer.
Those differences remain relevant to performance; they are not hidden by the render cache.

## Native first measurement — unoptimized, same host

Measured on 2026-10-06 on an **AMD Ryzen 9 9955HX3D**, Linux
`7.2.6-locietta-WSL2-xanmod1`, with four server hardware threads (`8,10,12,14`),
four separate load-generator threads (`16,18,20,22`) and **16 clients**. Both binaries ran
directly on the host. Storage was ext4, not tmpfs. Each configuration/repetition started from
the same isolated seed; outbound delivery endpoints were changed to fail-fast localhost ports
for both. Three interleaved repetitions, eight seconds per route after warmup, gzip, no User-Agent.

The Rust executable came from image revision `ccece30e8e160d8c3e05bf395ee55ee35962093b`.
The native executable was built from `61c393f` in `ReleaseFast`. These measurements are
**not comparable with the published DHH hardware/table below**.

| HTTP workload | Rust req/s | Zig++ req/s | Zig++ / Rust | Zig++ p99 ms |
|---|---:|---:|---:|---:|
| Room page | 14,288.5 | 955.9 | 0.067× | 28.03 |
| Messages page | 15,426.7 | 1,163.9 | 0.075× | 26.62 |
| Sidebar | 13,286.6 | 1,504.7 | 0.113× | 20.80 |
| Search | 17,897.4 | 1,745.8 | 0.098× | 18.08 |
| Post a message | 3,531.9 | 2,008.5 | 0.569× | 18.88 |

Cells are medians across three repetitions. **This first, unoptimized native target was slower than Rust.**
The POST row remains a partial-application measurement: native broadcast, push and webhook
delivery are absent. It is not a complete Campfire leaderboard submission.

Verification completed before timing: all ten strict live conformance scenarios, identity/gzip
DOM equality and real POST persistence, plus Chromium login, navigation, pagination, search and
browser-origin HTTP POST/reload/search read-back. Native module suites passed on `threadz` and
`threaded`. Normal composer Send-button operation and the whole Campfire suite are not claimed.
All **1,722,998 measured responses** were HTTP 200; all 30 measured scenarios had zero transport
errors. The final native database retained 17,306 benchmark messages (including warmup), all
17,306 indexed with the expected plain text.

[Raw runs, latency/CPU data and ranges](bench/results/native-zigpp-20261006/report.md),
[binary fingerprints and verification provenance](bench/results/native-zigpp-20261006/verification.json),
[live conformance report](bench/results/native-zigpp-20261006/native-contract.json),
[gzip report](bench/results/native-zigpp-20261006/gzip-contract.json),
[browser report](bench/results/native-zigpp-20261006/browser-contract.json) and
[native room screenshot](bench/results/native-zigpp-20261006/native-room.webp).

Reproduce with the existing runner and the pinned Rust image executable:

```sh
NATIVE_RUST_BIN=/path/to/pinned/rust/campfire \
NATIVE_ZIGPP_BIN="$PWD/zig-out/bin/campfire-zigpp" \
RUST_IMAGE=ghcr.io/basecamp/once-campfire-rust@sha256:f92903e60522f1eadfe4d30e009c89cde81652d4919390e6fd72d03661dc7b34 \
SERVER_CPUS=8,10,12,14 LOADGEN_CPUS=16,18,20,22 PORT=4390 \
BENCH_WORK_DIR=/path/to/ext4/benchmark-work \
bench/attrib --configs native-rust,native-zigpp \
  --routes room_show,messages_page,sidebar,search,post_message \
  --concs 16 --secs 8 --reps 3 --cable '' --app-env CAMPFIRE_WORKERS=4 \
  --out bench/results/native-zigpp-rerun
```

Choose equivalent disjoint CPU sets on a different host. Stop acceptance servers and browser
activity first; do not compile or run the conformance suite while timing.

## Rust baseline

A Rust implementation of [ONCE Campfire](https://github.com/basecamp/once-campfire). It uses the
existing SQLite database, storage layout and signed/encrypted cookies, so existing installs can
upgrade without migrating data or signing everyone out.

One `campfire` executable replaces Ruby, Puma, Redis, Resque and Thruster, with libvips and ffmpeg
for media. The Rails frontend ships with a few [port-owned overrides](crates/assets/OVERRIDES.md).
The app includes TLS, HTTP/2, Web Push, bot webhooks, search and Action Cable-compatible WebSockets.

## Rust baseline deployment

With [ONCE](https://github.com/basecamp/once), on a server with Docker:

```sh
once deploy ghcr.io/basecamp/once-campfire-rust --host chat.example.com
```

ONCE manages secrets, TLS, backups and upgrades. Or run Docker directly:

```sh
docker run -d -p 80:80 -p 443:443 \
  -e SECRET_KEY_BASE=... -e VAPID_PUBLIC_KEY=... -e VAPID_PRIVATE_KEY=... \
  -e TLS_DOMAIN=chat.example.com \
  -v campfire:/rails/storage \
  ghcr.io/basecamp/once-campfire-rust
```

- `TLS_DOMAIN` enables automatic Let's Encrypt certificates; `DISABLE_SSL` enables plain HTTP.
- `/rails/storage` holds the database, uploads, backups and certificates. Existing installs must
  keep their storage and secrets.
- Web Push needs a valid P-256 VAPID key pair in URL-safe Base64. `VAPID_SUBJECT` sets the contact
  URL; its default is `https://` plus the first `TLS_DOMAIN`, or the project's URL.
- The app listener on `TARGET_PORT` (3000) binds loopback. `TARGET_BIND` overrides this; that listener
  trusts `X-Forwarded-*` from whoever reaches it. Other settings are in
  [`config.rs`](crates/campfire/src/config.rs).
- Images support amd64 and arm64. `:latest` and version tags track
  [releases](https://github.com/basecamp/once-campfire-rust/releases); `:main` tracks the main branch.

## Published upstream leaderboard — different hardware

Measured with 16 concurrent clients on an AMD Ryzen AI MAX+ 395,
with four hardware threads allocated to each app.
These are upstream results, not measurements of this native Zig++ target or this host.


| HTTP workload (requests/sec) | Rails | [Django](https://github.com/basecamp/once-campfire-django) | [Laravel](https://github.com/basecamp/once-campfire-laravel) | [Express](https://github.com/basecamp/once-campfire-express) | [Elixir](https://github.com/basecamp/once-campfire-elixir) | [Go](https://github.com/basecamp/once-campfire-go) | [Rust](https://github.com/basecamp/once-campfire-rust) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Room page | 241 | 170 | 164 | 559 | 722 | 3,860 | 36,260 |
| Messages page | 413 | 196 | 175 | 777 | 1,053 | 5,573 | 40,872 |
| Sidebar | 552 | 615 | 715 | 4,125 | 1,275 | 19,753 | 34,672 |
| Search | 435 | 315 | 305 | 1,294 | 1,156 | 7,053 | 33,299 |
| Post a message | 273 | 154 | 137 | 256 | 801 | 4,767 | 6,896 |

Database scheduling, rich text rendering and cached-page gzip improvements contributed by
Daniel Collin ([emoon](https://github.com/emoon)) in
[#43](https://github.com/basecamp/once-campfire-rust/pull/43).

## Rust baseline development

Check out the `reference/` submodule before building. Rust 1.98.1 is available through mise;
native media dependencies are specified in the [`Dockerfile`](Dockerfile).

```sh
git submodule update --init
parity/bin/reference build
parity/bin/seed build
CAMPFIRE_REQUIRE_SEED=1 cargo test --workspace --exclude html5ever
cargo clippy --workspace --exclude html5ever --all-targets
parity/bin/candidate build
parity/bin/candidate compare
bench/run
```

Seed generation and parity checks need Docker. Tests without the seed skip app integration tests.
For local development, run `cargo run -p campfire -- server` with `SECRET_KEY_BASE` set
(or `SECRET_KEY_BASE_DUMMY=1`). Build an image with `docker build -t campfire-rust .`.

The parity harness compares HTML, DOM, accessibility trees, assets, Cable frames and screenshots
against Rails. See [`parity/SCREENS.md`](parity/SCREENS.md) for coverage and masks,
[`AGENTS.md`](AGENTS.md) for repository layout and working rules,
[`CONTRIBUTING.md`](CONTRIBUTING.md) for contributions, and [`SECURITY.md`](SECURITY.md) for security reports.

## Rust baseline known differences

The app keeps the Rails database, storage and current cookie formats compatible. Deliberate
behavior changes and compatibility limits are listed below.

<details>
<summary>Differences from Rails</summary>

- **WebSockets:** `permessage-deflate` without context takeover compresses each broadcast once
  for all subscribers. Decoded messages remain identical.
- **CSRF:** `Sec-Fetch-Site` replaces tokens. Writes accept `same-origin` and `same-site`, reject
  `cross-site` and missing headers over HTTPS with 422, and retain the `Origin` check. Plain HTTP
  accepts missing headers with `SameSite=Lax` cookies. Pages omit CSRF tags and fields; old tabs
  still work, but HTTPS forms require a browser that sends the header (Safari 16.4 or newer).
- **Jobs:** Redis and Resque are replaced by in-process queues with `JOB_CONCURRENCY` workers per
  job kind. Queued pushes and webhooks are lost on a crash; slow webhooks don't block pushes.
- **Push:** invalid VAPID keys disable push at boot. Subscriptions survive TLS/configuration
  failures and are deleted only on 404/410 or an invalid subscription P-256 key. Notification
  bodies are truncated with an ellipsis at 3 KB and titles at 256 bytes. `VAPID_SUBJECT` is configurable.
  Delivery timeouts are 10 seconds per connect/read and 30 seconds overall.
- **Cookies:** sessions are written only on change and deleted when empty; `last_room` only on
  change. `session_token` is re-signed on the hourly activity refresh, retaining its rolling
  20-year expiry. Other authenticated reads avoid the database writer.
- **Caching:** room, messages and search ETags hash cached page parts rather than the body.
  Copy-link buttons cache paths and resolve them against the page URL; bot JSON is cached per
  base URL, preventing a request's Host from changing other users' links.
- **SQLite:** boot adds `index_messages_on_room_id_and_created_at` if missing. It remains compatible
  with Rails. Memory mapping is disabled; reads use SQLite's page cache.
- **Media formats:** libvips 8.16.1 and ffmpeg 7.1.5 use the Rails image's Debian sources, with
  byte-identical thumbnails, posters and metadata for supported formats. libvips omits loaders
  Rails already blocks. ffmpeg omits external-library-only formats: tracker modules, game-console
  music, JPEG XL/SVG frames, codec2, teletext and DASH/IMF. Tracker/game-console uploads lack
  duration and bit rate. Unused encoders, muxers, hardware and network support are omitted.
- **Media processing:** message uploads are copied and checksummed before saving their rows, then
  deleted if saving fails. The redundant MD5 reread is skipped; analysis, variants, posters and
  client direct-upload checksums still validate files. At most four media jobs run off the database
  writer. Variants/posters are saved already analyzed; concurrent transforms keep the first saved
  result and delete duplicates. ffmpeg posters time out at 60 seconds, ffprobe at 30.
- **Request limits:** non-file-upload bodies and direct uploads are capped at 16 MiB (413).
  Nonnumeric direct-upload sizes and oversized QR codes return 422. Page numbers cap at a billion.
- **Cable limits:** 64 subscriptions per connection, 4 KiB identifiers and 1 MiB messages.
  Clients that don't read for 30 seconds disconnect. Banning/deactivating a user closes their
  connections after commit.
- **Unfurling:** 10 seconds overall, 5 per connect/read, at most 16 concurrent unfurls, and only
  the first 256 attributes of a `meta` tag are read. Timed-out pages unfurl nothing.
- **Webhooks:** 60 seconds overall, 7 per connect/read. Replies over 100 MB after decompression
  fail delivery without posting a response.
- **Front server:** `TARGET_PORT` binds loopback and enforces front-server timeouts and
  `MAX_REQUEST_BODY`. Cache keys count toward `CACHE_SIZE`, preserve raw paths/queries, skip URIs
  over 2 KB and forward range requests. Idle HTTP/1 connections close at the shorter of
  `HTTP_IDLE_TIMEOUT` and `HTTP_READ_TIMEOUT` until request headers arrive (30 seconds with defaults,
  60 with image settings); HTTP/2 uses the idle timeout. Response header lines containing DEL are omitted.
- **Passwords:** bcrypt runs outside database connections/transactions. Unknown emails still
  perform one bcrypt check.
- **JSON:** floats use the shortest equivalent digits. The web app manifest properly JSON-escapes
  account names and URLs.
- **Search:** words are literal full-text terms, including `NOT`, `AND`, `OR` and `NEAR`.
- **Routes and UI:** `/rooms/directs/:id` redirects to the room; infinite `Accept` q-values sort
  first or last by sign; EdgeHTML install instructions include the missing image; the new-ping
  picker requests JSON so suggestions appear.
- **Rich text attributes:** autolinking escapes `<`/`>` in attributes to prevent stored XSS.
  Sanitization drops `name` attributes to prevent DOM clobbering. Styles retain only `color` and
  `background-color` with plain keyword/hex/RGB/HSL values or CSS variables in bot/webhook HTML;
  message pages drop styles.
- **Rich text attachments:** content attachments nest at most eight levels; deeper content is
  empty. Deleted-user mentions render ☒ and are omitted in the editor. Active Storage attachments
  embedded in message bodies, which the composer can't create, render ☒.
- **Malformed rich text:** plain-text extraction failures are logged and use empty text or an
  attachment filename; messages are still indexed, pushed, broadcast and sent to bots. Bodies
  beyond 400 nesting levels or 400 attributes per element are stored unchanged with empty plain
  text. These messages render as unrenderable.
- **Not ported:** Active Storage streaming's duplicate `session_token` cookie or legacy AES-CBC
  cookies; Campfire uses AES-GCM.

HTTP-01 ACME validation is only unit-tested; TLS-ALPN-01 is tested end to end against a local ACME
server. Rich text is checked against Rails on 658 cases, including 400 fuzzed cases.

</details>

## License

MIT. See [`MIT-LICENSE`](MIT-LICENSE).
