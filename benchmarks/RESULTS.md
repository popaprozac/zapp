# Zapp Benchmark Results

Machine-recorded measurements from `benchmarks/scripts/measure-all.sh`. Each
entry is a dated section appended verbatim by the script. Older runs are kept
for historical comparison.

All numbers come from minimal hello-world apps in `benchmarks/apps/` — one
window, one ping button, one native handler returning a timestamp. Every
framework does the same thing so the measurements compare framework overhead
rather than app complexity.

See `README.md` in this folder for methodology, what each column means, and
how to reproduce these numbers.

**Note on Wails (two builds)**: Wails v3 stubs `openDevTools()` to an
empty function under the `-tags production` build tag that
`wails3 task darwin:package` uses by default, making devtools
unreachable in a release build. The benchmark measures Wails twice:

- **Size / startup / idle / build times** come from the production
  build (`build-all.sh`, no DEV flag) — the fair release baseline
  matching every other framework.
- **IPC bench** comes from a separate rebuild with `DEV=true`
  (`scripts/build-wails-devtools.sh`), which drops the production
  tag so devtools work and is the only way to reach the
  paste-into-console bridge-bench.js flow. DEV=true also disables Go
  inlining (`-gcflags=all=-l`), so the Wails IPC number is
  annotated "DEV build" and is on a very slightly slower Go binary
  than the production build.

See `README.md` → "Devtools in release builds" → Wails for the full
story.

## 2026-04-11 — Zach's Mac Studio (macOS 26.5, arm64)

### Size, startup, idle memory

Startup: median of 15 samples after 5 warmups + 1 prime launch. Idle:
`footprint` sum across all bundle processes after 3s settle. Binary column
shows the main executable for native-style bundles, the Electron Framework
for Electron, or the self-extracting archive for Electrobun (noted in
parentheses).

Build times from `build-all.sh` — cold wipes each app's local build
outputs first (not dep caches); hot leaves them in place.

| Framework | Version | Build (cold) | Build (hot) | Binary | Bundle | Icon | Startup (ms) | Idle (MB) |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| zapp-jsc | 35047a7 | 3.5s | 3.1s | 445 KB | 2.8 MB | 2.4 MB | 91 | 26 |
| zapp-txiki | 35047a7 | 3.2s | 3.1s | 6.5 MB | 8.9 MB | 2.4 MB | 94 | 25 |
| tauri | 2.10.3 | 53.8s | 30.3s | 8.0 MB | 8.1 MB | 96 KB | 97 | 26 |
| wails | 3.0.0-alpha.74 | 1.9s | 1.0s | 7.5 MB | 9.0 MB | 45 KB | 83 | 32 |
| electron | 41.2.0 | 3.6s | 2.7s | 170.6 MB (framework) | 263.3 MB | 265 KB | 96 | 90 |
| electrobun | 1.16.0 | 12.8s | 13.2s | 17.0 MB (archive) | 17.1 MB | — | 91 | 101 |

Notes on the numbers:

- **Zapp icon dominates the bundle.** The 2.4 MB multi-resolution .icns
  is 84% of zapp-jsc's 2.8 MB bundle. Without the icon the shipping
  weight would be ~480 KB.
- **Tauri cold build is Rust release compile.** 54s is hundreds of
  crates (`wry`, `tao`, serde, etc.). Hot rebuild is 30s because Cargo
  re-links but re-checks all deps. A no-change incremental is well
  under a second.
- **Electrobun cold ≈ hot** because it doesn't have incremental
  compilation — each build re-bundles the bun runtime, zstd-compresses,
  and creates the dmg.
- **Zapp cold ≈ hot** because Zen-C doesn't do incremental compilation
  yet — every `bun run package` recompiles the full tree.
- **Electron ships Chromium.** The 170 MB binary and 263 MB bundle are
  the Electron Framework + helpers + V8 + Skia + ffmpeg. That's why
  idle RAM is 90 MB even for a one-window hello-world.
- **Electrobun's bundle grows after first launch.** The 17 MB figure is
  the download/shipping weight; after first launch the self-extracting
  archive unpacks bun + native libs into Contents/MacOS, growing the
  on-disk .app to ~69 MB.

<details><summary>raw JSON (size / startup / idle)</summary>

