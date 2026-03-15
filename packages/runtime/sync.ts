type Bridge = {
  syncWait?: (request: {
    key: string;
    timeoutMs: number | null;
    signal?: AbortSignal;
  }) => Promise<"notified" | "timed-out">;
  syncNotify?: (request: { key: string; count: number }) => boolean;
  syncCancel?: (request: { id: string }) => boolean;
};

export type SyncWaitOptions = {
  timeoutMs?: number | null;
  signal?: AbortSignal;
};

const getBridge = (): Bridge | null =>
  ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as Bridge | undefined) ?? null;

export interface SyncAPI {
  wait(key: string, timeoutOrOptions?: number | SyncWaitOptions | null): Promise<"notified" | "timed-out">;
  notify(key: string, count?: number): boolean;
}

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
