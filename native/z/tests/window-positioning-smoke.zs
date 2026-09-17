import { WindowManager, WindowOptions, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, WindowGetPositionOperation, WindowSetPositionOperation,
  WindowCenterOperation, createWindowManager } from "../framework/window.zs";
import { WindowGetBoundsOperation, WindowGetDisplayOperation } from "../framework/window.zs";
import { Bounds, Display } from "../api/zapp/window.zs";
import { WindowPosition, checkedWindowPosition } from "../framework/window-positioning.zs";
import { WindowError } from "../framework/application-error.zs";
import json from "std/json";
import { BridgeMessage, BridgeMessageKind, encodeBridgeResponse } from "../framework/bridge.zs";
import { routeWindowBridgeMessage } from "../framework/window-bridge.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { Set } from "std/collections";
import { thread } from "std/thread";

class Probe on thread.main {
  position: WindowPosition;
  calls: i32;
  closeOnMove: boolean;
  hasDisplay: boolean;
}

function backend(owner: Weak<WindowManager>, probe: Probe): WindowBackend on thread.main {
  const create: WindowCreateOperation = (in id, in options): void => {};
  const noop: WindowOperation = (in id): void => {};
  const title: WindowTitleOperation = (in id, in title): void => {};
  const state: (in id: String, value: boolean) => void on thread.main = (in id, value): void => {};
  const getPosition: WindowGetPositionOperation = move (in id): WindowPosition => probe.position;
  const getBounds: WindowGetBoundsOperation = move (in id): Bounds => Bounds({
    x: probe.position.x, y: probe.position.y, width: 900.5, height: 660.25 });
  const getDisplay: WindowGetDisplayOperation = move (in id): Option<Display> => {
    if (!probe.hasDisplay) return Option<Display>.none;
    return Option.some(Display({ id: "opaque-display", bounds: Bounds({ x: -1600.5, y: -200.25, width: 1600, height: 1000 }),
      workArea: Bounds({ x: -1600.5, y: -176.25, width: 1600, height: 936.5 }), scaleFactor: 2, isPrimary: false }));
  };
  const setPosition: WindowSetPositionOperation = move (in id, position): void => {
    probe.position = position; probe.calls = probe.calls + 1;
    if (probe.closeOnMove) {
      match (attempt owner.upgrade()) { success(windows) => windows.closedNative(in id); failure(_) => {} }
    }
  };
  const center: WindowCenterOperation = move (in id): void => {
    probe.position = WindowPosition({ x: 100.5, y: 200.25 }); probe.calls = probe.calls + 1;
  };
  return WindowBackend({ create, show: noop, hide: noop, focus: noop, minimize: noop, unminimize: noop,
    setMaximized: state, setFullscreen: state, close: noop, setTitle: title, getPosition, setPosition, center, getBounds, getDisplay });
}

function selection(): CapabilitySelection {
  let names = Array<String>(); let permissions = Set<String>();
  let methods = Set<String>(); let workers = Set<String>();
  return new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(),
    serviceMethods: methods.freeze(), workerIds: workers.freeze() });
}

function route(inout windows: WindowManager, method: String, arguments: String): boolean on thread.main {
  const message = BridgeMessage({ kind: BridgeMessageKind.invoke, id: 1, method, arguments });
  const permissions = ApplicationPermissions();
  return match (routeWindowBridgeMessage(in message, in permissions, "win-1", selection(), inout windows)) {
    response(reply) => {
      if (!reply.ok) return false;
      if (message.method == "__window:get-position") {
        const position = match (attempt json.decode<WindowPosition>(in reply.payload)) {
          success(value) => value; failure(_) => return false;
        };
        if (position.x != -80.25 || position.y != 40.5) return false;
      }
      if (message.method == "__window:get-bounds") {
        const bounds = match (attempt json.decode<Bounds>(in reply.payload)) { success(value) => value; failure(_) => return false; };
        if (bounds.x != -80.25 || bounds.y != 40.5 || bounds.width != 900.5 || bounds.height != 660.25) return false;
      }
      if (message.method == "__window:get-display") {
        const display = match (attempt json.decode<Display>(in reply.payload)) { success(value) => value; failure(_) => return false; };
        if (display.id != "opaque-display" || display.bounds.x != -1600.5 || display.workArea.height != 936.5 || display.scaleFactor != 2 || display.isPrimary) return false;
      }
      select true;
    }
    _ => false;
  };
}

