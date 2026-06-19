/**
 * Worker — Zapp Workers with postMessage + named channels.
 *
 * @example
 * ```ts
 * import { Worker } from "@zappdev/runtime";
 *
 * const w = new Worker("./worker.ts");
 *
 * // Standard postMessage
 * w.postMessage({ task: "compute" });
 * w.onmessage = (e) => console.log(e.data);
 *
 * // Named channels (typed routing)
 * w.send("compute", { n: 42 });
 * w.receive("result", (data) => console.log(data));
 *
 * w.terminate();
 * ```
 */

import { getBridge, type ZappBridge } from "./bridge";

// Channel message envelope
const CHANNEL_KEY = "__zc";
const DATA_KEY = "d";

export interface WorkerMessageEvent {
  data: unknown;
}

export class Worker {
  readonly id: string;
  private _bridge: ZappBridge;
  onmessage: ((event: WorkerMessageEvent) => void) | null = null;
  onerror: ((error: unknown) => void) | null = null;

  /** @internal */
  _messageHandlers: Array<(event: WorkerMessageEvent) => void> = [];

  /**
   * Create a dedicated worker.
   *
   * @param scriptUrl Module URL bundled by the Vite plugin.
   * @param opts.engine Which engine to spawn this worker on. Picking an
   *   engine the project hasn't built into the binary triggers a runtime
   *   downgrade (logged) to whichever engine IS compiled in. See
   *   `docs/architecture.md#worker-engines` for the size/speed matrix.
   *
   *   **Recommended** (new projects):
   *   - `"zjs"` (default) — Zapp's first-party engine. Cross-platform,
   *     ~1 MB, iOS-friendly. Direct value-marshalling host bridge.
   *   - `"bare-jsc"` — almost-equal recommendation on macOS. JIT via
   *     system JSC framework (zero engine bundle cost). Less streamlined
   *     web APIs — opt into bare-* packages à la carte.
   *
   *   **Perf opt-ins:**
   *   - `"bare-v8"` — JIT on Windows/Linux. ~30 MB bundle increase.
   *
   *   **Niche:**
   *   - `"bare-quickjs"` / `"bare-mqjs"` — small cross-platform variants
   *     for size-constrained targets. zjs is usually a better fit.
   *   - `"bare-hermes"` — Hermes AOT bytecode. Mostly subsumed by zjs's
   *     own bytecode option once mature.
   *
   */
  constructor(scriptUrl: string, opts?: {
    engine?: "zjs" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes";
    name?: string;
  }) {
    this._bridge = getBridge();
    this.id = (this._bridge as any).createWorker(scriptUrl, {
      engine: opts?.engine,
      name: opts?.name,
    });

    // Register this instance for message dispatch
    (this._bridge as any)._workers[this.id] = this;
  }

  /** Send a raw message to the worker. */
  postMessage(data: unknown): void {
    (this._bridge as any).postToWorker(this.id, data);
  }

  /** Send a message on a named channel. */
  send(channel: string, data: unknown): void {
    this.postMessage({ [CHANNEL_KEY]: channel, [DATA_KEY]: data });
  }

  /** Listen for messages on a named channel. Returns unsubscribe function. */
  receive(channel: string, handler: (data: unknown) => void): () => void {
    const listener = (event: WorkerMessageEvent) => {
      const msg = event.data as Record<string, unknown>;
      if (msg && msg[CHANNEL_KEY] === channel) {
        handler(msg[DATA_KEY]);
      }
    };
    this._messageHandlers.push(listener);
    return () => {
      this._messageHandlers = this._messageHandlers.filter(h => h !== listener);
    };
  }

  /** Terminate the worker. */
  terminate(): void {
    (this._bridge as any).terminateWorker(this.id);
    delete (this._bridge as any)._workers[this.id];
  }
}

/**
 * Note: `SharedWorker` is intentionally NOT provided by `@zappdev/runtime`.
 * Use the platform-native `new SharedWorker()` (WKWebView / WebView2) for the
 * web-standard refcounted-across-windows worker; for a Zapp-engine background
 * worker that any window or the backend can talk to, use a **headless** worker
 * (`zapp.config.ts` `headless`) plus the `Workers` namespace below.
 */

/**
 * Snapshot of one active worker, as returned by `Workers.list()`.
 *
 * Mirrors the native registry's JSON shape. `name` and `supervisor` are
 * omitted when not applicable (no display name; not a supervised headless
 * worker). `engine` is `"pending"` until the native resolver picks the
 * engine that actually runs the worker.
 */
export interface WorkerInfo {
  id: string;
  name?: string;
  scriptUrl: string;
  engine: "zjs" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes" | "pending";
  /** Owning window ids — one entry for a dedicated worker, empty for headless. */
  owners: string[];
  supervisor?: {
    maxRetries: number;
    withinMs: number;
    failCount: number;
    gaveUp: boolean;
  };
}

/**
 * A lightweight handle to a worker addressed by id (returned by
 * {@link Workers.get}). Mirrors the operations of a dedicated `Worker`
 * instance for a worker you didn't create — chiefly headless workers.
 *
 * `receive()` (subscribing to messages FROM the worker, webview ← headless)
 * is intentionally absent: a headless worker has no single owner webview, so
 * receiving requires the worker to address subscribers — a separate piece of
 * worker→subscriber routing, planned as a follow-up.
 */
