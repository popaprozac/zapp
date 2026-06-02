// `import type` is erased at compile time — no runtime resolution, but
// your editor gets full IntelliSense on the config:
//   - autocompletion on `engine: "bare-jsc"` etc.
//   - inline docs on every option (hover any field)
//   - type errors on typos / wrong shapes (e.g. `restart: { tries: 3 }`)
import type { ZappConfig } from "@zappdev/cli/config";

const config: ZappConfig = {
  name: "hello-world",
  identifier: "com.zapp.helloworld",
  version: "0.1.0",
  deepLinkSchemes: ["helloworld"],
  // Custom in-webview protocols (G19). The "asset" handler below
  // serves dynamically-generated SVG thumbnails — try it from
  // DevTools: `<img src="asset://thumb-blue">`.
  protocols: ["asset"],
  singleInstance: true,
  // No icon configured — will use framework default (assets/zapp.icon)
  //
  // Every headless worker is pinned to `zjs` — Zapp's first-party
  // engine. The host-bridge surface that the demo exercises is wired:
  // Services.invokeSync (direct in-thread service call, no syncWait
  // round-trip needed), send/receive (worker→worker postMessage),
  // dispatchEventToAll, postToWebview, and workerCrash → supervisor
  // record_failure → `worker:crashed` / `worker:gave-up`, and
  // restart-on-crash works end-to-end across zjs and bare-* engines
  // (the supervisor recreates the JS context within the configured
  // cap, then fires worker:gave-up). Verified Phase 1+2+3 of
  // docs/superpowers/plans/2026-06-01-worker-supervisor-restart.md.
  // Declarative worker capabilities. The CLI verifies each entry's
  // underlying npm package is installed, and the Vite plugin auto-
  // prepends `import "@zappdev/runtime/worker-globals/<sub>"` to
  // every bundled worker entry so the corresponding globals
  // (fetch, WebSocket, etc.) "just work" without per-worker boilerplate.
  workerModules: ["fetch"],
  // Smoke-test the new webviewPreferences plumbing — autoplay flipped on
  // exercises the WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback
  // path. The other three fields stay at platform default (unset).
  webviewPreferences: {
    autoplayWithoutUserGesture: true,
  },
  headless: {
    // Cross-engine smoke matrix (manual verification — click force-crash 4 times):
    //   zjs (macOS)      → crashed×4, restarted×2, gave-up×2
    //   zjs (iOS Sim)    → same sequence (pending human verification — kqueue + CFRunLoop path)
    //   bare-jsc (macOS) → same sequence
    //   bare-v8          → same sequence (Win/Linux JIT)
    // Verified Phase 4 / Task 4.1 of the supervisor-restart plan.
    supervised: {
      script: "src/workers/supervised.ts",
      name: "sync-engine",
      restart: { maxRetries: 2, withinMs: 30_000 },
      engine: "zjs",
    },
    ticker: {
      script: "src/workers/ticker.ts",
      engine: "zjs",
      bytecode: true,
    },

    // Verification-only — re-enable to exercise broken-from-start supervisor flow.
    // After 3 immediate top-level throws (maxRetries: 2), supervisor fires
    // worker:gave-up; no infinite restart loop.
    // broken: {
    //   script: "src/workers/broken-from-start.ts",
    //   engine: "zjs",
    //   restart: { maxRetries: 2, withinMs: 30_000 },
    // },

    // Host-bridge benchmark workers — disabled by default. See
    // benchmarks/host-bridge-results.md for results. The proper
    // benchmark vehicle going forward is benchmarks/apps/zapp-host-bridge
    // (tracked under task #148); these hello-world entries were the
    // ad-hoc first-pass measurement.
    //
    // "bench-bare-jsc": { script: "src/workers/bench.ts", engine: "bare-jsc" },
    // "bench-zjs":      { script: "src/workers/bench.ts", engine: "zjs" },
  },
};

export default config;
