import { thread } from "std/thread";
import { Map } from "std/collections";
import {
  Command,
  Menu,
  MenuError,
  MenuItem,
} from "./menu.zs";

internal type ApplicationMenuSetOperation = (
  in menu: Menu
) => void throws MenuError on thread.main;
internal type ApplicationMenuStopOperation = () => void on thread.main;

internal struct ApplicationMenuBackend {
  set: ApplicationMenuSetOperation;
  stop: ApplicationMenuStopOperation;
}

function ignoreApplicationMenu(
  in menu: Menu
): void throws MenuError on thread.main {}

function inactiveApplicationMenuBackend(
): ApplicationMenuBackend on thread.main {
  const set: ApplicationMenuSetOperation = ignoreApplicationMenu;
  const stop: ApplicationMenuStopOperation = (): void => {};
  return ApplicationMenuBackend({ set, stop });
}

function validateMenuItems(
  in items: Array<MenuItem>
): void throws MenuError on thread.main {
  for (const item of items) {
    match (in item) {
      command(command) => {
        if (command.label.byteLength == 0) {
          throw MenuError({ message: "menu command labels cannot be empty" });
        }
      }
      submenu(group) => {
        if (group.label.byteLength == 0) {
          throw MenuError({ message: "submenu labels cannot be empty" });
        }
        try validateMenuItems(in group.items);
      }
      separator => {}
      role(_) => {}
    }
  }
}

readonly class StoredApplicationMenu on thread.main {
  menu: Menu;
}

class ApplicationMenuState on thread.main {
  current: StoredApplicationMenu;
  configured: boolean;
  frontendOwnerToken: String;
  frontendWindowId: String;
  frontendCommands: Map<String, Command>;
  backend: ApplicationMenuBackend;
  active: boolean;

  function set(
    inout this,
    menu: Menu
  ): void throws MenuError {
    try validateMenuItems(in menu.items);
    const replacement = new StoredApplicationMenu({ menu: move menu });
    if (this.active) try this.backend.set(in replacement.menu);
    this.current = replacement;
    this.configured = true;
    this.frontendOwnerToken = "";
    this.frontendWindowId = "";
    this.frontendCommands = Map<String, Command>();
  }

  function setFrontend(
    inout this,
    menu: Menu,
    ownerToken: String,
    windowId: String,
    commands: Map<String, Command>
  ): void throws MenuError {
    try validateMenuItems(in menu.items);
    const replacement = new StoredApplicationMenu({ menu: move menu });
    if (this.active) try this.backend.set(in replacement.menu);
    this.current = replacement;
    this.configured = true;
    this.frontendOwnerToken = move ownerToken;
    this.frontendWindowId = move windowId;
    this.frontendCommands = move commands;
  }

  function setFrontendCommandEnabled(
    inout this,
    in ownerToken: String,
    in windowId: String,
    in commandId: String,
    enabled: boolean
  ): void throws MenuError {
    if (
      ownerToken != this.frontendOwnerToken
      || windowId != this.frontendWindowId
    ) {
      throw MenuError({ message: "frontend menu registration is no longer active" });
    }
    const found = this.frontendCommands.get(commandId);
    match (in found) {
      some(command) => {
        let current = command;
        current.setEnabled(enabled);
      }
      none => throw MenuError({ message: "unknown frontend menu command" });
    }
  }

  function invalidateFrontendOwner(
    inout this,
    in windowId: String
  ): void {
    if (windowId != this.frontendWindowId) return;
    this.frontendOwnerToken = "";
    this.frontendWindowId = "";
    this.frontendCommands = Map<String, Command>();
  }

  function start(
    inout this,
    backend: ApplicationMenuBackend
  ): void throws MenuError {
    this.backend = backend;
    this.active = true;
    if (this.configured) {
      const selected = this.current;
      try this.backend.set(in selected.menu);
    }
  }

  function stop(inout this): void {
    if (this.active) this.backend.stop();
    this.active = false;
    this.backend = inactiveApplicationMenuBackend();
  }
}

function createApplicationMenuState(
): ApplicationMenuState on thread.main {
  return new ApplicationMenuState({
    current: new StoredApplicationMenu({
      menu: Menu({ items: Array<MenuItem>() }),
    }),
    configured: false,
    frontendOwnerToken: "",
    frontendWindowId: "",
    frontendCommands: Map<String, Command>(),
    backend: inactiveApplicationMenuBackend(),
    active: false,
  });
}

// The application owns one logical menu bar. Its definition may be installed
// before run(), then realized by the selected platform backend during startup.
export readonly class ApplicationMenu on thread.main {
  internal readonly state: ApplicationMenuState;

  internal constructor() {
    this.state = createApplicationMenuState();
  }

  function set(
    inout this,
    menu: Menu
  ): void throws MenuError on thread.main {
    try this.state.set(move menu);
  }

  internal function setFrontend(
    inout this,
    menu: Menu,
    ownerToken: String,
    windowId: String,
    commands: Map<String, Command>
  ): void throws MenuError on thread.main {
    try this.state.setFrontend(
      move menu,
      move ownerToken,
      move windowId,
      move commands
    );
  }

  internal function setFrontendCommandEnabled(
    inout this,
    in ownerToken: String,
    in windowId: String,
    in commandId: String,
    enabled: boolean
  ): void throws MenuError on thread.main {
    try this.state.setFrontendCommandEnabled(
      in ownerToken,
      in windowId,
      in commandId,
      enabled
    );
  }

  internal function invalidateFrontendOwner(
    inout this,
    in windowId: String
  ): void on thread.main {
    this.state.invalidateFrontendOwner(in windowId);
  }

  internal function start(
    inout this,
    backend: ApplicationMenuBackend
  ): void throws MenuError on thread.main {
    try this.state.start(backend);
  }

  internal function stop(inout this): void on thread.main {
    this.state.stop();
  }
}

internal function createApplicationMenu(
): ApplicationMenu on thread.main {
  return new ApplicationMenu();
}
