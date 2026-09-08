import { Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";
import { ApplicationEvents } from "../../application-events.zs";

// This delivery owner is independent of AppKit initialization. It outlives
// listener cancellation/join and every admitted main-executor wakeup.
const launchEvents = Once<ApplicationEvents>();

internal function initializeMacOSLaunchDelivery(
  events: ApplicationEvents
): OnceLifetime<ApplicationEvents> on thread.main {
  return launchEvents.initialize(move events);
}

internal function deliverMacOSLaunches(): void on thread.main {
  const events = launchEvents.get();
  const inbox = events.activationInbox();
  inbox.beginWake();
  events.drainActivation();
}
