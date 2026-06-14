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
import { ensurePermission } from "./permissions";

// In worker contexts, __zappBridge.dock is a sync host dispatcher that
// calls darwin_dock_* directly. Webview fallback uses IPC-style post.
function dockHost(): ((action: string, args?: unknown) => void) | null {
  const host = (globalThis as any).__zappBridge;
  return host?.dock ?? null;
}

export const Dock = {
  /** Show the app icon in the dock/taskbar. */
  showIcon(): void {
    ensurePermission("dock");
    const host = dockHost();
    if (host) { host("showIcon"); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:showIcon", a: {} }));
  },

  /** Hide the app icon from the dock/taskbar. */
  hideIcon(): void {
    ensurePermission("dock");
    const host = dockHost();
    if (host) { host("hideIcon"); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:hideIcon", a: {} }));
  },

  /** Set a text badge on the dock icon (e.g. "5", "new"). */
  setBadge(label: string): void {
    ensurePermission("dock");
    const host = dockHost();
    if (host) { host("setBadge", { label }); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:setBadge", a: { label } }));
  },

  /** Remove the badge from the dock icon. */
  removeBadge(): void {
    ensurePermission("dock");
    const host = dockHost();
    if (host) { host("removeBadge"); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:removeBadge", a: {} }));
  },

  /** Bounce the dock icon to get user attention.
   * @param type "informational" (bounces once) or "critical" (bounces until activated). Default: "informational"
   */
  bounce(type: "informational" | "critical" = "informational"): void {
    ensurePermission("dock");
    const host = dockHost();
    if (host) { host("bounce", { type: type === "critical" ? 1 : 0 }); return; }
    (getBridge() as any).post(JSON.stringify({
      t: 4, m: "dock:bounce", a: { type: type === "critical" ? 1 : 0 },
    }));
  },

  /** Set a custom dock icon from a file path. */
  setIcon(path: string): void {
    ensurePermission("dock");
    const host = dockHost();
    if (host) { host("setIcon", { path }); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:setIcon", a: { path } }));
  },

  /** Reset the dock icon to the app bundle default. */
  resetIcon(): void {
    ensurePermission("dock");
    const host = dockHost();
    if (host) { host("resetIcon"); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:resetIcon", a: {} }));
  },

  /**
   * Show a progress bar on the app's taskbar button (Windows) / dock tile.
   * @param fraction 0..1 completion. Pass a negative value to clear.
   * @param options.mode "normal" (default), "indeterminate" (animated, ignores
   *   fraction), "error" (red), or "paused" (yellow).
   *
   * Windows-native (ITaskbarList3). No-op on macOS for now (dock-tile progress
   * isn't wired) and inert on iOS — safe to call cross-platform.
   */
  setProgress(
    fraction: number,
    options?: { mode?: "normal" | "indeterminate" | "error" | "paused" },
  ): void {
    ensurePermission("dock");
    const modeMap = { normal: 0, indeterminate: 1, error: 2, paused: 3 } as const;
    const mode = modeMap[options?.mode ?? "normal"];
    const permille = fraction < 0 ? -1 : Math.max(0, Math.min(1000, Math.round(fraction * 1000)));
    const host = dockHost();
    if (host) { host("setProgress", { permille, mode }); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:setProgress", a: { permille, mode } }));
  },

  /** Clear the taskbar/dock progress indicator. */
  clearProgress(): void {
    ensurePermission("dock");
    const host = dockHost();
    if (host) { host("setProgress", { permille: -1, mode: 4 }); return; }
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "dock:setProgress", a: { permille: -1, mode: 4 } }));
  },
};
