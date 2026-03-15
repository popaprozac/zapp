export interface WorkerOptions {
  shared?: boolean;
  importMetaUrl?: string | URL;
}

type ZappBridge = {
  createWorker: (scriptUrl: string, options?: { shared?: boolean }) => string;
  postToWorker: (workerId: string, data: unknown) => void;
  terminateWorker: (workerId: string) => void;
  subscribeWorker: (
    workerId: string,
    onMessage?: (data: unknown) => void,
    onError?: (data: unknown) => void,
    onClose?: (data: unknown) => void,
  ) => () => void;
  resolveWorkerScriptURL?: (scriptURL: string | URL) => string;
};

function getBridge(): ZappBridge {
  const b = (globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as ZappBridge | undefined;
  if (!b?.createWorker) {
    throw new Error(
      "Zapp worker bridge unavailable. " +
      "Make sure the webview bootstrap has loaded before importing @zapp/runtime.",
    );
  }
  return b;
}

function rewriteToBundledWorker(url: URL): string {
  const ext = url.pathname.split(".").pop()?.toLowerCase();
  if (ext !== "ts" && ext !== "tsx") return url.toString();
  const toBundledUrl = (mappedPath: string): string => {
    const normalized = mappedPath.startsWith("/") ? mappedPath : `/${mappedPath}`;
    if (url.protocol === "zapp:") {
      return `zapp://app${normalized}`;
    }
    return new URL(normalized, url).toString();
  };
  const manifest = (globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.workerManifest")
  ] as Record<string, string> | undefined;
  const fileName = url.pathname.split("/").pop() ?? "worker.ts";
  const spec = `./${fileName}`;
  if (manifest) {
    const mapped = manifest[spec] ?? manifest[fileName];
    if (typeof mapped === "string" && mapped.length > 0) {
      return toBundledUrl(mapped);
    }
  }
  const pathParts = url.pathname.split("/");
  const fallbackName = pathParts[pathParts.length - 1] ?? "worker.ts";
  const stem = fallbackName.replace(/\.[^.]+$/, "");
  const bundledPath = `/zapp-workers/${stem}.mjs`;
  return toBundledUrl(bundledPath);
}

function resolveWorkerScriptURL(
  scriptURL: string | URL,
  importMetaUrl?: string | URL,
): string {
  const bridge = getBridge();
  if (bridge.resolveWorkerScriptURL) {
    return bridge.resolveWorkerScriptURL(scriptURL);
  }
  if (scriptURL instanceof URL) {
    return rewriteToBundledWorker(scriptURL);
  }
  if (importMetaUrl) {
    return rewriteToBundledWorker(new URL(scriptURL, String(importMetaUrl)));
  }
  return scriptURL;
}

type ListenerEntry = { listener: EventListenerOrEventListenerObject; once: boolean };

export class Worker {
  readonly id: string;
  readonly scriptURL: string;

  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: ErrorEvent) => void) | null = null;
  onclose: ((event: Event) => void) | null = null;

  #listeners: Record<"message" | "error" | "close", ListenerEntry[]> = {
    message: [],
    error: [],
    close: [],
  };
  #pendingErrors: ErrorEvent[] = [];
  #unsubscribe: (() => void) | null = null;

  constructor(scriptURL: string | URL, options?: WorkerOptions) {
    const bridge = getBridge();
    const resolved = resolveWorkerScriptURL(scriptURL, options?.importMetaUrl);
    this.scriptURL = resolved;
    this.id = bridge.createWorker(resolved, {
      shared: options?.shared === true,
    });
    this.#unsubscribe = bridge.subscribeWorker(
      this.id,
      (payload) => {
        if (payload && typeof payload === "object" && "__zapp_channel" in (payload as Record<string, unknown>)) {
          const event = new MessageEvent("message", { data: payload });
          this.#emit("message", event);
          return;
        }
        const event = new MessageEvent("message", { data: payload });
        this.onmessage?.(event);
        this.#emit("message", event);
      },
      (payload) => {
        const errorPayload = payload as {
          message?: string;
          filename?: string;
          lineno?: number;
          colno?: number;
        };
        const event = new ErrorEvent("error", {
          message: errorPayload?.message ?? "Worker error",
          filename: errorPayload?.filename ?? "",
          lineno: errorPayload?.lineno ?? 0,
          colno: errorPayload?.colno ?? 0,
        });
        this.#dispatchError(event);
      },
      () => {
        const event = new Event("close");
        this.onclose?.(event);
        this.#emit("close", event);
      },
    );
  }

  postMessage(data: unknown): void {
    getBridge().postToWorker(this.id, data);
  }

  send(channel: string, data: unknown): void {
    this.postMessage({ __zapp_channel: channel, data });
  }

  receive(channel: string, handler: (data: unknown) => void): () => void {
    const cb = (e: Event) => {
      const payload = (e as MessageEvent).data as Record<string, unknown>;
      if (payload && typeof payload === "object" && payload.__zapp_channel === channel) {
        handler(payload.data);
      }
    };
    this.addEventListener("message", cb);
    return () => this.removeEventListener("message", cb);
  }

  terminate(): void {
    this.#unsubscribe?.();
    this.#unsubscribe = null;
    getBridge().terminateWorker(this.id);
  }

  addEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions,
  ): void {
    if (!listener) return;
    if (type !== "message" && type !== "error" && type !== "close") return;
    const list = this.#listeners[type as "message" | "error" | "close"];
    for (const entry of list) {
      if (entry.listener === listener) return;
    }
    const once = typeof options === "object" && options?.once === true;
    const signal = typeof options === "object" ? options.signal : undefined;
    if (signal?.aborted) return;
    list.push({ listener, once });
    if (type === "error") this.#flushPendingErrors();
    if (signal) {
      const onAbort = () => this.removeEventListener(type, listener);
      signal.addEventListener("abort", onAbort, { once: true });
    }
  }

  removeEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject | null,
  ): void {
    if (!listener) return;
    if (type !== "message" && type !== "error" && type !== "close") return;
    const list = this.#listeners[type as "message" | "error" | "close"];
    for (let i = list.length - 1; i >= 0; i -= 1) {
      if (list[i]?.listener === listener) list.splice(i, 1);
    }
  }

  dispatchEvent(event: Event): boolean {
    if (!event || (event.type !== "message" && event.type !== "error" && event.type !== "close")) return true;
    this.#emit(event.type as "message" | "error" | "close", event);
    return !event.defaultPrevented;
  }

  #emit(type: "message" | "error" | "close", event: Event): void {
    const list = this.#listeners[type].slice();
    for (const entry of list) {
      if (typeof entry.listener === "function") {
        (entry.listener as (e: Event) => void)(event);
      } else {
        entry.listener.handleEvent(event);
      }
      if (entry.once) this.removeEventListener(type, entry.listener);
    }
  }

  #dispatchError(event: ErrorEvent): void {
    if (this.#listeners.error.length === 0 && this.onerror == null) {
      this.#pendingErrors.push(event);
      return;
    }
    this.onerror?.(event);
    this.#emit("error", event);
  }

  #flushPendingErrors(): void {
    if (this.#pendingErrors.length === 0) return;
    if (this.#listeners.error.length === 0 && this.onerror == null) return;
    const pending = this.#pendingErrors.splice(0);
    for (const event of pending) {
      this.onerror?.(event);
      this.#emit("error", event);
    }
  }
}

