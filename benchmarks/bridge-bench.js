/**
 * Cross-framework bridge benchmark — paste into devtools.
 *
 * Each benchmark app exposes a single hook:
 *
 *     window.__bench.ping() -> Promise<{ pong: number }>
 *
 * Under the hood that calls each framework's idiomatic IPC — Services.invoke
 * for Zapp, `invoke()` for Tauri, PingService.Ping() for Wails,
 * ipcRenderer.invoke for Electron, defineRPC.request.ping for Electrobun —
 * but this script doesn't care which. It measures whatever round-trip
 * latency the framework ships by default.
 *
 *
 * Why batched timing?
 * -------------------
 * `performance.now()` in release webviews is clamped to coarse granularity
 * as a Spectre mitigation: WebKit rounds to 1 ms, Chromium to 0.1 ms.
 * Timing an individual IPC call that takes ~50 µs just returns 0 or 1000 µs,
 * so per-call percentiles are meaningless in a packaged build.
 *
 * We work around this by timing *batches*: each batch runs BATCH_SIZE
 * sequential ping calls inside a single start/end measurement. With
 * BATCH_SIZE=200, a batch takes tens of milliseconds — safely above the
 * clamp — and we get BATCHES independent samples of "average round-trip".
 * From those we report min / mean / max / stdev across batches, which is
 * honest and reproducible on release builds.
 *
 *
 * Usage:
 *   1. Build the app in release and launch it.
 *   2. Right-click inside the window and pick "Inspect Element" to open
 *      the devtools (Wails and Electrobun auto-open devtools in the
 *      bench build because their context menus don't include Inspect).
 *   3. Paste the contents of this file into the console and press enter.
 *   4. Wait ~1-2 seconds. Results print to the same console.
 */

(async () => {
  const WARMUP = 500;
  const BATCHES = 30;
  const BATCH_SIZE = 200;
  const TOTAL = BATCHES * BATCH_SIZE;

  if (!globalThis.__bench || typeof globalThis.__bench.ping !== "function") {
    console.error(
      "[bridge-bench] window.__bench.ping is missing. " +
        "Make sure you're inspecting the benchmark app's main window " +
        "(not a helper/devtools process) and that the app was built " +
        "with the benchmark hook wired up."
    );
    return;
  }

  const summarize = (label, perCallUs) => {
    const sorted = perCallUs.slice().sort((a, b) => a - b);
    const min = sorted[0];
    const max = sorted[sorted.length - 1];
    const median = sorted[Math.floor(sorted.length * 0.5)];
    const mean = sorted.reduce((s, x) => s + x, 0) / sorted.length;
    const variance =
      sorted.reduce((s, x) => s + (x - mean) * (x - mean), 0) / sorted.length;
    const stdev = Math.sqrt(variance);
    const record = {
      label,
      total_calls: perCallUs.length * BATCH_SIZE,
      batches: perCallUs.length,
      batch_size: BATCH_SIZE,
      warmup: WARMUP,
      min_us: +min.toFixed(1),
      median_us: +median.toFixed(1),
      mean_us: +mean.toFixed(1),
      max_us: +max.toFixed(1),
      stdev_us: +stdev.toFixed(1),
      throughput_per_sec: Math.round(1_000_000 / mean),
    };
    const fmt = (x) => x.toFixed(1) + " µs";
    console.log(`=== ${label} ===`);
    console.log(
      `total:      ${record.total_calls} calls (${record.batches} batches × ${BATCH_SIZE}, ${WARMUP} warmup)`
    );
    console.log(`min:        ${fmt(min)} (fastest batch avg)`);
    console.log(`median:     ${fmt(median)} (batch median)`);
    console.log(`mean:       ${fmt(mean)} (overall avg)`);
    console.log(`max:        ${fmt(max)} (slowest batch avg)`);
    console.log(`stdev:      ${fmt(stdev)} (across batches)`);
    console.log(`throughput: ${record.throughput_per_sec} calls/sec (at mean)`);
    console.log("json:", JSON.stringify(record));
    return record;
  };

  // --- Webview → native (IPC) ---
  const ping = globalThis.__bench.ping;

  for (let i = 0; i < WARMUP; i++) {
    try {
      await ping();
    } catch (e) {
      console.error("[bridge-bench] warmup call failed:", e);
      return;
    }
  }

  const webviewPerCallUs = new Array(BATCHES);
  for (let b = 0; b < BATCHES; b++) {
    const t0 = performance.now();
    for (let i = 0; i < BATCH_SIZE; i++) {
      await ping();
    }
    const t1 = performance.now();
    webviewPerCallUs[b] = ((t1 - t0) * 1000) / BATCH_SIZE;
  }

  summarize("webview → native", webviewPerCallUs);

  // --- Worker → native (direct host call, no IPC) ---
  // Only measured for frameworks that expose the worker bench hook. The
  // worker spawns fresh each run, so warmup and timing happen on the
  // worker thread's own performance.now().
  if (typeof globalThis.__bench.workerBench === "function") {
    try {
      const workerPerCallUs = await globalThis.__bench.workerBench({
        batches: BATCHES,
        batchSize: BATCH_SIZE,
        warmup: WARMUP,
      });
      summarize("worker  → native", workerPerCallUs);
    } catch (e) {
      console.error("[bridge-bench] worker bench failed:", e);
    }
  } else {
    console.log(
      "[bridge-bench] worker → native: skipped (no __bench.workerBench hook on this framework)"
    );
  }
})();
