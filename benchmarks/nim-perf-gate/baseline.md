# Nim perf-gate — zc baseline (worker → native `invokeService` latency)

This captures the **zc (Zen-C) build** baseline that the Nim-driven build
must match within **15%**. Same bench app, same engine, same bridge path;
only the build language changes for the Nim comparison run.

- **App:** `benchmarks/apps/zapp-host-bridge` (`src/bench-worker.ts`)
- **Build:** default `zc` (`ZAPP_NATIVE_LANG` unset)
- **Engine:** `zjs` (headless `bench-zjs` worker)
- **Workload:**
  - `invokeService.small` — `invokeService("noop", { i: 1 })` × 10,000 (200-iter warmup)
  - `invokeService.medium` — `invokeService("echo", <50-item obj, ~3 KB JSON>)` × 1,000
- **Date:** 2026-06-15
- **Machine:** Apple M4 Max, arm64 (Darwin 25.5.0)

## Runs (zjs, µs/op)

| run | invokeService.small | invokeService.medium |
|----:|--------------------:|---------------------:|
| 1   | 0.61                | 57.87                |
| 2   | 1.01                | 60.74                |
| 3   | 0.88                | 60.39                |

Raw `[bench:zjs]` lines:

```
run 1: invokeService.small x10000: 6.13ms total, 1629992 ops/sec, 0.61 us/op
run 1: invokeService.medium x1000: 57.87ms total, 17280 ops/sec, 57.87 us/op
run 2: invokeService.small x10000: 10.08ms total, 992556 ops/sec, 1.01 us/op
run 2: invokeService.medium x1000: 60.74ms total, 16463 ops/sec, 60.74 us/op
run 3: invokeService.small x10000: 8.77ms total, 1139861 ops/sec, 0.88 us/op
run 3: invokeService.medium x1000: 60.39ms total, 16559 ops/sec, 60.39 us/op
```

## Baseline

Median across the 3 runs:

- `invokeService.small`  median = **0.88 µs/op**
- `invokeService.medium` median = 60.39 µs/op

```
ZC_BASELINE_SMALL = 0.88 µs/op
```

The Nim build's `invokeService.small` median must land within 15% of this
(i.e. ≤ 1.01 µs/op) to pass the gate.

## Notes / caveats

- The bench app's config ships two headless workers (`bench-zjs`,
  `bench-bare-jsc`). On this run the **bare-jsc** worker SIGSEGVs at startup
  (`bare_worker_thread → bare_setup → js_create_string_utf8`, `strlen(NULL)`)
  and takes the whole process down before `bench-zjs` can run — so the raw
  binary and the as-shipped two-worker `.app` both produced zero bench lines.
  Captured the zjs baseline by temporarily disabling the `bench-bare-jsc`
  entry in `zapp.config.ts`, rebuilding, running, then reverting the edit
  (config restored, not committed). The Nim comparison should use the same
  zjs-only config for an apples-to-apples gate. The bare-jsc startup crash is
  a separate pre-existing issue (likely `vendor/bare` submodule state) — out
  of scope for this baseline.
- Must run the packaged `.app` binary
  (`release/bench-host-bridge.app/Contents/MacOS/bench-host-bridge`), not the
  raw `bin/` binary — the headless workers only fire under the bundle context.
- Run method: background-launch + `sleep 8` + `kill -INT` (the worker
  schedules its suite 1500 ms after boot and finishes well within 8 s).
- Run-to-run variance on `.small` is meaningful (0.61–1.01 µs/op, ~1.6×) —
  expected at sub-microsecond scale; use the median, not a single run.
