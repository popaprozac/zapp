import { Window, WindowOptions, WindowManager, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, createWindowManager } from "../framework/window.zs";
import { WindowError } from "../framework/application-error.zs";
import { WindowFocusedEvent } from "../framework/events.zs";
import { thread } from "std/thread";

class Probe on thread.main {
  creates: i32;
  shows: i32;
  focuses: i32;
  focusEvents: i32;
  registered: boolean;
  lastFocused: String;
  closeOnFocus: boolean;

  constructor() {
    this.creates = 0;
    this.shows = 0;
    this.focuses = 0;
    this.focusEvents = 0;
    this.registered = true;
    this.lastFocused = "";
    this.closeOnFocus = false;
  }
}

function backend(owner: Weak<WindowManager>, probe: Probe): WindowBackend on thread.main {
  const create: WindowCreateOperation = move (in id: String, in options: WindowOptions): void => {
    probe.creates = probe.creates + 1;
  };
  const show: WindowOperation = move (in id: String): void => { probe.shows = probe.shows + 1; };
  const focus: WindowOperation = move (in id: String): void => {
    probe.focuses = probe.focuses + 1;
    probe.lastFocused = copy id;
    let windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    const options = windows.options(in id);
    match (in options) {
      some(value) => { probe.registered = value.visible; }
      none => { probe.registered = false; }
    }
    // Model a synchronous native delegate callback, not an optimistic event
    // from Window.focus(). The subscriber may close its own window here.
    windows.focusedNative(in id);
  };
  const hide: WindowOperation = (in id: String): void => {};
  const close: WindowOperation = move (in id: String): void => {
    let windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    if (windows.closeRequestedNative(in id)) windows.closedNative(in id);
  };
  const setTitle: WindowTitleOperation = (in id: String, in title: String): void => {};
  return WindowBackend({ create, show, focus, hide, close, setTitle });
}

function verify(): i32 throws WindowError on thread.main {
  let windows = createWindowManager();
  const first = try windows.create(WindowOptions({ visible: false }));
  const second = try windows.create(WindowOptions({ visible: false }));
  const probe = new Probe();
  // An event listener must not keep its publishing window alive in a cycle.
  const observedWindow = weak first;
  const subscription = match (attempt first.events.focused.subscribe(move (in event: WindowFocusedEvent): void => {
    probe.focusEvents = probe.focusEvents + 1;
    if (probe.closeOnFocus) {
      match (attempt observedWindow.upgrade()) {
        success(window) => window.close();
        failure(_) => {}
      }
    }
  })) { success(value) => value; failure(_) => return 1; };
  first.focus();
  second.focus();
  first.focus();
  if (probe.focusEvents != 0) return 2;
  try windows.start(backend(weak windows, probe), true);
  if (probe.creates != 2 || probe.focuses != 1 || probe.focusEvents != 1) return 3;
  if (probe.lastFocused != first.id || !probe.registered) return 4;
  first.hide();
  first.show();
  if (probe.shows != 1 || probe.focuses != 1 || probe.focusEvents != 1) return 5;
  first.hide();
  first.focus();
  if (probe.focuses != 2 || probe.focusEvents != 2 || !probe.registered) return 6;
  probe.closeOnFocus = true;
  first.focus();
  if (probe.focuses != 3 || probe.focusEvents != 3 || !probe.registered) return 7;
  match (windows.get(in first.id)) { some(_) => return 8; none => {} }
  first.focus(); first.show();
  if (probe.focuses != 3 || probe.shows != 1) return 9;
  const remaining = windows.all();
  if (remaining.length != 1) return 10;
  windows.stop();

  let pending = createWindowManager();
  const hidden = try pending.create(WindowOptions());
  const closed = try pending.create(WindowOptions());
  hidden.focus(); hidden.hide();
  closed.focus(); closed.close();
  const cancelledProbe = new Probe();
  try pending.start(backend(weak pending, cancelledProbe), true);
  if (cancelledProbe.creates != 1 || cancelledProbe.focuses != 0) return 11;
  pending.stop();
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt verify()) { success(value) => value; failure(_) => 20; };
}
