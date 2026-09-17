import { WindowManager, WindowOptions, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, createWindowManager } from "../framework/window.zs";
import { WindowError } from "../framework/application-error.zs";
import { WindowStateStore, WindowStateInbox,
  SavedWindowState, decodeWindowStates, recoveredWindowPosition, writeWindowStates } from "../framework/window-state.zs";
import { WindowPosition } from "../framework/window-positioning.zs";
import { Bounds } from "../framework/window-display.zs";
import { Channel } from "std/channel";
import { thread } from "std/thread";
import process from "std/process";
import fs from "std/fs";
import json from "std/json";
import console from "std/console";
import { Set } from "std/collections";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { BridgeMessage, BridgeMessageKind } from "../framework/bridge.zs";
import { routeWindowBridgeMessage } from "../framework/window-bridge.zs";

class CreationProbe on thread.main {
  calls: i32;
  nestedRejected: boolean;
  constructor() { this.calls = 0; this.nestedRejected = false; }
}

function verifiesActiveStateKeys(): boolean throws WindowError on thread.main {
  let windows = createWindowManager();
  const owner = weak windows;
  const probe = new CreationProbe();
  const create: WindowCreateOperation = move (in id: String, in options: WindowOptions): void => {
    probe.calls = probe.calls + 1;
    if (probe.calls == 1) {
      let current = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
      // Model native creation calling back into application code before the
      // outer window is registered. Its reserved key must already be exclusive.
      match (attempt current.create(WindowOptions({ stateKey: Option.some("active") }))) {
        success(_) => {}
        failure(_) => { probe.nestedRejected = true; }
      }
      throw WindowError({ id: copy id, message: "intentional creation failure" });
    }
  };
  const noop: WindowOperation = (in id: String): void => {};
  const title: WindowTitleOperation = (in id: String, in title: String): void => {};
  const state: (in id: String, value: boolean) => void on thread.main = (in id: String, value: boolean): void => {};
  try windows.start(WindowBackend({ create, show: noop, hide: noop, focus: noop, close: noop,
    minimize: noop, unminimize: noop, setTitle: title, setMaximized: state, setFullscreen: state }), true);
  match (attempt windows.create(WindowOptions({ stateKey: Option.some("active") }))) {
    success(_) => return false;
    failure(_) => {}
  }
  if (probe.calls != 1 || !probe.nestedRejected) return false;
  // Failure must release the reservation; success replaces it with a live key.
  const created = try windows.create(WindowOptions({ stateKey: Option.some("active") }));
  match (attempt windows.create(WindowOptions({ stateKey: Option.some("active") }))) {
    success(_) => return false;
    failure(_) => {}
  }
  if (probe.calls != 2) return false;
  windows.closedNative(in created.id);
  const reopened = try windows.create(WindowOptions({ stateKey: Option.some("active") }));
  windows.stop();
  return probe.calls == 3;
}

function rejectsRendererStateKey(inout windows: WindowManager): boolean on thread.main {
  let names = Array<String>();
  let permissions = Set<String>();
  permissions.add("window:create");
  let services = Set<String>();
  let workers = Set<String>();
  const selection = new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(),
    serviceMethods: services.freeze(), workerIds: workers.freeze() });
  const allowed = ApplicationPermissions({ windowCreate: true });
  const message = BridgeMessage({ kind: BridgeMessageKind.invoke, id: 1, method: "__window:create",
    arguments: '{"stateKey":"private.native.slot"}' });
  return match (routeWindowBridgeMessage(in message, in allowed, "win-2", selection, inout windows)) {
    response(reply) => !reply.ok;
    _ => false;
  };
}

async function saveOnScopeExit(directory: String): void on thread.main {
  const inbox = new WindowStateInbox();
  const { sender, receiver } = Channel<boolean>.bounded(1);
  const syncReceiver = receiver.sync();
  const workerDirectory = copy directory;
  const worker = thread.spawn(move (): void => writeWindowStates(move workerDirectory, inbox, move syncReceiver));
  let store = new WindowStateStore(move directory, inbox, sender.sync());
  store.remember(SavedWindowState({ key: "scoped", width: 800, height: 600, x: 20, y: 30, maximized: false }));
  // Early return: explicitly signal before the unconsumed native thread joins.
  store.stop();
  return;
}

