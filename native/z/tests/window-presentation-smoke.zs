import { WindowPresentationState } from "../framework/window-presentation.zs";
import { WindowManager, WindowOptions, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, WindowBooleanOperation, createWindowManager } from "../framework/window.zs";
import { WindowError } from "../framework/application-error.zs";
import { WindowEvent } from "../framework/events.zs";
import { BridgeMessage, BridgeMessageKind } from "../framework/bridge.zs";
import { routeWindowBridgeMessage } from "../framework/window-bridge.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { Set } from "std/collections";
import { thread } from "std/thread";

function requestIs(value: Option<boolean>, expected: boolean): boolean {
  return match (value) { some(actual) => actual == expected; none => false; };
}
function absent(value: Option<boolean>): boolean {
  return match (value) { some(_) => false; none => true; };
}

function verifyState(): i32 {
  let state = WindowPresentationState();
  state.requestFullscreen(false);
  if (!absent(state.takeFullscreenRequest())) return 1;
  state.requestFullscreen(true);
  if (!requestIs(state.takeFullscreenRequest(), true) || !state.fullscreenTransition) return 2;
  state.requestFullscreen(true);
  if (!absent(state.takeFullscreenRequest())) return 3;
  state.requestFullscreen(false);
  state.requestMaximized(true);
  if (!absent(state.takeMaximizedRequest()) || state.observeMaximized(true)) return 4;
  if (!state.completeFullscreen(true)) return 5;
  if (!requestIs(state.takeFullscreenRequest(), false)) return 6;
  if (!absent(state.takeMaximizedRequest())) return 7;
  if (!state.completeFullscreen(false)) return 8;
  if (!requestIs(state.takeMaximizedRequest(), true)) return 9;
  if (!state.observeMaximized(true) || state.observeMaximized(true)) return 10;
  if (!state.observeMaximized(false) || state.observeMaximized(false)) return 11;
  // A failed native transition consumes its request without retrying forever.
  state.requestFullscreen(true);
  if (!requestIs(state.takeFullscreenRequest(), true)) return 12;
  if (state.completeFullscreen(false) || state.fullscreenTransition) return 13;
  if (!absent(state.takeFullscreenRequest())) return 14;
  // Native green-button transitions follow the same state rules.
  state.beginFullscreen();
  state.requestMaximized(false);
  if (!absent(state.takeMaximizedRequest())) return 15;
  state.completeFullscreen(true);
  if (!absent(state.takeMaximizedRequest())) return 16;
  state.beginFullscreen();
  state.completeFullscreen(false);
  if (!requestIs(state.takeMaximizedRequest(), false)) return 17;
  return 0;
}

class Probe on thread.main {
  maximizes: i32;
  fullscreens: i32;
  lastMaximized: boolean;
  lastFullscreen: boolean;
  events: i32;
  registered: boolean;
  closeOnEvent: boolean;

  constructor() {
    this.maximizes = 0;
    this.fullscreens = 0;
    this.lastMaximized = false;
    this.lastFullscreen = false;
    this.events = 0;
    this.registered = true;
    this.closeOnEvent = false;
  }
}

function backend(owner: Weak<WindowManager>, probe: Probe): WindowBackend on thread.main {
  const create: WindowCreateOperation = (in id: String, in options: WindowOptions): void => {};
  const noop: WindowOperation = (in id: String): void => {};
  const title: WindowTitleOperation = (in id: String, in value: String): void => {};
  const close: WindowOperation = move (in id: String): void => {
    match (attempt owner.upgrade()) {
      success(windows) => { if (windows.closeRequestedNative(in id)) windows.closedNative(in id); }
      failure(_) => {}
    }
  };
  const maximized: WindowBooleanOperation = move (in id: String, value: boolean): void => {
    probe.maximizes = probe.maximizes + 1;
    probe.lastMaximized = value;
    match (attempt owner.upgrade()) {
      success(windows) => {
        probe.registered = match (windows.get(in id)) { some(_) => true; none => false; };
      }
      failure(_) => { probe.registered = false; }
    }
  };
  const fullscreen: WindowBooleanOperation = move (in id: String, value: boolean): void => {
    probe.fullscreens = probe.fullscreens + 1;
    probe.lastFullscreen = value;
  };
  return WindowBackend({ create, show: noop, hide: noop, focus: noop, minimize: noop,
    unminimize: noop, close, setTitle: title, setMaximized: maximized, setFullscreen: fullscreen });
}

