// Host-bridge benchmark worker — measures the per-call cost of the
// host-bridge surface user code actually pays for:
//
//   1. invokeService(method, args) — worker → service → worker round-trip
//   2. Events.emit(name, payload)  — worker → all-webview broadcast (one-way)
//   3. Workers.send(target, ch, d) — worker → worker direct (one-way)
//
// Multiple copies of this worker can run side-by-side, one per engine
// (configured in zapp.config.ts as `bench-bare-jsc`, `bench-zjs`, etc.).
// They self-trigger on startup with a 1.5s grace
// period so the app finishes its own bootstrap before the timing loop
// starts. Results are logged to stderr in CSV-friendly format so the
// CLI dev console captures them.
//
// To skip the bench (after you've collected numbers), comment out the
// three `bench-*` entries in zapp.config.ts. The `noop` service in
// hello-world/zapp/app.zc can stay — it's tiny.

import { Events, Workers } from "@zappdev/runtime";
import "@zappdev/runtime/worker-globals";

const bridge: any = (globalThis as any).__zappBridge ?? {};
const workerId: string = bridge.workerId ?? "?";
const engineLabel = workerId.replace(/^h-bench-/, "") || workerId;

function now(): number {
  // bare workers DO have performance.now via the standard worker
  // bootstrap (which polyfills it from process.hrtime). Fall back
  // to Date.now if anything is missing.
  return typeof performance !== "undefined" && performance.now
    ? performance.now()
    : Date.now();
}

interface BenchResult {
  label: string;
  iters: number;
  totalMs: number;
  opsPerSec: number;
  usPerOp: number;
}

function fmt(r: BenchResult): string {
  return `[bench:${engineLabel}] ${r.label} x${r.iters}: ` +
    `${r.totalMs.toFixed(2)}ms total, ` +
    `${r.opsPerSec.toFixed(0)} ops/sec, ` +
    `${r.usPerOp.toFixed(2)} µs/op`;
}

// invokeService — pure round-trip worker → service → worker. The
// `noop` service returns a constant JSON, so this is dominated by:
//   - JSON.stringify args on JS-side wrapper
//   - host fn string read + native dispatch_sync into the service
//   - service handler (returns thread-local buf)
//   - JSON.parse result on JS-side wrapper
function bench_invoke(iters: number): BenchResult {
  // Warmup — gives the JIT time to tier up the host fn callsite +
  // the JSON.stringify/parse pair. Without warmup the first ~100
  // calls dominate the total on JIT engines.
  for (let i = 0; i < 200; i++) bridge.invokeService("noop", { i });

  const start = now();
  for (let i = 0; i < iters; i++) bridge.invokeService("noop", { i });
  const totalMs = now() - start;
  return {
    label: "invokeService(noop)",
    iters,
    totalMs,
    opsPerSec: (iters * 1000) / totalMs,
    usPerOp: (totalMs * 1000) / iters,
  };
}

// Events.emit — fire-and-forget broadcast. Doesn't measure receiver
// work; just the cost of bridge.dispatchEventToAll round trip from
// JS through the host into native event dispatch + return. We use a
// '__bench:tick' name so listening webviews can be silent observers
// without polluting their event handlers.
function bench_emit(iters: number): BenchResult {
  for (let i = 0; i < 200; i++) Events.emit("__bench:warmup", { i });

  const start = now();
  for (let i = 0; i < iters; i++) Events.emit("__bench:tick", { i, t: now() });
  const totalMs = now() - start;
  return {
    label: "Events.emit",
    iters,
    totalMs,
    opsPerSec: (iters * 1000) / totalMs,
    usPerOp: (totalMs * 1000) / iters,
  };
}

// Workers.send — direct point-to-point worker → worker. We send to
// `h-ticker` because that worker exists across all configurations
// (same hello-world, same engine line-up). The receiver doesn't reply
// for this measurement — we're measuring sender cost only.
function bench_send(iters: number): BenchResult {
  for (let i = 0; i < 50; i++) Workers.send("h-ticker", "__bench:warmup", { i });

  const start = now();
  for (let i = 0; i < iters; i++) Workers.send("h-ticker", "__bench:tick", { i });
  const totalMs = now() - start;
  return {
    label: "Workers.send",
    iters,
    totalMs,
    opsPerSec: (iters * 1000) / totalMs,
    usPerOp: (totalMs * 1000) / iters,
  };
}

console.log(`[bench:${engineLabel}] worker booted, scheduling suite in 1500ms`);

setTimeout(() => {
  console.log(`[bench:${engineLabel}] === starting suite ===`);
  try {
    console.log(fmt(bench_invoke(10_000)));
    console.log(fmt(bench_emit(10_000)));
    console.log(fmt(bench_send(10_000)));
    console.log(`[bench:${engineLabel}] === done ===`);
  } catch (e: any) {
    console.error(`[bench:${engineLabel}] suite threw: ${e?.message ?? e}`);
  }
}, 1500);
