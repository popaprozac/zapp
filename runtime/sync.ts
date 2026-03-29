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
   */
  async wait(
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
   * @param key - Sync key
   * @param count - Number of waiters to wake (default 1)
   */
  notify(key: string, count = 1): void {
    const bridge = getBridge() as any;
    if (!bridge?.syncNotify) return;
    if (typeof key !== "string" || key.trim().length === 0) return;
    bridge.syncNotify(key.trim(), Math.max(1, Math.min(count, 65535)));
  },
};