function selection(): CapabilitySelection {
  let names = Array<String>();
  let permissions = Set<String>();
  let serviceMethods = Set<String>();
  let workerIds = Set<String>();
  return new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(),
    serviceMethods: serviceMethods.freeze(), workerIds: workerIds.freeze() });
}
function route(inout windows: WindowManager, method: String, arguments: String): boolean on thread.main {
  const message = BridgeMessage({ kind: BridgeMessageKind.action, id: 0, method, arguments });
  const permissions = ApplicationPermissions();
  return match (routeWindowBridgeMessage(in message, in permissions, "win-1", selection(), inout windows)) {
    handled => true;
    _ => false;
  };
}

function verifyManager(): i32 throws WindowError on thread.main {
  let windows = createWindowManager();
  const window = try windows.create(WindowOptions());
  const probe = new Probe();
  const observed = weak window;
  const subscription = match (attempt window.events.all.subscribe(move (in event: WindowEvent): void => {
    match (in event) {
      maximized(_) => { probe.events = probe.events + 1; }
      unmaximized(_) => { probe.events = probe.events + 1; }
      fullscreenEntered(_) => { probe.events = probe.events + 1; }
      fullscreenExited(_) => { probe.events = probe.events + 1; }
      _ => return;
    }
    if (probe.closeOnEvent) {
      match (attempt observed.upgrade()) { success(value) => value.close(); failure(_) => {} }
    }
  })) { success(value) => value; failure(_) => return 20; };
  window.maximize(); window.unmaximize(); window.maximize();
  window.setFullscreen(true); window.setFullscreen(false);
  if (probe.maximizes != 0 || probe.events != 0) return 21;
  try windows.start(backend(weak windows, probe), true);
  if (probe.maximizes != 1 || !probe.lastMaximized || probe.fullscreens != 0 || !probe.registered) return 22;
  if (probe.events != 0) return 23;
  if (!windows.maximizedChangedNative(in window.id, true)) return 24;
  if (windows.maximizedChangedNative(in window.id, true) || probe.events != 1) return 25;
  window.setFullscreen(true); window.setFullscreen(true); window.setFullscreen(false);
  if (probe.fullscreens != 1 || !probe.lastFullscreen || probe.events != 1) return 26;
  window.unmaximize();
  if (probe.maximizes != 1) return 27;
  if (!windows.fullscreenChangedNative(in window.id, true)) return 28;
  if (probe.fullscreens != 2 || probe.lastFullscreen || probe.events != 2) return 29;
  if (windows.maximizedChangedNative(in window.id, false)) return 30;
  if (!windows.fullscreenChangedNative(in window.id, false)) return 31;
  if (probe.maximizes != 2 || probe.lastMaximized || probe.events != 3) return 32;
  if (!windows.maximizedChangedNative(in window.id, false) || probe.events != 4) return 33;
  // Failure and duplicate notifications do not synthesize state events.
  window.setFullscreen(true);
  if (windows.fullscreenChangedNative(in window.id, false)) return 34;
  if (probe.fullscreens != 3 || probe.events != 4) return 35;
  if (!route(inout windows, "setFullscreen", '{"windowId":"win-1","fullscreen":"true"}')) return 36;
  if (!route(inout windows, "setFullscreen", '{"windowId":"win-1"}')) return 37;
  if (probe.fullscreens != 3) return 38;
  if (!route(inout windows, "setFullscreen", '{"windowId":"win-1","fullscreen":true}')) return 39;
  if (probe.fullscreens != 4) return 40;
  windows.fullscreenChangedNative(in window.id, false);
  if (!route(inout windows, "maximize", '{"windowId":"win-1"}')) return 41;
  if (!route(inout windows, "unmaximize", '{"windowId":"win-1"}')) return 42;
  if (probe.maximizes != 4 || probe.lastMaximized) return 43;
  // A subscriber can close the window before deferred work resumes.
  window.setFullscreen(true);
  window.maximize();
  probe.closeOnEvent = true;
  windows.fullscreenChangedNative(in window.id, true);
  match (windows.get(in window.id)) { some(_) => return 44; none => {} }
  const requests = probe.fullscreens;
  window.setFullscreen(false); window.maximize(); window.unmaximize();
  windows.fullscreenChangedNative(in window.id, false);
  windows.maximizedChangedNative(in window.id, true);
  if (probe.fullscreens != requests || probe.maximizes != 4) return 45;
  subscription.unsubscribe();
  windows.stop();
  return 0;
}

function main(): i32 on thread.main {
  const state = verifyState();
  if (state != 0) return state;
  return match (attempt verifyManager()) { success(value) => value; failure(_) => 99; };
}
