# Zapp host-bridge benchmarks (rev 2)

Measures the per-call cost of the three host-bridge surfaces user code
actually pays for — `invokeService(method, args)`, `Events.emit(name, payload)`,
and `Workers.send(target, channel, data)` — across all three engines that
hello-world links today.

Methodology: three identical bench workers (one per engine), same script
(`hello-world/src/workers/bench.ts`), 10,000 iterations of each operation
after a 200-iteration warmup. Median of 5 cold-launch runs. macOS arm64
M-series, app signed adhoc with `com.apple.security.cs.allow-jit`.

## Results (median µs/op, range across 5 runs)

| Engine | `invokeService` | `Events.emit` | `Workers.send` |
|---|---:|---:|---:|
| **txiki** (QuickJS) | **0.36** (0.28–0.78) | 4.38 (3.10–5.69) | 1.27 (1.10–3.22) |
| **bare-jsc** | 1.00 (0.80–1.90) | 3.70 (2.30–5.80) | **0.90** (0.70–1.50) |
| **jsc** (legacy `.m`) | 1.20 (1.08–1.32) | **3.04** (2.95–3.46) | 2.42 (2.30–2.55) |

In ops/sec terms:

| Engine | `invokeService` | `Events.emit` | `Workers.send` |
|---|---:|---:|---:|
| txiki    | **2.8M** ops/s | 228K ops/s | 787K ops/s |
| bare-jsc | 1.0M ops/s | 270K ops/s | **1.1M** ops/s |
| jsc      | 833K ops/s | **329K** ops/s | 413K ops/s |

## Reading the numbers

**invokeService — txiki wins by ~3×.** Both `jsc.m` and `txiki.c` use the
**zero-JSON tree walk** path (`jscvalue_to_jsonvalue` / `jsvalue_to_jsonvalue`
→ `service_invoke_native(JsonValue*)`) — args go directly from JS values to a
JsonValue tree without round-tripping through string land. Bare currently uses
the **legacy string path** (`JSON.stringify` → host fn reads string →
`service_invoke_sync(const char*)` → returns string → `JSON.parse`), eating
two passes through string land. txiki additionally benefits from QuickJS's
cheaper FFI (no JSC bridge wrappers around every host call).

The fix: write a `js_value_to_jsonvalue(env, val) -> JsonValue*` walker on top
of the libjs ABI's `js_get_named_property` / `js_get_value_*` and route bare's
`invokeService` through `service_invoke_native`. Estimated ~50 LoC; would
likely pull bare-jsc into the 0.4–0.5 µs range, matching txiki. Tracked as a
follow-up.

**Workers.send — bare-jsc wins.** `bare_worker_post_message` is `msg_queue_push
+ uv_async_send` — a single mutex acquire + a libuv async wakeup. `jsc.m`
uses GCD `dispatch_async` to a serial queue, which has more setup per-call.
`txiki.c` is somewhere in the middle. This is the only operation where bare's
threading model is faster than the legacy alternatives.

**Events.emit — tied within noise.** All three engines hit the same native
fan-out path (`dispatch_event_to_all` → walks every webview + every worker
engine's broadcast helper). Differences come from how each engine stringifies
the payload: bare uses JS-side `JSON.stringify`, jsc.m uses
`NSJSONSerialization`, txiki uses QuickJS's built-in `JSON.stringify`. Native
fan-out cost dominates per-call.

## Real-world interpretation

In absolute terms **every engine is fast enough**:
- 1 µs/op on bare = **1 million round-trips per second**.
- 0.36 µs/op on txiki = 2.8M.
- A typical Zapp app makes well under 100 bridge calls/sec, so even the
  slowest of these is 10,000× faster than required.

Engine choice should be driven by:
- **Binary size** (bare-jsc adds ~730 KB on Apple, bare-v8 adds 60 MB elsewhere)
- **API surface** (Bare's npm-shaped module ecosystem vs txiki's WHATWG-native)
- **Memory footprint** (V8 ~30-50 MB resident, JSC ~5 MB, QuickJS ~1 MB)

Not by per-call host-bridge latency — it's not a bottleneck for any
realistic workload.

## Variance notes

The 0.28–0.78 µs range on txiki and 0.80–1.90 range on bare-jsc reflects
**JIT warmup**. The 200-iteration warmup catches QuickJS's interpreter→JIT
tier-up but not always JSC's full LLInt → Baseline → DFG → FTL ladder.
Longer warmup loops would tighten the bare-jsc range; we kept warmup short
because realistic worker code doesn't sit in tight bridge-call loops.

The Date.now-based timer in older bare-timers builds caps precision at
~0.5ms — for 10,000 iters that's ~0.05 µs/op resolution, still adequate.

## Run it yourself

```bash
cd hello-world
bun run dev 2>&1 | tee /tmp/bench.log
# Wait ~3 seconds after the window opens, then ^C
grep "\[bench:" /tmp/bench.log
```

The bench workers are configured in `zapp.config.ts` (three `bench-*`
entries). To stop running them, comment out those entries — the `noop`
service in `zapp/app.zc` can stay.

## Follow-ups

1. **Port bare to `service_invoke_native`** — write `js_value_to_jsonvalue`
   on the libjs ABI, reroute `bare_host_invoke_service`. Expected ~3× speedup
   on `invokeService`, matching txiki.
2. **Worker spawn time** — not measured here. End-to-end from `bare_setup` to
   first user-script line is the more critical "is the engine fast enough"
   number for short-lived workers.
3. **Memory per worker** — also not measured. V8's resident-set is the long
   pole on non-Apple platforms.
4. **Sync wait/notify latency** — the `darwin_sync_handle` round trip
   includes a main-queue dispatch on the result side. Worth a dedicated
   bench when picking up the sync subsystem.
