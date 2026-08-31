import { Map } from "std/collections";
import { thread } from "std/thread";
import { WindowError } from "./application-error.zs";
import {
  WindowEvents,
  createWindowEvents,
} from "./window-events.zs";

export struct WindowOptions {
  title: String = "";
  url: String = "/";
  width: u32 = 900;
  height: u32 = 640;
  visible: boolean = true;
  resizable: boolean = true;
  inject: Array<String> = Array<String>();
  capabilities: Array<String> = Array<String>("default");
}

struct WindowRecord {
  window: Window;
  options: WindowOptions;
}

internal type WindowCreateOperation = (
  in id: String,
  in options: WindowOptions
) => void throws WindowError on thread.main;

internal type WindowOperation = (
  in id: String
) => void on thread.main;

internal type WindowTitleOperation = (
  in id: String,
  in title: String
) => void on thread.main;

internal struct WindowBackend {
  create: WindowCreateOperation;
  show: WindowOperation;
  hide: WindowOperation;
  close: WindowOperation;
  setTitle: WindowTitleOperation;
}

function ignoreWindowCreate(
  in id: String,
  in options: WindowOptions
): void throws WindowError on thread.main {}

function ignoreWindowOperation(in id: String): void on thread.main {}

function ignoreWindowTitle(
  in id: String,
  in title: String
): void on thread.main {}

function inactiveWindowBackend(): WindowBackend on thread.main {
  return WindowBackend({
    create: ignoreWindowCreate,
    show: ignoreWindowOperation,
    hide: ignoreWindowOperation,
    close: ignoreWindowOperation,
    setTitle: ignoreWindowTitle,
  });
}

export readonly class Window on thread.main {
  readonly id: String;
  readonly events: WindowEvents;
  internal readonly manager: Weak<WindowManager>;

  internal constructor(
    id: String,
    manager: Weak<WindowManager>
  ) {
    this.id = move id;
    this.events = createWindowEvents();
    this.manager = manager;
  }

  function show(): void on thread.main {
    const id = copy this.id;
    const current = attempt this.manager.upgrade();
    match (current) {
      success(manager) => manager.show(in id);
      failure(_) => {}
    }
  }

  function hide(): void on thread.main {
    const id = copy this.id;
    const current = attempt this.manager.upgrade();
    match (current) {
      success(manager) => manager.hide(in id);
      failure(_) => {}
    }
  }

  function close(): void on thread.main {
    const id = copy this.id;
    const current = attempt this.manager.upgrade();
    match (current) {
      success(manager) => manager.close(in id);
      failure(_) => {}
    }
  }

  function setTitle(title: String): void on thread.main {
    const id = copy this.id;
    const current = attempt this.manager.upgrade();
    match (current) {
      success(manager) => manager.setTitle(in id, move title);
      failure(_) => {}
    }
  }
}

class WindowManagerState on thread.main {
  windows: Map<String, WindowRecord>;
  nextId: u64;
  backend: WindowBackend;
  active: boolean;

  function create(
    inout this,
    owner: Weak<WindowManager>,
    options: WindowOptions
  ): Window throws WindowError {
    const id = `win-${this.nextId}`;
    this.nextId = this.nextId + 1;
    const window = new Window(copy id, owner);
    if (this.active) try this.backend.create(in id, in options);
    this.windows.set(
      move id,
      WindowRecord({
        window,
        options,
      })
    );
    return window;
  }

  function get(in id: String): Option<Window> {
    const found = this.windows.get(id);
    return match (in found) {
      some(record) => Option.some(record.window);
      none => Option.none;
    };
  }

  function all(): Array<Window> {
    let result = Array<Window>();
    for (const entry of this.windows) {
      let retained = entry.value.window;
      result.push(move retained);
    }
    return result;
  }

