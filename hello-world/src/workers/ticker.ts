// Ticker headless worker — broadcasts counter:tick to every webview
// every 2s. Demonstrates the canonical "single source of truth pushes
// state to all windows" pattern without per-window polling.
//
// Originally this lived in `src/backend.ts` as a privileged backend
// entry point, but the `--backend` flag is stale (see
// `project_backend_stale.md`). A headless worker is the supported
// way to do app-wide background work today.

import { Events, Workers } from "@zappdev/runtime";
// `workerModules` in zapp.config.ts (now ["fetch"]) drives the
// install — no manual side-effect import needed here.

let counter = 0;
setInterval(() => {
  counter++;
  Events.emit("counter:tick", { value: counter, ts: Date.now() });
}, 2000);

// Pipeline-style channel — receive a "ping" via Workers.send from any
// context (webview or another worker), reply by re-sending on a
// "pong" channel. Demonstrates the worker→worker pipe (the supervised
// worker can address us as "h-ticker", same as a webview).
receive("ping", (data: any) => {
  console.log("received ping:", JSON.stringify(data));
  // Reply: echo back to the supervised worker if that's who sent it,
  // otherwise broadcast via Events for the webview test path.
  if (data?.replyTo) {
    Workers.send(data.replyTo, "pong", { from: "h-ticker", ts: Date.now() });
  } else {
    Events.emit("ticker:pong", { from: "h-ticker", ts: Date.now() });
  }
});

console.log("started");
