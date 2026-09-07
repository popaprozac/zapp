import AppKit from "AppKit/AppKit.h";
import console from "std/console";
import { thread } from "std/thread";
import {
  ApplicationQuitRequestedEvent,
  ApplicationEventSubscriptionError,
  createApplicationEvents,
} from "../framework/application-events.zs";
import {
  initializeMacOSApplicationHost,
} from "../framework/platform/macos/application-host.zs";

class ShutdownObservation on thread.main {
  stops: i32;
}

function run(): i32 throws ApplicationEventSubscriptionError on thread.main {
  const events = createApplicationEvents();
  const host = initializeMacOSApplicationHost(events);
  const observed = new ShutdownObservation({ stops: 0 });
  const retained = observed;
  events.start(move (): void => { retained.stops = retained.stops + 1; });
  const veto = try events.quitRequested.subscribe(
    move (in event: ApplicationQuitRequestedEvent): void => event.cancel()
  );
  const application = AppKit.NSApplication.sharedApplication;
  application.terminate(null);
  if (observed.stops != 0) return 1;
  veto.unsubscribe();
  application.terminate(null);
  if (observed.stops != 1) return 2;
  application.terminate(null);
  if (observed.stops != 1) return 3;
  events.finish();
  // This marker is essential: an accidental AppKit exit(0) is not a pass.
  console.log("native quit returned to Z after cancellation and acceptance");
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt run()) {
    success(status) => status;
    failure(_) => 4;
  };
}
