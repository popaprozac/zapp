import { Map } from "std/collections";
import { WindowPresentationState } from "./window-presentation.zs";
import { TitleBarOptions } from "./window-titlebar.zs";
import { thread } from "std/thread";
import { WindowError } from "./application-error.zs";
import { Menu, MenuError } from "./menu.zs";
import { ContextMenuOptions } from "./context-menu.zs";
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
  titleBar: TitleBarOptions = TitleBarOptions();
  inject: Array<String> = Array<String>();
  capabilities: Array<String> = Array<String>("default");
  navigation: String = "default";
}

struct WindowRecord {
  window: Window;
  options: WindowOptions;
  relatedOwner: Option<Window> = Option<Window>.none;
  pendingMinimize: boolean = false;
  presentation: WindowPresentationState = WindowPresentationState();
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

internal type WindowBooleanOperation = (
  in id: String,
  value: boolean
) => void on thread.main;

internal struct WindowBackend {
  create: WindowCreateOperation;
  show: WindowOperation;
  focus: WindowOperation;
  minimize: WindowOperation;
  unminimize: WindowOperation;
  setMaximized: WindowBooleanOperation;
  setFullscreen: WindowBooleanOperation;
  hide: WindowOperation;
  close: WindowOperation;
  setTitle: WindowTitleOperation;
  showContextMenu: WindowContextMenuOperation = unavailableContextMenu;
}

internal type WindowContextMenuOperation = (
  in id: String,
  in menu: Menu,
  options: ContextMenuOptions
) => void throws MenuError on thread.main;

function unavailableContextMenu(
  in id: String,
  in menu: Menu,
  options: ContextMenuOptions
): void throws MenuError on thread.main {
  throw MenuError({ message: "context menus require an active native window" });
}

function ignoreWindowCreate(
  in id: String,
  in options: WindowOptions
): void throws WindowError on thread.main {}

function ignoreWindowOperation(in id: String): void on thread.main {}
function ignoreWindowBoolean(in id: String, value: boolean): void on thread.main {}

function ignoreWindowTitle(
  in id: String,
  in title: String
): void on thread.main {}

function inactiveWindowBackend(): WindowBackend on thread.main {
  return WindowBackend({
    create: ignoreWindowCreate,
    show: ignoreWindowOperation,
    focus: ignoreWindowOperation,
    minimize: ignoreWindowOperation,
    unminimize: ignoreWindowOperation,
    setMaximized: ignoreWindowBoolean,
    setFullscreen: ignoreWindowBoolean,
    hide: ignoreWindowOperation,
    close: ignoreWindowOperation,
    setTitle: ignoreWindowTitle,
  });
}

export readonly class Window on thread.main {
  readonly id: String;
  readonly events: WindowEvents;
  internal readonly manager: Weak<WindowManager>;

  async function showContextMenu(
    in menu: Menu,
    options: ContextMenuOptions
  ): void throws MenuError on thread.main {
    try this.presentContextMenu(in menu, options);
  }

  internal function presentContextMenu(
    in menu: Menu,
    options: ContextMenuOptions
  ): void throws MenuError on thread.main {
    const owner = attempt this.manager.upgrade();
    match (owner) {
      success(manager) => try manager.showContextMenu(in this.id, in menu, options);
      failure(_) => throw MenuError({ message: "context menu window is no longer available" });
    }
  }

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

  // Reveal/restore this window and request foreground keyboard focus. The OS
  // decides activation; the native delegate, not this request, emits focused.
  function focus(): void on thread.main {
    const id = copy this.id;
    const current = attempt this.manager.upgrade();
    match (current) {
      success(manager) => manager.focus(in id);
      failure(_) => {}
    }
  }

  function minimize(): void on thread.main {
    const id = copy this.id;
    match (attempt this.manager.upgrade()) {
      success(manager) => manager.minimize(in id);
      failure(_) => {}
    }
  }

  function unminimize(): void on thread.main {
    const id = copy this.id;
    match (attempt this.manager.upgrade()) {
      success(manager) => manager.unminimize(in id);
      failure(_) => {}
    }
  }

  function maximize(): void on thread.main {
    const id = copy this.id;
    match (attempt this.manager.upgrade()) {
      success(manager) => manager.setMaximized(in id, true);
      failure(_) => {}
    }
  }

  function unmaximize(): void on thread.main {
    const id = copy this.id;
    match (attempt this.manager.upgrade()) {
      success(manager) => manager.setMaximized(in id, false);
      failure(_) => {}
    }
  }

  function setFullscreen(value: boolean): void on thread.main {
    const id = copy this.id;
    match (attempt this.manager.upgrade()) {
      success(manager) => manager.setFullscreen(in id, value);
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
  pendingFocus: String;
  preflighting: Array<Window>;

  function adoptNative(inout this, owner: Weak<WindowManager>, id: String, options: WindowOptions,
    relatedOwner: Option<Window>): Option<Window> {
    if (!this.active || id == "" || this.windows.has(id)) return Option.none;
    match (in relatedOwner) {
      some(parent) => {
        const current = this.get(in parent.id);
        match (current) { some(value) => { if (value != parent) return Option.none; } none => return Option.none; }
      }
      none => {}
    }
    const window = new Window(copy id, owner);
    this.windows.set(move id, WindowRecord({ window, options: move options, relatedOwner }));
    return Option.some(window);
  }

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
        this.windows.set(copy id, move current);
        if (this.active) this.backend.show(in id);
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
        this.windows.set(copy id, move current);
        if (this.pendingFocus == id) this.pendingFocus = "";
        if (this.active) this.backend.hide(in id);
      }
      none => {}
    }
  }