```json
{"label": "zapp-jsc", "binary_bytes": 456496, "binary_note": "main", "bundle_bytes": 2985984, "icon_bytes": 2504702, "startup_ms": 91, "startup_us": 91698, "idle_mb": 26, "runs": 15, "framework_version": "35047a7", "build_cold_s": 3.45, "build_hot_s": 3.1}
{"label": "zapp-txiki", "binary_bytes": 6791456, "binary_note": "main", "bundle_bytes": 9322496, "icon_bytes": 2504702, "startup_ms": 94, "startup_us": 94782, "idle_mb": 25, "runs": 15, "framework_version": "35047a7", "build_cold_s": 3.21, "build_hot_s": 3.15}
{"label": "tauri", "binary_bytes": 8405040, "binary_note": "main", "bundle_bytes": 8515584, "icon_bytes": 98451, "startup_ms": 97, "startup_us": 97926, "idle_mb": 26, "runs": 15, "framework_version": "2.10.3", "build_cold_s": 53.8, "build_hot_s": 30.29}
{"label": "wails", "binary_bytes": 7820240, "binary_note": "main", "bundle_bytes": 9474048, "icon_bytes": 46697, "startup_ms": 83, "startup_us": 83733, "idle_mb": 32, "runs": 15, "framework_version": "3.0.0-alpha.74", "build_cold_s": 1.93, "build_hot_s": 1.03}
{"label": "electron", "binary_bytes": 178890304, "binary_note": "framework", "bundle_bytes": 276066304, "icon_bytes": 272259, "startup_ms": 96, "startup_us": 96339, "idle_mb": 90, "runs": 15, "framework_version": "41.2.0", "build_cold_s": 3.64, "build_hot_s": 2.73}
{"label": "electrobun", "binary_bytes": 17775734, "binary_note": "archive", "bundle_bytes": 17969152, "icon_bytes": 0, "startup_ms": 91, "startup_us": 91646, "idle_mb": 101, "runs": 15, "framework_version": "1.16.0", "build_cold_s": 12.83, "build_hot_s": 13.22}
```

</details>

### IPC bridge round-trip

Measured with `bridge-bench.js`: 6000 calls (30 batches x 200), 500
warmup. Each value is the per-call average within a batch; min/median/
mean/max/stdev are computed across the 30 batches. Batched timing
sidesteps the WebKit 1 ms `performance.now()` clamp that makes per-call
timing useless in release WKWebView builds.

Wails was rebuilt with `DEV=true` for this measurement (the only way to
get devtools in a packaged Wails build). All other frameworks used their
standard release/production builds.

| Framework | Median (µs) | Mean (µs) | Min (µs) | Max (µs) | Stdev (µs) | Throughput |
|---|---:|---:|---:|---:|---:|---:|
| Electron | 51.5 | 52.0 | 48.5 | 66.0 | 3.6 | 19,212/s |
| Zapp (txiki) | 130.0 | 134.3 | 80.0 | 190.0 | 32.3 | 7,444/s |
| Zapp (JSC) | 140.0 | 137.5 | 90.0 | 225.0 | 33.3 | 7,273/s |
| Tauri | 275.0 | 275.7 | 235.0 | 305.0 | 16.7 | 3,628/s |
| Wails (DEV) | 325.0 | 327.3 | 270.0 | 365.0 | 17.1 | 3,055/s |
| Electrobun | 375.0 | 389.0 | 345.0 | 615.0 | 54.0 | 2,571/s |

**Observations:**

- **Electron** is fastest at 52 µs — Chromium's IPC to Node.js uses
  optimized named pipes / mach ports, not the WKWebView message handler
  path. This is the benefit of shipping your own browser engine.
- **Zapp** is second at ~135 µs (both engines) — 2.6x Electron but 2x
  faster than Tauri/Wails. Both Zapp engines share the same native
  Zen-C bridge code so JSC vs txiki is within noise. The WKWebView
  `userContentController` message handler path is the bottleneck, not
  the worker engine.
- **Tauri** at 276 µs — also WKWebView, but the Rust-side JSON
  serialization through `serde_json` + the Tauri invoke protocol adds
  overhead compared to Zapp's direct C-level handler.
- **Wails** at 327 µs — Go's binding layer + JSON marshaling is
  slightly slower than Tauri's Rust equivalent. Also measured on a DEV
  build without Go inlining, so the production number would be modestly
  faster.
- **Electrobun** at 389 µs — uses an encrypted WebSocket between the
  bun child process and the WKWebView (AES-GCM per message), which
  adds measurable latency vs. the direct message-handler path the
  other WKWebView frameworks use.

<details><summary>raw JSON (IPC)</summary>

```json
{"label":"zapp-jsc","total_calls":6000,"batches":30,"batch_size":200,"warmup":500,"min_us":90,"median_us":140,"mean_us":137.5,"max_us":225,"stdev_us":33.3,"throughput_per_sec":7273}
{"label":"zapp-txiki","total_calls":6000,"batches":30,"batch_size":200,"warmup":500,"min_us":80,"median_us":130,"mean_us":134.3,"max_us":190,"stdev_us":32.3,"throughput_per_sec":7444}
{"label":"tauri","total_calls":6000,"batches":30,"batch_size":200,"warmup":500,"min_us":235,"median_us":275,"mean_us":275.7,"max_us":305,"stdev_us":16.7,"throughput_per_sec":3628}
{"label":"wails-dev","total_calls":6000,"batches":30,"batch_size":200,"warmup":500,"min_us":270,"median_us":325,"mean_us":327.3,"max_us":365,"stdev_us":17.1,"throughput_per_sec":3055}
{"label":"electron","total_calls":6000,"batches":30,"batch_size":200,"warmup":500,"min_us":48.5,"median_us":51.5,"mean_us":52,"max_us":66,"stdev_us":3.6,"throughput_per_sec":19212}
{"label":"electrobun","total_calls":6000,"batches":30,"batch_size":200,"warmup":500,"min_us":345,"median_us":375,"mean_us":389,"max_us":615,"stdev_us":54,"throughput_per_sec":2571}
```

</details>
