/** Focused frontend API for the application-owned native menu. */

import { getBridge } from "./bridge";
import { ensurePermission } from "./permissions";
import { MenuError } from "./menu-errors";

export { MenuError, type MenuErrorPayload } from "./menu-errors";

export const MenuRole = {
  Application: "application",
  Edit: "edit",
  Window: "window",
  About: "about",
  Services: "services",
  Hide: "hide",
  HideOthers: "hideOthers",
  ShowAll: "showAll",
  Quit: "quit",
  Undo: "undo",
  Redo: "redo",
  Cut: "cut",
  Copy: "copy",
  Paste: "paste",
  SelectAll: "selectAll",
  Minimize: "minimize",
  Zoom: "zoom",
  Close: "close",
  ToggleFullScreen: "toggleFullScreen",
} as const;

export type MenuRole = (typeof MenuRole)[keyof typeof MenuRole];

export const CommandState = {
  Off: "off",
  On: "on",
  Mixed: "mixed",
} as const;

export type CommandState = (typeof CommandState)[keyof typeof CommandState];

export interface CommandInvocation {
  readonly command: Command;
}

export type CommandAction = (
  invocation: CommandInvocation,
) => void | Promise<void>;

export interface CommandOptions {
  label: string;
  shortcut?: string;
  enabled?: boolean;
  state?: CommandState;
  action: CommandAction;
}

export interface CommandMenuItem {
  readonly command: Command;
}

export interface SubmenuItem {
  readonly label: string;
  readonly items: readonly MenuItem[];
}

export interface SeparatorMenuItem {
  readonly type: "separator";
}

export interface RoleMenuItem {
  readonly role: MenuRole;
}

export interface InlineCommandMenuItem {
  readonly label: string;
  readonly shortcut?: string;
  readonly enabled?: boolean;
  readonly action: CommandAction;
}

export type MenuItem =
  | CommandMenuItem
  | SubmenuItem
  | SeparatorMenuItem
  | RoleMenuItem
  | InlineCommandMenuItem;

interface WireCommand {
  kind: "command";
  commandId: string;
  label: string;
  shortcut: string;
  enabled: boolean;
  state: CommandState;
}

interface WireSubmenu {
  kind: "submenu";
  label: string;
  items: WireMenuItem[];
}

interface WireSeparator {
  kind: "separator";
}

interface WireRole {
  kind: "role";
  role: MenuRole;
}

type WireMenuItem = WireCommand | WireSubmenu | WireSeparator | WireRole;

interface MenuOwner {
  readonly token: string;
  readonly commandsById: Map<string, Command>;
  readonly commands: Set<Command>;
}

let currentOwner: MenuOwner | undefined;
let wiredBridge: ReturnType<typeof getBridge> | undefined;
let unwireEvents: (() => void) | undefined;

function requiredLabel(value: string, kind: "command" | "submenu"): string {
  if (typeof value === "string" && value.trim().length > 0) return value;
  throw new MenuError({ message: `${kind} labels cannot be empty` });
}

function ownerToken(): string {
  const windowId = (globalThis as any)[Symbol.for("zapp.windowId")];
  const prefix = typeof windowId === "string" && windowId.length > 0
    ? windowId
    : "webview";
  return `${prefix}:${globalThis.crypto.randomUUID()}`;
}

function wireEvents(): void {
  const bridge = getBridge();
  if (wiredBridge === bridge) return;
  unwireEvents?.();
  const unsubscribe = bridge.on("__zapp:menu-command", (payload) => {
    if (payload === null || typeof payload !== "object") return;
    const record = payload as Record<string, unknown>;
    const owner = currentOwner;
    if (
      !owner
      || record.ownerToken !== owner.token
      || typeof record.commandId !== "string"
    ) return;
    const command = owner.commandsById.get(record.commandId);
    if (!command) return;
    try {
      const result = command.action({ command });
      if (result && typeof (result as Promise<void>).catch === "function") {
        void (result as Promise<void>).catch((error) => {
          console.error("[zapp] menu action failed:", error);
        });
      }
    } catch (error) {
      console.error("[zapp] menu action failed:", error);
    }
  });
  wiredBridge = bridge;
  unwireEvents = unsubscribe;
}

