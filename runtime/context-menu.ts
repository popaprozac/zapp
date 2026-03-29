/**
 * ContextMenu — native context menus.
 *
 * @example
 * ```ts
 * import { ContextMenu } from "@zappdev/runtime";
 *
 * ContextMenu.show([
 *     { label: "Copy", role: "copy" },
 *     { label: "Paste", role: "paste" },
 *     { type: "separator" },
 *     { label: "Custom Action", action: () => console.log("clicked!") },
 * ]);
 * ```
 */

import { getBridge } from "./bridge";
import { Events } from "./events";
import type { MenuItemDef } from "./menu";

let ctxActionCounter = 0;
let lastContextX = 0;
let lastContextY = 0;

// Track right-click position
if (typeof document !== "undefined") {
  document.addEventListener("contextmenu", (e) => {
    lastContextX = e.clientX;
    lastContextY = e.clientY;
  }, true);
}

function collectAndStrip(items: MenuItemDef[]): { clean: any[]; actions: Map<string, () => void> } {
  const actions = new Map<string, () => void>();

  function walk(items: MenuItemDef[]): any[] {
    return items.map(item => {
      const clean: any = { ...item };
      if (clean.action) {
        if (!clean.id) clean.id = `__ctx_${++ctxActionCounter}`;
        actions.set(clean.id, clean.action);
        delete clean.action;
      }
      if (clean.submenu) clean.submenu = walk(clean.submenu);
      return clean;
    });
  }

  return { clean: walk(items), actions };
}

export interface ContextMenuOptions {
  /** X position in CSS pixels. Defaults to last contextmenu event position. */
  x?: number;
  /** Y position in CSS pixels. Defaults to last contextmenu event position. */
  y?: number;
}

export const ContextMenu = {
  show(items: MenuItemDef[], options?: ContextMenuOptions): void {
    const { clean, actions } = collectAndStrip(items);

    // One-shot event listener for action clicks
    if (actions.size > 0) {
      const off = Events.on("__menu:click", (payload: any) => {
        const id = typeof payload === "string" ? JSON.parse(payload).id : payload?.id;
        const handler = actions.get(id);
        if (handler) handler();
        off(); // One-shot: remove after first click
      });

      // Auto-cleanup after 30 seconds if no click
      setTimeout(() => off(), 30000);
    }

    const x = options?.x ?? lastContextX;
    const y = options?.y ?? lastContextY;

    (getBridge() as any).post(JSON.stringify({
      t: 4, m: "showContextMenu",
      a: { items: clean, x, y }
    }));
  },
};
