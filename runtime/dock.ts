/**
 * Dock — dock icon and badge control.
 *
 * @example
 * ```ts
 * import { Dock } from "@zappdev/runtime";
 *
 * Dock.setBadge("5");
 * Dock.bounce();
 * Dock.hideIcon();
 * ```
 */

import { getBridge } from "./bridge";

// In worker contexts, __zappBridge.dock is a sync host dispatcher that
// calls darwin_dock_* directly. Webview fallback uses IPC-style post.
function dockHost(): ((action: string, args?: unknown) => void) | null {
  const host = (globalThis as any).__zappBridge;
  return host?.dock ?? null;
}

export const Dock = {
  /** Show the app icon in the dock/taskbar. */
  showIcon(): void {
    const host = dockHost();
    if (host) { host("showIcon"); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:showIcon", a: {} }));
  },

  /** Hide the app icon from the dock/taskbar. */
  hideIcon(): void {
    const host = dockHost();
    if (host) { host("hideIcon"); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:hideIcon", a: {} }));
  },

  /** Set a text badge on the dock icon (e.g. "5", "new"). */
  setBadge(label: string): void {
    const host = dockHost();
    if (host) { host("setBadge", { label }); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:setBadge", a: { label } }));
  },

  /** Remove the badge from the dock icon. */
  removeBadge(): void {
    const host = dockHost();
    if (host) { host("removeBadge"); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:removeBadge", a: {} }));
  },

  /** Bounce the dock icon to get user attention.
   * @param type "informational" (bounces once) or "critical" (bounces until activated). Default: "informational"
   */
  bounce(type: "informational" | "critical" = "informational"): void {
    const host = dockHost();
    if (host) { host("bounce", { type: type === "critical" ? 1 : 0 }); return; }
    (getBridge() as any).post(JSON.stringify({
      t: 4, m: "dock:bounce", a: { type: type === "critical" ? 1 : 0 },
    }));
  },

  /** Set a custom dock icon from a file path. */
  setIcon(path: string): void {
    const host = dockHost();
    if (host) { host("setIcon", { path }); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:setIcon", a: { path } }));
  },

  /** Reset the dock icon to the app bundle default. */
  resetIcon(): void {
    const host = dockHost();
    if (host) { host("resetIcon"); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:resetIcon", a: {} }));
  },
};
