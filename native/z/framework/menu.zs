import { thread } from "std/thread";
import {
  Event,
  EventSubscription,
} from "./events.zs";

export type CommandAction = () => void on thread.main;

export struct MenuError {
  message: String;
}

export readonly struct CommandOptions {
  label: String;
  shortcut: String = "";
  enabled: boolean = true;
}

// A command is shared UI behavior, not one native menu-item allocation.
// Menus, toolbars, and future shortcut surfaces can retain the same identity.
export class Command on thread.main {
  readonly label: String;
  readonly shortcut: String;
  internal enabledValue: boolean;
  internal readonly action: CommandAction;
  internal readonly enabledChanges: Event<boolean>;

  constructor(
    options: CommandOptions,
    action: CommandAction
  ) {
    this.label = copy options.label;
    this.shortcut = copy options.shortcut;
    this.enabledValue = options.enabled;
    this.action = action;
    this.enabledChanges = new Event<boolean>();
  }

  function isEnabled(): boolean {
    return this.enabledValue;
  }

  function setEnabled(inout this, enabled: boolean): void {
    if (this.enabledValue == enabled) return;
    this.enabledValue = enabled;
    let changes = this.enabledChanges;
    changes.publish(in enabled);
  }

  internal function subscribeEnabled(
    handler: (in enabled: boolean) => void on thread.main
  ): EventSubscription throws MenuError {
    let changes = this.enabledChanges;
    return match (attempt changes.subscribe(handler)) {
      success(subscription) => subscription;
      failure(error) => throw MenuError({
        message: error.message.copyBytes(0, error.message.byteLength),
      });
    };
  }

  internal function invoke(): void {
    if (this.enabledValue) this.action();
  }
}

// Roles are typed platform behaviors. Some produce conventional submenus;
// others delegate to the native responder chain or Z application lifecycle.
export enum MenuRole {
  application,
  edit,
  window,
  about,
  services,
  hide,
  hideOthers,
  showAll,
  quit,
  undo,
  redo,
  cut,
  copy,
  paste,
  selectAll,
  minimize,
  zoom,
  close,
  toggleFullScreen,
}

export readonly struct MenuGroup {
  label: String;
  items: Array<MenuItem>;
}

// Tagged variants keep separators, roles, submenus, and commands from
// accumulating contradictory optional fields.
export enum MenuItem {
  command Command,
  submenu MenuGroup,
  separator,
  role MenuRole,
}

export readonly struct Menu {
  items: Array<MenuItem>;
}
