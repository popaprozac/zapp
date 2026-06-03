/**
 * App — application lifecycle, events, and configuration.
 *
 * @example
 * ```ts
 * import { App, AppEvent } from "@zappdev/runtime";
 *
 * App.on(AppEvent.REOPEN, () => console.log("dock icon clicked"));
 * App.on(AppEvent.OPEN_URL, (data) => console.log("deep link:", data.url));
 * App.quit();
 * ```
 */

import { getBridge } from "./bridge";
import { Events, AppEvent, eventName } from "./events";

// Send a window-action-style message (t:4) for fire-and-forget app
// commands that don't need a request/response. Same wire format as
// runtime/window.ts's windowAction; duplicated here to avoid an
// import cycle through the window module.
function appAction(action: string, args: Record<string, unknown> = {}): void {
  (getBridge() as any).post(JSON.stringify({ t: 4, m: action, a: args }));
}

// Cached system appearance. Webviews seed this from bootstrap config
// (so the first synchronous read after import is correct, no flash).
// Workers don't get bootstrap config — they default to "light" until
// the first app:theme-changed event fires; native dispatches one at
// startup for any webview-spawned worker so this is rarely an issue
// in practice. Subscribed at module-load so cached value tracks live
// changes (System Settings → Appearance toggles, auto-schedule).
let _theme: "light" | "dark" = "light";
{
  const cfg = (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
  if (cfg && (cfg.theme === "light" || cfg.theme === "dark")) {
    _theme = cfg.theme;
  }
  // Bridge should be available at module-load (bootstrap runs before user
  // code in both webview and worker contexts), but guard so a non-Zapp
  // import (e.g. running tests outside a webview) doesn't blow up.
  try {
    Events.on("app:theme-changed", (data: any) => {
      if (data && (data.theme === "light" || data.theme === "dark")) {
        _theme = data.theme;
      }
    });
  } catch { /* bridge not available — fine for non-Zapp imports */ }
}

export const App = {
  /** Listen for app lifecycle events. Returns unsubscribe function. */
  on(event: AppEvent, handler: (data?: any) => void): () => void {
    const name = eventName(event);
    return Events.on(name, handler);
  },

  /**
   * Quit the application.
   *
   * If a quit guard is armed via {@link App.setQuitGuard}, a plain
   * `App.quit()` is intercepted: the app stays open and fires
   * `AppEvent.BEFORE_QUIT` instead. Call `App.quit({ force: true })`
   * (e.g. after the user confirms in your "unsaved changes?" dialog) to
   * actually terminate.
   */
  quit(opts?: { force?: boolean }): void {
    appAction("quit", { force: opts?.force ?? false });
  },

  /**
   * Arm/disarm the app-level quit guard. When armed, Cmd-Q / the menu
   * Quit / `App.quit()` fire `AppEvent.BEFORE_QUIT` and do NOT terminate;
   * call `App.quit({ force: true })` to proceed. The App analog of
   * `WindowHandle.setCloseGuard`. macOS only.
   */
  setQuitGuard(enabled: boolean): void {
    appAction("setQuitGuard", { enabled });
  },

  /**
   * Enable or disable launch-at-login. Returns whether the change took
   * effect. macOS 13+; on macOS 12 this is a no-op that returns `false`.
   * iOS/Windows: `false`.
   */
  async setLoginItem(enabled: boolean): Promise<boolean> {
    return (await getBridge().invoke("__app:setLoginItem", { enabled })) as boolean;
  },

  /** Whether this app is registered to launch at login. */
  async getLoginItemEnabled(): Promise<boolean> {
    return (await getBridge().invoke("__app:getLoginItem")) as boolean;
  },

  /** Open a URL in the system browser. */
  openExternal(url: string): void {
    appAction("openExternal", { url });
  },

  /**
   * Reveal a file or folder in Finder, with the item selected.
   * For files this is the same as right-click → "Show in Finder".
   * Fire-and-forget — silently no-ops if the path doesn't exist.
   *
   * Path variables (`$userData`, `~/`, etc.) are expanded the same
   * way `app.fs.*` resolves them, so the same path string works for
   * both reading and revealing.
   *
   * Note: passing a folder reveals the folder *inside its parent*,
   * not the folder's contents. Use `App.openPath(folder)` if you
   * want the folder itself opened in Finder.
   *
   * Not gated by the FS allowlist — Finder reveal is a user-visible
   * action that doesn't mutate disk state.
   */
  showItemInFolder(path: string): void {
    appAction("showItemInFolder", { path });
  },

  /**
   * Open a file or folder using the system default application.
   * - File: launches the associated app (TextEdit for `.txt`,
   *   Preview for `.png`, etc.) — equivalent to a double-click.
   * - Folder: opens the folder in Finder.
   *
   * For URLs with schemes (`https://`, `mailto:`, etc.) use
   * `App.openExternal` instead — this method takes filesystem paths
   * only. Path variables (`$userData`, `~/`, etc.) are expanded.
   *
   * Not gated by the FS allowlist — handing off to the default app is
   * user-visible and the user can cancel.
   */
  openPath(path: string): void {
    appAction("openPath", { path });
  },

  /**
   * Move a file or folder to the user's Trash. Reversible from
   * Finder via "Put Back". Fire-and-forget — silent on failure
   * (path missing, permission denied, **or path not in
   * `config.fs.allow`**). Callers wanting to confirm removal can
   * `app.fs.exists(path)` afterward.
   *
   * Path variables (`$userData`, `~/`, etc.) are expanded.
   *
   * **Gated by the FS allowlist** — same `config.fs.allow` list that
   * gates `app.fs.remove`. Paths the user picks via `Dialog.openFile`
   * extend the session allowlist automatically, so the common
   * "user picks file → app trashes it" flow works out of the box.
   */
  trashItem(path: string): void {
    appAction("trashItem", { path });
  },

  /** Get the app config injected by the native bootstrap. */
  getConfig(): Record<string, unknown> {
    return (globalThis as any)[Symbol.for("zapp.bootstrapConfig")] ?? {};
  },

  /**
   * Current system appearance. Returns `"light"` or `"dark"`. Synchronous
   * — backed by an in-memory cache that's seeded at import time from the
   * bootstrap config and refreshed on every `AppEvent.THEME_CHANGED`.
   *
   * Subscribe to changes:
   *
   * @example
   * ```ts
   * import { App, AppEvent } from "@zappdev/runtime";
   *
   * applyTheme(App.getTheme());
   * App.on(AppEvent.THEME_CHANGED, ({ theme }) => applyTheme(theme));
   * ```
   *
   * **Worker caveat.** Workers don't receive bootstrap config, so the
   * cached value defaults to `"light"` until the first
   * `app:theme-changed` event arrives. If your worker needs the theme
   * before then, listen for the event and act on it.
   */
  getTheme(): "light" | "dark" {
    return _theme;
  },
};
