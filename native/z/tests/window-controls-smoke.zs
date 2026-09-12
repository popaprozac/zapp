import { Window, WindowManager, WindowOptions, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, createWindowManager } from "../framework/window.zs";
import { WindowError } from "../framework/application-error.zs";
import { WindowMinimizedEvent, WindowUnminimizedEvent, WindowEvent } from "../framework/events.zs";
import { BridgeMessage, BridgeMessageKind } from "../framework/bridge.zs";
import { routeWindowBridgeMessage } from "../framework/window-bridge.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { Set } from "std/collections";
import { thread } from "std/thread";

class Probe on thread.main {
  minimizes: i32;
  unminimizes: i32;
  focuses: i32;
  minimizedEvents: i32;
  unminimizedEvents: i32;
  aggregateEvents: i32;
  emit: boolean;
  closeOnMinimize: boolean;
  registered: boolean;
  restoreOnCreate: boolean;

  constructor() {
    this.minimizes = 0;
    this.unminimizes = 0;
    this.focuses = 0;
    this.minimizedEvents = 0;
    this.unminimizedEvents = 0;
    this.aggregateEvents = 0;
    this.emit = false;
    this.closeOnMinimize = false;
    this.registered = true;
    this.restoreOnCreate = false;
  }
}

function backend(owner: Weak<WindowManager>, probe: Probe): WindowBackend on thread.main {
  const create: WindowCreateOperation = move (in id: String, in options: WindowOptions): void => {
    if (probe.restoreOnCreate) {
      match (attempt owner.upgrade()) {
        success(windows) => windows.unminimize(in id);
        failure(_) => {}
      }
    }
  };
  const noop: WindowOperation = (in id: String): void => {};
  const focus: WindowOperation = move (in id: String): void => { probe.focuses = probe.focuses + 1; };
  const minimize: WindowOperation = move (in id: String): void => {
    probe.minimizes = probe.minimizes + 1;
    let windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    probe.registered = match (windows.get(in id)) { some(_) => true; none => false; };
    if (probe.emit) windows.minimizedNative(in id);
  };
  const unminimize: WindowOperation = move (in id: String): void => {
    probe.unminimizes = probe.unminimizes + 1;
    let windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    if (probe.emit) windows.unminimizedNative(in id);
  };
  const close: WindowOperation = move (in id: String): void => {
    let windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    if (windows.closeRequestedNative(in id)) windows.closedNative(in id);
  };
  const setTitle: WindowTitleOperation = (in id: String, in title: String): void => {};
  const setState: (in id: String, value: boolean) => void on thread.main = (in id: String, value: boolean): void => {};
  return WindowBackend({ create, show: noop, hide: noop, focus, minimize, unminimize, close, setTitle,
    setMaximized: setState, setFullscreen: setState });
}

function selection(): CapabilitySelection {
  let names = Array<String>();
  let permissions = Set<String>();
  let serviceMethods = Set<String>();
  let workerIds = Set<String>();
  return new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(),
    serviceMethods: serviceMethods.freeze(), workerIds: workerIds.freeze() });
}

function route(
  inout windows: WindowManager, method: String, arguments: String
): boolean on thread.main {
  const message = BridgeMessage({ kind: BridgeMessageKind.action, id: 0, method, arguments });
  const permissions = ApplicationPermissions();
  return match (routeWindowBridgeMessage(in message, in permissions, "win-1", selection(), inout windows)) {
    handled => true;
    _ => false;
  };
}

