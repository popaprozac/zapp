/**
 * Shortcuts — system-wide global hotkeys.
 *
 * Backed by Carbon's RegisterEventHotKey on macOS (works regardless of
 * focus, no accessibility entitlement needed). Accelerator strings use
 * the same `"CmdOrCtrl+Shift+Space"` notation as menu accelerators.
 *
 * Callbacks are dispatched on the registering context's event loop —
 * webview registrations fire in the webview, worker registrations fire
 * in the worker. Multiple contexts can each register the same
 * accelerator independently (each gets its own callback) — Carbon
 * itself only allows one app-wide registration, but we route the
 * single native dispatch to every JS-side listener.
 *
 * @example
 * ```ts
 * import { Shortcuts } from "@zappdev/runtime";
 *
 * const ok = await Shortcuts.register("CmdOrCtrl+Shift+Space", () => {
 *   Window.current().show();
 * });
 * if (!ok) console.warn("hotkey already taken by another app");
 *
 * await Shortcuts.unregister("CmdOrCtrl+Shift+Space");
 * ```
 */

import { getBridge } from "./bridge";
import { Events } from "./events";

// Accelerator → callback map. Native fires `app:shortcut-triggered`
// with the accelerator string; we route to the local callback. One
// subscription per process is enough — multiple register() calls in
// the same context just update the map entry.
const callbacks = new Map<string, () => void>();

let subscribed = false;
function ensureSubscribed(): void {
  if (subscribed) return;
  try {
    Events.on("app:shortcut-triggered", (data: any) => {
      const acc = data?.accelerator;
      if (typeof acc === "string") {
        const cb = callbacks.get(acc);
        if (cb) {
          try { cb(); } catch (e) { console.error("[shortcuts]", e); }
        }
      }
    });
    subscribed = true;
  } catch { /* bridge not ready — defer */ }
}

function shortcutsHost(): ((action: string, args?: unknown) => unknown) | null {
  const host = (globalThis as any).__zappBridge;
  return host?.shortcuts ?? null;
}

export const Shortcuts = {
  /**
   * Register a global hotkey. Returns `true` on success, `false` if:
   * - the accelerator is already registered by this app (call
   *   `unregister` first if you want to replace).
   * - another app already holds the hotkey at the OS level.
   * - the accelerator string couldn't be parsed (unknown modifier or
   *   key — check the accepted tokens in the docs).
   *
   * @param accelerator e.g. `"CmdOrCtrl+Shift+Space"`, `"Cmd+K"`.
   * @param handler invoked on every press while the registration is
   *   active. Errors thrown inside the handler are caught and logged.
   */
  async register(accelerator: string, handler: () => void): Promise<boolean> {
    if (!accelerator) return false;
    ensureSubscribed();
    callbacks.set(accelerator, handler);
    const host = shortcutsHost();
    let ok: boolean;
    if (host) {
      ok = Boolean(host("register", { accelerator }));
    } else {
      const r = await getBridge().invoke("__shortcuts:register", { accelerator }) as unknown;
      ok = r === true;
    }
    if (!ok) callbacks.delete(accelerator);  // don't leak the callback if native refused
    return ok;
  },

  /**
   * Unregister a previously-registered shortcut. Returns `true` if
   * found and removed, `false` if it wasn't registered. Idempotent —
   * safe to call regardless of state.
   */
  async unregister(accelerator: string): Promise<boolean> {
    if (!accelerator) return false;
    callbacks.delete(accelerator);
    const host = shortcutsHost();
    if (host) return Promise.resolve(Boolean(host("unregister", { accelerator })));
    const r = await getBridge().invoke("__shortcuts:unregister", { accelerator }) as unknown;
    return r === true;
  },

  /** Test whether an accelerator is currently registered by this app. */
  async isRegistered(accelerator: string): Promise<boolean> {
    if (!accelerator) return false;
    const host = shortcutsHost();
    if (host) return Promise.resolve(Boolean(host("isRegistered", { accelerator })));
    const r = await getBridge().invoke("__shortcuts:isRegistered", { accelerator }) as unknown;
    return r === true;
  },

  /**
   * Tear down every shortcut this app has registered. Useful for
   * "Reset shortcuts" UI or test teardown. Doesn't fire the per-
   * shortcut handlers.
   */
  async unregisterAll(): Promise<void> {
    callbacks.clear();
    const host = shortcutsHost();
    if (host) { host("unregisterAll"); return; }
    await getBridge().invoke("__shortcuts:unregisterAll");
  },
};
