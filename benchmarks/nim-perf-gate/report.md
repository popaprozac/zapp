# Nim perf-gate — result + verdict (worker → native `invokeService` latency)

Final gate for the Zapp Nim-migration **worker host-object perf gate**:
Nim-driven build vs default zc (Zen-C) build, same bench app, same engine,
same bridge path, **back-to-back in one session** on the same machine. The
only variable across the two builds is the language of `service_invoke_native`
(the native handler the worker's `invokeService` round-trips into).

- **App:** `benchmarks/apps/zapp-host-bridge` (`src/bench-worker.ts`)
- **Engine:** `zjs` (headless `bench-zjs` worker)
- **Workload:**
  - `invokeService.small` — `invokeService("noop", { i: 1 })` × 10,000 (200-iter warmup)
  - `invokeService.medium` — `invokeService("echo", <50-item obj, ~3 KB JSON>)` × 1,000
- **Date:** 2026-06-15
- **Machine:** Apple M4 Max, arm64 (Darwin 25.5.0)
- **Builds:** Nim = `ZAPP_NATIVE_LANG=nim bun run build` (`bin/bench-host-bridge`, 427 KB);
  zc = `ZAPP_NATIVE_LANG` unset, `bun run build` (`bin/bench-host-bridge`, 691 KB).
  Both run from the project dir (zjs.c loads `.zapp/workers/` cwd-relative);
  the stale `release/*.app` (722 KB, prior zc build) was ignored.
- **Run method:** background-launch + 12 s window + `kill -INT`; the worker
  schedules its suite 1500 ms after boot and finishes well within the window.
  7 runs per build. `bench-bare-jsc` was excluded for both (see caveats).

## Nim build (zjs, µs/op) — 7 runs

| run | invokeService.small | invokeService.medium |
|----:|--------------------:|---------------------:|
| 1   | 0.93                | 62.57                |
| 2   | 1.33                | 61.11                |
| 3   | 1.09                | 59.24                |
| 4   | 1.18                | 58.90                |
| 5   | 0.80                | 62.41                |
| 6   | 0.92                | 58.70                |
| 7   | 0.90                | 57.49                |

- `invokeService.small`  median = **0.93 µs/op** (range 0.80–1.33, spread 1.66×)
- `invokeService.medium` median = **59.24 µs/op** (range 57.49–62.57, spread 1.09×)

## zc build (zjs, µs/op) — 7 runs (fresh, same session)

| run | invokeService.small | invokeService.medium |
|----:|--------------------:|---------------------:|
| 1   | 1.09                | 61.86                |
| 2   | 0.74                | 58.85                |
| 3   | 1.11                | 63.37                |
| 4   | 0.81                | 59.27                |
| 5   | 0.88                | 61.07                |
| 6   | 0.79                | 59.63                |
| 7   | 0.73                | 63.31                |

- `invokeService.small`  median = **0.81 µs/op** (range 0.73–1.11, spread 1.52×)
- `invokeService.medium` median = **61.07 µs/op** (range 58.85–63.37, spread 1.08×)

## Verdict

| metric  | nim median | zc median | ratio (nim/zc) | bar      | result |
|---------|-----------:|----------:|---------------:|---------:|:------:|
| small   | 0.93 µs/op | 0.81 µs/op | **1.15×**     | ≤ 1.15×  | PASS   |
| medium  | 59.24 µs/op| 61.07 µs/op| **0.97×**     | ≤ 1.15×  | PASS   |

### **VERDICT: PASS**

- `ratio_small`  = **1.15** — at the bar, and the Nim small median (0.93)
  sits **inside** the zc small observed band (0.73–1.11). The small case is
  sub-microsecond and noise-dominated (both builds show ~1.5–1.7× run-to-run
  spread), so this is parity, not a regression.
- `ratio_medium` = **0.97** — Nim is marginally *faster* on the stable,
  reliable medium case. Medium is the corroborating signal (~60 µs, ~8–9%
  spread); it clears the bar with margin.

Both conditions of the gate are met: small is within the bar **and** clearly
within the zc small noise band, **and** medium is at parity (≤ 1.15×).

## Greenlight

`service_invoke_native` in Nim is at parity with zc on the worker host-object
hot path. **Greenlight breadth** — proceed widening the Nim migration beyond
this single handler.

## Notes / caveats

- **Identical bridged value.** BOTH builds link the **identical zc-emitted
  `JsonValue`** (the bridge value type and the zc-emitted service plumbing are
  shared). The only thing that differs between the two binaries is the language
  of `service_invoke_native`. This isolates the measurement to that one
  function's cost.
- **`noop`/`echo` are constant-returning stubs.** They don't parse the native
  arguments. So `invokeService.medium` measures the **worker-side** cost —
  JSON build of the ~3 KB payload + the FFI crossing + the value bridge — not
  native argument parsing. That's the right thing to hold constant for an
  apples-to-apples language comparison of the call path.
- **small is noise-dominated → medium is the reliable signal.** At sub-µs the
  `small` µs/op swings ~1.5–1.7× run-to-run on both builds; a single small run
  proves nothing. The medium case (~60 µs, ~8% spread) is the dependable
  corroborator, and it shows Nim at-or-slightly-ahead.
- **bench-bare-jsc excluded.** The bench app's config ships a second headless
  worker (`bench-bare-jsc`) that SIGSEGVs at startup (pre-existing
  `vendor/bare` issue) and would take the process down before `bench-zjs`
  runs. It was temporarily disabled in `zapp.config.ts` for the zc re-run and
  then reverted (config restored, **not** committed). The Nim build already
  skips non-zjs workers, so no edit was needed there. The bare-jsc crash is
  out of scope for this gate.