export interface WorkerHandle {
  /** The worker id this handle wraps (e.g. `"h-db"`). */
  readonly id: string;
  /** Send a raw message to the worker (fire-and-forget). */
  postMessage(data: unknown): void;
  /** Send a channel-typed message — the worker's `self.receive("<channel>")` picks it up. */
  send(channel: string, data: unknown): void;
  /** Terminate the worker. No-op for an unknown/terminated id. */
  terminate(): void;
  /** The worker's registry snapshot, or `null` if it isn't running. */
  info(): Promise<WorkerInfo | null>;
}

/**
 * Workers — namespace for managing workers by ID, complementing the
 * `Worker` class which is instance-scoped. Use this when you only have
 * a string ID and no live `Worker` handle — most commonly for headless
 * workers configured via `zapp.config.ts`'s `headless` map, since those
 * are started by the framework and never expose a JS-side `Worker`
 * instance.
 *
 * @example
 * ```ts
 * import { Workers } from "@zappdev/runtime";
 *
 * // zapp.config.ts:
 * //   headless: { sync: "src/workers/sync.ts" }
 * // → at runtime, the worker is reachable as "h-sync".
 * Workers.terminate("h-sync");
 * ```
 */
export const Workers = {
  /**
   * Terminate a worker by ID. Equivalent to `worker.terminate()` for
   * dedicated workers; the only path for headless workers (no JS handle).
   *
   * Recognised ID forms:
   * - `"w-N"` — dedicated worker instance (same as `worker.terminate()`)
   * - `"h-<key>"` — headless worker keyed by `zapp.config.ts` `headless`
   *
   * Unknown IDs are a silent no-op (native logs but doesn't throw).
   */
  terminate(id: string): void {
    if (!id) return;
    const bridge = getBridge();
    (bridge as any).terminateWorker(id);
    // Drop any local message-handler registration so subsequent posts
    // to a stale ID don't accumulate listeners. Mirrors what
    // `Worker.terminate()` does for the instance path.
    const workers = (bridge as any)._workers;
    if (workers && id in workers) delete workers[id];
  },

  /**
   * Send a raw message to any worker by ID — webview → worker, worker
   * → worker, backend → worker, all reachable through the same call.
   * For pipelines (`ingest → db → sync`) this skips the broadcast
   * fan-out you'd get from `Events.emit`, keeping the message
   * point-to-point.
   *
   * The receiving worker picks it up via the standard worker scope:
   * `self.onmessage` for raw, `self.receive("channel", handler)` for
   * channel-typed messages (use `Workers.send` for the channel form).
   *
   * Unknown / terminated IDs are a silent no-op.
   *
   * @example
   * ```ts
   * // From any context — webview or another worker
   * Workers.postMessage("h-db", { type: "write", row: { ... } });
   * ```
   */
  postMessage(targetId: string, data: unknown): void {
    if (!targetId) return;
    (getBridge() as any).postToWorker(targetId, data);
  },

  /**
   * Channel-typed equivalent of `postMessage` — wraps `data` so the
   * target's `self.receive("<channel>", handler)` picks it up.
   * Mirrors `worker.send(channel, data)` but for arbitrary worker IDs
   * (including headless workers that have no `Worker` instance).
   *
   * @example
   * ```ts
   * Workers.send("h-db", "write", { row: { ... } });
   * // In src/workers/db.ts:
   * receive("write", (row) => { ... });
   * ```
   */
  send(targetId: string, channel: string, data: unknown): void {
    if (!targetId) return;
    (getBridge() as any).postToWorker(targetId, {
      [CHANNEL_KEY]: channel,
      [DATA_KEY]: data,
    });
  },

  /**
   * Snapshot every active worker — dedicated and headless — across all
   * engines. Resolves to an array of {@link WorkerInfo}.
   *
   * Works from both the webview and inside a worker. The two contexts
   * reach the native registry differently (the webview round-trips the
   * `__zapp:workers-list` IPC route, which already JSON-parses the
   * result; a worker calls its host bridge synchronously and gets a JSON
   * string back), so this normalizes both shapes.
   *
   * @example
   * ```ts
   * for (const w of await Workers.list()) {
   *   console.log(w.id, w.engine, w.name ?? "(unnamed)");
   * }
   * ```
   */
  async list(): Promise<WorkerInfo[]> {
    const bridge = getBridge() as any;
    const result = await bridge.listWorkers();
    if (typeof result === "string") return JSON.parse(result) as WorkerInfo[];
    return (result ?? []) as WorkerInfo[];
  },

  /**
   * Get an ergonomic {@link WorkerHandle} for a worker you didn't create —
   * most usefully a **headless** worker (`"h-<key>"`), which has no JS-side
   * `Worker` instance. The complement to `list()` (discover) → `get()`
   * (interact): instead of repeating the id to `Workers.send`/`terminate`,
   * hold a handle that mirrors the `Worker` instance surface.
   *
   * Synchronous and cheap — it just binds the id; no registry round-trip.
   * `send`/`postMessage`/`terminate` are fire-and-forget (an unknown or
   * terminated id is a silent no-op, like `Workers.send`); `info()` is async
   * (it reads the registry) and resolves to `null` for an unknown id.
   *
   * @example
   * ```ts
   * const db = Workers.get("h-db");
   * db.send("write", { row: { ... } });
   * const info = await db.info();   // WorkerInfo | null
   * db.terminate();
   * ```
   */
  get(id: string): WorkerHandle {
    return {
      id,
      postMessage: (data: unknown) => Workers.postMessage(id, data),
      send: (channel: string, data: unknown) => Workers.send(id, channel, data),
      terminate: () => Workers.terminate(id),
      info: async () => (await Workers.list()).find((w) => w.id === id) ?? null,
    };
  },
};
