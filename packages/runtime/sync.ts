type Bridge = {
  syncWait?: (request: {
    key: string;
    timeoutMs: number | null;
    signal?: AbortSignal;
  }) => Promise<"notified" | "timed-out">;
  syncNotify?: (request: { key: string; count: number }) => boolean;
  syncCancel?: (request: { id: string }) => boolean;
};

/** Options for {@link SyncAPI.wait}. */
export type SyncWaitOptions = {
  /** Timeout in milliseconds, or null to wait indefinitely. */
  timeoutMs?: number | null;
  /** An AbortSignal to cancel the wait. */
  signal?: AbortSignal;
};

const getBridge = (): Bridge | null =>
  ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as Bridge | undefined) ?? null;

/** API for cross-context synchronization primitives (wait/notify). */
export interface SyncAPI {
  /** Block until the given key is notified or the timeout elapses. */
  wait(key: string, timeoutOrOptions?: number | SyncWaitOptions | null): Promise<"notified" | "timed-out">;
  /** Wake up to `count` waiters blocked on the given key. */
  notify(key: string, count?: number): boolean;
}

/** The singleton synchronization API instance. */
export const Sync: SyncAPI = {
  async wait(
    key: string,
    timeoutOrOptions: number | SyncWaitOptions | null = 30000
  ): Promise<"notified" | "timed-out"> {
    const bridge = getBridge();
    if (!bridge?.syncWait) {
      throw new Error("Sync bridge is unavailable.");
    }
    if (typeof key !== "string" || key.trim().length === 0) {
      throw new Error("Sync key must be a non-empty string.");
    }
    const options: SyncWaitOptions =
      typeof timeoutOrOptions === "number" || timeoutOrOptions == null
        ? { timeoutMs: timeoutOrOptions }
        : timeoutOrOptions;
    return await bridge.syncWait({
      key: key.trim(),
      timeoutMs: options.timeoutMs ?? null,
      signal: options.signal,
    });
  },

  notify(key: string, count = 1): boolean {
    const bridge = getBridge();
    if (!bridge?.syncNotify) return false;
    if (typeof key !== "string" || key.trim().length === 0) return false;
    return bridge.syncNotify({ key: key.trim(), count });
  },
};
