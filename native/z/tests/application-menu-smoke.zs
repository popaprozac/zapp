import {
  ApplicationMenuBackend,
  ApplicationMenuSetOperation,
  ApplicationMenuStopOperation,
  createApplicationMenu,
} from "../framework/application-menu.zs";
import {
  Command,
  CommandAction,
  CommandOptions,
  Menu,
  MenuError,
  MenuItem,
} from "../framework/menu.zs";
import { thread } from "std/thread";

class MenuObservation on thread.main {
  sets: i32;
  actions: i32;
}

function runApplicationMenuSmoke(
): i32 throws MenuError on thread.main {
  const observed = new MenuObservation({ sets: 0, actions: 0 });
  const setObserved = observed;
  const setMenu: ApplicationMenuSetOperation = move (
    in menu: Menu
  ): void => {
    setObserved.sets = setObserved.sets + i32(menu.items.length);
  };
  const stopObserved = observed;
  const stopMenu: ApplicationMenuStopOperation = move (): void => {
    stopObserved.sets = stopObserved.sets + 10;
  };
  const backend = ApplicationMenuBackend({
    set: setMenu,
    stop: stopMenu,
  });
  const actionObserved = observed;
  const action: CommandAction = move (): void => {
    actionObserved.actions = actionObserved.actions + 1;
  };
  const command = new Command(
    CommandOptions({ label: "Create Note" }),
    action
  );
  let menu = createApplicationMenu();
  try menu.set(Menu({
    items: Array<MenuItem>(MenuItem.command(command)),
  }));
  if (observed.sets != 0) return 1;
  try menu.start(backend);
  if (observed.sets != 1) return 2;
  command.invoke();
  if (observed.actions != 1) return 3;
  menu.stop();
  if (observed.sets != 11) return 4;
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt runApplicationMenuSmoke()) {
    success(status) => status;
    failure(_) => 9;
  };
}
