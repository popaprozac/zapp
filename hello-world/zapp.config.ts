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
  // **Engine soak (alpha 67):** every headless worker is now pinned to
  // bare-jsc to exercise the new engine across the full host-bridge
  // surface (Services.invokeSync, syncWait/syncNotify, send/receive,
  // dispatchEventToAll, supervisor crash reporting). The legacy `jsc`
  // and `txiki` engines are still compiled in via build.zc, so we can
  // flip individual workers back if a regression surfaces.
  //
  // Caveat: bare worker restart-on-crash is not yet wired (same gap
  // as txiki). On force-crash the supervised worker will currently
  // emit `worker:crashed` + record the failure, but won't restart.
  // Tracked under project_txiki_worker_restart memory.
  // Declarative worker capabilities. The CLI verifies each entry's
  // underlying npm package is installed, and the Vite plugin auto-
  // prepends `import "@zappdev/runtime/worker-globals/<sub>"` to
  // every bundled worker entry so the corresponding globals
  // (fetch, WebSocket, etc.) "just work" without per-worker boilerplate.
  workerModules: ["fetch"],
  headless: {
    supervised: {
      script: "src/workers/supervised.ts",
      restart: { maxRetries: 2, withinMs: 30_000 },
      engine: "bare-hermes",
    },
    ticker: {
      script: "src/workers/ticker.ts",
      engine: "bare-hermes",
    },

    // Host-bridge benchmark workers — disabled by default. See
    // benchmarks/host-bridge-results.md for results. The proper
    // benchmark vehicle going forward is benchmarks/apps/zapp-host-bridge
    // (tracked under task #148); these hello-world entries were the
    // ad-hoc first-pass measurement.
    //
    // "bench-bare-jsc": { script: "src/workers/bench.ts", engine: "bare-jsc" },
    // "bench-jsc":      { script: "src/workers/bench.ts", engine: "jsc" },
    // "bench-txiki":    { script: "src/workers/bench.ts", engine: "txiki" },
  },
};

export default config;
