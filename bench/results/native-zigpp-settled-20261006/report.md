**ReleaseFast + system SQLite baseline, after the user paused competing agent activity.**
Native source `8e9e777`; system SQLite 3.45.1 through the C API, not Zig++ `std.db`/Turso.
Both server executables, the load generator, canonical seed and all recorded runner settings
match the earlier matrices. Native uses four Threadz serving workers; each server has the
same four-core CPU affinity. The 16-client load generator has four separate cores.

**Rust control recovery:** medians are 1.6–3.2% above the first control and 2.67–2.92× the
earlier drifted batch. Rust's within-batch min–max spread is 0.33–1.96% of each route's median.
This supports the contention explanation, not causal isolation of other agents. Native messages
still vary from 33,225.6 to 38,128.5 req/s (13.7% min–max spread relative to the median).
Use the ranges below; these results are not comparable with published DHH hardware.

All 3,774,450 measured responses were HTTP 200; all 30 scenarios had zero transport errors.
The last native database retained 27,625 benchmark messages including warmup, with distinct
client IDs, ActionText and matching FTS plain text. POST omits native broadcast, push/jobs and
webhook delivery, so this remains a five-HTTP-path baseline, not complete-application parity.
Prior compatibility and browser checks are reused via matching binary hashes, not rerun.

[Verification, backend and fingerprints](verification.json),
[previous optimized batch](../native-zigpp-optimized-20261006/report.md) and
[first control](../native-zigpp-20261006/report.md).

```
date: 2026-10-06T13:02:35-0400
host: 7.2.6-locietta-WSL2-xanmod1, 32 threads
server cpus: 8,10,12,14; loadgen cpus: 16,18,20,22
image: ghcr.io/basecamp/once-campfire-rust@sha256:f92903e60522f1eadfe4d30e009c89cde81652d4919390e6fd72d03661dc7b34 sha256:f92903e60522f1eadfe4d30e009c89cde81652d4919390e6fd72d03661dc7b34
native-rust: /home/autark/work/campfire/baseline/campfire preload=
native-zigpp: /home/autark/src/once-campfire-zigpp/zig-out/bin/campfire-zigpp preload=
env: WEB_CONCURRENCY=3 RAILS_MAX_THREADS=5 JOB_CONCURRENCY=3
routes: room_show,messages_page,sidebar,search,post_message; concs: 16; secs: 8; cable: ; app env: CAMPFIRE_WORKERS=4
user agent: (none)
```

Reps per configuration: native-rust 3, native-zigpp 3. Cells: median [min–max]; (×) is the gain over native-rust (>1 is better).
Host load (1-min loadavg at start of each run): native-rust 0.07/3.42/4.90, native-zigpp 3.56/5.27/5.25

### HTTP room_show

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 14,518 [14,493–14,541] | 21,174 [20,884–21,177] (1.46×) |
| c=16 p50 ms | 1.06 [1.06–1.06] | 0.73 [0.73–0.74] (1.44×) |
| c=16 p99 ms | 2.04 [2.04–2.05] | 1.53 [1.40–1.55] (1.33×) |
| c=16 campfire CPU ms/req | 0.22 [0.22–0.22] | 0.16 [0.16–0.16] (1.41×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.86 [0.86–0.87] | 0.83 [0.81–0.84] |
| c=16 campfire cores busy | 3.26 [3.26–3.26] | 3.37 [3.36–3.37] |
| avg response bytes | 24,231 [24,231–24,231] | 24,105 [24,105–24,105] |

### HTTP messages_page

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 15,896 [15,880–16,029] | 35,837 [33,226–38,128] (2.25×) |
| c=16 p50 ms | 0.97 [0.97–0.97] | 0.40 [0.33–0.42] (2.43×) |
| c=16 p99 ms | 1.81 [1.80–1.82] | 0.94 [0.79–1.35] (1.93×) |
| c=16 campfire CPU ms/req | 0.20 [0.20–0.20] | 0.097 [0.092–0.10] (2.10×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.90 [0.89–0.91] | 1.26 [1.19–1.31] |
| c=16 campfire cores busy | 3.22 [3.22–3.22] | 3.46 [3.37–3.52] |
| avg response bytes | 16,158 [16,158–16,158] | 16,086 [16,086–16,086] |

### HTTP sidebar

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 13,547 [13,481–13,556] | 19,222 [18,728–19,500] (1.42×) |
| c=16 p50 ms | 1.14 [1.13–1.14] | 0.77 [0.74–0.79] (1.47×) |
| c=16 p99 ms | 2.22 [2.22–2.25] | 1.69 [1.52–1.77] (1.32×) |
| c=16 campfire CPU ms/req | 0.24 [0.24–0.24] | 0.17 [0.13–0.18] (1.41×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.79 [0.79–0.79] | 0.66 [0.65–0.67] |
| c=16 campfire cores busy | 3.26 [3.26–3.26] | 3.29 [2.59–3.33] |
| avg response bytes | 5,910 [5,910–5,910] | 5,872 [5,872–5,872] |

### HTTP search

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 18,224 [18,009–18,255] | 12,588 [12,000–12,677] (0.69×) |
| c=16 p50 ms | 0.82 [0.81–0.83] | 1.22 [0.91–1.49] (0.67×) |
| c=16 p99 ms | 1.90 [1.88–1.93] | 2.99 [2.36–3.54] (0.64×) |
| c=16 campfire CPU ms/req | 0.18 [0.18–0.18] | 0.19 [0.19–0.20] (0.95×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.95 [0.94–0.96] | 0.49 [0.48–0.50] |
| c=16 campfire cores busy | 3.32 [3.31–3.33] | 2.41 [2.40–2.44] |
| avg response bytes | 9,766 [9,766–9,766] | 9,596 [9,596–9,596] |

### HTTP post_message

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 3,646 [3,631–3,703] | 3,059 [3,040–3,090] (0.84×) |
| c=16 p50 ms | 4.11 [4.02–4.13] | 3.87 [3.76–4.07] (1.06×) |
| c=16 p99 ms | 13.9 [13.7–14.6] | 12.9 [12.8–13.0] (1.08×) |
| c=16 campfire CPU ms/req | 0.75 [0.74–0.75] | 0.39 [0.39–0.39] (1.91×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.30 [0.29–0.30] | 0.14 [0.14–0.14] |
| c=16 campfire cores busy | 2.72 [2.72–2.72] | 1.20 [1.18–1.21] |
| avg response bytes | 1,991 [1,991–1,992] | 2,024 [2,024–2,025] |
