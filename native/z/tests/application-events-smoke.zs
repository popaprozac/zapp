import {
  ApplicationEventSubscriptionError,
  ApplicationQuitRequestedEvent,
  createApplicationEvents,
} from "../framework/application-events.zs";
import { thread } from "std/thread";

class ObservedApplicationEvents on thread.main {
  requests: i32;
  quits: i32;
}

function runApplicationEventsSmoke(
): i32 throws ApplicationEventSubscriptionError on thread.main {
  const events = createApplicationEvents();
  const observed = new ObservedApplicationEvents({
    requests: 0,
    quits: 0,
  });
  const quitObserved = observed;
  events.start(move (): void => {
    quitObserved.quits = quitObserved.quits + 1;
  });

  const requestObserved = observed;
  const subscription = try events.quitRequested.subscribe(
    move (in event: ApplicationQuitRequestedEvent): void => {
      requestObserved.requests = requestObserved.requests + 1;
      event.cancel();
    }
  );

  events.requestQuit();
  if (observed.requests != 1 || observed.quits != 0) return 1;

  subscription.unsubscribe();
  events.requestQuit();
  if (observed.requests != 1 || observed.quits != 1) return 2;

  events.requestQuit();
  if (observed.quits != 1) return 3;

  events.finish();
  const late = attempt events.quitRequested.subscribe(
    move (in event: ApplicationQuitRequestedEvent): void => {}
  );
  return match (late) {
    success(_) => 4;
    failure(_) => 0;
  };
}

function main(): i32 on thread.main {
  return match (attempt runApplicationEventsSmoke()) {
    success(status) => status;
    failure(_) => 5;
  };
}
