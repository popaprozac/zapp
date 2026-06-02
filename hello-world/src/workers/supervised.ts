// Supervisor demo worker.
//
// This headless worker is configured in zapp.config.ts with a restart
// policy of 2 retries inside 30s. The UI emits a `force-crash` event;
// this worker schedules a deferred throw via setTimeout so the
// exception escapes the bootstrap's catch wrapper and reaches JSC's
// exception handler, which routes through the supervisor.
//
// Each force-crash should produce:
//   - 1st crash:  worker:crashed → worker:restarted
//   - 2nd crash:  worker:crashed → worker:restarted
//   - 3rd crash:  worker:crashed → worker:gave-up

import { Events, Sync, Workers } from "@zappdev/runtime";
// `workerModules` in zapp.config.ts (now ["fetch"]) drives the
// install — no manual side-effect import needed here.

console.log("[supervised] starting");

Events.on("force-crash", () => {
  console.log("[supervised] received force-crash → throwing in 0ms");
  // setTimeout dispatches into the worker queue; the callback runs
  // unwrapped, so a throw becomes uncaught at top level.
  setTimeout(() => {
    throw new Error("forced crash from supervisor demo");
  }, 0);
});

// Worker→worker pipeline demo: when the UI emits `relay-to-ticker`,
// this worker sends a `ping` directly to the ticker headless worker
// via `Workers.send` (no broadcast fan-out, no webview hop). The
// ticker echoes back to *this* worker on the `pong` channel.
receive("pong", (data: any) => {
  console.log("[supervised] got pong from ticker:", JSON.stringify(data));
  Events.emit("supervised:pipeline-done", { hop: "supervised → ticker → supervised", ts: Date.now() });
});

Events.on("relay-to-ticker", () => {
  console.log("[supervised] relaying ping to h-ticker");
  Workers.send("h-ticker", "ping", { replyTo: "h-supervised", from: "h-supervised" });
});

// --- Worker event delivery smoke (audit 2026-06-01) ---
// One listener per gap category. Each logs when it fires, so the
// manual matrix in docs/superpowers/plans/2026-06-01-worker-event-delivery-audit.md
// can verify the unified worker_broadcast_eval_js / worker_eval_js path
// is reaching workers for every native-emit event source. Event names
// were discovered by grepping `_onEvent(` and `_dispatchAppEvent`
// translations in the worker bootstrap.

// Window event — native/window/callbacks.zc:134 (`_onEvent('window:event', …)`).
// Payload: { windowId, event, w, h, x, y }. Fires for resize/move/focus/etc.
// when the host has subscribed the worker to that window+event bitmask.
Events.on("window:event", (data: any) => {
  console.log(`[supervised] window:event received: ${JSON.stringify(data)}`);
});

// Global shortcut — native/platform/darwin/shortcuts.m:205
// (`_onEvent('app:shortcut-triggered', '<id>')`). Payload is the bare
// shortcut id string (no JSON.parse needed — bootstrap leaves it as the
// raw string when parse fails).
Events.on("app:shortcut-triggered", (data: any) => {
  console.log(`[supervised] app:shortcut-triggered received: ${JSON.stringify(data)}`);
});

// Menu item click — native/platform/darwin/menu.m:29
// (`_onEvent('__menu:click', '{"id":"…"}')`). Covers app menu bar +
// context menus; payload is { id }.
Events.on("__menu:click", (data: any) => {
  console.log(`[supervised] __menu:click received: ${JSON.stringify(data)}`);
});

// Tray status-item click — native/platform/darwin/tray.m:153 + :166
// (`_onEvent('__tray:click', '{"id":<int>}')`). Payload is { id } (the
// tray slot id).
Events.on("__tray:click", (data: any) => {
  console.log(`[supervised] __tray:click received: ${JSON.stringify(data)}`);
});

// Notification click — workers receive this via the Layer 2
// `_dispatchAppEvent` path (eventId 102 → `app:notification-click`) wired
// in bootstrap/worker.ts:81-98. Payload is { id }. Layer 1 `__notif:click`
// `_onEvent` is intentionally NOT broadcast to workers (see
// native/platform/darwin/notification.m:23-27 comment — would double-fire).
Events.on("app:notification-click", (data: any) => {
  console.log(`[supervised] app:notification-click received: ${JSON.stringify(data)}`);
});

// Sync result — exercise the targeted-delivery path landed in T4
// (sync.m:294 `worker_eval_js((char*)worker_id, (char*)js_c)`).
//
// Flow when the user clicks the webview's "Run supervised sync test" pair:
//   1. Webview emits `supervised-sync-test` → this worker calls
//      `await Sync.wait("__supervised-sync-audit", 10000)`
//   2. The Sync.wait registers a pending promise + asks the host bridge
//      to block until a notify with that key arrives (or the timeout).
//   3. Webview clicks "Wake supervised's sync.wait" → calls
//      `Sync.notify("__supervised-sync-audit")` → reaches sync.m, which
//      builds the `bridge.dispatchSyncResult(payload)` IIFE and calls
//      worker_eval_js(worker_id, js) to deliver it to THIS worker
//      specifically (routed via the registry's engine field).
//   4. This worker's pending promise resolves with "notified"; we log it.
//
// If the log fires, T4's engine-agnostic targeted dispatch is reaching
// zjs workers end-to-end (the bug Gap C documented).
//
// Requires the runtime/sync.ts longhand rewrite (commit 68d0403) —
// the async-method-shorthand form crashed zjs's parser on import.
Events.on("supervised-sync-test", async () => {
  console.log(`[supervised] Sync.wait("__supervised-sync-audit", 10000) started`);
  const result = await Sync.wait("__supervised-sync-audit", 10000);
  console.log(`[supervised] Sync.wait("__supervised-sync-audit") → ${result}`);
});

console.log("[supervised] ready");