function verify(): i32 throws WindowError on thread.main {
  const invalidReply = WindowPosition({ x: f64.fromBits(0x7ff0000000000000), y: 0 });
  const response = encodeBridgeResponse(42, true, in invalidReply);
  if (response.ok || response.id != 42 || response.payload != '{"code":"INTERNAL_ERROR","message":"Failed to encode native response."}') return 22;
  const position = try checkedWindowPosition(WindowPosition({ x: -100.5, y: -50.25 }));
  match (attempt checkedWindowPosition(WindowPosition({ x: f64.fromBits(0x7ff0000000000000), y: 0 }))) {
    success(_) => return 1; failure(_) => {}
  }
  match (attempt checkedWindowPosition(WindowPosition({ x: 0, y: f64.fromBits(0x7ff8000000000000) }))) {
    success(_) => return 2; failure(_) => {}
  }
  let windows = createWindowManager();
  const window = try windows.create(WindowOptions({ resizable: false }));
  match (attempt window.getPosition()) { success(_) => return 3; failure(_) => {} }
  match (attempt window.setPosition(position)) { success => return 4; failure(_) => {} }
  match (attempt window.center()) { success => return 5; failure(_) => {} }
  match (attempt window.getBounds()) { success(_) => return 23; failure(_) => {} }
  match (attempt window.getDisplay()) { success(_) => return 24; failure(_) => {} }
  const probe = new Probe({ position: WindowPosition({ x: 0, y: 0 }), calls: 0, closeOnMove: false, hasDisplay: true });
  try windows.start(backend(weak windows, probe), true);
  try window.setPosition(position);
  const measured = try window.getPosition();
  if (measured.x != -100.5 || measured.y != -50.25 || probe.calls != 1) return 6;
  const id = copy window.id;
  const moveRequest = `{"windowId":"${id}","position":{"x":-80.25,"y":40.5}}`;
  if (!route(inout windows, "__window:set-position", moveRequest)) return 7;
  const bridged = try window.getPosition();
  if (bridged.x != -80.25 || bridged.y != 40.5) return 8;
  const identity = `{"windowId":"${id}"}`;
  if (!route(inout windows, "__window:get-bounds", copy identity)) return 25;
  if (!route(inout windows, "__window:get-display", copy identity)) return 26;
  const snapshot = try window.getBounds();
  const displaySnapshot = try window.getDisplay();
  probe.hasDisplay = false;
  match (try window.getDisplay()) { some(_) => return 27; none => {} }
  const displayMessage = BridgeMessage({ kind: BridgeMessageKind.invoke, id: 2, method: "__window:get-display", arguments: copy identity });
  const permissions = ApplicationPermissions();
  match (routeWindowBridgeMessage(in displayMessage, in permissions, "win-1", selection(), inout windows)) {
    response(reply) => { if (!reply.ok || reply.payload != "null") return 28; }
    _ => return 29;
  }
  if (route(inout windows, "__window:get-display", '{"windowId":"missing"}')) return 30;
  if (route(inout windows, "__window:get-bounds", '{"windowId":"missing"}')) return 31;
  if (!route(inout windows, "__window:get-position", copy identity)) return 9;
  if (!route(inout windows, "__window:center", identity)) return 10;
  const centered = try window.getPosition();
  if (centered.x != 100.5 || centered.y != 200.25 || probe.calls != 3) return 11;
  const wrongType = `{"windowId":"${id}","position":{"x":"10","y":0}}`;
  const overflow = `{"windowId":"${id}","position":{"x":1e999,"y":0}}`;
  const missingY = `{"windowId":"${id}","position":{"x":0}}`;
  if (route(inout windows, "__window:set-position", wrongType)) return 12;
  if (route(inout windows, "__window:set-position", overflow)) return 13;
  if (route(inout windows, "__window:set-position", missingY)) return 14;
  if (route(inout windows, "__window:center", '{"windowId":"missing"}')) return 15;
  if (probe.calls != 3) return 16;
  probe.closeOnMove = true;
  try window.setPosition(position);
  match (windows.get(in id)) { some(_) => return 17; none => {} }
  match (attempt window.getPosition()) { success(_) => return 18; failure(_) => {} }
  match (attempt window.setPosition(position)) { success => return 19; failure(_) => {} }
  match (attempt window.center()) { success => return 20; failure(_) => {} }
  match (attempt window.getBounds()) { success(_) => return 32; failure(_) => {} }
  match (attempt window.getDisplay()) { success(_) => return 33; failure(_) => {} }
  if (snapshot.x != -80.25 || snapshot.y != 40.5) return 34;
  match (in displaySnapshot) { some(display) => { if (display.id != "opaque-display") return 35; } none => return 36; }
  if (probe.calls != 4) return 21;
  windows.stop();
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt verify()) { success(code) => code; failure(_) => 90; };
}