  function focus(inout this, in id: String): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        current.options.visible = true;
        current.pendingMinimize = false;
        // Native focus can synchronously deliver events (and user callbacks).
        // Restore the record first; never overwrite callback changes afterward.
        this.windows.set(copy id, move current);
        if (this.active) {
          this.pendingFocus = "";
          this.backend.focus(in id);
        } else this.pendingFocus = copy id;
      }
      none => {}
    }
  }

  function minimize(inout this, in id: String): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        current.pendingMinimize = !this.active;
        this.windows.set(copy id, move current);
        if (this.pendingFocus == id) this.pendingFocus = "";
        if (this.active) this.backend.minimize(in id);
      }
      none => {}
    }
  }

  function unminimize(inout this, in id: String): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        current.pendingMinimize = false;
        this.windows.set(copy id, move current);
        if (this.active) this.backend.unminimize(in id);
      }
      none => {}
    }
  }


  function setMaximized(inout this, in id: String, value: boolean): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        current.presentation.requestMaximized(value);
        this.windows.set(copy id, move current);
        this.drivePresentation(in id);
      }
      none => {}
    }
  }

  function setFullscreen(inout this, in id: String, value: boolean): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        current.presentation.requestFullscreen(value);
        this.windows.set(copy id, move current);
        this.drivePresentation(in id);
      }
      none => {}
    }
  }

  function drivePresentation(inout this, in id: String): void {
    if (!this.active) return;
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        const fullscreen = current.presentation.takeFullscreenRequest();
        const maximized = current.presentation.takeMaximizedRequest();
        this.windows.set(copy id, move current);
        match (fullscreen) {
          some(value) => { this.backend.setFullscreen(in id, value); return; }
          none => {}
        }
        match (maximized) {
          some(value) => this.backend.setMaximized(in id, value);
          none => {}
        }
      }
      none => {}
    }
  }

  function fullscreenWillChangeNative(inout this, in id: String): void {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        current.presentation.beginFullscreen();
        this.windows.set(copy id, move current);
      }
      none => {}
    }
  }

  function fullscreenChangedNative(inout this, in id: String, value: boolean): boolean {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        const changed = current.presentation.completeFullscreen(value);
        const window = current.window;
        this.windows.set(copy id, move current);
        if (changed) {
          if (value) window.events.publishFullscreenEntered(in id);
          else window.events.publishFullscreenExited(in id);
        }
        // Subscribers can close the window or enqueue a newer desired state.
        this.drivePresentation(in id);
        return changed;
      }
      none => return false;
    }
  }

  function maximizedChangedNative(inout this, in id: String, value: boolean): boolean {
    const found = this.windows.remove(id);
    match (found) {
      some(record) => {
        let current = record;
        const changed = current.presentation.observeMaximized(value);
        const window = current.window;
        this.windows.set(copy id, move current);
        if (changed) {
          if (value) window.events.publishMaximized(in id);
          else window.events.publishUnmaximized(in id);
        }
        return changed;
      }
      none => return false;
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
    const family = this.closeFamily(in id);
    if (family.length == 0) return true;
    for (const window of family) {
      for (const pending of this.preflighting) {
        if (window == pending) return false;
      }
    }
    for (const window of family) { this.preflighting.push(window); }
    const active = this.active;
    let allowed = true;
    for (const window of family) {
      if (!window.events.publishCloseRequested(in window.id)
        || this.active != active || !this.sameCloseFamily(in id, in family)) {
        allowed = false;
        break;
      }
    }
    let remaining = Array<Window>();
    for (const pending of this.preflighting) {
      let included = false;
      for (const window of family) { if (window == pending) included = true; }
      if (!included) remaining.push(pending);
    }
    this.preflighting = move remaining;
    return allowed;
  }

  // Snapshot owned window identities before callbacks. Parentage can only be
  // assigned at native adoption, against a still-live owner, so it is acyclic.
  private function closeFamily(in id: String): Array<Window> {
    let family = Array<Window>();
    match (this.get(in id)) { some(window) => family.push(window); none => return family; }
    let index: usize = 0;
    while (index < family.length) {
      const parent: Window = family[index];
      for (const entry of this.windows) {
        match (in entry.value.relatedOwner) {
          some(owner) => { if (owner == parent) family.push(entry.value.window); }
          none => {}
        }
      }
      index = index + 1;
    }
    return family;
  }

  private function sameCloseFamily(in id: String, in expected: Array<Window>): boolean {
    const current = this.closeFamily(in id);
    if (current.length != expected.length) return false;
    for (const window of expected) {
      let found = false;
      for (const candidate of current) { if (window == candidate) found = true; }
      if (!found) return false;
    }
    return true;
  }

  function closedNative(inout this, in id: String): void {
    // Committed closure is not another preflight. Remove the complete logical
    // subtree before user callbacks; native routing retirement happens first.
    const family = this.closeFamily(in id);
    for (const window of family) {
      if (this.pendingFocus == window.id) this.pendingFocus = "";
      this.windows.delete(window.id);
    }
    let index = family.length;
    while (index > 0) {
      index = index - 1;
      const window: Window = family[index];
      window.events.publishClosed(in window.id);
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

  function minimizedNative(inout this, in id: String): void {
    match (this.get(in id)) {
      some(window) => window.events.publishMinimized(in id);
      none => {}
    }
  }

  function unminimizedNative(inout this, in id: String): void {
    match (this.get(in id)) {
      some(window) => window.events.publishUnminimized(in id);
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

  function navigationRequestedNative(
    inout this,
    in id: String,
    in url: String,
    mainFrame: boolean,
    allowedByProfile: boolean
  ): boolean {
    const found = this.get(in id);
    return match (found) {
      some(window) => {
        let events = window.events;
        select events.publishNavigationRequested(
          in id,
          in url,
          mainFrame,
          allowedByProfile
        );
      }
      none => false;
    };
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
    // Snapshot handles; do not keep a Map view across native callbacks.
    const pending = this.all();
    for (const window of pending) {
      const id = copy window.id;
      const found = this.options(in id);
      match (found) {
        some(options) => {
          try this.backend.create(in id, in options);
          // Creation may have closed the window or issued a newer request.
          // Read and consume pending state only after its callbacks finish.
          const latest = this.windows.remove(id);
          match (latest) {
            some(record) => {
              let current = record;
              const minimize = current.pendingMinimize;
              current.pendingMinimize = false;
              this.windows.set(copy id, move current);
              if (minimize) this.backend.minimize(in id);
              this.drivePresentation(in id);
            }
            none => {}
          }
        }
        none => {}
      }
    }
    const requestedFocus = copy this.pendingFocus;
    this.pendingFocus = "";
    if (this.windows.has(requestedFocus)) this.backend.focus(in requestedFocus);
  }

  function stop(inout this): void {
    this.active = false;
    this.pendingFocus = "";
    this.backend = inactiveWindowBackend();
  }
}

function createWindowManagerState(): WindowManagerState on thread.main {
  return new WindowManagerState({
    windows: Map<String, WindowRecord>(),
    nextId: 1,
    backend: inactiveWindowBackend(),
    active: false,
    pendingFocus: "",
    preflighting: Array<Window>(),
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

  // Adopt a platform-created, ready window without allocating another native
  // window. Only the platform coordinator assigns these ids; renderer input
  // must never select one. Adoption publishes no callbacks.
  internal function adoptNative(inout this, id: String, options: WindowOptions): Option<Window> on thread.main {
    return this.state.adoptNative(weak this, move id, move options, Option<Window>.none);
  }

  internal function adoptRelatedNative(inout this, parent: Window, id: String,
    options: WindowOptions): Option<Window> on thread.main {
    return this.state.adoptNative(weak this, move id, move options, Option.some(parent));
  }

  internal function showContextMenu(
    in id: String,
    in menu: Menu,
    options: ContextMenuOptions
  ): void throws MenuError on thread.main {
    if (!this.state.active || !this.state.windows.has(id)) {
      throw MenuError({ message: "context menu window is no longer available" });
    }
    try this.state.backend.showContextMenu(in id, in menu, options);
  }

  function all(): Array<Window> on thread.main {
    return this.state.all();
  }

  internal function show(inout this, in id: String): void on thread.main {
    this.state.show(in id);
  }

  internal function focus(inout this, in id: String): void on thread.main {
    this.state.focus(in id);
  }

  internal function minimize(inout this, in id: String): void on thread.main {
    this.state.minimize(in id);
  }

  internal function unminimize(inout this, in id: String): void on thread.main {
    this.state.unminimize(in id);
  }

  internal function minimizedNative(inout this, in id: String): void on thread.main {
    this.state.minimizedNative(in id);
  }

  internal function unminimizedNative(inout this, in id: String): void on thread.main {
    this.state.unminimizedNative(in id);
  }

  internal function setMaximized(inout this, in id: String, value: boolean): void on thread.main {
    this.state.setMaximized(in id, value);
  }

  internal function setFullscreen(inout this, in id: String, value: boolean): void on thread.main {
    this.state.setFullscreen(in id, value);
  }

  internal function fullscreenWillChangeNative(inout this, in id: String): void on thread.main {
    this.state.fullscreenWillChangeNative(in id);
  }

  internal function fullscreenChangedNative(inout this, in id: String, value: boolean): boolean on thread.main {
    return this.state.fullscreenChangedNative(in id, value);
  }

  internal function maximizedChangedNative(inout this, in id: String, value: boolean): boolean on thread.main {
    return this.state.maximizedChangedNative(in id, value);
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

  internal function navigationRequestedNative(
    inout this,
    in id: String,
    in url: String,
    mainFrame: boolean,
    allowedByProfile: boolean
  ): boolean on thread.main {
    return this.state.navigationRequestedNative(
      in id,
      in url,
      mainFrame,
      allowedByProfile
    );
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
