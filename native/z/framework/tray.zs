import embed from "std/embed";
import { Map } from "std/collections";
import { thread } from "std/thread";
import { Menu, MenuItem } from "./menu.zs";

export struct TrayError {
  id: String;
  message: String;
}

export struct TrayOptions {
  icon: embed.StaticBytes;
  template: boolean = false;
  tooltip: String = "";
  menu: Menu;
}

internal type TrayCreateOperation = (in id: String, in options: TrayOptions) => void throws TrayError on thread.main;
internal type TrayMenuOperation = (in id: String, in menu: Menu) => void throws TrayError on thread.main;
internal type TrayTooltipOperation = (in id: String, in tooltip: String) => void throws TrayError on thread.main;
internal type TrayRemoveOperation = (in id: String) => void on thread.main;
internal type TrayStopOperation = () => void on thread.main;

internal struct TrayBackend {
  create: TrayCreateOperation;
  setMenu: TrayMenuOperation;
  setTooltip: TrayTooltipOperation;
  remove: TrayRemoveOperation;
  stop: TrayStopOperation;
}

function unavailableCreate(in id: String, in options: TrayOptions): void throws TrayError on thread.main {
  throw TrayError({ id: copy id, message: "trays are unavailable on the active platform" });
}
function unavailableMenu(in id: String, in menu: Menu): void throws TrayError on thread.main {
  throw TrayError({ id: copy id, message: "tray is not active" });
}
function unavailableTooltip(in id: String, in tooltip: String): void throws TrayError on thread.main {
  throw TrayError({ id: copy id, message: "tray is not active" });
}
function ignoreRemove(in id: String): void on thread.main {}
function ignoreStop(): void on thread.main {}

internal function unsupportedTrayBackend(): TrayBackend on thread.main {
  return TrayBackend({ create: unavailableCreate, setMenu: unavailableMenu,
    setTooltip: unavailableTooltip, remove: ignoreRemove, stop: ignoreStop });
}

function validateTrayMenu(in id: String, in items: Array<MenuItem>): void throws TrayError on thread.main {
  for (const item of items) {
    match (in item) {
      command(command) => if (command.label.byteLength == 0) {
        throw TrayError({ id: copy id, message: "tray command labels cannot be empty" });
      }
      submenu(group) => {
        if (group.label.byteLength == 0) throw TrayError({ id: copy id, message: "tray submenu labels cannot be empty" });
        try validateTrayMenu(in id, in group.items);
      }
      separator => {}
      role(_) => throw TrayError({ id: copy id, message: "tray menus currently accept commands, submenus, and separators" });
    }
  }
}

// A handle is not the native owner. The application registry retains the tray
// until remove() or shutdown; the weak backreference prevents a manager cycle.
export readonly class Tray on thread.main {
  readonly id: String;
  internal readonly manager: Weak<TrayManager>;

  internal constructor(id: String, manager: Weak<TrayManager>) {
    this.id = move id;
    this.manager = manager;
  }

  function setMenu(menu: Menu): void throws TrayError {
    const owner = attempt this.manager.upgrade();
    match (owner) {
      success(manager) => try manager.setMenu(in this.id, move menu);
      failure(_) => throw TrayError({ id: copy this.id, message: "tray has been removed" });
    }
  }

  function setTooltip(tooltip: String): void throws TrayError {
    const owner = attempt this.manager.upgrade();
    match (owner) {
      success(manager) => try manager.setTooltip(in this.id, move tooltip);
      failure(_) => throw TrayError({ id: copy this.id, message: "tray has been removed" });
    }
  }

  function remove(): void {
    const owner = attempt this.manager.upgrade();
    match (owner) {
      success(manager) => manager.remove(in this.id);
      failure(_) => {}
    }
  }
}

struct TrayRecord {
  tray: Tray;
  options: TrayOptions;
}

class TrayManagerState on thread.main {
  records: Map<String, TrayRecord>;
  nextId: u64;
  backend: TrayBackend;
  active: boolean;
  stopped: boolean;

