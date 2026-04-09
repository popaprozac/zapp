// Example worker — runs in a JSC/txiki.js context with host object access.

import { Services } from "@zappdev/runtime";
import "@zappdev/runtime/worker-globals";

console.log("[worker] started");

// Channel API — typed message routing
receive("ping", (data) => {
  console.log("[worker] received ping:", JSON.stringify(data));
  send("pong", { echo: data, timestamp: Date.now() });
});

// Call native service via host object (sync, nanosecond-level)
receive("invoke-service", (data) => {
  const result = Services.invokeSync("greet", data as any);
  console.log("[worker] service result:", JSON.stringify(result));
  send("service-result", result);
});

console.log("[worker] ready");
