/**
 * Tray — system menu-bar / status-item.
 *
 * Each tray sits in the macOS menu bar (top of the screen). A tray
 * is either click-driven (your handler runs on left/right click) or
 * menu-driven (a popup menu appears on click). Pass `menu` for the
 * second mode; otherwise wire `on("click", ...)` / `on("right-click", ...)`.
 *
 * Trays survive across window opens and closes — they're owned by
 * the app, not by any window.
 *
 * @example
 * ```ts
 * import { Tray, App, Window } from "@zappdev/runtime";
 *
 * const status = Tray.create({
 *   icon: "build/menubar-icon.png",      // 18×18 template PNG
 *   tooltip: "My App",
 *   menu: [
 *     { label: "Open Window", action: () => Window.current().show() },
 *     { type: "separator" },
 *     { label: "Quit", role: "quit" },
 *   ],
 * });
 *
 * // …or click-only:
 * const ping = Tray.create({ icon: "build/ping.png" });
 * ping.on("click", () => console.log("clicked"));
 * ping.on("right-click", () => console.log("right-clicked"));
 * ```
 */

import { getBridge } from "./bridge";
import { Events } from "./events";
import { ensurePermission } from "./permissions";
import type { MenuItemDef } from "./menu";
import type { WindowHandle } from "./window";
import { Window } from "./window";
import type { ActionContext, MenuItemPatch } from "./action-context";
import { patchMenuTree } from "./action-context";

export interface AttachWindowOptions {
  /**
   * Where the window appears relative to the tray icon. Default:
   * `"centerBelow"` — top-of-window aligned with bottom-of-icon, x
   * centered on the icon.
   */
  position?: "centerBelow" | "centerAbove" | "rightCenter";
  /**
   * Hide the attached window when focus moves away — cmd-tab to
   * another app, another window in this app becomes key. Default:
   * `true`. Combine with `dismissOnOutsideClick` for full menu-bar
   * dismiss UX, or set `false` for a panel that survives focus
   * changes (e.g. lookups while typing in another window).
   */
  dismissOnBlur?: boolean;
  /**
   * Hide the attached window when the user clicks outside it (any
   * other window, the menu bar, another app's space). Default:
   * `true`. Set `false` to keep the popover sticky and require an
   * explicit close from inside.
   */
  dismissOnOutsideClick?: boolean;
  /**
   * Second tray click hides the window. Default: `true` — clicking
   * the icon again is the natural "close this thing" gesture.
   */
  toggleOnClick?: boolean;
  /**
   * Pixel adjustment to the computed anchor point. Default
   * `{ x: 0, y: 4 }` — 4px gap between menu bar and the attached
   * window (room for the menu bar's own subtle drop shadow).
   */
  offset?: { x?: number; y?: number };
}

export interface TrayOptions {
  /**
   * Path to icon image. Shown as-is by default (WYSIWYG) — a small
   * (≈18×18) PNG works best. For automatic light/dark tinting, provide a
   * monochrome glyph (black silhouette on transparent) and set
   * `template: true`. Absolute paths, or paths relative to the app's
   * working directory / bundle resources, both resolve. Required.
   *
   * **Note:** a large full-color image (e.g. a 1024×1024 app icon) is
   * scaled down to menu-bar size; for a crisp result supply a small icon.
   */
  icon: string;
  /** Optional text shown next to the icon in the menu bar. */
  title?: string;
  /** Tooltip on hover. */
  tooltip?: string;
  /**
   * Menu shown on click. When set, the system handles clicks → menu
   * appears; the `click` event does not fire. Omit for click-driven
   * trays where you want to wire `on("click", ...)` yourself.
   */
  menu?: MenuItemDef[];
   /**
   * Treat the icon as a template image — macOS ignores its color and
   * auto-tints the opaque region for light/dark mode. **Defaults to
   * `false`** (the icon renders as-is). Set `true` ONLY for a monochrome
   * glyph designed as a template; applying it to a normal full-color
   * icon renders a solid silhouette (a white/black blob), not your icon.
   */
  template?: boolean;
}

export interface TrayHandle {
  readonly id: number;
  setIcon(path: string, opts?: { template?: boolean }): void;
  setTitle(title: string): void;
  setTooltip(tooltip: string): void;
  setMenu(items: MenuItemDef[]): void;
  on(event: "click" | "right-click", handler: () => void): () => void;
  /**
   * Attach a window to this tray icon. Left-click toggles the window's
   * visibility; the window auto-positions relative to the icon and
   * (by default) hides on blur.
   *
   * **Coexists with `setMenu(...)`** — the new behavior is purely
   * additive. With both configured, left-click drives the window and
   * right-click opens the menu.
   *
   * **Window setup**: create the window with `borderless: true` and a
   * fixed `width` / `height`. The attached window is forced to floating
   * level when shown.
   *
   * @example
   * ```ts
   * const win = await Window.create({
   *   title: "Stats",
   *   width: 320, height: 480,
   *   borderless: true, visible: false,
   * });
   * tray.attachWindow(win, { position: "centerBelow" });
   * ```
   */
  attachWindow(window: WindowHandle, opts?: AttachWindowOptions): void;
  /** Detach the previously attached window. Restores menu-only or click-event mode. */
  detachWindow(): void;
  destroy(): void;
}

