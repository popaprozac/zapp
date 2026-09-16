import { WindowManager, WindowOptions, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, WindowGetSizeOperation, WindowSetSizeOperation,
  createWindowManager } from "../framework/window.zs";
import { WindowSize } from "../framework/events.zs";
import { WindowError } from "../framework/application-error.zs";
import { WindowSizeLimits, checkedWindowSize } from "../framework/window-sizing.zs";
import { BridgeMessage, BridgeMessageKind } from "../framework/bridge.zs";
import { routeWindowBridgeMessage } from "../framework/window-bridge.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { Set } from "std/collections";
import { thread } from "std/thread";

class Probe on thread.main {
  width: u32;
  height: u32;
  calls: i32;
  closeOnSize: boolean;
  constructor() {
    this.width = 640; this.height = 480; this.calls = 0; this.closeOnSize = false;
  }
}

function backend(owner: Weak<WindowManager>, probe: Probe): WindowBackend on thread.main {
  const create: WindowCreateOperation = move (in id, in options): void => {
    probe.width = options.width; probe.height = options.height;
  };
  const noop: WindowOperation = (in id): void => {};
  const title: WindowTitleOperation = (in id, in title): void => {};
  const state: (in id: String, value: boolean) => void on thread.main = (in id, value): void => {};
  const getSize: WindowGetSizeOperation = move (in id): WindowSize => {
    return WindowSize({ width: probe.width, height: probe.height });
  };
  const setSize: WindowSetSizeOperation = move (in id, size): void => {
    probe.width = size.width; probe.height = size.height; probe.calls = probe.calls + 1;
    match (attempt owner.upgrade()) {
      success(windows) => {
        windows.resizedNative(in id, size.width, size.height);
        if (probe.closeOnSize) windows.closedNative(in id);
      }
      failure(_) => {}
    }
  };
  return WindowBackend({ create, show: noop, hide: noop, focus: noop, minimize: noop, unminimize: noop,
    setMaximized: state, setFullscreen: state, close: noop, setTitle: title, getSize, setSize });
}

function selection(): CapabilitySelection {
  let names = Array<String>();
  let permissions = Set<String>();
  let methods = Set<String>();
  let workers = Set<String>();
  return new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(),
    serviceMethods: methods.freeze(), workerIds: workers.freeze() });
}

function route(inout windows: WindowManager, method: String, arguments: String): boolean on thread.main {
  const message = BridgeMessage({ kind: BridgeMessageKind.invoke, id: 1, method, arguments });
  const permissions = ApplicationPermissions();
  return match (routeWindowBridgeMessage(in message, in permissions, "win-1", selection(), inout windows)) {
    response(reply) => reply.ok;
    _ => false;
  };
}

function verify(): i32 throws WindowError on thread.main {
  const limits = WindowSizeLimits({ minWidth: Option.some(u32(300)), maxHeight: Option.some(u32(600)) });
  const size = try checkedWindowSize(WindowSize({ width: 100, height: 800 }), limits);
  if (size.width != 300 || size.height != 600) return 1;
  match (attempt checkedWindowSize(WindowSize({ width: 0, height: 1 }), limits)) { success(_) => return 2; failure(_) => {} }
  match (attempt checkedWindowSize(size, WindowSizeLimits({ maxWidth: Option.some(u32(0)) }))) { success(_) => return 3; failure(_) => {} }
  match (attempt checkedWindowSize(size, WindowSizeLimits({ minHeight: Option.some(u32(10)), maxHeight: Option.some(u32(5)) }))) { success(_) => return 4; failure(_) => {} }
  let windows = createWindowManager();
  match (attempt windows.create(WindowOptions({ width: 0 }))) { success(_) => return 5; failure(_) => {} }
  const window = try windows.create(WindowOptions({ width: 100, height: 900, resizable: false,
    minWidth: Option.some(u32(300)), maxHeight: Option.some(u32(600)) }));
  match (attempt window.getSize()) { success(_) => return 6; failure(_) => {} }
  match (attempt window.setSize(size)) { success => return 7; failure(_) => {} }
  const probe = new Probe();
  try windows.start(backend(weak windows, probe), true);
  const initial = try window.getSize();
  if (initial.width != 300 || initial.height != 600) return 8;
  try window.setSize(WindowSize({ width: 200, height: 400 }));
  const measured = try window.getSize();
  if (measured.width != 300 || measured.height != 400 || probe.calls != 1) return 9;
  const id = copy window.id;
  const readRequest = `{"windowId":"${id}"}`;
  const writeRequest = `{"windowId":"${id}","size":{"width":420,"height":450}}`;
  const zeroRequest = `{"windowId":"${id}","size":{"width":0,"height":450}}`;
  const fractionalRequest = `{"windowId":"${id}","size":{"width":1.5,"height":450}}`;
  if (!route(inout windows, "__window:get-size", move readRequest)) return 10;
  if (!route(inout windows, "__window:set-size", move writeRequest)) return 11;
  if (route(inout windows, "__window:set-size", move zeroRequest)) return 12;
  if (route(inout windows, "__window:set-size", move fractionalRequest)) return 13;
  if (route(inout windows, "__window:get-size", '{"windowId":"missing"}')) return 14;
  if (probe.calls != 2) return 15;
  probe.closeOnSize = true;
  try window.setSize(size);
  match (windows.get(in id)) { some(_) => return 16; none => {} }
  match (attempt window.getSize()) { success(_) => return 17; failure(_) => {} }
  match (attempt window.setSize(size)) { success => return 18; failure(_) => {} }
  if (probe.calls != 3) return 19;
  windows.stop();
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt verify()) { success(code) => code; failure(_) => 90; };
}