/** Shared command identity reusable across menus and future command surfaces. */
export class Command {
  readonly label: string;
  readonly shortcut: string;
  readonly action: CommandAction;
  readonly _id: string;
  _enabled: boolean;
  _state: CommandState;
  _ownerToken?: string;

  constructor(options: CommandOptions) {
    this.label = requiredLabel(options.label, "command");
    this.shortcut = options.shortcut ?? "";
    this._enabled = options.enabled ?? true;
    this._state = options.state ?? CommandState.Off;
    this.action = options.action;
    this._id = `command:${globalThis.crypto.randomUUID()}`;
  }

  get enabled(): boolean { return this._enabled; }
  get state(): CommandState { return this._state; }

  /** Update every installed native item that shares this command identity. */
  async setEnabled(enabled: boolean): Promise<void> {
    if (this._ownerToken && this._ownerToken === currentOwner?.token) {
      await getBridge().invoke("__zapp:menu:set-enabled", {
        ownerToken: this._ownerToken,
        commandId: this._id,
        enabled,
      });
    }
    this._enabled = enabled;
  }

  /** Update the check/selection state of every installed native item. */
  async setState(state: CommandState): Promise<void> {
    if (!Object.values(CommandState).includes(state)) {
      throw new MenuError({ message: `unknown command state ${JSON.stringify(state)}` });
    }
    if (this._ownerToken && this._ownerToken === currentOwner?.token) {
      await getBridge().invoke("__zapp:menu:set-state", {
        ownerToken: this._ownerToken,
        commandId: this._id,
        state,
      });
    }
    this._state = state;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function commandItem(
  command: Command,
  owner: MenuOwner,
): WireCommand {
  owner.commandsById.set(command._id, command);
  owner.commands.add(command);
  return {
    kind: "command",
    commandId: command._id,
    label: command.label,
    shortcut: command.shortcut,
    enabled: command.enabled,
    state: command.state,
  };
}

function serializeItem(item: MenuItem, owner: MenuOwner): WireMenuItem {
  if (!isRecord(item)) {
    throw new MenuError({ message: "menu items must be objects" });
  }
  if (item.command instanceof Command) return commandItem(item.command, owner);
  if (item.type === "separator") return { kind: "separator" };
  if (typeof item.role === "string") {
    if (!Object.values(MenuRole).includes(item.role as MenuRole)) {
      throw new MenuError({ message: `unknown menu role ${JSON.stringify(item.role)}` });
    }
    return { kind: "role", role: item.role as MenuRole };
  }
  if (Array.isArray(item.items)) {
    return {
      kind: "submenu",
      label: requiredLabel(item.label as string, "submenu"),
      items: item.items.map((child) => serializeItem(child as MenuItem, owner)),
    };
  }
  if (typeof item.action === "function") {
    return commandItem(new Command({
      label: item.label as string,
      shortcut: typeof item.shortcut === "string" ? item.shortcut : undefined,
      enabled: typeof item.enabled === "boolean" ? item.enabled : undefined,
      action: item.action as CommandAction,
    }), owner);
  }
  throw new MenuError({ message: "invalid menu item variant" });
}

export interface ApplicationMenu {
  /** Replace the application menu and own its callbacks until replacement. */
  set(items: readonly MenuItem[]): Promise<void>;
}

/** @internal Shared by the focused Application facade. */
export const applicationMenu: ApplicationMenu = {
  async set(items: readonly MenuItem[]): Promise<void> {
    ensurePermission("menu");
    wireEvents();
    const owner: MenuOwner = {
      token: ownerToken(),
      commandsById: new Map(),
      commands: new Set(),
    };
    const wireItems = items.map((item) => serializeItem(item, owner));
    await getBridge().invoke("__zapp:menu:set", {
      ownerToken: owner.token,
      items: wireItems,
    });
    for (const command of currentOwner?.commands ?? []) {
      command._ownerToken = undefined;
    }
    for (const command of owner.commands) command._ownerToken = owner.token;
    currentOwner = owner;
  },
};