function verify(): i32 throws WindowError on thread.main {
  let windows = createWindowManager();
  const window = try windows.create(WindowOptions());
  const probe = new Probe();
  const observed = weak window;
  const minimized = match (attempt window.events.minimized.subscribe(move (in event: WindowMinimizedEvent): void => {
    if (event.windowId != "win-1") return;
    probe.minimizedEvents = probe.minimizedEvents + 1;
    if (probe.closeOnMinimize) {
      match (attempt observed.upgrade()) { success(value) => value.close(); failure(_) => {} }
    }
  })) { success(value) => value; failure(_) => return 1; };
  const unminimized = match (attempt window.events.unminimized.subscribe(move (in event: WindowUnminimizedEvent): void => {
    if (event.windowId == "win-1") probe.unminimizedEvents = probe.unminimizedEvents + 1;
  })) { success(value) => value; failure(_) => return 2; };
  const all = match (attempt window.events.all.subscribe(move (in event: WindowEvent): void => {
    match (in event) {
      minimized(_) => { probe.aggregateEvents = probe.aggregateEvents + 1; }
      unminimized(_) => { probe.aggregateEvents = probe.aggregateEvents + 1; }
      _ => {}
    }
  })) { success(value) => value; failure(_) => return 3; };
  window.focus();
  window.minimize();
  window.minimize();
  if (probe.minimizes != 0 || probe.minimizedEvents != 0) return 4;
  try windows.start(backend(weak windows, probe), true);
  if (probe.minimizes != 1 || probe.focuses != 0 || !probe.registered) return 5;
  // Requests do not fabricate events, including repeat requests.
  window.minimize(); window.unminimize(); window.unminimize();
  if (probe.minimizedEvents != 0 || probe.unminimizedEvents != 0) return 6;
  probe.emit = true;
  window.minimize(); window.unminimize();
  if (probe.minimizedEvents != 1 || probe.unminimizedEvents != 1 || probe.aggregateEvents != 2) return 7;
  // Same checked action route as show/hide; malformed and stale ids are harmless.
  if (!route(inout windows, "focus", '{"windowId":"win-1"}')) return 8;
  if (!route(inout windows, "minimize", '{"windowId":"win-1"}')) return 9;
  if (!route(inout windows, "unminimize", '{"windowId":"win-1"}')) return 10;
  if (probe.focuses != 1 || probe.minimizedEvents != 2 || probe.unminimizedEvents != 2) return 11;
  const requests = probe.minimizes;
  if (!route(inout windows, "minimize", '{"windowId":42}')) return 12;
  if (!route(inout windows, "minimize", '{"windowId":"absent"}')) return 13;
  if (probe.minimizes != requests) return 14;
  // Delivery can close its own window without resurrecting a registry entry.
  probe.closeOnMinimize = true;
  window.minimize();
  match (windows.get(in window.id)) { some(_) => return 15; none => {} }
  if (!probe.registered) return 16;
  const closedRequests = probe.minimizes;
  const closedRestores = probe.unminimizes;
  window.minimize(); window.unminimize(); window.focus();
  windows.minimizedNative(in window.id); windows.unminimizedNative(in window.id);
  if (probe.minimizes != closedRequests || probe.unminimizes != closedRestores) return 17;
  if (probe.minimizedEvents != 3 || probe.unminimizedEvents != 2) return 18;
  minimized.unsubscribe(); unminimized.unsubscribe(); all.unsubscribe();
  windows.stop();

  let pending = createWindowManager();
  const restored = try pending.create(WindowOptions());
  const focused = try pending.create(WindowOptions());
  const closed = try pending.create(WindowOptions());
  restored.minimize(); restored.unminimize();
  focused.minimize(); focused.focus();
  closed.minimize(); closed.close();
  const cancelled = new Probe();
  try pending.start(backend(weak pending, cancelled), true);
  if (cancelled.minimizes != 0 || cancelled.focuses != 1 || cancelled.unminimizes != 0) return 19;
  pending.stop();
  let reentrant = createWindowManager();
  const changed = try reentrant.create(WindowOptions());
  changed.minimize();
  const changedProbe = new Probe();
  changedProbe.restoreOnCreate = true;
  try reentrant.start(backend(weak reentrant, changedProbe), true);
  if (changedProbe.minimizes != 0 || changedProbe.unminimizes != 1) return 20;
  reentrant.stop();
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt verify()) { success(value) => value; failure(_) => 30; };
}
