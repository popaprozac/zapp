# Zapp host-bridge bench — results

Measures the per-call cost of `__zappBridge.invokeService(method, args)` from
worker code, side by side across three engines compiled into the bench binary:
**zjs** (Zapp's first-party engine), **jsc** (system JavaScriptCore via the
legacy `jsc.m` bridge), and **txiki** (QuickJS-NG via `txiki.c`).

Three identical workers, same TS source, run their suite at app startup. The
binary is signed adhoc with `com.apple.security.cs.allow-jit` so JSC actually
JITs the hot path (without it, JSC's tier-up doesn't run and the comparison
becomes interpreter-vs-interpreter).

## Headline numbers

7-run cold-launch median µs/op (range across runs):

| Engine | invokeService.small | invokeService.medium |
|---|---:|---:|
| **zjs** | **0.45** (0.42–0.56) | **55.70** (55.02–58.79) |
| jsc (legacy `.m`) | 1.08 (1.07–1.13) | 128.03 (125.07–130.20) |
| txiki (QuickJS) | **0.26** (0.25–0.36) | **41.45** (40.20–42.74) |

Workloads:
- **`.small`**: `{ i: 1 }` — single primitive property, ~12-byte JSON.
- **`.medium`**: `{ items: [50 × { id, name, tags, value }], meta: {...} }` — ~3 KB JSON, ~250 nodes.
- 10,000 iters for small, 1,000 for medium, 200-iter warmup, JIT primed.

## Reading the numbers

**zjs vs JSC** (the comparison new users care about most):
- **Small payload: 2.4× faster** than system JSC (0.45 µs vs 1.08 µs). zjs's
  direct value-marshalling host bridge skips a JS-side `JSON.stringify` hop.
- **Medium payload: 2.3× faster** than system JSC (55.7 µs vs 128 µs). Same
  reason, magnified — the `ZjsValue → JsonValue` tree walker visits each
  node once instead of paying for JSC's `[payload toObject]` (NSObject
  bridging) + `NSJSONSerialization`.

**zjs vs txiki (QuickJS interpreter)**:
- txiki wins on both: 0.26 µs vs 0.45 µs on small, 41 µs vs 56 µs on medium.
- txiki has the same zero-JSON design plus a more mature inline-cache layer
  in QuickJS-NG. zjs is the newer engine with smaller cost-per-FFI-crossing
  headroom; closing this gap is iterative work in the engine itself, not
  the bridge.
- For most Zapp workloads (~100s of services calls/sec, not 10K+), both are
  comfortably under the latency floor that matters.

**The takeaway for engine choice**: pick zjs as the default for new projects.
First-party, cross-platform, JIT-free (so iOS App Store eligible),
~2× faster than legacy `jsc.m` on every host-call workload measured here.
Pick txiki only when peak FFI throughput matters AND you don't need any of
zjs's first-party advantages (cross-platform consistency, bytecode AOT,
direct value marshalling).

## What landed during this measurement

Three zjs engine bugs were caught and fixed upstream during the bench:

1. **For-loop scope leak** (zjs `5dc4d19`) — `for (let e = 0; e < ...)`
   inside a function with `e` as a parameter leaked the loop's `let`
   binding into the outer scope, so `bench.label` ended up holding the
   loop's terminal iter count instead of the label string. Surfaced as
   the bench label showing `10000` instead of `"invokeService.small"`.
2. **Walker GC root** (zjs `5994be2`) — `ZjsValue`s held only on the C
   stack across recursive `zjs_call(Object.keys, ...)` traversals could
   be reclaimed mid-walk. Fixed by the new `zjs_pin` / `zjs_unpin` ABI
   plus updating the Zapp walker to pin `keys` (and `v`) for the
   iteration. Same commit also fixed a latent `zjs_call` issue where its
   return value was unrooted across the internal `drain_microtasks`.
3. **Atom-table invariant** (zjs `5a30e7b`) — `zjs_set_property` keys
   were interned as plain (non-atom) strings, but the hidden-class GC
   marker assumes `transition_name` is always an atom (pinned via the
   atom-table root walk). After enough major GCs, the bridge object's
   transition names were swept, the hidden class lost its slot map,
   and `bridge.invokeService` started reading `undefined` ("property
   is not a function"). Fixed by routing both `zjs_set_property` and
   `zjs_get_property` keys through `ctx_intern_atom`. This was the
   long-tail bug — only surfaced after ~10K host calls had built up
   enough alloc pressure to trigger a major GC at the right moment.

Each bug was caught with a small targeted upstream trace patch
(`ZJS_TRACE_UNWIND` env var, `Op::Return at entry-frame` tracing,
thrown-value tag + message dump) and fixed without any Zapp-side
workaround.

## What's not in this table yet

- **bare-jsc / bare-quickjs**: clang's command-line argument buffer
  overflows when txiki + bare-* + bare-jsc + zjs are all in the link
  line at once — the trailing libz.a path gets truncated mid-string and
  the linker fails to find it. Trimmed the bench to zjs + jsc + txiki
  for this run. Adding bare-* back is a separate fix (likely a
  consolidation pass on `cli/src/build-config.ts`'s `allLinkLibs`
  accumulator to use shorter relative paths or `-l<name>` form where
  possible). Tracked separately.
- **emit.\* benches**: disabled. Each `Events.emit(...)` broadcasts an
  IIFE into every other worker's eval inbox via `dispatch_event_to_all`;
  three workers running `emit.small` × 10K each saturates the consumer
  inbox before any producing worker can finish. Needs a different bench
  shape — either run one engine at a time, or scope dispatch to webview-
  only when measuring synthetic events. Tracked separately.
- **bare-v8 / bare-hermes**: not built for this run. First build of each
  adds ~60s of cmake; will add as separate runs when their numbers are
  needed.

## Methodology

- Dev machine: macOS 26, Apple Silicon M-series.
- App: `benchmarks/apps/zapp-host-bridge` (single window, three headless
  bench workers, no other workload).
- Each run: kill any prior instance, launch app, wait 8s for the suite
  to finish, INT-terminate.
- 7 runs aggregated by the included `run.sh`.

## Run it yourself

```bash
cd benchmarks/apps/zapp-host-bridge
bun install
bun run package
./run.sh 7
```

Numbers print to stdout; raw data lands in `/tmp/host-bridge-bench/results.csv`.

## Caveats

1. **Run-to-run variance** is modest now that all engines complete cleanly
   — zjs's medium ranges 55.0–58.8 µs (5% spread), jsc 125–130 µs (4%),
   txiki 40–43 µs (6%). JSC's tiered JIT (LLInt → Baseline → DFG → FTL)
   takes a few iterations to fully tier up; the 200-iter warmup catches
   tier-up for 1,000-iter benches.
2. **Memory footprint not measured.** zjs's resident-set is smallest
   (~1 MB), txiki's is similar, JSC's varies with JIT tier-up. Tracked
   separately in `benchmarks/binary-size-matrix.md`.
3. **Only the worker → service path measured.** WebView → service via
   the IPC bus uses a different mechanism (`Services.invoke` async).
   The existing `benchmarks/bridge-bench.js` measures that path.
4. **Single-context bench.** Real Zapp apps run multiple workers
   concurrently. The bench's three workers run in parallel here too, but
   they share the same JSON workload pattern; perf under mixed workloads
   (one worker doing heavy compute, another emitting events) could
   diverge from these numbers.
