export default {
  name: "hello-world",
  identifier: "com.zapp.helloworld",
  version: "0.1.0",
  deepLinkSchemes: ["helloworld"],
  singleInstance: true,
  // No icon configured — will use framework default (assets/zapp.icon)
  headless: {
    // Supervisor demo — throws on `force-crash` event. Restart policy
    // allows 2 retries inside 30s, then gives up. The UI listens for
    // worker:crashed / worker:restarted / worker:gave-up events.
    supervised: {
      script: "src/workers/supervised.ts",
      restart: { maxRetries: 2, withinMs: 30_000 },
    },
    // Ticker — emits counter:tick every 2s. Drives the "Backend
    // State" section in the main UI; demonstrates the canonical
    // single-source-of-truth state-push-to-all-windows pattern.
    ticker: "src/workers/ticker.ts",
  },
};
