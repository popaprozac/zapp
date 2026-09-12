import AppKit from "AppKit/AppKit.h";
import embed from "std/embed";
import { thread } from "std/thread";
import { Command, CommandOptions, CommandInvocation, Menu, MenuItem } from "../framework/menu.zs";
import { TrayOptions, createTrayManager, TrayManagerLifetime } from "../framework/tray.zs";
import { macOSTrayBackend } from "../framework/platform/macos/tray-backend.zs";

const ICON = embed.bytes("../../../spikes/z-notes/zapp/assets/tray.png");
const INVALID = embed.bytes("./tray-native-smoke.zs");
function action(in invocation: CommandInvocation): void on thread.main {}
function menu(command: Command): Menu { return Menu({ items: Array<MenuItem>(MenuItem.command(command)) }); }

function main(): i32 {
  const app = AppKit.NSApplication.sharedApplication;
  app.finishLaunching();
  const manager = createTrayManager();
  const lifetime = TrayManagerLifetime({ manager });
  const command = new Command(CommandOptions({ label: "Tray native probe" }), action);
  const tray = match (attempt manager.create(TrayOptions({ icon: ICON, template: true, menu: menu(command) }))) {
    success(value) => value; failure(_) => return 1;
  };
  match (attempt manager.start(macOSTrayBackend())) { success => {} failure(_) => return 2; }
  match (attempt tray.setTooltip("Updated")) { success => {} failure(_) => return 3; }
  match (attempt tray.setMenu(menu(command))) { success => {} failure(_) => return 4; }
  command.setEnabled(false);
  command.setEnabled(true);
  // Invalid decoding fails before a native status item is registered.
  match (attempt manager.create(TrayOptions({ icon: INVALID, menu: menu(command) }))) {
    success(_) => return 5; failure(_) => {}
  }
  const remaining = manager.all();
  if (remaining.length != 1) return 6;
  tray.remove();
  tray.remove();
  match (attempt tray.setTooltip("Removed")) { success => return 7; failure(_) => {} }
  manager.stop();
  manager.stop();
  return 0;
}
