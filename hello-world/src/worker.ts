// Example worker. `workerModules: ["fetch"]` in zapp.config.ts is the
// only setup needed for `fetch` to be on globalThis here — the CLI
// verifies bare-fetch is installed and the Vite plugin auto-prepends
// `import "@zappdev/runtime/worker-globals/fetch"` into this bundle.
// No bare-* packages should be imported by user code.

import { Services } from "@zappdev/runtime";

console.log("[worker] started");

console.log("[worker] fetch typeof:", typeof fetch);

fetch("https://www.google.com").then(res => res.text()).then(text => {
  console.log("[worker] google response:", text);
});

receive("ping", (data) => {
  console.log("[worker] received ping:", JSON.stringify(data));
  send("pong", { echo: data, timestamp: Date.now() });
});

receive("invoke-service", (data) => {
  const result = Services.invokeSync("greet", data as any);
  console.log("[worker] service result:", JSON.stringify(result));
  send("service-result", result);
});

console.log("[worker] ready");
