/**
 * Worker globals — typed declarations for Zapp Worker contexts.
 * Import this in worker scripts for TypeScript support.
 *
 * @example
 * ```ts
 * /// <reference path="@zappdev/runtime/worker-globals" />
 * // or
 * import "@zappdev/runtime/worker-globals";
 *
 * send("channel", { data: 123 });
 * receive("result", (data) => console.log(data));
 * ```
 */

export {};

declare global {
  /** Send a message on a named channel to the owning WebView. */
  function send(channel: string, data: unknown): void;

  /** Listen for messages on a named channel. Returns unsubscribe function. */
  function receive(channel: string, handler: (data: unknown) => void): () => void;

  /** Post a raw message to the owning WebView. */
  function postMessage(data: unknown): void;

  /** Raw message handler — receives all messages from the WebView. */
  var onmessage: ((event: { data: unknown }) => void) | null;

  /** The native bridge — host objects for direct C calls. */
  var __zappBridge: {
    /** Invoke a native service synchronously. Returns the result directly. */
    invokeService(method: string, args?: unknown): unknown;

    /** Post data back to the owning WebView. */
    postToWebview(data: unknown): void;

    /** Sync wait — register a waiter on a key. */
    syncWait(key: string, timeoutMs?: number): void;

    /** Sync notify — wake waiters on a key. */
    syncNotify(key: string, count?: number): void;
  };

  var self: typeof globalThis;
}