  function create(inout this, owner: Weak<TrayManager>, options: TrayOptions): Tray throws TrayError {
    if (this.stopped) throw TrayError({ id: "", message: "cannot create a tray after application shutdown" });
    if (options.icon.length == 0) throw TrayError({ id: "", message: "tray icon bytes cannot be empty" });
    try validateTrayMenu("", in options.menu.items);
    const id = `tray-${this.nextId}`;
    this.nextId = this.nextId + 1;
    const tray = new Tray(copy id, owner);
    if (this.active) try this.backend.create(in id, in options);
    this.records.set(move id, TrayRecord({ tray, options: move options }));
    return tray;
  }

  function get(in id: String): Option<Tray> {
    const found = this.records.get(id);
    return match (in found) { some(record) => Option.some(record.tray); none => Option.none; };
  }

  function all(): Array<Tray> {
    let result = Array<Tray>();
    for (const entry of this.records) {
      let tray = entry.value.tray;
      result.push(move tray);
    }
    return result;
  }

  function setMenu(inout this, in id: String, menu: Menu): void throws TrayError {
    try validateTrayMenu(in id, in menu.items);
    const found = this.records.remove(id);
    match (found) {
      some(value) => {
        let record = value;
        if (this.active) {
          const updated = attempt this.backend.setMenu(in id, in menu);
          match (updated) {
            success => {}
            failure(error) => { this.records.set(copy id, move record); throw error; }
          }
        }
        record.options.menu = move menu;
        this.records.set(copy id, move record);
      }
      none => throw TrayError({ id: copy id, message: "tray has been removed" });
    }
  }

  function setTooltip(inout this, in id: String, tooltip: String): void throws TrayError {
    const found = this.records.remove(id);
    match (found) {
      some(value) => {
        let record = value;
        if (this.active) {
          const updated = attempt this.backend.setTooltip(in id, in tooltip);
          match (updated) {
            success => {}
            failure(error) => { this.records.set(copy id, move record); throw error; }
          }
        }
        record.options.tooltip = move tooltip;
        this.records.set(copy id, move record);
      }
      none => throw TrayError({ id: copy id, message: "tray has been removed" });
    }
  }

  function remove(inout this, in id: String): void {
    if (!this.records.has(id)) return;
    if (this.active) this.backend.remove(in id);
    this.records.delete(id);
  }

  function start(inout this, backend: TrayBackend): void throws TrayError {
    if (this.active || this.stopped) throw TrayError({ id: "", message: "tray manager can only start once" });
    this.backend = backend;
    // Mark active before realization so stop() rolls back partial startup.
    this.active = true;
    let failure = Option<TrayError>.none;
    for (const entry of this.records) {
      const created = attempt this.backend.create(in entry.key, in entry.value.options);
      match (created) {
        success => {}
        failure(error) => {
          failure = Option.some(move error);
          break;
        }
      }
    }
    match (failure) {
      some(error) => { this.stop(); throw error; }
      none => {}
    }
  }

  function stop(inout this): void {
    if (this.active) this.backend.stop();
    this.active = false;
    this.stopped = true;
    this.backend = unsupportedTrayBackend();
    // Release application-owned commands even when a command captured the app.
    this.records = Map<String, TrayRecord>();
  }
}

export readonly class TrayManager on thread.main {
  internal readonly state: TrayManagerState;

  internal constructor() {
    this.state = new TrayManagerState({ records: Map<String, TrayRecord>(),
      nextId: 1, backend: unsupportedTrayBackend(), active: false, stopped: false });
  }

  function create(options: TrayOptions): Tray throws TrayError {
    let state = this.state;
    return try state.create(weak this, move options);
  }
  function get(in id: String): Option<Tray> { return this.state.get(in id); }
  function all(): Array<Tray> { return this.state.all(); }

  internal function setMenu(in id: String, menu: Menu): void throws TrayError {
    let state = this.state;
    try state.setMenu(in id, move menu);
  }
  internal function setTooltip(in id: String, tooltip: String): void throws TrayError {
    let state = this.state;
    try state.setTooltip(in id, move tooltip);
  }
  internal function remove(in id: String): void {
    let state = this.state;
    state.remove(in id);
  }
  internal function start(backend: TrayBackend): void throws TrayError {
    let state = this.state;
    try state.start(backend);
  }
  internal function stop(): void {
    let state = this.state;
    state.stop();
  }
}

internal struct TrayManagerLifetime on thread.main {
  manager: TrayManager;
  deinit { this.manager.stop(); }
}

internal function createTrayManager(): TrayManager on thread.main { return new TrayManager(); }
