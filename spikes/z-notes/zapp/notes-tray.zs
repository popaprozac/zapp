import { Application } from "zapp";
import { Command, CommandOptions, CommandInvocation, Menu, MenuItem } from "zapp/menu";
import { TrayError, TrayOptions } from "zapp/tray";
import { WindowOptions } from "zapp/window";
import embed from "std/embed";
import console from "std/console";
import { thread } from "std/thread";

const ICON = embed.bytes("./assets/tray.png");

function showNotes(in invocation: CommandInvocation): void on thread.main {
  const app = Application.current();
  const windows = app.windows.all();
  for (const window of windows) { window.focus(); return; }
  match (attempt app.windows.create(WindowOptions({
    title: "Z Notes", url: "/notes", inject: Array<String>("base"),
    width: 720, height: 460,
  }))) {
    success(window) => window.focus();
    failure(error) => console.error(`could not reopen Z Notes: ${error.message}`);
  }
}

function quitNotes(in invocation: CommandInvocation): void on thread.main {
  const app = Application.current();
  app.quit();
}

export function configureNotesTray(app: Application, count: Command): void throws TrayError on thread.main {
  const show = new Command(CommandOptions({ label: "Show Z Notes" }), showNotes);
  const quit = new Command(CommandOptions({ label: "Quit Z Notes" }), quitNotes);
  // The application owns this item after registration. No local handle needs
  // to survive, and the shared count command also appears in the app menu.
  const tray = try app.trays.create(TrayOptions({
    icon: ICON,
    template: true,
    tooltip: "Z Notes",
    menu: Menu({ items: Array<MenuItem>(
      MenuItem.command(show), MenuItem.command(count),
      MenuItem.separator, MenuItem.command(quit)
    ) }),
  }));
}
