import { Events } from "./events";
import type { MenuItemDef } from "./menu";

let contextMenuSeq = 0;
let _lastContextX = 0;
let _lastContextY = 0;

// Track the last contextmenu event position
if (typeof document !== "undefined") {
  document.addEventListener("contextmenu", (e) => {
    _lastContextX = e.clientX;
    _lastContextY = e.clientY;
  }, true); // capture phase — runs before user handlers
}

type ActionEntry = { id: string; handler: () => void };

function collectActions(items: MenuItemDef[], actions: ActionEntry[]): MenuItemDef[] {
  return items.map((item) => {
    const copy = { ...item };
    if (copy.action && !copy.id) {
      copy.id = `__ctx_${++contextMenuSeq}`;
    }
    if (copy.action && copy.id) {
      actions.push({ id: copy.id, handler: copy.action });
    }
    delete copy.action;
    if (copy.submenu) {
      copy.submenu = collectActions(copy.submenu, actions);
    }
    return copy;
  });
}

export interface ContextMenuAPI {
  /** Show a native context menu at the current cursor position */
  show(items: MenuItemDef[]): void;
}

export const ContextMenu: ContextMenuAPI = {
  show(items: MenuItemDef[]): void {
    const actions: ActionEntry[] = [];
    const cleanItems = collectActions(items, actions);

    // Wire up action handlers — clean up after any click or menu dismiss
    const offs: (() => void)[] = [];
    for (const { id, handler } of actions) {
      const off = Events.on(`menu:${id}`, () => {
        handler();
        for (const o of offs) o();
      });
      offs.push(off);
    }

    // Auto-cleanup after a short delay if no item was clicked (menu dismissed)
    setTimeout(() => {
      for (const off of offs) off();
    }, 30000);

    // Post to native
    const handler = (globalThis as unknown as Record<string, Record<string, Record<string, { postMessage?: (m: string) => void }>>>)
      .webkit?.messageHandlers?.zapp;
    const chromeWebview = (globalThis as unknown as Record<string, Record<string, { postMessage?: (m: string) => void }>>)
      .chrome?.webview;

    const windowId = (globalThis as unknown as Record<symbol, unknown>)[Symbol.for("zapp.windowId")] as string | undefined;
    // Pass last known mouse position for accurate placement
    const msg = `window\nshowContextMenu\n${JSON.stringify({
      windowId: windowId ?? "unknown",
      items: cleanItems,
      x: _lastContextX,
      y: _lastContextY,
    })}`;

    if (handler?.postMessage) {
      handler.postMessage(msg);
    } else if (chromeWebview?.postMessage) {
      chromeWebview.postMessage(msg);
    }
  },
};
