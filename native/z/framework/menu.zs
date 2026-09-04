import { thread } from "std/thread";
import {
  Event,
  EventSubscription,
} from "./events.zs";

export enum CommandState {
  off,
  on,
  mixed,
}

export readonly struct CommandInvocation {
  command: Command;
}

export type CommandAction = (
  in invocation: CommandInvocation
) => void on thread.main;

export struct MenuError {
  message: String;
}

export readonly struct CommandOptions {
  label: String;
  shortcut: String = "";
  enabled: boolean = true;
  state: CommandState = CommandState.off;
}

class CommandRuntimeState on thread.main {
  enabledValue: boolean;
  stateValue: CommandState;
  readonly enabledChanges: Event<boolean>;
  readonly stateChanges: Event<CommandState>;

  function setEnabled(inout this, enabled: boolean): void {
    if (this.enabledValue == enabled) return;
    this.enabledValue = enabled;
    let changes = this.enabledChanges;
    changes.publish(in enabled);
  }

  function setState(inout this, state: CommandState): void {
    if (this.stateValue == state) return;
    this.stateValue = state;
    let changes = this.stateChanges;
    changes.publish(in state);
  }
}

// A command is shared UI behavior, not one native menu-item allocation.
// Menus, toolbars, and future shortcut surfaces can retain the same identity.
export readonly class Command on thread.main {
  readonly label: String;
  readonly shortcut: String;
  internal readonly action: CommandAction;
  internal readonly runtime: CommandRuntimeState;

  constructor(
    options: CommandOptions,
    action: CommandAction
  ) {
    this.label = copy options.label;
    this.shortcut = copy options.shortcut;
    this.action = action;
    this.runtime = new CommandRuntimeState({
      enabledValue: options.enabled,
      stateValue: options.state,
      enabledChanges: new Event<boolean>(),
      stateChanges: new Event<CommandState>(),
    });
  }

  function isEnabled(): boolean {
    return this.runtime.enabledValue;
  }

  function state(): CommandState {
    return this.runtime.stateValue;
  }

  function setEnabled(enabled: boolean): void {
    let runtime = this.runtime;
    runtime.setEnabled(enabled);
  }

  function setState(state: CommandState): void {
    let runtime = this.runtime;
    runtime.setState(state);
  }

  internal function subscribeEnabled(
    handler: (in enabled: boolean) => void on thread.main
  ): EventSubscription throws MenuError {
    let changes = this.runtime.enabledChanges;
    return match (attempt changes.subscribe(handler)) {
      success(subscription) => subscription;
      failure(error) => throw MenuError({
        message: error.message.copyBytes(0, error.message.byteLength),
      });
    };
  }

  internal function subscribeState(
    handler: (in state: CommandState) => void on thread.main
  ): EventSubscription throws MenuError {
    let changes = this.runtime.stateChanges;
    return match (attempt changes.subscribe(handler)) {
      success(subscription) => subscription;
      failure(error) => throw MenuError({
        message: error.message.copyBytes(0, error.message.byteLength),
      });
    };
  }

  internal function invoke(): void {
    if (!this.runtime.enabledValue) return;
    const invocation = CommandInvocation({ command: this });
    this.action(in invocation);
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
