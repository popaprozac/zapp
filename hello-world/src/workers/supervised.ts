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

import { Events } from "@zappdev/runtime";
import "@zappdev/runtime/worker-globals";

console.log("[supervised] starting");

Events.on("force-crash", () => {
  console.log("[supervised] received force-crash → throwing in 0ms");
  // setTimeout dispatches into the worker queue; the callback runs
  // unwrapped, so a throw becomes uncaught at top level.
  setTimeout(() => {
    throw new Error("forced crash from supervisor demo");
  }, 0);
});

console.log("[supervised] ready");
