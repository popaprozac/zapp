# Zapp host-bridge bench — results

Measures the per-call cost of `__zappBridge.invokeService(method, args)` and
`Events.emit(name, payload)` from worker code, side by side across the three
engines compiled into the bench binary (`jsc.m`, `txiki.c`, `bare-jsc`).

Three identical workers, same TS source, run their suite at app startup. The
binary is signed adhoc with `com.apple.security.cs.allow-jit` so JSC actually
JITs the hot path (without it, JSC's tier-up doesn't run and the comparison
becomes interpreter-vs-interpreter).

## Headline numbers

5-run cold-launch median µs/op (range across runs):

| Engine | invokeService.small | invokeService.medium | emit.small | emit.medium |
|---|---:|---:|---:|---:|
| jsc (legacy `.m`) | 1.23 (1.22–1.30) | 138.39 (133.81–142.36) | **1.86** (1.79–1.88) | 98.23 (96.60–107.43) |
| txiki (QuickJS) | **0.41** (0.23–0.57) | 49.52 (44.06–54.78) | 3.01 (1.76–4.98) | 78.02 (74.11–135.88) |
| **bare-jsc** | 1.00 (0.70–1.50) | **60.00** (41.00–128.00) | 2.10 (1.60–5.20) | **19.00** (15.00–47.00) |

Workloads:
- **`.small`**: `{ i: 1 }` — single primitive property, ~12-byte JSON.
- **`.medium`**: `{ items: [50 × { id, name, tags, value }], meta: {...} }` — ~3 KB JSON.
- 10,000 iters for small, 1,000 for medium, 200-iter warmup.

## Reading the numbers

**Small payload (FFI-dominated):**
- txiki wins (0.41 µs) — QuickJS's FFI is cheaper than JSC's bridge crossings.
- bare-jsc and jsc.m are within noise (1.0 vs 1.2 µs).
- Per-call overhead floor across all engines: **~1 µs**. That's 1M ops/sec — well above any realistic Zapp workload.

**Medium payload (data-walk dominated):**
- bare-jsc (60 µs) and txiki (50 µs) are the fast tier.
- jsc.m (138 µs) is **2.3× slower than bare-jsc**.
- This is where bare's design wins: it uses JSC's JIT'd `JSON.stringify` on the JS side, then C just reads a string. jsc.m goes through `[payload toObject]` (NSObject bridging) + `NSJSONSerialization` per call — both expensive on data with many properties.

**emit.medium (broadcast):**
- bare-jsc (19 µs) is **5× faster than jsc.m** (98 µs) and **4× faster than txiki** (78 µs).
- Same explanation: JIT'd JSON.stringify > NSJSONSerialization > QuickJS's interpreted JSON.
- This is a real, repeatable bare advantage on data-heavy event broadcasts.

## What this means for engine choice

For Zapp apps that use workers heavily:
- **macOS / iOS** — `bare-jsc` is the right default. Faster than jsc.m on all
  realistic workloads, same binary cost on top of jsc.m (~700 KB), and it
  unlocks the npm `bare-*` module ecosystem.
- **txiki stays competitive on FFI-heavy workloads** (lots of small calls)
  but loses to bare on realistic data-shaped calls.
- **jsc.m's perf disadvantage on medium payloads is the strongest argument
  for retiring it.** Once we're confident in bare-jsc's stability, removing
  jsc.m from the build saves ~50 KB of binary AND makes the framework
  faster on the calls users actually make.

## What didn't pan out

We initially ported bare's `_invokeServiceRaw` to use `service_invoke_native`
with a `js_value_to_jsonvalue` tree walker — same shape jsc.m and txiki.c
use. The walker matched the existing engines' algorithm exactly but ran
**slower** on the medium payload (169 µs vs 60 µs string path) because
libjs's reflection API (`js_get_named_property`, `js_typeof`,
`js_get_value_*`) has per-call overhead that jsc.m's direct JSC selectors
avoid. The legacy "JSON.stringify on JS side, read string in C" path is
the right shape for bare's libjs ABI cost profile.

Decision: revert the tree-walker port. Document the libjs reflection cost
as a finding, leave the optimization for if/when libjs gains a faster
walk API. **Closes task #147 and #149.**

## Methodology

- Dev machine: macOS 26, Apple Silicon M-series.
- App: `benchmarks/apps/zapp-host-bridge` (single window, three headless
  bench workers, no other workload).
- Each run: kill any prior instance, launch app, wait 8s for the suite to
  finish, INT-terminate.
- 5 runs aggregated by the included `run.sh`.

## Run it yourself

```bash
cd benchmarks/apps/zapp-host-bridge
bun install
bun run package
./run.sh 5
```

Numbers print to stdout; raw data lands in `/tmp/host-bridge-bench/results.csv`.

## Caveats

1. **Run-to-run variance** is significant on the medium-payload runs (40–128
   µs range on bare). JSC's tiered JIT (LLInt → Baseline → DFG → FTL) takes
   a few iterations to fully tier up; the 200-iter warmup catches tier-up
   for 1,000-iter benches but a long-running production worker would see
   more consistent numbers.
2. **bare-quickjs / bare-v8 not yet measured.** First build of each adds
   ~60s of cmake; will add as separate runs when their numbers are needed.
3. **Memory footprint not measured.** V8's resident-set is the long pole
   on Linux/Windows and isn't visible here.
4. **Only the worker → service path measured.** WebView → service via the
   IPC bus uses a different mechanism (`Services.invoke` async). The
   existing `benchmarks/bridge-bench.js` measures that path.
