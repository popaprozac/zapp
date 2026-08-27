import { Map } from "std/collections";
import { thread } from "std/thread";

export struct WindowOptions {
  title: String = "";
  url: String = "/";
  width: u32 = 900;
  height: u32 = 640;
  visible: boolean = true;
  resizable: boolean = true;
}

struct WindowRecord {
  window: Window;
  options: WindowOptions;
}

export type WindowCreateOperation = (
  in id: String,
  in options: WindowOptions
) => void on thread.main;

export type WindowOperation = (
  in id: String
) => void on thread.main;

export type WindowTitleOperation = (
  in id: String,
  in title: String
) => void on thread.main;

export struct WindowBackend {
  create: WindowCreateOperation;
  show: WindowOperation;
  hide: WindowOperation;
  close: WindowOperation;
  setTitle: WindowTitleOperation;
}

function ignoreWindowCreate(
  in id: String,
  in options: WindowOptions
): void on thread.main {}

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

export readonly class Window {
  readonly id: String;
  readonly __manager: Weak<WindowManager>;

  static function __create(
    id: String,
    manager: Weak<WindowManager>
  ): Window on thread.main {
    return new Window({
      id: move id,
      __manager: manager,
    });
  }

  function show(): void on thread.main {
    const id = copy this.id;
    const current = attempt this.__manager.upgrade();
    match (current) {
      success(manager) => manager.__show(in id);
      failure(_) => {}
    }
  }

  function hide(): void on thread.main {
    const id = copy this.id;
    const current = attempt this.__manager.upgrade();
    match (current) {
      success(manager) => manager.__hide(in id);
      failure(_) => {}
    }
  }

  function close(): void on thread.main {
    const id = copy this.id;
    const current = attempt this.__manager.upgrade();
    match (current) {
      success(manager) => manager.__close(in id);
      failure(_) => {}
    }
  }

  function setTitle(title: String): void on thread.main {
    const id = copy this.id;
    const current = attempt this.__manager.upgrade();
    match (current) {
      success(manager) => manager.__setTitle(in id, move title);
      failure(_) => {}
    }
  }
}

class WindowManagerState on thread.main {
  windows: Map<String, WindowRecord>;
  nextId: u64;
  backend: WindowBackend;
  active: boolean;

  static function __create(): WindowManagerState on thread.main {
    return new WindowManagerState({
      windows: Map<String, WindowRecord>(),
      nextId: 1,
      backend: inactiveWindowBackend(),
      active: false,
    });
  }

  function create(
    inout this,
    owner: Weak<WindowManager>,
    options: WindowOptions
  ): Window {
    const id = `win-${this.nextId}`;
    this.nextId = this.nextId + 1;
    const window = Window.__create(copy id, owner);
    if (this.active) this.backend.create(in id, in options);
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
      result.push(entry.value.window);
    }
    return result;
  }

  function __show(inout this, in id: String): void {
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

  function __hide(inout this, in id: String): void {
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

  function __close(inout this, in id: String): void {
    if (this.active && this.windows.has(id)) {
      this.backend.close(in id);
    }
    this.windows.delete(id);
  }

  function __setTitle(
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

  function __options(in id: String): Option<WindowOptions> {
    const found = this.windows.get(id);
    return match (in found) {
      some(record) => Option.some(copy record.options);
      none => Option.none;
    };
  }

  function __start(
    inout this,
    backend: WindowBackend,
    realizePending: boolean
  ): void {
    this.backend = backend;
    this.active = true;
    if (!realizePending) return;
    for (const entry of this.windows) {
      const id = copy entry.value.window.id;
      const options = copy entry.value.options;
      this.backend.create(in id, in options);
    }
  }

  function __stop(inout this): void {
    this.active = false;
    this.backend = inactiveWindowBackend();
  }
}

export readonly class WindowManager on thread.main {
  readonly __state: WindowManagerState;

  static function __create(): WindowManager on thread.main {
    return new WindowManager({ __state: WindowManagerState.__create() });
  }

  function create(inout this, options: WindowOptions): Window on thread.main {
    const owner = weak this;
    return this.__state.create(owner, options);
  }

  function get(in id: String): Option<Window> on thread.main {
    return this.__state.get(in id);
  }

  function all(): Array<Window> on thread.main {
    return this.__state.all();
  }

  function __show(inout this, in id: String): void on thread.main {
    this.__state.__show(in id);
  }

  function __hide(inout this, in id: String): void on thread.main {
    this.__state.__hide(in id);
  }

  function __close(inout this, in id: String): void on thread.main {
    this.__state.__close(in id);
  }

  function __setTitle(
    inout this,
    in id: String,
    title: String
  ): void on thread.main {
    this.__state.__setTitle(in id, move title);
  }

  function __options(
    in id: String
  ): Option<WindowOptions> on thread.main {
    return this.__state.__options(in id);
  }

  function __start(
    inout this,
    backend: WindowBackend,
    realizePending: boolean
  ): void on thread.main {
    this.__state.__start(backend, realizePending);
  }

  function __stop(inout this): void on thread.main {
    this.__state.__stop();
  }
}

export function createWindowManager(): WindowManager on thread.main {
  return WindowManager.__create();
}
