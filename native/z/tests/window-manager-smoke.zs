import {
  WindowOptions,
  createWindowManager,
} from "../framework/window.zs";
import { WindowError } from "../framework/application-error.zs";
import {
  WindowBlurredEvent,
  WindowCloseRequestedEvent,
  WindowClosedEvent,
  WindowEvent,
  WindowFocusedEvent,
  WindowResizedEvent,
} from "../framework/window-events.zs";
import { thread } from "std/thread";

class ObservedWindowLifecycle on thread.main {
  focused: i32;
  blurred: i32;
  resized: i32;
  closeRequested: i32;
  cancelClose: boolean;
  closed: i32;
  aggregate: i32;
}

function runWindowManagerSmoke(): i32 throws WindowError on thread.main {
  let windows = createWindowManager();
  const primary = try windows.create(WindowOptions({
    title: "Primary",
    width: 720,
    height: 460,
  }));
  const secondary = try windows.create(WindowOptions());
  const observed = new ObservedWindowLifecycle({
    focused: 0,
    blurred: 0,
    resized: 0,
    closeRequested: 0,
    cancelClose: true,
    closed: 0,
    aggregate: 0,
  });
  const focusedObserved = observed;
  const focusedHandler: (
    in event: WindowFocusedEvent
  ) => void on thread.main = move (in event: WindowFocusedEvent): void => {
    if (event.windowId == "win-1") focusedObserved.focused = 1;
  };
  const focused = match (attempt primary.events.focused.subscribe(
    focusedHandler
  )) {
    success(subscription) => subscription;
    failure(_) => return 9;
  };
  const blurredObserved = observed;
  const blurredHandler: (
    in event: WindowBlurredEvent
  ) => void on thread.main = move (in event: WindowBlurredEvent): void => {
    if (event.windowId == "win-1") blurredObserved.blurred = 1;
  };
  const blurred = match (attempt primary.events.blurred.subscribe(
    blurredHandler
  )) {
    success(subscription) => subscription;
    failure(_) => return 10;
  };
  const resizedObserved = observed;
  const resizedHandler: (
    in event: WindowResizedEvent
  ) => void on thread.main = move (in event: WindowResizedEvent): void => {
    resizedObserved.resized = i32(event.size.width + event.size.height);
  };
  const resized = match (attempt primary.events.resized.subscribe(
    resizedHandler
  )) {
    success(subscription) => subscription;
    failure(_) => return 11;
  };
  const closedObserved = observed;
  const closedHandler: (
    in event: WindowClosedEvent
  ) => void on thread.main = move (in event: WindowClosedEvent): void => {
    if (event.windowId == "win-1") closedObserved.closed = 1;
  };
  const closed = match (attempt primary.events.closed.subscribe(
    closedHandler
  )) {
    success(subscription) => subscription;
    failure(_) => return 12;
  };
  const closeRequestedObserved = observed;
  const closeRequestedHandler: (
    in event: WindowCloseRequestedEvent
  ) => void on thread.main = move (
    in event: WindowCloseRequestedEvent
  ): void => {
    closeRequestedObserved.closeRequested =
      closeRequestedObserved.closeRequested + 1;
    if (closeRequestedObserved.cancelClose) event.cancel();
  };
  const closeRequested = match (attempt primary.events.closeRequested.subscribe(
    closeRequestedHandler
  )) {
    success(subscription) => subscription;
    failure(_) => return 20;
  };
  const aggregateObserved = observed;
  const aggregateHandler: (
    in event: WindowEvent
  ) => void on thread.main = move (in event: WindowEvent): void => {
    aggregateObserved.aggregate = aggregateObserved.aggregate + 1;
  };
  const aggregate = match (attempt primary.events.all.subscribe(
    aggregateHandler
  )) {
    success(subscription) => subscription;
    failure(_) => return 13;
  };

  if (primary.id != "win-1" || secondary.id != "win-2") return 1;
  const initial = windows.all();
  if (initial.length != 2) return 2;

  const found = windows.get(primary.id);
  const foundId = match (found) {
    some(window) => copy window.id;
    none => "";
  };
  if (foundId != "win-1") return 3;

  primary.hide();
  const hidden = windows.options(primary.id);
  const isHidden = match (hidden) {
    some(options) => !options.visible;
    none => false;
  };
  if (!isHidden) return 4;

  primary.show();
  primary.setTitle("Renamed");
  const updated = windows.options(primary.id);
  const isVisible = match (in updated) {
    some(options) => options.visible;
    none => false;
  };
  if (!isVisible) return 5;
  const hasUpdatedTitle = match (updated) {
    some(options) => options.title == "Renamed";
    none => false;
  };
  if (!hasUpdatedTitle) return 8;

  windows.focusedNative(primary.id);
  windows.blurredNative(primary.id);
  windows.resizedNative(primary.id, 720, 460);
  if (observed.focused != 1) return 14;
  if (observed.blurred != 1) return 15;
  if (observed.resized != 1180) return 16;
  if (observed.aggregate != 3) return 17;

  primary.close();
  if (observed.closeRequested != 1 || observed.closed != 0) return 18;
  const afterCancelledClose = windows.all();
  if (afterCancelledClose.length != 2) return 19;
  observed.cancelClose = false;
  primary.close();
  primary.close();
  if (observed.closeRequested != 2) return 21;
  if (observed.closed != 1) return 22;
  if (observed.aggregate != 6) return 23;
  const remaining = windows.all();
  if (remaining.length != 1) return 6;
  return match (windows.get(primary.id)) {
    some(_) => 7;
    none => 0;
  };
}

function main(): i32 on thread.main {
  return match (attempt runWindowManagerSmoke()) {
    success(status) => status;
    failure(_) => 10;
  };
}
