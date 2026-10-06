```
date: 2026-10-06T03:58:26-0400
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
Host load (1-min loadavg at start of each run): native-rust 2.89/4.19/4.37, native-zigpp 4.71/5.08/4.34

### HTTP room_show

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 14,288 [14,093–14,643] | 956 [939–958] (0.07×) |
| c=16 p50 ms | 1.08 [1.05–1.09] | 16.7 [14.9–18.8] (0.06×) |
| c=16 p99 ms | 2.10 [2.03–2.13] | 28.0 [23.7–31.9] (0.07×) |
| c=16 campfire CPU ms/req | 0.23 [0.22–0.23] | 3.62 [3.62–3.66] (0.06×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.88 [0.87–0.88] | 0.050 [0.050–0.050] |
| c=16 campfire cores busy | 3.27 [3.26–3.27] | 3.47 [3.43–3.47] |
| avg response bytes | 24,231 [24,231–24,231] | 21,309 [21,309–21,309] |

### HTTP messages_page

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 15,427 [15,301–15,674] | 1,164 [1,148–1,167] (0.08×) |
| c=16 p50 ms | 1.00 [0.98–1.00] | 12.2 [12.2–13.6] (0.08×) |
| c=16 p99 ms | 1.92 [1.87–1.92] | 26.6 [19.1–33.3] (0.07×) |
| c=16 campfire CPU ms/req | 0.21 [0.21–0.21] | 2.91 [2.91–2.96] (0.07×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.90 [0.90–0.91] | 0.050 [0.050–0.050] |
| c=16 campfire cores busy | 3.22 [3.22–3.22] | 3.39 [3.39–3.40] |
| avg response bytes | 16,158 [16,158–16,158] | 12,520 [12,520–12,520] |

### HTTP sidebar

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 13,287 [13,281–13,419] | 1,505 [1,323–1,519] (0.11×) |
| c=16 p50 ms | 1.15 [1.14–1.16] | 10.6 [10.1–11.7] (0.11×) |
| c=16 p99 ms | 2.29 [2.26–2.31] | 20.8 [18.4–22.9] (0.11×) |
| c=16 campfire CPU ms/req | 0.25 [0.24–0.25] | 1.65 [1.58–1.95] (0.15×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.79 [0.79–0.79] | 0.070 [0.060–0.070] |
| c=16 campfire cores busy | 3.26 [3.26–3.26] | 2.48 [2.40–2.58] |
| avg response bytes | 5,910 [5,910–5,910] | 5,820 [5,820–5,820] |

### HTTP search

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 17,897 [17,234–18,240] | 1,746 [1,722–1,758] (0.10×) |
| c=16 p50 ms | 0.83 [0.82–0.86] | 9.34 [9.13–11.4] (0.09×) |
| c=16 p99 ms | 1.94 [1.90–2.06] | 18.1 [16.1–19.4] (0.11×) |
| c=16 campfire CPU ms/req | 0.19 [0.18–0.19] | 1.64 [1.64–1.66] (0.11×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.95 [0.94–0.96] | 0.080 [0.080–0.080] |
| c=16 campfire cores busy | 3.32 [3.31–3.33] | 2.86 [2.85–2.89] |
| avg response bytes | 9,766 [9,766–9,766] | 9,620 [9,620–9,620] |

### HTTP post_message

| Metric | native-rust | native-zigpp |
|---|---|---|
| c=16 req/s | 3,532 [3,490–3,629] | 2,008 [1,945–2,017] (0.57×) |
| c=16 p50 ms | 4.23 [4.12–4.25] | 6.81 [6.10–6.97] (0.62×) |
| c=16 p99 ms | 14.8 [14.4–15.1] | 18.9 [17.6–21.4] (0.78×) |
| c=16 campfire CPU ms/req | 0.77 [0.75–0.78] | 0.66 [0.66–0.68] (1.17×) |
| c=16 thrust CPU ms/req | – | – |
| c=16 docker-proxy CPU ms/req | – | – |
| c=16 loadgen cores busy | 0.30 [0.29–0.30] | 0.10 [0.10–0.10] |
| c=16 campfire cores busy | 2.74 [2.71–2.76] | 1.33 [1.32–1.33] |
| avg response bytes | 1,991 [1,990–1,991] | 1,995 [1,995–1,996] |
