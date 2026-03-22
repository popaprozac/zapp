/**
 * Zapp Bridge Performance Benchmark
 *
 * Paste this into the webview dev tools console while the app is running.
 * The Zapp runtime is already loaded — we access it via __zapp global.
 *
 * Measures:
 *   1. Service invoke round-trip (JS → Native → JS)
 *   2. Event emit throughput (fire-and-forget)
 */

(async () => {
  const zapp = (globalThis as any).__zapp;
  if (!zapp?.invoke) {
    console.error("Zapp runtime not found. Run this in a Zapp webview.");
    return;
  }

  const WARMUP = 50;
  const ITERATIONS = 1000;

  console.log("=== Zapp Bridge Performance ===\n");

  // --- 1. Service invoke round-trip ---
  console.log(`Service invoke round-trip (${ITERATIONS} calls):`);

  // Warmup
  for (let i = 0; i < WARMUP; i++) {
    try { await zapp.invoke("ping", { n: i }); } catch { break; }
  }

  const t0 = performance.now();
  let successCount = 0;
  for (let i = 0; i < ITERATIONS; i++) {
    try {
      await zapp.invoke("ping", { n: i });
      successCount++;
    } catch {
      break;
    }
  }
  const t1 = performance.now();

  if (successCount === 0) {
    console.log("  No 'ping' service registered. Register one to measure invoke latency.");
    console.log('  Example: app.service.add("ping", ping_service)');
  } else {
    const total = t1 - t0;
    const perCall = total / successCount;
    console.log(`  Calls:      ${successCount}`);
    console.log(`  Total:      ${total.toFixed(1)} ms`);
    console.log(`  Per call:   ${perCall.toFixed(3)} ms`);
    console.log(`  Throughput: ${(1000 / perCall).toFixed(0)} calls/sec`);
  }
  console.log("");

  // --- 2. Event emit (fire-and-forget) ---
  console.log(`Event emit throughput (${ITERATIONS} calls):`);
  const t2 = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    zapp.emit("bench:noop", { n: i });
  }
  const t3 = performance.now();
  const emitTotal = t3 - t2;
  const emitPer = emitTotal / ITERATIONS;
  console.log(`  Total:      ${emitTotal.toFixed(1)} ms`);
  console.log(`  Per call:   ${emitPer.toFixed(3)} ms`);
  console.log(`  Throughput: ${(1000 / emitPer).toFixed(0)} calls/sec`);
  console.log("");

  // --- Summary ---
  console.log("=== Reference (other frameworks) ===");
  console.log("  Electron ipcRenderer.invoke:  ~0.1–0.5 ms/call");
  console.log("  Tauri invoke command:         ~0.05–0.2 ms/call");
  console.log("  Wails binding call:           ~0.1–0.3 ms/call");
  console.log("  Electrobun RPC:               ~0.05–0.1 ms/call");
})();
