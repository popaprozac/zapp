/**
 * ContextMenu — native context menus.
 *
 * @example Right-click (uses last pointer position automatically):
 * ```ts
 * element.addEventListener("contextmenu", (e) => {
 *   e.preventDefault();
 *   ContextMenu.show([
 *     { label: "Copy", role: "copy" },
 *     { label: "Paste", role: "paste" },
 *   ]);
 * });
 * ```
 *
 * @example Dropdown button (positioned below the button):
 * ```ts
 * button.addEventListener("click", (e) => {
 *   ContextMenu.show(items, { anchor: e.currentTarget as HTMLElement });
 * });
 * ```
 *
 * @example Explicit position:
 * ```ts
 * ContextMenu.show(items, { x: 100, y: 200 });
 * ```
 */

import { getBridge } from "./bridge";
import { Events } from "./events";
import { ensurePermission } from "./permissions";
import type { MenuItemDef } from "./menu";

let ctxActionCounter = 0;

// Last-known pointer position in CSS pixels (viewport-relative). Tracks
// every pointer event — contextmenu, pointerdown, click — so a menu opened
// from *any* event type has a sensible fallback position when the caller
// doesn't pass explicit coordinates. Prior versions only listened to
// contextmenu, which left dropdown-from-button patterns stuck at (0, 0).
let lastPointerX = 0;
let lastPointerY = 0;

if (typeof document !== "undefined") {
  const track = (e: MouseEvent | PointerEvent) => {
    lastPointerX = e.clientX;
    lastPointerY = e.clientY;
  };
  document.addEventListener("contextmenu", track, true);
  document.addEventListener("pointerdown", track, true);
  document.addEventListener("click", track, true);
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
  /** Explicit X (CSS pixels, viewport-relative). Highest priority. */
  x?: number;
  /** Explicit Y (CSS pixels, viewport-relative). Highest priority. */
  y?: number;
  /**
   * Show the menu at the position of this MouseEvent (e.g. pass `e` from
   * a `click` or `contextmenu` handler). Uses `clientX` / `clientY`.
   */
  event?: MouseEvent | PointerEvent;
  /**
   * Show the menu anchored to this element — positions the menu at the
   * element's bottom-left corner, matching the native dropdown-button
   * convention. Uses `getBoundingClientRect()`.
   */
  anchor?: Element;
}

function resolvePosition(options?: ContextMenuOptions): { x: number; y: number } {
  if (options?.x != null && options?.y != null) {
    return { x: options.x, y: options.y };
  }
  if (options?.event) {
    return { x: options.event.clientX, y: options.event.clientY };
  }
  if (options?.anchor) {
    const r = options.anchor.getBoundingClientRect();
    return { x: r.left, y: r.bottom };
  }
  return { x: lastPointerX, y: lastPointerY };
}

export const ContextMenu = {
  show(items: MenuItemDef[], options?: ContextMenuOptions): void {
    ensurePermission("menu");
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

    const { x, y } = resolvePosition(options);

    (getBridge() as any).post(JSON.stringify({
      t: 4, m: "showContextMenu",
      a: { items: clean, x, y }
    }));
  },
};
