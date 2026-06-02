// Zapp host-bridge benchmark — measures per-call cost of the three
// host-bridge surfaces user code actually pays for, side by side
// across surviving engines. The headless workers below auto-run
// their bench suite at startup and log results to stderr; `run.sh`
// launches the app, captures the log, and aggregates.
//
// Engine selection is the single source of truth here: the CLI
// synthesises the matching `ZAPP_WORKER_ENGINE_*` defines from the
// `engine:` field on each worker. To compare an additional engine,
// add a worker entry below — no build.zc edits needed.
export default {
  name: "bench-host-bridge",
  identifier: "com.zapp.bench.host-bridge",
  version: "0.0.0",
  // Auto-merged via cli/src/entitlements.ts when a JSC-class engine
  // is enabled — explicit here so the bench numbers are honest about
  // running with JIT (without `allow-jit`, bare-jsc falls back to the
  // interpreter and the comparison becomes meaningless).
  macos: {
    entitlements: {
      "com.apple.security.cs.allow-jit": true,
    },
  },
  headless: {
    // zjs — Zapp's first-party engine.
    "bench-zjs":      { script: "src/bench-worker.ts", engine: "zjs" },
    // bare-jsc — system JavaScriptCore on macOS (with allow-jit). JIT-on
    // baseline. Add bare-quickjs / bare-v8 entries here when comparing
    // the Win/Linux defaults — first build of each adds ~60s of cmake
    // work, so leave commented when not actively measuring.
    "bench-bare-jsc": { script: "src/bench-worker.ts", engine: "bare-jsc" },
    // "bench-bare-quickjs": { script: "src/bench-worker.ts", engine: "bare-quickjs" },
    // "bench-bare-v8":      { script: "src/bench-worker.ts", engine: "bare-v8" },
  },
};
