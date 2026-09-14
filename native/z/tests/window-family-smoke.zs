import { Window, WindowManager, WindowOptions, WindowBackend, WindowCreateOperation,
  WindowOperation, WindowTitleOperation, createWindowManager } from "../framework/window.zs";
import { WindowCloseRequestedEvent, WindowClosedEvent } from "../framework/events.zs";
import { WindowEventSubscription } from "../framework/window-events.zs";
import { thread } from "std/thread";

function verify(value: boolean, code: i32): void throws i32 { if (!value) throw code; }
function count(windows: WindowManager): usize on thread.main { const all = windows.all(); return all.length; }
function present(windows: WindowManager, in id: String): boolean on thread.main {
  return match (windows.get(in id)) { some(_) => true; none => false; };
}
function adopt(windows: WindowManager, parent: Window, id: String): Window throws i32 on thread.main {
  return match (windows.adoptRelatedNative(parent, move id, WindowOptions())) { some(value) => value; none => throw 90; };
}
function create(windows: WindowManager): Window throws i32 on thread.main {
  return match (attempt windows.create(WindowOptions())) { success(value) => value; failure(_) => throw 91; };
}
class Probe on thread.main {
  commits: i32;
  requests: i32;
  closed: i32;
  veto: boolean;
  reenter: boolean;
  mode: i32;
  clean: boolean;
}
function probe(): Probe on thread.main {
  return new Probe({ commits: 0, requests: 0, closed: 0, veto: true, reenter: false, mode: 0, clean: true });
}
function start(windows: WindowManager, probe: Probe): void throws i32 on thread.main {
  const owner = weak windows;
  const create: WindowCreateOperation = (in id: String, in options): void => {};
  const ignore: WindowOperation = (in id: String): void => {};
  const title: WindowTitleOperation = (in id: String, in title: String): void => {};
  const state: (in id: String, value: boolean) => void on thread.main = (in id: String, value: boolean): void => {};
  const close: WindowOperation = move (in id: String): void => {
    const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    if (windows.closeRequestedNative(in id)) { probe.commits = probe.commits + 1; windows.closedNative(in id); }
  };
  match (attempt windows.start(WindowBackend({ create, show: ignore, focus: ignore, hide: ignore,
    minimize: ignore, unminimize: ignore, setMaximized: state, setFullscreen: state, close, setTitle: title }), false)) {
    success => {} failure(_) => throw 92;
  }
}

function checkFamily(): void throws i32 on thread.main {
  const windows = createWindowManager(); const state = probe(); try start(windows, state);
  const root = try create(windows);
  const child = try adopt(windows, root, "child");
  const grandchild = try adopt(windows, child, "grandchild");
  const sibling = try adopt(windows, root, "sibling");
  const other = try create(windows);
  const owner = weak windows;
  let subscriptions = Array<WindowEventSubscription>();
  const all = windows.all();
  for (const borrowed of all) {
    const window: Window = borrowed;
    const request = match (attempt window.events.closeRequested.subscribe(move (in event: WindowCloseRequestedEvent): void => {
      state.requests = state.requests + 1;
      if (state.veto && event.windowId == "child") event.cancel();
      if (state.reenter) {
        const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
        const id = "win-1";
        match (windows.get(in id)) { some(root) => root.close(); none => {} }
        const childId = "child";
        match (windows.get(in childId)) { some(child) => child.close(); none => {} }
      }
    })) { success(value) => value; failure(_) => throw 93; };
    subscriptions.push(request);
    const closed = match (attempt window.events.closed.subscribe(move (in event: WindowClosedEvent): void => {
      state.closed = state.closed + 1;
      const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
      if (count(windows) != 1 || present(windows, "win-1") || present(windows, "child")
        || present(windows, "grandchild") || present(windows, "sibling")) state.clean = false;
      windows.closedNative(in event.windowId);
    })) { success(value) => value; failure(_) => throw 94; };
    subscriptions.push(closed);
  }
  root.close();
  try verify(state.commits == 0 && state.closed == 0 && count(windows) == 5, 1);
  const before = state.requests;
  child.close();
  try verify(state.requests == before + 1 && count(windows) == 5 && state.commits == 0, 2);
  state.veto = false; state.reenter = true; state.requests = 0;
  root.close();
  try verify(state.requests == 4 && state.commits == 1 && state.closed == 4 && state.clean, 3);
  try verify(count(windows) == 1 && present(windows, in other.id), 4);
  match (windows.adoptRelatedNative(root, "late", WindowOptions())) { some(_) => throw 5; none => {} }
  const foreign = createWindowManager(); const firstForeign = try create(foreign); const foreignRoot = try create(foreign);
  try verify(foreignRoot.id == other.id, 7);
  match (windows.adoptRelatedNative(foreignRoot, "foreign", WindowOptions())) { some(_) => throw 6; none => {} }
}

function checkMutation(mode: i32): void throws i32 on thread.main {
  const windows = createWindowManager(); const state = probe(); state.mode = mode; try start(windows, state);
  const root = try create(windows); const child = try adopt(windows, root, "child");
  const owner = weak windows;
  const request = match (attempt root.events.closeRequested.subscribe(move (in event: WindowCloseRequestedEvent): void => {
    const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    const parent = match (windows.get(in event.windowId)) { some(value) => value; none => return; };
    const mutation = state.mode; state.mode = 0;
    if (mutation == 1) { match (windows.adoptRelatedNative(parent, "new-child", WindowOptions())) { some(_) => {} none => { state.clean = false; } } }
    if (mutation == 2) {
      const id = "child"; windows.closedNative(in id);
      match (windows.adoptRelatedNative(parent, "child", WindowOptions())) { some(_) => {} none => { state.clean = false; } }
    }
    if (mutation == 3) windows.stop();
  })) { success(value) => value; failure(_) => throw 95; };
  root.close();
  try verify(state.clean && state.commits == 0 && present(windows, in root.id), 10 + mode);
  if (mode == 1 || mode == 2) {
    root.close();
    try verify(state.commits == 1 && count(windows) == 0, 20 + mode);
  }
}

function main(): i32 on thread.main {
  return match (attempt run()) { success => 0; failure(code) => code; };
}
function run(): void throws i32 on thread.main {
  try checkFamily(); try checkMutation(1); try checkMutation(2); try checkMutation(3);
}
