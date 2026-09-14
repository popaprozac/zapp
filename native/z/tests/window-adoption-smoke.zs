import { WindowManager, WindowOptions, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, createWindowManager } from "../framework/window.zs";
import { WindowError } from "../framework/application-error.zs";
import { WindowCloseRequestedEvent, WindowClosedEvent } from "../framework/events.zs";
import { thread } from "std/thread";

function count(in windows: WindowManager): usize on thread.main {
  const values = windows.all();
  return values.length;
}

class Probe on thread.main {
  creates: i32;
  controls: i32;
  requests: i32;
  closed: i32;
  veto: boolean;
  retiredBeforeCallback: boolean;

  constructor() {
    this.creates = 0; this.controls = 0; this.requests = 0; this.closed = 0;
    this.veto = true; this.retiredBeforeCallback = false;
  }
}

function backend(owner: Weak<WindowManager>, probe: Probe): WindowBackend on thread.main {
  const create: WindowCreateOperation = move (in id: String, in options: WindowOptions): void => { probe.creates = probe.creates + 1; };
  const control: WindowOperation = move (in id: String): void => { probe.controls = probe.controls + 1; };
  const close: WindowOperation = move (in id: String): void => {
    const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    if (windows.closeRequestedNative(in id)) windows.closedNative(in id);
  };
  const title: WindowTitleOperation = move (in id: String, in title: String): void => { probe.controls = probe.controls + 1; };
  const state: (in id: String, value: boolean) => void on thread.main = move (in id: String, value: boolean): void => { probe.controls = probe.controls + 1; };
  return WindowBackend({ create, show: control, focus: control, hide: control, close, setTitle: title,
    minimize: control, unminimize: control, setMaximized: state, setFullscreen: state });
}

function verify(): i32 throws WindowError on thread.main {
  const windows = createWindowManager();
  const probe = new Probe();
  match (windows.adoptNative("related-1", WindowOptions())) { some(_) => return 1; none => {} }
  try windows.start(backend(weak windows, probe), false);
  match (windows.adoptNative("", WindowOptions())) { some(_) => return 2; none => {} }
  const child = match (windows.adoptNative("related-1", WindowOptions({ title: "Inspector" }))) { some(value) => value; none => return 3; };
  match (windows.adoptNative("related-1", WindowOptions())) { some(_) => return 4; none => {} }
  if (probe.creates != 0 || count(in windows) != 1) return 5;
  const found = match (windows.get(in child.id)) { some(value) => value; none => return 6; };
  if (found != child) return 7;
  child.hide(); child.show(); child.focus(); child.minimize(); child.unminimize(); child.setTitle("Updated");
  if (probe.controls != 6) return 8;
  const options = match (windows.options(in child.id)) { some(value) => value; none => return 9; };
  if (options.title != "Updated" || !options.visible) return 10;
  const owner = weak windows;
  const request = match (attempt child.events.closeRequested.subscribe(move (in event: WindowCloseRequestedEvent): void => {
    probe.requests = probe.requests + 1;
    if (probe.veto) event.cancel();
  })) { success(value) => value; failure(_) => return 11; };
  const closed = match (attempt child.events.closed.subscribe(move (in event: WindowClosedEvent): void => {
    probe.closed = probe.closed + 1;
    match (attempt owner.upgrade()) {
      success(manager) => {
        probe.retiredBeforeCallback = match (manager.get(in event.windowId)) { some(_) => false; none => true; };
        manager.closedNative(in event.windowId);
      }
      failure(_) => {}
    }
  })) { success(value) => value; failure(_) => return 12; };
  child.close();
  if (probe.requests != 1 || probe.closed != 0 || count(in windows) != 1) return 13;
  probe.veto = false;
  child.close();
  if (probe.requests != 2 || probe.closed != 1 || !probe.retiredBeforeCallback || count(in windows) != 0) return 14;
  child.close(); child.show(); child.focus(); child.minimize(); child.setTitle("stale");
  if (probe.requests != 2 || probe.closed != 1 || probe.controls != 6) return 15;
  const ordinary = try windows.create(WindowOptions());
  if (ordinary.id != "win-1" || probe.creates != 1) return 16;
  windows.stop();
  match (windows.adoptNative("related-2", WindowOptions())) { some(_) => return 17; none => {} }
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt verify()) { success(value) => value; failure(_) => 20; };
}