async function main(): i32 on thread.main {
  const args = process.args();
  if (args.length != 1) return 1;
  const directory = copy args[0];
  const scopedDirectory = `${directory}/scoped`;
  await saveOnScopeExit(copy scopedDirectory);
  const scopedPath = `${scopedDirectory}/window-state.json`;
  if (!fs.exists(scopedPath)) return 17;
  match (attempt verifiesActiveStateKeys()) {
    success(valid) => { if (!valid) return 20; }
    failure(_) => return 21;
  }
  let windows = createWindowManager();
  const first = match (attempt windows.create(WindowOptions({ stateKey: Option.some("notes.main") }))) { success(value) => value; failure(_) => return 2; };
  match (attempt windows.create(WindowOptions({ stateKey: Option.some("notes.main") }))) { success(_) => return 3; failure(_) => {} }
  windows.closedNative(in first.id);
  match (attempt windows.create(WindowOptions({ stateKey: Option.some("notes.main") }))) { success(_) => {} failure(_) => return 4; }
  match (attempt windows.create(WindowOptions({ stateKey: Option.some("") }))) { success(_) => return 5; failure(_) => {} }
  const rejected = rejectsRendererStateKey(inout windows);
  if (!rejected) return 14;
  const corrupt = decodeWindowStates("{");
  const future = decodeWindowStates('{"version":2,"windows":[]}');
  if (corrupt.length != 0 || future.length != 0) return 6;
  const invalid = decodeWindowStates('{"version":1,"windows":[{"key":"x","width":0,"height":2,"x":0,"y":0,"maximized":false}]}');
  const duplicate = decodeWindowStates('{"version":1,"windows":[{"key":"x","width":1,"height":2,"x":0,"y":0,"maximized":false},{"key":"x","width":1,"height":2,"x":0,"y":0,"maximized":false}]}');
  if (invalid.length != 0 || duplicate.length != 0) return 16;
  const work = Bounds({ x: -1280, y: 24, width: 1280, height: 900 });
  const position = recoveredWindowPosition(WindowPosition({ x: 9000, y: -800 }), 500, 400, work);
  if (position.x != -500 || position.y != 24) return 7;
  const oversized = recoveredWindowPosition(WindowPosition({ x: -9000, y: 9000 }), 2000, 2000, work);
  if (oversized.x != work.x || oversized.y != work.y) return 8;
  const inbox = new WindowStateInbox();
  const { sender, receiver } = Channel<boolean>.bounded(1);
  const syncReceiver = receiver.sync();
  const workerDirectory = copy directory;
  const worker = thread.spawn(move (): void => writeWindowStates(move workerDirectory, inbox, move syncReceiver));
  let store = new WindowStateStore(copy directory, inbox, sender.sync());
  match (store.find("notes.main")) { some(_) => { store.stop(); return 9; } none => {} }
  let index: u32 = 0;
  while (index < 100) {
    store.remember(SavedWindowState({ key: "notes.main", width: 700 + index, height: 460, x: -120.5, y: 48.25, maximized: true }));
    index = index + 1;
  }
  const pending = inbox.pendingCount();
  if (pending > 1) { store.stop(); return 10; }
  store.stop();
  await worker;
  const source = match (attempt fs.readText(`${directory}/window-state.json`)) { success(value) => value; failure(_) => return 11; };
  const restored = decodeWindowStates(in source);
  if (restored.length != 1 || restored[0].width != 799 || restored[0].x != -120.5 || !restored[0].maximized) return 12;
  const temporary = `${directory}/window-state.pending`;
  if (fs.exists(temporary)) return 13;
  const { sender: freshSender, receiver: freshReceiver } = Channel<boolean>.bounded(1);
  let fresh = new WindowStateStore(copy directory, new WindowStateInbox(), freshSender.sync());
  match (fresh.find("notes.main")) { some(value) => { if (value.width != 799) return 18; } none => return 19; }
  console.log("state opt-in, duplicate live keys, corrupt/version fallback, recovery, coalescing and atomic worker save passed");
  return 0;
}
