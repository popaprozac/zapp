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

  constructor(scriptUrl: string) {
    this._bridge = getBridge();
    this.id = (this._bridge as any).createWorker(scriptUrl);

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

/** Port for SharedWorker communication — mirrors Worker API. */
export class SharedWorkerPort {
  readonly id: string;
  private _bridge: ZappBridge;
  onmessage: ((event: WorkerMessageEvent) => void) | null = null;

  /** @internal */
  _messageHandlers: Array<(event: WorkerMessageEvent) => void> = [];

  /** @internal */
  constructor(workerId: string, bridge: ZappBridge) {
    this.id = workerId;
    this._bridge = bridge;
  }

  /** Send a raw message to the shared worker. */
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
}

/**
 * SharedWorker — persists as long as any window holds a reference.
 * Multiple windows creating SharedWorker with the same URL connect to the same native worker.
 *
 * @example
 * ```ts
 * const sw = new SharedWorker("./shared-worker.ts");
 * sw.port.postMessage({ task: "sync" });
 * sw.port.onmessage = (e) => console.log(e.data);
 * sw.port.send("channel", data);
 * ```
 */
export class SharedWorker {
  readonly port: SharedWorkerPort;

  constructor(scriptUrl: string) {
    const bridge = getBridge();
    const workerId = (bridge as any).createSharedWorker(scriptUrl);
    this.port = new SharedWorkerPort(workerId, bridge);

    // Register port for message dispatch
    (bridge as any)._workers[workerId] = this.port;
  }
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
   * - `"sw-N"` — **rejected at the native layer**. Shared workers must
   *   be released via `port` disconnect; the last disconnect auto-
   *   terminates. Calling this for a SharedWorker ID is a no-op rather
   *   than an error so callers don't have to care about the distinction.
   *
   * Unknown IDs are also a silent no-op (native logs but doesn't throw).
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
};