  function show(inout this, in id: String): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        current.options.visible = true;
        if (this.active) this.backend.show(in id);
        this.windows.set(copy id, move current);
      }
      none => {}
    }
  }

  function hide(inout this, in id: String): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        current.options.visible = false;
        if (this.active) this.backend.hide(in id);
        this.windows.set(copy id, move current);
      }
      none => {}
    }
  }

  function close(inout this, in id: String): void {
    if (this.active && this.windows.has(id)) {
      this.backend.close(in id);
      return;
    }
    if (this.closeRequestedNative(in id)) this.closedNative(in id);
  }

  function closeRequestedNative(
    inout this,
    in id: String
  ): boolean {
    const found = this.get(in id);
    return match (found) {
      some(window) => {
        let events = window.events;
        select events.publishCloseRequested(in id);
      }
      none => true;
    };
  }

  function closedNative(inout this, in id: String): void {
    const removed = this.windows.remove(id);
    match (removed) {
      some(record) => {
        let events = record.window.events;
        events.publishClosed(in id);
      }
      none => {}
    }
  }

  function focusedNative(inout this, in id: String): void {
    const found = this.get(in id);
    match (found) {
      some(window) => {
        let events = window.events;
        events.publishFocused(in id);
      }
      none => {}
    }
  }

  function blurredNative(inout this, in id: String): void {
    const found = this.get(in id);
    match (found) {
      some(window) => {
        let events = window.events;
        events.publishBlurred(in id);
      }
      none => {}
    }
  }

  function resizedNative(
    inout this,
    in id: String,
    width: u32,
    height: u32
  ): void {
    const found = this.get(in id);
    match (found) {
      some(window) => {
        let events = window.events;
        events.publishResized(in id, width, height);
      }
      none => {}
    }
  }

  function setTitle(
    inout this,
    in id: String,
    title: String
  ): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        if (this.active) this.backend.setTitle(in id, in title);
        current.options.title = move title;
        this.windows.set(copy id, move current);
      }
      none => {}
    }
  }

  function options(in id: String): Option<WindowOptions> {
    const found = this.windows.get(id);
    return match (in found) {
      some(record) => Option.some(copy record.options);
      none => Option.none;
    };
  }

  function start(
    inout this,
    backend: WindowBackend,
    realizePending: boolean
  ): void throws WindowError {
    this.backend = backend;
    this.active = true;
    if (!realizePending) return;
    for (const entry of this.windows) {
      const id = copy entry.value.window.id;
      const options = copy entry.value.options;
      try this.backend.create(in id, in options);
    }
  }

  function stop(inout this): void {
    this.active = false;
    this.backend = inactiveWindowBackend();
  }
}

function createWindowManagerState(): WindowManagerState on thread.main {
  return new WindowManagerState({
    windows: Map<String, WindowRecord>(),
    nextId: 1,
    backend: inactiveWindowBackend(),
    active: false,
  });
}

export readonly class WindowManager on thread.main {
  internal readonly state: WindowManagerState;

  internal constructor() {
    this.state = createWindowManagerState();
  }

  function create(
    inout this,
    options: WindowOptions
  ): Window throws WindowError on thread.main {
    const owner = weak this;
    return try this.state.create(owner, options);
  }

  function get(in id: String): Option<Window> on thread.main {
    return this.state.get(in id);
  }

  function all(): Array<Window> on thread.main {
    return this.state.all();
  }

  internal function show(inout this, in id: String): void on thread.main {
    this.state.show(in id);
  }

  internal function hide(inout this, in id: String): void on thread.main {
    this.state.hide(in id);
  }

  internal function close(inout this, in id: String): void on thread.main {
    this.state.close(in id);
  }

  internal function closedNative(inout this, in id: String): void on thread.main {
    this.state.closedNative(in id);
  }

  internal function closeRequestedNative(
    inout this,
    in id: String
  ): boolean on thread.main {
    return this.state.closeRequestedNative(in id);
  }

  internal function focusedNative(inout this, in id: String): void on thread.main {
    this.state.focusedNative(in id);
  }

  internal function blurredNative(inout this, in id: String): void on thread.main {
    this.state.blurredNative(in id);
  }

  internal function resizedNative(
    inout this,
    in id: String,
    width: u32,
    height: u32
  ): void on thread.main {
    this.state.resizedNative(in id, width, height);
  }

  internal function setTitle(
    inout this,
    in id: String,
    title: String
  ): void on thread.main {
    this.state.setTitle(in id, move title);
  }

  internal function options(
    in id: String
  ): Option<WindowOptions> on thread.main {
    return this.state.options(in id);
  }

  internal function start(
    inout this,
    backend: WindowBackend,
    realizePending: boolean
  ): void throws WindowError on thread.main {
    try this.state.start(backend, realizePending);
  }

  internal function stop(inout this): void on thread.main {
    this.state.stop();
  }
}

internal function createWindowManager(): WindowManager on thread.main {
  return new WindowManager();
}
