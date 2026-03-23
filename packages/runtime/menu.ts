import { Events } from "./events";

export interface MenuItemDef {
  /** Unique ID for click events. Auto-generated if action is provided without id. */
  id?: string;
  /** Display text. Required unless type is "separator" or role is set. */
  label?: string;
  /** Item type. Default: "normal" */
  type?: "normal" | "separator" | "checkbox";
  /** Whether the item is clickable. Default: true */
  enabled?: boolean;
  /** For checkbox items. Default: false */
  checked?: boolean;
  /** Keyboard shortcut. Use "CmdOrCtrl" for cross-platform Cmd/Ctrl. */
  accelerator?: string;
  /** Built-in menu role. Overrides label/submenu with standard items. */
  role?: "editMenu" | "windowMenu" | "appMenu";
  /** Click handler. Sugar for menu.on(id, handler). */
  action?: () => void;
  /** Nested submenu items. */
  submenu?: MenuItemDef[];
}

export interface MenuHandle {
  /** Listen for a menu item click by its ID */
  on(itemId: string, handler: () => void): () => void;
  /** The raw menu definition (for re-serialization) */
  readonly items: MenuItemDef[];
}

export interface MenuAPI {
  /** Build a menu from a definition array */
  build(items: MenuItemDef[]): MenuHandle;
}

let menuIdSeq = 0;

type ActionEntry = { id: string; handler: () => void };

function collectActions(items: MenuItemDef[], actions: ActionEntry[]): MenuItemDef[] {
  return items.map((item) => {
    const copy = { ...item };
    if (copy.action && !copy.id) {
      copy.id = `__menu_${++menuIdSeq}`;
    }
    if (copy.action && copy.id) {
      actions.push({ id: copy.id, handler: copy.action });
    }
    // Strip action from the serialized def (not JSON-serializable)
    delete copy.action;
    if (copy.submenu) {
      copy.submenu = collectActions(copy.submenu, actions);
    }
    return copy;
  });
}

function postMenu(items: MenuItemDef[]): void {
  const handler = (globalThis as unknown as Record<string, Record<string, Record<string, { postMessage?: (m: string) => void }>>>)
    .webkit?.messageHandlers?.zapp;
  const chromeWebview = (globalThis as unknown as Record<string, Record<string, { postMessage?: (m: string) => void }>>)
    .chrome?.webview;

  const msg = `app\nsetMenu\n${JSON.stringify({ items })}`;

  if (handler?.postMessage) {
    handler.postMessage(msg);
  } else if (chromeWebview?.postMessage) {
    chromeWebview.postMessage(msg);
  }
}

export const Menu: MenuAPI = {
  build(items: MenuItemDef[]): MenuHandle {
    const actions: ActionEntry[] = [];
    const cleanItems = collectActions(items, actions);

    // Post the cleaned (no functions) menu to native
    postMenu(cleanItems);

    // Wire up inline action handlers
    const offs: (() => void)[] = [];
    for (const { id, handler } of actions) {
      offs.push(Events.on(`menu:${id}`, handler as () => void));
    }

    return {
      get items() { return cleanItems; },
      on(itemId: string, handler: () => void): () => void {
        return Events.on(`menu:${itemId}`, handler as () => void);
      },
    };
  },
};
