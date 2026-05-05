// Ticker headless worker — broadcasts counter:tick to every webview
// every 2s. Demonstrates the canonical "single source of truth pushes
// state to all windows" pattern without per-window polling.
//
// Originally this lived in `src/backend.ts` as a privileged backend
// entry point, but the `--backend` flag is stale (see
// `project_backend_stale.md`). A headless worker is the supported
// way to do app-wide background work today.

import { Events } from "@zappdev/runtime";
import "@zappdev/runtime/worker-globals";

let counter = 0;
setInterval(() => {
  counter++;
  Events.emit("counter:tick", { value: counter, ts: Date.now() });
}, 2000);

console.log("[ticker] started");
