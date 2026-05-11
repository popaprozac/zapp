// Zapp host-bridge benchmark — measures per-call cost of the three
// host-bridge surfaces user code actually pays for, side by side
// across every engine compiled in. The headless workers below
// auto-run their bench suite at startup and log results to stderr;
// `run.sh` launches the app, captures the log, and aggregates.
//
// To compare additional engines, edit the `engine:` field on each
// worker AND the corresponding `//> macos: define: ZAPP_WORKER_ENGINE_*`
// in `zapp/build.zc`.
export default {
  name: "bench-host-bridge",
  identifier: "com.zapp.bench.host-bridge",
  version: "0.0.0",
  // Auto-merged via cli/src/entitlements.ts when a JSC-class engine
  // is enabled — explicit here so the bench numbers are honest about
  // running with JIT (without `allow-jit`, JSC falls back to the
  // interpreter and the comparison becomes meaningless).
  macos: {
    entitlements: {
      "com.apple.security.cs.allow-jit": true,
    },
  },
  headless: {
    "bench-jsc":      { script: "src/bench-worker.ts", engine: "jsc" },
    "bench-txiki":    { script: "src/bench-worker.ts", engine: "txiki" },
    "bench-bare-jsc": { script: "src/bench-worker.ts", engine: "bare-jsc" },
    // Add bare-quickjs / bare-v8 entries here when comparing the
    // Win/Linux defaults — first build of each adds ~60s of cmake
    // work, so leave commented when not actively measuring.
    // "bench-bare-quickjs": { script: "src/bench-worker.ts", engine: "bare-quickjs" },
    // "bench-bare-v8":      { script: "src/bench-worker.ts", engine: "bare-v8" },
  },
};
