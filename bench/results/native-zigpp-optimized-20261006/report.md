**Interpretation limit — Rust reference drift.** Native source: `8e9e777`.
The unchanged Rust binary and recorded runner settings produced only 35–39% of the
[earlier control throughput](../native-zigpp-20261006/report.md). The cause is not established.
Ratios below compare configurations within this interleaved batch; they are not a controlled
native before/after speedup, stable leaderboard result, or comparison with published DHH hardware.
POST omits native broadcast, push/jobs and webhook delivery work.

All 1,323,179 measured responses were HTTP 200; all 30 scenarios had zero transport errors.
[Fingerprints, integrity checks and caveats](verification.json),
[unchanged live gate](native-contract.json), [warm-cache wire/permission checks](gzip-contract.json)
and [actual Chromium evidence](browser-contract.json) accompany the raw six JSON runs.

```
date: 2026-10-06T08:03:11-0400
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
Host load (1-min loadavg at start of each run): native-rust 0.30/3.93/4.03, native-zigpp 3.27/4.79/5.06

### HTTP room_show

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 5,336 [4,794–5,495] | 7,548 [6,869–7,577] (1.41×) |
| c=16 p50 ms | 2.89 [2.81–3.22] | 1.99 [1.94–2.26] (1.45×) |
| c=16 p99 ms | 5.74 [5.71–6.41] | 4.40 [4.17–4.70] (1.30×) |
| c=16 campfire CPU ms/req | 0.61 [0.59–0.67] | 0.44 [0.42–0.49] (1.38×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.85 [0.83–0.85] | 0.79 [0.78–0.79] |
| c=16 campfire cores busy | 3.24 [3.23–3.25] | 3.34 [3.18–3.34] |
| avg response bytes | 24,231 [24,231–24,231] | 24,105 [24,105–24,105] |

### HTTP messages_page

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 5,673 [5,240–5,736] | 12,153 [11,458–13,054] (2.14×) |
| c=16 p50 ms | 2.74 [2.71–2.97] | 1.31 [1.12–1.34] (2.09×) |
| c=16 p99 ms | 5.25 [5.15–5.54] | 2.57 [2.53–2.62] (2.05×) |
| c=16 campfire CPU ms/req | 0.56 [0.56–0.61] | 0.28 [0.26–0.30] (2.00×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.89 [0.88–0.89] | 1.21 [1.20–1.23] |
| c=16 campfire cores busy | 3.20 [3.20–3.21] | 3.45 [3.42–3.45] |
| avg response bytes | 16,158 [16,158–16,158] | 16,086 [16,086–16,086] |

### HTTP sidebar

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 4,894 [4,562–5,244] | 6,874 [6,014–7,064] (1.40×) |
| c=16 p50 ms | 3.14 [2.93–3.37] | 2.07 [2.01–2.56] (1.52×) |
| c=16 p99 ms | 6.32 [6.15–6.70] | 5.62 [4.90–5.78] (1.13×) |
| c=16 campfire CPU ms/req | 0.66 [0.62–0.71] | 0.47 [0.46–0.53] (1.42×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.77 [0.77–0.77] | 0.63 [0.63–0.63] |
| c=16 campfire cores busy | 3.24 [3.24–3.25] | 3.20 [3.20–3.23] |
| avg response bytes | 5,910 [5,910–5,910] | 5,872 [5,872–5,872] |

### HTTP search

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 6,244 [5,451–6,298] | 4,522 [4,272–4,997] (0.72×) |
| c=16 p50 ms | 2.43 [2.41–2.77] | 3.35 [3.07–3.92] (0.73×) |
| c=16 p99 ms | 5.21 [5.20–6.10] | 7.43 [6.97–7.60] (0.70×) |
| c=16 campfire CPU ms/req | 0.54 [0.53–0.62] | 0.52 [0.49–0.57] (1.03×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.93 [0.90–0.93] | 0.49 [0.49–0.50] |
| c=16 campfire cores busy | 3.38 [3.37–3.38] | 2.42 [2.37–2.45] |
| avg response bytes | 9,766 [9,766–9,766] | 9,596 [9,596–9,596] |

### HTTP post_message

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 1,365 [1,284–1,390] | 1,301 [1,270–1,353] (0.95×) |
| c=16 p50 ms | 11.3 [11.1–11.9] | 10.8 [9.64–10.8] (1.05×) |
| c=16 p99 ms | 26.7 [26.5–28.5] | 29.6 [28.6–30.9] (0.90×) |
| c=16 campfire CPU ms/req | 2.08 [2.03–2.20] | 1.01 [0.97–1.05] (2.06×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.30 [0.29–0.30] | 0.15 [0.15–0.16] |
| c=16 campfire cores busy | 2.83 [2.82–2.84] | 1.32 [1.32–1.33] |
| avg response bytes | 1,991 [1,991–1,991] | 2,024 [2,024–2,025] |