let trayCounter = 0;
const clickHandlers = new Map<number, Set<() => void>>();
const rightClickHandlers = new Map<number, Set<() => void>>();
const menuActionsByTray = new Map<number, Map<string, (ctx?: ActionContext) => void>>();
const menuTreesByTray = new Map<number, MenuItemDef[]>();

let eventsWired = false;

function ensureEventsWired() {
  if (eventsWired) return;
  eventsWired = true;
  Events.on("__tray:click", (payload: any) => {
    const data = typeof payload === "string" ? JSON.parse(payload) : payload;
    const handlers = clickHandlers.get(data?.id);
    if (handlers) for (const h of handlers) h();
  });
  Events.on("__tray:right-click", (payload: any) => {
    const data = typeof payload === "string" ? JSON.parse(payload) : payload;
    const handlers = rightClickHandlers.get(data?.id);
    if (handlers) for (const h of handlers) h();
  });
  Events.on("__menu:click", (payload: any) => {
    const data = typeof payload === "string" ? JSON.parse(payload) : payload;
    const itemId = data?.id;
    if (!itemId) return;
    // Menu items are global (action ids unique app-wide via menu.ts's
    // counter), but tray menus register their actions under the tray's
    // own map. Look across all trays — first match wins.
    for (const [trayId, actions] of menuActionsByTray) {
      const handler = actions.get(itemId);
      if (!handler) continue;
      let win: WindowHandle;
      try {
        win = Window.current();
      } catch {
        // Outside WebView context — should not normally happen for tray menu clicks.
        return;
      }
      const update = (patch: MenuItemPatch) => {
        const tree = menuTreesByTray.get(trayId);
        if (!tree) return;
        const patched = patchMenuTree(tree, itemId, patch);
        menuTreesByTray.set(trayId, patched);
        postAction("tray:setMenu", { id: trayId, items: stripActions(patched) });
      };
      handler({ id: itemId, window: win, update });
      return;
    }
  });
}

let menuActionCounter = 0;

function collectActions(items: MenuItemDef[]): Map<string, (ctx?: ActionContext) => void> {
  const actions = new Map<string, (ctx?: ActionContext) => void>();
  function walk(items: MenuItemDef[]) {
    for (const item of items) {
      if (item.action) {
        if (!item.id) item.id = `__tray_menu_${++menuActionCounter}`;
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

function postAction(method: string, args: Record<string, unknown>) {
  (getBridge() as any).post(JSON.stringify({ t: 4, m: method, a: args }));
}

export const Tray = {
  create(opts: TrayOptions): TrayHandle {
    ensurePermission("tray");
    ensureEventsWired();
    const id = ++trayCounter;

    let cleanMenu: any[] = [];
    if (opts.menu) {
      menuActionsByTray.set(id, collectActions(opts.menu));
      menuTreesByTray.set(id, opts.menu);
      cleanMenu = stripActions(opts.menu);
    }

    postAction("tray:create", {
      id,
      icon: opts.icon,
      title: opts.title ?? "",
      tooltip: opts.tooltip ?? "",
      template: opts.template ?? false,
      menu: cleanMenu,
    });

    return {
      id,

      setIcon(path: string, iconOpts?: { template?: boolean }) {
        postAction("tray:setIcon", {
          id, path,
          template: iconOpts?.template ?? false,
        });
      },

      setTitle(title: string) {
        postAction("tray:setTitle", { id, title });
      },

      setTooltip(tooltip: string) {
        postAction("tray:setTooltip", { id, tooltip });
      },

      setMenu(items: MenuItemDef[]) {
        menuActionsByTray.set(id, collectActions(items));
        menuTreesByTray.set(id, items);
        postAction("tray:setMenu", { id, items: stripActions(items) });
      },

      attachWindow(window: WindowHandle, opts?: AttachWindowOptions) {
        // WindowHandle.id is "win-<N>" — extract N for the native call.
        const m = /^win-(\d+)$/.exec(window.id);
        const numericId = m ? parseInt(m[1], 10) : -1;
        if (numericId < 0) {
          console.warn(`[zapp] tray.attachWindow: bad windowId "${window.id}"`);
          return;
        }
        postAction("tray:attachWindow", {
          id,
          windowId: numericId,
          position: opts?.position ?? "centerBelow",
          dismissOnBlur: opts?.dismissOnBlur ?? true,
          dismissOnOutsideClick: opts?.dismissOnOutsideClick ?? true,
          toggleOnClick: opts?.toggleOnClick ?? true,
          offset: { x: opts?.offset?.x ?? 0, y: opts?.offset?.y ?? 4 },
        });
      },

      detachWindow() {
        postAction("tray:detachWindow", { id });
      },

      on(event: "click" | "right-click", handler: () => void) {
        const map = event === "click" ? clickHandlers : rightClickHandlers;
        let set = map.get(id);
        if (!set) { set = new Set(); map.set(id, set); }
        set.add(handler);
        return () => { set!.delete(handler); };
      },

      destroy() {
        postAction("tray:destroy", { id });
        clickHandlers.delete(id);
        rightClickHandlers.delete(id);
        menuActionsByTray.delete(id);
        menuTreesByTray.delete(id);
      },
    };
  },
};
