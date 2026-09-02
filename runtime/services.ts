/**
 * Services — call typed native services from JavaScript.
 *
 * @example
 * ```ts
 * import { Services } from "@zappdev/runtime";
 * const result = await Services.invoke("greet", { name: "World" });
 * ```
 */

import { getBridge } from "./bridge";
import { errorFromBridgePayload } from "./errors";

function abortError(): Error {
  const error = new Error("The operation was aborted");
  error.name = "AbortError";
  return error;
}

function normalizeWorkerError(error: unknown): Error {
  if (typeof error === "string") return errorFromBridgePayload(error);
  if (error instanceof Error) {
    return error.name === "Error"
      ? errorFromBridgePayload(error.message)
      : error;
  }
  return new Error(String(error));
}

function invokeDirectWorker<TReturn, TArgs>(
  hostBridge: { invokeService(method: string, args?: TArgs): TReturn },
  method: string,
  args: TArgs | undefined,
  opts: InvokeOptions | undefined,
): CancellablePromise<TReturn> {
  let completed = false;
  const source = new Promise<TReturn>((resolve, reject) => {
    if (opts?.signal?.aborted) {
      completed = true;
      reject(abortError());
      return;
    }
    // Synchronous native services are hot: enter the host during the call,
    // then expose the result through the same Promise API generated for a
    // WebView. Once entered, this tier has no suspended work to cancel.
    try {
      const value = hostBridge.invokeService(method, args);
      completed = true;
      resolve(value);
    } catch (error) {
      completed = true;
      reject(normalizeWorkerError(error));
    }
  }) as CancellablePromise<TReturn>;
  source.cancel = () => {
    if (completed) return;
    completed = true;
  };
  return source;
}

export interface InvokeOptions {
  /** Timeout in milliseconds. Default: 15000. */
  timeout?: number;
  /** Abort the pending bridge request and request native task cancellation. */
  signal?: AbortSignal;
}

export interface CancellablePromise<T> extends Promise<T> {
  /** Cancel the pending invoke. Rejects with an AbortError. */
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
    const directWorkerInvoke = (globalThis as any).__zappWorkerInvokeService;
    if (typeof directWorkerInvoke === "function") {
      return invokeDirectWorker(
        { invokeService: directWorkerInvoke },
        method,
        args,
        opts,
      );
    }

    // Worker context: retain the same generated Promise API while selecting
    // the fastest host transport available underneath it. A Z-owned worker
    // host exposes invokeService directly; older hosts may additionally offer
    // invoke for asynchronous service continuations.
    const hostBridge = (globalThis as any).__zappBridge;
    if (hostBridge?.invokeService) {
      if (!hostBridge.invoke) {
        return invokeDirectWorker(hostBridge, method, args, opts);
      }
      const source = Promise.resolve().then(
        () => hostBridge.invoke(method, args, opts),
      ).catch((error) => {
        throw normalizeWorkerError(error);
      }) as CancellablePromise<TReturn>;
      source.cancel = () => {};
      return source;
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
