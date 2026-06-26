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
import type { ActionContext, MenuItemPatch } from "./action-context";
import { patchMenuTree } from "./action-context";
import { Window } from "./window";

export interface MenuItemDef {
  id?: string;
  label?: string;
  type?: "normal" | "separator" | "checkbox";
  enabled?: boolean;
  checked?: boolean;
  accelerator?: string;
  role?: "editMenu" | "windowMenu" | "appMenu" | "copy" | "cut" | "paste" | "selectAll" | "undo" | "redo" | "quit";
  action?: (ctx?: ActionContext) => void;
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

// Module-level app-menu state — avoids listener-accumulation and retains the
// tree so ctx.update can patch + re-send without a full rebuild from the caller.
let appMenuTree: MenuItemDef[] = [];
let appMenuActions = new Map<string, (ctx?: ActionContext) => void>();
let appMenuWired = false;

function collectActions(items: MenuItemDef[]): Map<string, (ctx?: ActionContext) => void> {
  const actions = new Map<string, (ctx?: ActionContext) => void>();

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

    // Retain the original tree (with actions) + collect action map.
    appMenuTree = items;
    appMenuActions = collectActions(items);

    // Send stripped tree to native.
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "setMenu", a: { items: stripActions(appMenuTree) } }));

    // Wire the listener exactly once — reads from module-level state so it
    // always sees the most recently retained tree and actions.
    if (!appMenuWired) {
      appMenuWired = true;
      Events.on("__menu:click", (payload: any) => {
        const id = typeof payload === "string" ? JSON.parse(payload).id : payload?.id;
        const fn = appMenuActions.get(id);
        if (!fn) return;
        let win: import("./window").WindowHandle;
        try {
          win = Window.current();
        } catch {
          // Outside WebView context — should not normally happen for menu clicks.
          return;
        }
        const update = (patch: MenuItemPatch) => {
          appMenuTree = patchMenuTree(appMenuTree, id, patch);
          (getBridge() as any).post(JSON.stringify({ t: 4, m: "setMenu", a: { items: stripActions(appMenuTree) } }));
        };
        fn({ id, window: win, update });
      });
    }

    return { items };
  },
};
