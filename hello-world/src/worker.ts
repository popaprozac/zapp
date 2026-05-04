// Example worker — runs in a JSC/txiki.js context with host object access.
//
// Kept intentionally light so it works on every supported engine:
//   - macOS JSC (no fetch/WebSocket/Streams)
//   - macOS txiki (full web APIs)
//   - iOS JSC (JIT-less; no fetch/WebSocket either)
//
// Real apps reach for Surreal / fetch / WebSocket via txiki on macOS.
// On iOS, until txiki cross-build lands (Phase 2), workers are JSC-only
// — see project_ios_path.md gotcha #2 for context.

import { Services } from "@zappdev/runtime";
import "@zappdev/runtime/worker-globals";

console.log("[worker] started");

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
