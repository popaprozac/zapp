/**
 * Services — call typed native services from JavaScript.
 *
 * @example
 * ```ts
 * import { Services } from "@zappdev/runtime/service";
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
  hostBridge: {
    invokeService(method: string, args?: TArgs): TReturn | PromiseLike<TReturn>;
    cancelService?(requestId: number): boolean;
  },
  method: string,
  args: TArgs | undefined,
  opts: InvokeOptions | undefined,
): CancellablePromise<TReturn> {
  const signal = opts?.signal;
  if (signal?.aborted) {
    const aborted = Promise.reject<TReturn>(abortError()) as CancellablePromise<TReturn>;
    aborted.cancel = () => {};
    return aborted;
  }

  let value: TReturn | PromiseLike<TReturn>;
  try {
    // Native entry remains hot and synchronous. Only a genuinely suspended
    // service returns a Promise-like continuation from the host.
    value = hostBridge.invokeService(method, args);
  } catch (error) {
    const failed = Promise.reject<TReturn>(
      normalizeWorkerError(error),
    ) as CancellablePromise<TReturn>;
    failed.cancel = () => {};
    return failed;
  }

  const thenable = value !== null
    && (typeof value === "object" || typeof value === "function")
    && typeof (value as { then?: unknown }).then === "function";
  if (!thenable) {
    // Keep synchronous worker services on the allocation-lean path. The
    // generated facade still returns its ordinary Promise API, but no abort
    // listener or native-continuation closure is needed after native return.
    const settled = Promise.resolve(value as TReturn) as CancellablePromise<TReturn>;
    settled.cancel = () => {};
    return settled;
  }

  let completed = false;
  let rejectSource: (reason?: unknown) => void = () => {};
  const id = Number((value as { __zappRequestId?: unknown }).__zappRequestId);
  const requestId = Number.isFinite(id) && id > 0 ? id : undefined;
  let cancel = () => {};
  const cleanup = () => signal?.removeEventListener("abort", cancel);
  const source = new Promise<TReturn>((resolve, reject) => {
    rejectSource = reject;
    Promise.resolve(value).then(
      (resolved) => {
        if (completed) return;
        completed = true;
        cleanup();
        resolve(resolved);
      },
      (error) => {
        if (completed) return;
        completed = true;
        cleanup();
        reject(normalizeWorkerError(error));
      },
    );
  }) as CancellablePromise<TReturn>;
  cancel = () => {
    if (completed) return;
    completed = true;
    if (requestId !== undefined) hostBridge.cancelService?.(requestId);
    cleanup();
    rejectSource(abortError());
  };
  source.cancel = cancel;
  signal?.addEventListener("abort", cancel, { once: true });
  // Cover a signal that changed after native entry but before listener setup.
  if (signal?.aborted) cancel();
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
        {
          invokeService: directWorkerInvoke,
          cancelService: (globalThis as any).__zappWorkerCancelService,
        },
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
