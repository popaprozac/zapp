import embed from "std/embed";
import { thread } from "std/thread";
import { Menu, MenuItem, MenuRole, Command, CommandOptions } from "../framework/menu.zs";
import { TrayOptions, TrayError, TrayBackend, TrayCreateOperation,
  TrayMenuOperation, TrayTooltipOperation, TrayRemoveOperation, TrayStopOperation,
  createTrayManager, TrayManager } from "../framework/tray.zs";

const ICON = embed.bytes("./tray-smoke.zs");

class Probe on thread.main {
  creates: i32;
  menus: i32;
  tooltips: i32;
  removes: i32;
  stops: i32;
  calls: i32;
  failAt: i32;

  function create(inout this, in id: String, in options: TrayOptions): void throws TrayError {
    this.creates = this.creates + 1;
    if (this.creates == this.failAt) throw TrayError({ id: copy id, message: "create failed" });
    if (options.icon.length == 0) throw TrayError({ id: copy id, message: "lost icon" });
  }
  function menu(inout this, in id: String, in menu: Menu): void throws TrayError {
    if (menu.items.length == 0) throw TrayError({ id: copy id, message: "test rejected replacement" });
    this.menus = this.menus + 1;
  }
  function tooltip(inout this, in id: String, in tooltip: String): void throws TrayError {
    if (tooltip == "reject") throw TrayError({ id: copy id, message: "test rejected tooltip" });
    this.tooltips = this.tooltips + 1;
  }
  function remove(inout this, in id: String): void { this.removes = this.removes + 1; }
  function stop(inout this): void { this.stops = this.stops + 1; }
  function invoke(inout this): void { this.calls = this.calls + 1; }
}

function probe(failAt: i32): Probe on thread.main {
  return new Probe({ creates: 0, menus: 0, tooltips: 0, removes: 0, stops: 0, calls: 0, failAt });
}

function backend(state: Probe): TrayBackend on thread.main {
  const create: TrayCreateOperation = move (in id: String, in options: TrayOptions): void => {
    try state.create(in id, in options);
  };
  const setMenu: TrayMenuOperation = move (in id: String, in menu: Menu): void => {
    try state.menu(in id, in menu);
  };
  const setTooltip: TrayTooltipOperation = move (in id: String, in tooltip: String): void => {
    try state.tooltip(in id, in tooltip);
  };
  const remove: TrayRemoveOperation = move (in id: String): void => state.remove(in id);
  const stop: TrayStopOperation = move (): void => state.stop();
  return TrayBackend({ create, setMenu, setTooltip, remove, stop });
}

function menu(command: Command): Menu on thread.main {
  return Menu({ items: Array<MenuItem>(MenuItem.command(command)) });
}

function count(manager: TrayManager): usize on thread.main {
  const trays = manager.all();
  return trays.length;
}

function main(): i32 on thread.main {
  const state = probe(0);
  const command = new Command(CommandOptions({ label: "Show Notes" }), move (in invocation): void => state.invoke());
  const manager = createTrayManager();
  const first = match (attempt manager.create(TrayOptions({ icon: ICON, menu: menu(command) }))) {
    success(value) => value; failure(_) => return 1;
  };
  // A second presentation shares the command, not the first tray's lifetime.
  const second = match (attempt manager.create(TrayOptions({ icon: ICON, menu: menu(command) }))) {
    success(value) => value; failure(_) => return 2;
  };
  if (count(manager) != 2 || first.id == second.id || state.creates != 0) return 3;
  match (attempt first.setTooltip("Ready")) { success => {} failure(_) => return 4; }
  match (attempt manager.start(backend(state))) { success => {} failure(_) => return 5; }
  if (state.creates != 2 || state.tooltips != 0) return 6;
  match (attempt first.setMenu(Menu({ items: Array<MenuItem>() }))) { success => return 7; failure(_) => {} }
  match (attempt first.setMenu(menu(command))) { success => {} failure(_) => return 8; }
  match (attempt first.setTooltip("reject")) { success => return 9; failure(_) => {} }
  match (attempt first.setTooltip("Updated")) { success => {} failure(_) => return 10; }
  if (state.menus != 1 || state.tooltips != 1) return 11;
  first.remove();
  first.remove();
  if (state.removes != 1 || count(manager) != 1) return 12;
  match (manager.get(in first.id)) { some(_) => return 13; none => {} }
  match (attempt first.setTooltip("Retired")) { success => return 14; failure(_) => {} }
  command.invoke();
  if (state.calls != 1) return 15;
  match (attempt second.setMenu(menu(command))) { success => {} failure(_) => return 16; }
  manager.stop();
  manager.stop();
  second.remove();
  if (state.stops != 1 || count(manager) != 0) return 17;
  match (attempt manager.create(TrayOptions({ icon: ICON, menu: menu(command) }))) { success(_) => return 18; failure(_) => {} }
  match (attempt second.setMenu(menu(command))) { success => return 19; failure(_) => {} }

  const failing = createTrayManager();
  const retained = match (attempt failing.create(TrayOptions({ icon: ICON, menu: menu(command) }))) {
    success(value) => value; failure(_) => return 20;
  };
  match (attempt failing.create(TrayOptions({ icon: ICON, menu: menu(command) }))) { success(_) => {} failure(_) => return 21; }
  const failedState = probe(2);
  match (attempt failing.start(backend(failedState))) { success => return 22; failure(_) => {} }
  if (failedState.creates != 2 || failedState.stops != 1 || count(failing) != 0) return 23;
  match (attempt retained.setTooltip("Expired")) { success => return 24; failure(_) => {} }
  failing.stop();
  if (failedState.stops != 1) return 25;
  const invalid = createTrayManager();
  match (attempt invalid.create(TrayOptions({ icon: ICON, menu: Menu({ items: Array<MenuItem>(MenuItem.role(MenuRole.application)) }) }))) {
    success(_) => return 26; failure(_) => {}
  }
  invalid.stop();
  return 0;
}
