import { WindowManager, WindowOptions, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, WindowGetPositionOperation, WindowSetPositionOperation,
  WindowCenterOperation, createWindowManager } from "../framework/window.zs";
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
}

function backend(owner: Weak<WindowManager>, probe: Probe): WindowBackend on thread.main {
  const create: WindowCreateOperation = (in id, in options): void => {};
  const noop: WindowOperation = (in id): void => {};
  const title: WindowTitleOperation = (in id, in title): void => {};
  const state: (in id: String, value: boolean) => void on thread.main = (in id, value): void => {};
  const getPosition: WindowGetPositionOperation = move (in id): WindowPosition => probe.position;
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
    setMaximized: state, setFullscreen: state, close: noop, setTitle: title, getPosition, setPosition, center });
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
  const probe = new Probe({ position: WindowPosition({ x: 0, y: 0 }), calls: 0, closeOnMove: false });
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
  if (probe.calls != 4) return 21;
  windows.stop();
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt verify()) { success(code) => code; failure(_) => 90; };
}
