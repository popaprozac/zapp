import AppKit from "AppKit/AppKit.h";
import objc from "std/objc";
import { Map } from "std/collections";
import { thread } from "std/thread";
import { Menu, MenuItem, MenuError } from "../../menu.zs";
import { EventSubscription } from "../../events.zs";
import { TrayOptions, TrayError, TrayBackend, TrayCreateOperation,
  TrayMenuOperation, TrayTooltipOperation, TrayRemoveOperation, TrayStopOperation } from "../../tray.zs";
import { createMacOSCommandItemWithAction } from "./menu-backend.zs";

class TrayMenuGate on thread.main {
  active: boolean;
  function retire(inout this): void { this.active = false; }
}

struct MacOSTrayMenu on thread.main {
  menu: AppKit.NSMenu;
  gate: TrayMenuGate;
  connections: Array<objc.Connection>;
  subscriptions: Array<EventSubscription>;

  deinit {
    let gate = this.gate;
    gate.retire();
    this.menu.cancelTrackingWithoutAnimation();
  }
}

function appendTrayMenu(in items: Array<MenuItem>, gate: TrayMenuGate,
  inout connections: Array<objc.Connection>, inout subscriptions: Array<EventSubscription>
): AppKit.NSMenu throws MenuError on thread.main {
  const menu = AppKit.NSMenu.alloc().initWithTitle("");
  menu.autoenablesItems = false;
  for (const item of items) {
    match (in item) {
      command(command) => {
        const selected = command;
        const guard = gate;
        const action: () => void on thread.main = move (): void => {
          if (guard.active) selected.invoke();
        };
        menu.addItem(try createMacOSCommandItemWithAction(command, action, inout connections, inout subscriptions));
      }
      submenu(group) => {
        const child = try appendTrayMenu(in group.items, gate, inout connections, inout subscriptions);
        const nativeItem = AppKit.NSMenuItem.alloc().init();
        nativeItem.title = copy group.label;
        nativeItem.submenu = child;
        menu.addItem(nativeItem);
      }
      separator => menu.addItem(AppKit.NSMenuItem.separatorItem());
      role(_) => throw MenuError({ message: "tray menus currently accept commands, submenus, and separators" });
    }
  }
  return menu;
}

function createTrayMenu(in id: String, in definition: Menu): MacOSTrayMenu throws TrayError on thread.main {
  const gate = new TrayMenuGate({ active: true });
  let connections = Array<objc.Connection>();
  let subscriptions = Array<EventSubscription>();
  const menu = match (attempt appendTrayMenu(in definition.items, gate, inout connections, inout subscriptions)) {
    success(menu) => menu;
    failure(error) => throw TrayError({ id: copy id, message: copy error.message });
  };
  return MacOSTrayMenu({ menu, gate, connections: move connections, subscriptions: move subscriptions });
}

// The status bar also retains its item. Remove it explicitly before releasing
// this owner, and close callback admission before cancelling a tracking menu.
class MacOSTrayRecord on thread.main {
  readonly bar: AppKit.NSStatusBar;
  readonly item: AppKit.NSStatusItem;
  presentation: MacOSTrayMenu;
  active: boolean;

  function setMenu(inout this, presentation: MacOSTrayMenu): void {
    let previousGate = this.presentation.gate;
    previousGate.retire();
    this.presentation.menu.cancelTrackingWithoutAnimation();
    this.item.menu = presentation.menu;
    this.presentation = move presentation;
  }
  function retire(inout this): void {
    if (!this.active) return;
    this.active = false;
    let gate = this.presentation.gate;
    gate.retire();
    this.presentation.menu.cancelTrackingWithoutAnimation();
    this.item.menu = null;
    this.bar.removeStatusItem(this.item);
  }
  deinit {
    if (this.active) {
      let gate = this.presentation.gate;
      gate.retire();
      this.presentation.menu.cancelTrackingWithoutAnimation();
      this.item.menu = null;
      this.bar.removeStatusItem(this.item);
    }
  }
}

class MacOSTrayState on thread.main {
  records: Map<String, MacOSTrayRecord>;

  function create(inout this, in id: String, in options: TrayOptions): void throws TrayError {
    const data = AppKit.NSData.borrow(options.icon);
    const image = AppKit.NSImage.alloc().initWithData(data);
    if (image == null) throw TrayError({ id: copy id, message: "tray icon is not a supported image" });
    image.template = options.template;
    image.size = AppKit.NSMakeSize(18, 18);
    const presentation = try createTrayMenu(in id, in options.menu);
    const bar = AppKit.NSStatusBar.systemStatusBar;
    const item = bar.statusItemWithLength(24);
    const button = item.button;
    if (button == null) {
      bar.removeStatusItem(item);
      throw TrayError({ id: copy id, message: "the status bar did not create a tray button" });
    }
    button.image = image;
    button.toolTip = copy options.tooltip;
    item.menu = presentation.menu;
    this.records.set(copy id, new MacOSTrayRecord({ bar, item, presentation: move presentation, active: true }));
  }

  function setMenu(inout this, in id: String, in definition: Menu): void throws TrayError {
    const found = this.records.get(id);
    let record = match (in found) {
      some(record) => record;
      none => throw TrayError({ id: copy id, message: "native tray has been removed" });
    };
    const presentation = try createTrayMenu(in id, in definition);
    record.setMenu(move presentation);
  }

  function setTooltip(inout this, in id: String, in tooltip: String): void throws TrayError {
    const found = this.records.get(id);
    const record = match (in found) {
      some(record) => record;
      none => throw TrayError({ id: copy id, message: "native tray has been removed" });
    };
    const button = record.item.button;
    if (button == null) throw TrayError({ id: copy id, message: "native tray button is unavailable" });
    button.toolTip = copy tooltip;
  }

  function remove(inout this, in id: String): void {
    const removed = this.records.remove(id);
    match (removed) { some(value) => { let record = value; record.retire(); } none => {} }
  }

  function stop(inout this): void {
    for (const entry of this.records) { let record = entry.value; record.retire(); }
    this.records = Map<String, MacOSTrayRecord>();
  }
}

internal function macOSTrayBackend(): TrayBackend on thread.main {
  const state = new MacOSTrayState({ records: Map<String, MacOSTrayRecord>() });
  const create: TrayCreateOperation = move (in id: String, in options: TrayOptions): void => {
    try state.create(in id, in options);
  };
  const setMenu: TrayMenuOperation = move (in id: String, in menu: Menu): void => {
    try state.setMenu(in id, in menu);
  };
  const setTooltip: TrayTooltipOperation = move (in id: String, in tooltip: String): void => {
    try state.setTooltip(in id, in tooltip);
  };
  const remove: TrayRemoveOperation = move (in id: String): void => state.remove(in id);
  const stop: TrayStopOperation = move (): void => state.stop();
  return TrayBackend({ create, setMenu, setTooltip, remove, stop });
}
