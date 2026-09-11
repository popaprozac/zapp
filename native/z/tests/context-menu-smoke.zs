import { thread } from "std/thread";
import {
  ContextMenuOptions,
  createContextMenuSessions,
} from "../framework/context-menu.zs";
import {
  Command,
  CommandInvocation,
  CommandOptions,
  Menu,
  MenuError,
  MenuGroup,
  MenuItem,
  MenuRole,
} from "../framework/menu.zs";

class Observation on thread.main {
  dismissed: i32;
  invoked: i32;
}

function runSmoke(): i32 throws MenuError on thread.main {
  let sessions = createContextMenuSessions();
  const observed = new Observation({ dismissed: 0, invoked: 0 });
  const command = new Command(
    CommandOptions({ label: "Rename" }),
    move (in invocation: CommandInvocation): void => {
      observed.invoked = observed.invoked + 1;
    }
  );
  const menu = Menu({ items: Array<MenuItem>(MenuItem.command(command)) });
  const options = ContextMenuOptions({ x: 120.5, y: 80.0 });
  const first = try sessions.begin("win-1", in menu, options);
  const firstDismissed = observed;
  first.setDismiss(move (): void => {
    firstDismissed.dismissed = firstDismissed.dismissed + 1;
  });

  const conflict = attempt sessions.begin("win-2", in menu, options);
  match (conflict) {
    success(_) => return 1;
    failure(_) => {}
  }
  sessions.invalidateWindow("win-2");
  if (observed.dismissed != 0) return 2;
  if (!first.selectCommand("rename")) return 3;
  if (first.selectCommand("rename")) return 4;
  const reentrant = attempt sessions.begin("win-1", in menu, options);
  match (reentrant) {
    success(_) => return 21;
    failure(_) => {}
  }
  // The session is a selection gate, never an extra command invocation.
  if (observed.invoked != 0) return 5;
  if (sessions.finish(first) != "rename") return 6;
  if (sessions.finish(first) != "") return 7;

  const second = try sessions.begin("win-2", in menu, options);
  const secondDismissed = observed;
  second.setDismiss(move (): void => {
    secondDismissed.dismissed = secondDismissed.dismissed + 1;
  });
  // An old callback cannot clear a newer presentation.
  if (sessions.finish(first) != "") return 8;
  sessions.invalidateWindow("win-2");
  sessions.invalidateWindow("win-2");
  if (observed.dismissed != 1) return 9;
  if (second.selectCommand("rename")) return 10;
  if (sessions.finish(second) != "") return 11;

  const third = try sessions.begin("win-1", in menu, options);
  if (!third.selectCommand("rename")) return 12;
  // Navigation after selection but before delivery suppresses stale JS work.
  sessions.invalidateAll();
  if (sessions.finish(third) != "") return 13;

  const fourth = try sessions.begin("win-1", in menu, options);
  sessions.invalidateAll();
  const lateDismissed = observed;
  fourth.setDismiss(move (): void => {
    lateDismissed.dismissed = lateDismissed.dismissed + 1;
  });
  if (observed.dismissed != 2) return 14;
  if (sessions.finish(fourth) != "") return 15;
  command.invoke();
  if (observed.invoked != 1) return 16;

  const negative = attempt sessions.begin("win-1", in menu,
    ContextMenuOptions({ x: -1.0, y: 0.0 }));
  match (negative) {
    success(_) => return 17;
    failure(_) => {}
  }
  const unowned = attempt sessions.begin("", in menu, options);
  match (unowned) {
    success(_) => return 18;
    failure(_) => {}
  }
  const roles = Menu({ items: Array<MenuItem>(
    MenuItem.submenu(MenuGroup({
      label: "Unsafe role group",
      items: Array<MenuItem>(MenuItem.role(MenuRole.application)),
    }))
  ) });
  const invalidRole = attempt sessions.begin("win-1", in roles, options);
  match (invalidRole) {
    success(_) => return 19;
    failure(_) => {}
  }
  // Invalid requests do not poison the presentation slot.
  const finalSession = try sessions.begin("win-1", in menu, options);
  if (sessions.finish(finalSession) != "") return 20;
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt runSmoke()) {
    success(value) => value;
    failure(_) => 99;
  };
}
