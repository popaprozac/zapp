// Host-bridge benchmark worker — measures the per-call cost of the
// host-bridge surfaces user code actually pays for, across two
// payload sizes:
//
//   - SMALL: { i: <number> } — one primitive property. Dominant
//     cost is libjs / engine FFI overhead. JSON.stringify(SMALL) is
//     ~12 bytes; the libjs walker visits 1 object + 1 number.
//
//   - MEDIUM: { items: [50 × { id, name, tags, value }], meta: {...} }
//     — realistic shape that engineers actually pass to services.
//     JSON.stringify(MEDIUM) is ~3 KB; the walker visits ~250 nodes.
//     This is where the zero-JSON path should beat the legacy
//     stringify-then-parse path on bare-jsc.
//
// Three workers run side-by-side (jsc, txiki, bare-jsc — see
// zapp.config.ts headless map). Each labels its results with the
// engine extracted from `__zappBridge.workerId` and emits via
// Events.emit("bench:result", ...) so the webview can render a
// table; results also log to stderr so `run.sh` can scrape CSV.

import { Events } from "@zappdev/runtime";
// We don't need @zappdev/runtime/worker-globals here — the bench
// only uses Events.emit and __zappBridge.invokeService directly,
// not the WHATWG-shaped globals (fetch, WebSocket, etc.) that the
// worker-globals shim installs.

const bridge: any = (globalThis as any).__zappBridge ?? {};
const workerId: string = bridge.workerId ?? "?";
const engineLabel = workerId.replace(/^h-bench-/, "") || workerId;

function now(): number {
  return typeof performance !== "undefined" && performance.now
    ? performance.now()
    : Date.now();
}

interface BenchResult {
  engine: string;
  label: string;
  iters: number;
  totalMs: number;
  opsPerSec: number;
  usPerOp: number;
}

function run(label: string, iters: number, fn: () => void): BenchResult {
  // 200-iter warmup primes the JIT (JSC tier-up, QuickJS inline
  // cache warm). Without it the first ~10% of timed iters are 5×
  // slower on JIT engines and skew the mean.
  for (let i = 0; i < 200; i++) fn();
  const start = now();
  for (let i = 0; i < iters; i++) fn();
  const totalMs = now() - start;
  return {
    engine: engineLabel,
    label,
    iters,
    totalMs,
    opsPerSec: (iters * 1000) / totalMs,
    usPerOp: (totalMs * 1000) / iters,
  };
}

function emit(r: BenchResult): void {
  // Stderr line in CSV-ish shape — `run.sh` greps the [bench:]
  // prefix and parses the trailing fields.
  console.log(
    `[bench:${r.engine}] ${r.label} x${r.iters}: ` +
    `${r.totalMs.toFixed(2)}ms total, ` +
    `${r.opsPerSec.toFixed(0)} ops/sec, ` +
    `${r.usPerOp.toFixed(2)} us/op`
  );
  Events.emit("bench:result", r);
}

function buildMedium(seed: number): unknown {
  const items = new Array(50);
  for (let i = 0; i < 50; i++) {
    items[i] = {
      id: seed * 50 + i,
      name: `item-${seed}-${i}`,
      tags: ["a", "b", "c"],
      value: (seed + i) * 1.5,
    };
  }
  return { items, meta: { count: 50, seed, name: "bench" } };
}

console.log(`[bench:${engineLabel}] worker booted, scheduling suite in 1500ms`);

setTimeout(() => {
  console.log(`[bench:${engineLabel}] === starting suite ===`);
  try {
    // invokeService.small — single primitive. Measures pure FFI +
    // dispatch overhead.
    emit(run("invokeService.small", 10_000, () => {
      bridge.invokeService("noop", { i: 1 });
    }));

    // invokeService.medium — 50-item array of objects. Highlights
    // argument-walk cost. The engines that ship a zero-JSON walker
    // (zjs, bare-jsc, txiki) pull ahead of the legacy stringify-then-
    // parse path here.
    emit(run("invokeService.medium", 1_000, () => {
      bridge.invokeService("echo", buildMedium(1));
    }));

    // emit.* benches disabled — running 10K Events.emit per engine
    // floods every OTHER worker's broadcast inbox with the same
    // 10K IIFEs (dispatch_event_to_all has no per-worker filtering
    // today), so when 3 workers each run emit.small the system sees
    // ~30K events / sec, saturating the consumer-side inbox before
    // the producing worker can finish its bench. We need a different
    // shape to measure broadcast cost honestly — either run one
    // engine at a time, or scope dispatch to webview-only when the
    // payload is synthetic. Track separately.
    //
    // emit(run("emit.small", 10_000, () => {
    //   Events.emit("__bench:tick", { i: 1 });
    // }));
    //
    // emit(run("emit.medium", 1_000, () => {
    //   Events.emit("__bench:tick", buildMedium(2));
    // }));

    console.log(`[bench:${engineLabel}] === done ===`);
  } catch (e: any) {
    console.error(`[bench:${engineLabel}] suite threw: ${e?.message ?? e}`);
  }
}, 1500);
