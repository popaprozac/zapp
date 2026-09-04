import {
  Command,
  CommandAction,
  CommandOptions,
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
  const operation: CommandAction = move (): void => {
    observed.count = observed.count + 1;
  };
  let createNote = new Command(
    CommandOptions({
      label: "New Note",
      shortcut: "Primary+N",
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
  createNote.setEnabled(false);
  createNote.invoke();
  if (observed.count != 1) return 2;
  if (menu.items.length != 4) return 3;
  return 0;
}
