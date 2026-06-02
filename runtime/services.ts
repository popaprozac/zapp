/**
 * Services — call native Zen-C services from JavaScript.
 *
 * @example
 * ```ts
 * import { Services } from "@zappdev/runtime";
 * const result = await Services.invoke("greet", { name: "World" });
 * ```
 */

import { getBridge } from "./bridge";

export interface InvokeOptions {
  /** Timeout in milliseconds. Default: 15000. */
  timeout?: number;
}

export interface CancellablePromise<T> extends Promise<T> {
  /** Cancel the pending invoke. Rejects with CancelledError. */
  cancel(): void;
}

export const Services = {
  /**
   * Invoke a native service by name.
   * In WebView/backend: async bridge call (returns CancellablePromise).
   * In workers: sync host object call (returns resolved Promise).
   */
  invoke<TReturn = unknown, TArgs = Record<string, unknown>>(
    method: string,
    args?: TArgs,
    opts?: InvokeOptions
  ): CancellablePromise<TReturn> {
    // Worker/backend context: use host object for sync invocation
    const hostBridge = (globalThis as any).__zappBridge;
    if (hostBridge?.invokeService) {
      const result = hostBridge.invokeService(method, args) as TReturn;
      const p = Promise.resolve(result) as CancellablePromise<TReturn>;
      p.cancel = () => {};
      // Also expose sync result directly for worker convenience
      (p as any).value = result;
      return p;
    }

    // WebView context: async bridge call
    return getBridge().invoke(method, args as Record<string, unknown> | undefined, opts) as CancellablePromise<TReturn>;
  },

  /**
   * Invoke a native service synchronously (workers/backend only).
   * Throws if called from WebView context.
   */
  invokeSync<T = unknown>(method: string, args?: Record<string, unknown>): T {
    const hostBridge = (globalThis as any).__zappBridge;
    if (!hostBridge?.invokeService) {
      throw new Error("[zapp] invokeSync is only available in workers and backend contexts");
    }
    return hostBridge.invokeService(method, args) as T;
  },
};
