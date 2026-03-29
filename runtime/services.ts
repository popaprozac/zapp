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
   * Returns a cancellable promise that resolves with the service result.
   */
  invoke<T = unknown>(method: string, args?: Record<string, unknown>, opts?: InvokeOptions): CancellablePromise<T> {
    return getBridge().invoke(method, args, opts) as CancellablePromise<T>;
  },
};
