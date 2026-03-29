// Backend worker — runs before any window, no DOM, no WebView.
// Uses the same @zappdev/runtime API but with host object transport.

import { App, AppEvent, Notification } from "@zappdev/runtime";

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

console.log("[backend] initialized");