export class SharedWorker {
  readonly port: {
    postMessage: (data: unknown) => void;
    onmessage: ((event: MessageEvent) => void) | null;
    start: () => void;
    close: () => void;
    addEventListener: (type: string, listener: EventListenerOrEventListenerObject) => void;
    removeEventListener: (type: string, listener: EventListenerOrEventListenerObject) => void;
  };
  onerror: ((event: ErrorEvent) => void) | null = null;

  readonly #inner: Worker;

  constructor(scriptURL: string | URL, options?: WorkerOptions) {
    this.#inner = new Worker(scriptURL, {
      ...options,
      shared: true,
    });

    this.port = {
      postMessage: (data: unknown) => this.#inner.postMessage(data),
      onmessage: null,
      start: () => {},
      close: () => this.#inner.terminate(),
      addEventListener: (type: string, listener: EventListenerOrEventListenerObject) =>
        this.#inner.addEventListener(type, listener),
      removeEventListener: (type: string, listener: EventListenerOrEventListenerObject) =>
        this.#inner.removeEventListener(type, listener),
    };

    this.#inner.addEventListener("message", ((e: MessageEvent) => {
      this.port.onmessage?.(e);
    }) as EventListener);

    this.#inner.addEventListener("error", ((e: ErrorEvent) => {
      this.onerror?.(e);
    }) as EventListener);
  }

  send(channel: string, data: unknown): void {
    this.#inner.send(channel, data);
  }

  receive(channel: string, handler: (data: unknown) => void): () => void {
    return this.#inner.receive(channel, handler);
  }
}
