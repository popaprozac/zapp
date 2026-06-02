/**
 * Sync — cross-context wait/notify coordination.
 *
 * @example
 * ```ts
 * import { Sync } from "@zappdev/runtime";
 *
 * // In one context (window or worker):
 * const result = await Sync.wait("data-ready", 5000);
 * // result: "notified" | "timed-out"
 *
 * // In another context:
 * Sync.notify("data-ready");
 * ```
 */

import { getBridge } from "./bridge";

/** Options for {@link Sync.wait}. */
export interface SyncWaitOptions {
  /** Timeout in milliseconds, or null/undefined to wait indefinitely. */
  timeoutMs?: number | null;
}

export const Sync = {
  /**
   * Block until the given key is notified or the timeout elapses.
   * @param key - Sync key (non-empty string)
   * @param timeoutOrOptions - Timeout in ms, options object, or null for indefinite
   * @returns "notified" or "timed-out"
   *
   * Written as `wait: async function()` rather than `async wait()` shorthand
   * to work around a zjs parser case. Repro: `var x = { async m(e, n=3e4) {} }`
   * (declaration form + default parameter + multi-method object literal +
   * module mode) → `SyntaxError: module parse error`. Inline expression
   * forms `({ async m() {} }).m()` parse fine. The exact trigger is one of:
   * declaration vs expression, default parameter, mixed async/non-async,
   * or module vs script mode. See [[reference_zjs_async_method_shorthand]].
   */
  wait: async function(
    key: string,
    timeoutOrOptions: number | SyncWaitOptions | null = 30000
  ): Promise<"notified" | "timed-out"> {
    const bridge = getBridge() as any;
    if (!bridge?.syncWait) {
      throw new Error("Sync bridge is unavailable.");
    }
    if (typeof key !== "string" || key.trim().length === 0) {
      throw new Error("Sync key must be a non-empty string.");
    }

    const timeoutMs =
      typeof timeoutOrOptions === "number"
        ? timeoutOrOptions
        : timeoutOrOptions?.timeoutMs ?? null;

    return await bridge.syncWait(key.trim(), timeoutMs);
  },

  /**
   * Wake up to `count` waiters blocked on the given key.
   *
   * Defaults to **1** — same semantics as `pthread_cond_signal` /
   * `Object.notify()`. Use {@link Sync.notifyAll} to wake every current waiter.
   *
   * @param key - Sync key
   * @param count - Number of waiters to wake (default 1)
   */
  notify(key: string, count = 1): void {
    const bridge = getBridge() as any;
    if (!bridge?.syncNotify) return;
    if (typeof key !== "string" || key.trim().length === 0) return;
    bridge.syncNotify(key.trim(), Math.max(1, Math.min(count, 65535)));
  },

  /**
   * Wake every waiter currently blocked on the given key — broadcast.
   * Equivalent to `pthread_cond_broadcast` / `Object.notifyAll()`.
   */
  notifyAll(key: string): void {
    const bridge = getBridge() as any;
    if (!bridge?.syncNotify) return;
    if (typeof key !== "string" || key.trim().length === 0) return;
    bridge.syncNotify(key.trim(), 65535);
  },
};
