export default {
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
  headless: {
    // Supervisor demo — throws on `force-crash` event. Restart policy
    // allows 2 retries inside 30s, then gives up. The UI listens for
    // worker:crashed / worker:restarted / worker:gave-up events.
    // Pinned to JSC: full restart support is JSC-only today (txiki
    // restart needs pthread teardown + respawn — separate alpha).
    supervised: {
      script: "src/workers/supervised.ts",
      restart: { maxRetries: 2, withinMs: 30_000 },
      engine: "jsc",
    },
    // Ticker — emits counter:tick every 2s. Drives the cross-context
    // state section in the main UI. Pinned to txiki to demonstrate
    // mixing engines in the same app (G8): supervised runs on JSC,
    // ticker runs on txiki — both work side-by-side.
    ticker: {
      script: "src/workers/ticker.ts",
      engine: "txiki",
    },
  },
};
