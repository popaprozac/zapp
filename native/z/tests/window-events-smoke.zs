import {
  WindowClosedEvent,
  WindowEvent,
  WindowEventSubscriptionError,
  WindowFocusedEvent,
  WindowResizedEvent,
  createWindowEvents,
} from "../framework/window-events.zs";
import { thread } from "std/thread";

class ObservedEvents on thread.main {
  all: i32;
  firstFocus: i32;
  secondFocus: i32;
  resized: i32;
  closed: i32;
}

function runWindowEventsSmoke(
): i32 throws WindowEventSubscriptionError on thread.main {
  const events = createWindowEvents();
  const observed = new ObservedEvents({
    all: 0,
    firstFocus: 0,
    secondFocus: 0,
    resized: 0,
    closed: 0,
  });

  const allObserved = observed;
  const all = try events.all.subscribe(
    move (in event: WindowEvent): void => {
      match (in event) {
        focused(value) => {
          if (value.windowId == "win-1") {
            allObserved.all = allObserved.all + 1;
          }
        }
        blurred(_) => {}
        resized(value) => {
          allObserved.all = allObserved.all + i32(value.size.width);
        }
        closed(_) => { allObserved.all = allObserved.all + 10; }
      }
    }
  );
  const firstObserved = observed;
  const first = try events.focused.subscribe(
    move (in event: WindowFocusedEvent): void => {
      if (event.windowId == "win-1") {
        firstObserved.firstFocus = firstObserved.firstFocus + 1;
      }
    }
  );
  const secondObserved = observed;
  const second = try events.focused.subscribe(
    move (in event: WindowFocusedEvent): void => {
      if (event.windowId == "win-1") {
        secondObserved.secondFocus = secondObserved.secondFocus + 1;
      }
    }
  );
  const resizedObserved = observed;
  const resized = try events.resized.subscribe(
    move (in event: WindowResizedEvent): void => {
      resizedObserved.resized = i32(event.size.width + event.size.height);
    }
  );
  const closedObserved = observed;
  const closed = try events.closed.subscribe(
    move (in event: WindowClosedEvent): void => {
      if (event.windowId == "win-1") {
        closedObserved.closed = closedObserved.closed + 1;
      }
    }
  );

  events.publishFocused("win-1");
  first.unsubscribe();
  events.publishFocused("win-1");
  events.publishResized("win-1", 4, 6);
  events.publishClosed("win-1");

  if (observed.firstFocus != 1) return 1;
  if (observed.secondFocus != 2) return 2;
  if (observed.resized != 10) return 3;
  if (observed.closed != 1) return 4;
  if (observed.all != 16) return 5;

  const late = attempt events.closed.subscribe(
    move (in event: WindowClosedEvent): void => {}
  );
  return match (late) {
    success(_) => 6;
    failure(_) => 0;
  };
}

function main(): i32 on thread.main {
  return match (attempt runWindowEventsSmoke()) {
    success(status) => status;
    failure(_) => 7;
  };
}
