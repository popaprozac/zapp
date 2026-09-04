import {
  Command,
  CommandAction,
  CommandInvocation,
  CommandOptions,
  CommandState,
  Menu,
  MenuGroup,
  MenuItem,
  MenuRole,
} from "../framework/menu.zs";
import { thread } from "std/thread";

class CommandObservation on thread.main {
  count: i32;
}

function main(): i32 on thread.main {
  const observed = new CommandObservation({ count: 0 });
  const operation: CommandAction = move (
    in invocation: CommandInvocation
  ): void => {
    if (invocation.command.label == "New Note") {
      observed.count = observed.count + 1;
    }
  };
  let createNote = new Command(
    CommandOptions({
      label: "New Note",
      shortcut: "Primary+N",
      state: CommandState.on,
    }),
    operation
  );
  const menu = Menu({
    items: Array<MenuItem>(
      MenuItem.role(MenuRole.application),
      MenuItem.submenu(MenuGroup({
        label: "File",
        items: Array<MenuItem>(
          MenuItem.command(createNote),
          MenuItem.separator,
          MenuItem.role(MenuRole.quit)
        ),
      })),
      MenuItem.role(MenuRole.edit),
      MenuItem.role(MenuRole.window)
    ),
  });

  createNote.invoke();
  if (observed.count != 1) return 1;
  if (createNote.state() != CommandState.on) return 2;
  const enabledObserved = observed;
  const enabledSubscription = match (attempt createNote.subscribeEnabled(
    move (in enabled: boolean): void => {
      if (!enabled) enabledObserved.count = enabledObserved.count + 10;
    }
  )) {
    success(subscription) => subscription;
    failure(_) => return 3;
  };
  const stateObserved = observed;
  const stateSubscription = match (attempt createNote.subscribeState(
    move (in state: CommandState): void => {
      if (state == CommandState.mixed) {
        stateObserved.count = stateObserved.count + 100;
      }
    }
  )) {
    success(subscription) => subscription;
    failure(_) => return 4;
  };
  createNote.setState(CommandState.mixed);
  if (observed.count != 101) return 5;
  createNote.setState(CommandState.mixed);
  if (observed.count != 101) return 6;
  createNote.setEnabled(false);
  createNote.invoke();
  if (observed.count != 111) return 7;
  createNote.setEnabled(false);
  if (observed.count != 111) return 8;
  if (menu.items.length != 4) return 9;
  enabledSubscription.unsubscribe();
  stateSubscription.unsubscribe();
  return 0;
}
