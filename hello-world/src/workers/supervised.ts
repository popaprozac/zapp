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

import { Events, Workers } from "@zappdev/runtime";
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

// Sync result — INTENTIONALLY OMITTED from this worker.
//
// Two reasons:
//   1. There's no `Events.on("sync:result", …)` surface; the host calls
//      `bridge.dispatchSyncResult(id)` directly (native/platform/darwin/
//      sync.m:259) and the worker bootstrap resolves a pending promise
//      registered by `Sync.wait`. So the natural smoke shape is calling
//      `Sync.wait` from here and logging when it resolves.
//   2. `Sync.wait` from @zappdev/runtime/sync uses `async` method
//      shorthand (`{ async wait(...) {...} }`), and after Vite's bundler
//      drag-along the supervised.mjs entry hits zjs's parser which
//      currently rejects that exact shape with `SyntaxError: module
//      parse error` (vendor/zjs/src/context.zc:21470). The crash blocks
//      worker boot, taking out the other 5 listeners too.
//
// Sync delivery to workers is still covered by other vehicles:
//   - The webview "try-sync-wait" path that already exists in
//     hello-world's UI exercises bridge.syncWait + dispatchSyncResult
//     from the page side (different worker, different engine paths).
//   - benchmarks/apps/zapp-host-bridge exercises sync round-trip on
//     bare-jsc, where async-shorthand parses fine.
//
// Re-enable here once zjs's parser supports async-method shorthand (or
// the runtime's Sync wrapper is rewritten without it).

console.log("[supervised] ready");
