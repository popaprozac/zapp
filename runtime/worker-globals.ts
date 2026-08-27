/**
 * Worker globals — TYPE declarations for `send`, `receive`,
 * `__zappBridge`, etc.
 *
 * Runtime installation of WHATWG-shaped globals (`fetch`, `WebSocket`,
 * etc.) is driven by `workers.capabilities` in `zapp.config.ts`. The Vite
 * plugin auto-prepends the binding code to every worker bundle, so
 * user code can just call `fetch(...)` without any per-worker import.
 *
 * @example
 * ```ts
 * // zapp.config.ts
 * workers: { capabilities: ["fetch", "websocket"] }
 *
 * // src/worker.ts — no setup needed
 * fetch("https://example.com").then(r => r.text());
 * ```
 *
 * **Legacy per-subpath imports** (`import "@zappdev/runtime/worker-globals/fetch"`)
 * still work for projects not using `workers.capabilities`. They bind the
 * same globals via the file shims in this directory. Avoid mixing
 * the two approaches — the prelude is canonical.
 */

declare global {
  /** Send a message on a named channel to the owning WebView. */
  function send(channel: string, data: unknown): void;

  /** Listen for messages on a named channel. Returns unsubscribe function. */
  function receive(channel: string, handler: (data: unknown) => void): () => void;

  /** Post a raw message to the owning WebView. */
  function postMessage(data: unknown): void;

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
}

// The no-subpath aggregator does NOT auto-import per-capability shims
// anymore. Reason: those shims live outside the project root (in the
// framework's `runtime/worker-globals/`), so when bundled they cause
// Vite to externalize their `import bareFetch from "bare-fetch"` etc.
// — invalid output for the worker's `js_run_script` script context.
//
// Use `workers.capabilities` in `zapp.config.ts` for runtime installs (the
// canonical path), or import a specific subpath like
// `import "@zappdev/runtime/worker-globals/fetch"` for one-off opt-in.

export {};
