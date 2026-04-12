// Example worker — runs in a JSC/txiki.js context with host object access.

import { Services } from "@zappdev/runtime";
import { Surreal } from "surrealdb";
import "@zappdev/runtime/worker-globals";

console.log("[worker] started");

const db = new Surreal();

// Open a connection and authenticate
await db.connect("wss://mystic-ocean-06eev24ec5o75cqi0ecpgm5vr4.aws-euw1.surreal.cloud", {
	namespace: "okapi",
	database: "stats-dev",
});

console.log("[worker] surreal connected ", db.status);

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
