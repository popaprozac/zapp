/**
 * Menu — application menu bar.
 *
 * @example
 * ```ts
 * import { Menu, App } from "@zappdev/runtime";
 *
 * Menu.build([
 *     { role: "appMenu" },
 *     { label: "File", submenu: [
 *         { label: "New", accelerator: "CmdOrCtrl+N", action: () => console.log("New!") },
 *         { type: "separator" },
 *         { label: "Quit", accelerator: "CmdOrCtrl+Q", action: () => App.quit() },
 *     ]},
 *     { label: "Edit", role: "editMenu" },
 *     { label: "Window", role: "windowMenu" },
 * ]);
 * ```
 */

import { getBridge } from "./bridge";
import { Events } from "./events";
import { ensurePermission } from "./permissions";

export interface MenuItemDef {
  id?: string;
  label?: string;
  type?: "normal" | "separator" | "checkbox";
  enabled?: boolean;
  checked?: boolean;
  accelerator?: string;
  role?: "editMenu" | "windowMenu" | "appMenu" | "copy" | "cut" | "paste" | "selectAll" | "undo" | "redo" | "quit";
  action?: () => void;
  submenu?: MenuItemDef[];
  /** Icon for this item (macOS). "sf:gear" (SF Symbol) | "build/logo.png"
   *  (file path, relative-resolved) | "data:image/png;base64,…" (dynamic). */
  icon?: string;
  /** Force template rendering (monochrome, auto-tinted to menu text/dark mode)
   *  on/off. Default: "sf:" icons → true, file/data icons → false. */
  iconTemplate?: boolean;
}

export interface MenuHandle {
  readonly items: MenuItemDef[];
}

let menuActionCounter = 0;

function collectActions(items: MenuItemDef[]): Map<string, () => void> {
  const actions = new Map<string, () => void>();

  function walk(items: MenuItemDef[]) {
    for (const item of items) {
      if (item.action) {
        if (!item.id) {
          item.id = `__menu_${++menuActionCounter}`;
        }
        actions.set(item.id, item.action);
      }
      if (item.submenu) walk(item.submenu);
    }
  }

  walk(items);
  return actions;
}

function stripActions(items: MenuItemDef[]): any[] {
  return items.map(item => {
    const clean: any = { ...item };
    delete clean.action;
    if (clean.submenu) clean.submenu = stripActions(clean.submenu);
    return clean;
  });
}

export const Menu = {
  build(items: MenuItemDef[]): MenuHandle {
    ensurePermission("menu");
    const actions = collectActions(items);
    const clean = stripActions(items);

    // Wire up action event listeners
    if (actions.size > 0) {
      Events.on("__menu:click", (payload: any) => {
        const id = typeof payload === "string" ? JSON.parse(payload).id : payload?.id;
        const handler = actions.get(id);
        if (handler) handler();
      });
    }

    // Send to native
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "setMenu", a: { items: clean } }));

    return { items };
  },
};
