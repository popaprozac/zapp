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

console.log("[supervised] ready");
