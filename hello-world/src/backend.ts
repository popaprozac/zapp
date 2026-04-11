// Backend worker — runs before any window, no DOM, no WebView.
// Uses the same @zappdev/runtime API but with host object transport.

import { App, AppEvent, Events, Notification, Window, WindowEvent } from "@zappdev/runtime";

// Backend-owned state, broadcast to every open window every 2s.
// Demonstrates the canonical pattern: backend holds authoritative state,
// pushes deltas to all webviews, no per-window polling needed.
let counter = 0;
setInterval(() => {
  counter++;
  Events.emit("counter:tick", { value: counter, ts: Date.now() });
}, 2000);

App.on(AppEvent.STARTED, () => {
  console.log("[backend] app started");
});

App.on(AppEvent.REOPEN, (data) => {
  console.log("[backend] app reopened:", JSON.stringify(data));
});

App.on(AppEvent.OPEN_URL, (data) => {
  console.log("[backend] deep link:", JSON.stringify(data));
});

App.on(AppEvent.DID_BECOME_ACTIVE, () => {
  console.log("[backend] app became active");
});

App.on(AppEvent.DID_RESIGN_ACTIVE, () => {
  console.log("[backend] app became inactive");
});

Notification.on("click", (id) => {
  console.log("[backend] notification clicked:", id);
});

// Listen to window events from backend (all windows)
Events.on("window:move", (p) => {
  console.log("[backend] window moved:", JSON.stringify(p));
});

Events.on("window:resize", (p) => {
  console.log("[backend] window resized:", JSON.stringify(p));
});

console.log("[backend] initialized");