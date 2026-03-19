type EventHandler = (payload: unknown) => void;
type ListenerEntry = { id: number; fn: EventHandler; once?: boolean };
type WorkerSubscriber = (data: unknown) => void;
type WorkerSubscriptions = { message: WorkerSubscriber[]; error: WorkerSubscriber[]; close: WorkerSubscriber[] };
type WorkerBridge = {
  createWorker: (scriptUrl: string, options?: { shared?: boolean }) => string;
  postToWorker: (workerId: string, data: unknown) => void;
  terminateWorker: (workerId: string) => void;
  subscribe: (
    workerId: string,
    onMessage?: WorkerSubscriber,
    onError?: WorkerSubscriber,
    onClose?: WorkerSubscriber
  ) => () => void;
};

type RuntimeInternal = {
  __ctxId?: string;
  __listeners?: Record<string, ListenerEntry[]>;
  __lastId?: number;
  __invokeSeq?: number;
  __pendingInvokes?: Record<
    string,
    {
      resolve: (value: unknown) => void;
      reject: (reason?: unknown) => void;
      timeout: ReturnType<typeof setTimeout>;
    }
  >;
  __pendingSyncWaits?: Record<
    string,
    {
      resolve: (value: "notified" | "timed-out") => void;
      reject: (reason?: unknown) => void;
      timeout?: ReturnType<typeof setTimeout>;
    }
  >;
  workerBridge?: WorkerBridge;
  __workerBridgeDispatch?: (kind: string, workerId: string, payload: unknown) => void;
  invoke?: (serviceMethod: string, args: unknown) => Promise<unknown>;
  syncWait?: (
    key: string,
    timeoutMs?: number | null,
    signal?: AbortSignal
  ) => Promise<"notified" | "timed-out">;
  syncNotify?: (key: string, count?: number) => boolean;
  syncCancel?: (id: string) => boolean;
  emit?: (name: string, payload: unknown) => boolean;
  onEvent?: (name: string, handler: EventHandler) => number;
  onceEvent?: (name: string, handler: EventHandler) => number;
  offEvent?: (name: string, id: number) => void;
  offAllEvents?: (name?: string) => void;
};

type PublicZapp = {
  invoke?: (serviceMethod: string, args: unknown) => Promise<unknown>;
  syncWait?: (
    key: string,
    timeoutMs?: number | null,
    signal?: AbortSignal
  ) => Promise<"notified" | "timed-out">;
  syncNotify?: (key: string, count?: number) => boolean;
  syncCancel?: (id: string) => boolean;
  emit?: (name: string, payload: unknown) => boolean;
  on?: (name: string, handler: EventHandler) => () => void;
};

type ZappGlobal = typeof globalThis & {
  __zapp?: PublicZapp;
  chrome?: {
    webview?: { postMessage?: (message: string) => void };
  };
};

const g = globalThis as ZappGlobal;
const existingZapp = g.__zapp;
const zapp: PublicZapp =
  existingZapp && typeof existingZapp === "object" ? existingZapp : {};
const ensurePublicZappBinding = (): void => {
  if (g.__zapp === zapp) return;
  g.__zapp = zapp;
  try {
    Object.defineProperty(g, "__zapp", {
      value: zapp,
      enumerable: true,
      configurable: false,
      writable: false,
    });
  } catch {
    // Already defined non-configurable (e.g. second run in same context)
  }
};
const BRIDGE_SYMBOL = Symbol.for("zapp.bridge");
const BOOTSTRAP_CONFIG_SYMBOL = Symbol.for("zapp.bootstrapConfig");
const OWNER_ID_SYMBOL = Symbol.for("zapp.ownerId");
type ConfigSnapshot = {
  name: string;
  applicationShouldTerminateAfterLastWindowClosed: boolean;
  webContentInspectable: boolean;
  maxWorkers?: number;
};
type BridgeListeners = Record<string, Array<{ id: number; fn: EventHandler; once?: boolean }>>;
type NativeBridge = {
  _listeners: BridgeListeners;
  _lastId: number;
  _emit: (name: string, payload: unknown) => boolean;
  _onEvent: (name: string, handler: EventHandler) => number;
  _offEvent: (name: string, id: number) => void;
  _onceEvent: (name: string, handler: EventHandler) => number;
  _offAllEvents: (name?: string) => void;
  dispatchWorkerBridge: (kind: string, workerId: string, payload: unknown) => void;
  dispatchInvokeResult: (payload: unknown) => void;
  dispatchSyncResult: (payload: unknown) => void;
  dispatchWindowResult: (payload: unknown) => void;
  deliverEvent: (name: string, payload: unknown) => void;
  dispatchWindowEvent: (windowId: string, event: string) => void;
  getConfig: () => ConfigSnapshot | null;
  invoke: (request: unknown) => Promise<unknown>;
  syncWait: (request: unknown) => Promise<"notified" | "timed-out">;
  syncNotify: (request: unknown) => boolean;
  syncCancel: (request: unknown) => boolean;
  getServiceBindings: () => string | null;
  resetOwnerWorkers: () => void;
  createWorker: (scriptUrl: string, options?: { shared?: boolean }) => string;
  postToWorker: (workerId: string, data: unknown) => void;
  terminateWorker: (workerId: string) => void;
  subscribeWorker: (
    workerId: string,
    onMessage?: WorkerSubscriber,
    onError?: WorkerSubscriber,
    onClose?: WorkerSubscriber,
  ) => () => void;
  resolveWorkerScriptURL: (scriptURL: string | URL) => string;
  windowCreate: (options: unknown) => Promise<{ id: string }>;
  windowAction: (windowId: string, action: string, params?: Record<string, unknown>) => void;
  appAction: (action: string) => void;
};
const symbolStore = g as unknown as Record<symbol, unknown>;
const upsertBridge = (patch: Partial<NativeBridge>): void => {
  const existing = (symbolStore[BRIDGE_SYMBOL] ?? {}) as Partial<NativeBridge>;
  const next = Object.assign({}, existing, patch);
  Object.defineProperty(symbolStore, BRIDGE_SYMBOL, {
    value: next,
    enumerable: false,
    configurable: true,
    writable: false,
  });
};
const rt: RuntimeInternal = {};

const _listeners: BridgeListeners = {};
let _lastId = 0;
upsertBridge({ _listeners, _lastId } as unknown as Partial<NativeBridge>);
const ctxId = (rt.__ctxId ??= `ctx-${Date.now()}-${Math.random().toString(36).slice(2)}`);
const invokePending = (rt.__pendingInvokes = rt.__pendingInvokes ?? {});
const syncPending = (rt.__pendingSyncWaits = rt.__pendingSyncWaits ?? {});
let invokeSeq = rt.__invokeSeq ?? 0;
const ZAPP_SERVICE_PROTOCOL_VERSION = 1;
const MAX_INVOKE_ARG_BYTES = 128 * 1024;
type InvokeRequest = {
  v: number;
  id: string;
  method: string;
  args: unknown;
  meta: { sourceCtxId: string; capability?: string };
};
type InvokeResponse = {
  v: number;
  id: string;
  ok: boolean;
  result?: unknown;
  error?: { code?: string; message?: string; details?: unknown };
};
type SyncWaitRequest = {
  id: string;
  key: string;
  timeoutMs: number | null;
  meta: { sourceCtxId: string };
};
type SyncResultPayload = {
  id: string;
  ok: boolean;
  status?: "notified" | "timed-out" | "cancelled";
};
let appConfig =
  symbolStore[BOOTSTRAP_CONFIG_SYMBOL] == null
    ? null
    : {
        name: (symbolStore[BOOTSTRAP_CONFIG_SYMBOL] as ConfigSnapshot).name,
        applicationShouldTerminateAfterLastWindowClosed:
          (symbolStore[BOOTSTRAP_CONFIG_SYMBOL] as ConfigSnapshot)
            .applicationShouldTerminateAfterLastWindowClosed,
        webContentInspectable: (symbolStore[BOOTSTRAP_CONFIG_SYMBOL] as ConfigSnapshot)
          .webContentInspectable,
        maxWorkers: (symbolStore[BOOTSTRAP_CONFIG_SYMBOL] as ConfigSnapshot).maxWorkers,
      };

try {
  delete symbolStore[BOOTSTRAP_CONFIG_SYMBOL];
} catch {
  // Ignore if host makes this non-configurable.
}

const encodePayload = (value: unknown): string =>
  typeof value === "string" ? value : JSON.stringify(value ?? {});

const post = (type: string, key: string, payload: unknown): boolean => {
  ensurePublicZappBinding();
  const handler = g.chrome?.webview;
  if (!handler?.postMessage) return false;
  handler.postMessage(`${type}\n${key}\n${encodePayload(payload)}`);
  return true;
};

rt.invoke = (serviceMethod: string, args: unknown): Promise<unknown> =>
  new Promise((resolve, reject) => {
    const method = typeof serviceMethod === "string" ? serviceMethod.trim() : "";
    if (!method) {
      reject(new Error("Service method must be a non-empty string."));
      return;
    }
    const encodedArgs = encodePayload(args);
    if (encodedArgs.length > MAX_INVOKE_ARG_BYTES) {
      reject(new Error("Service payload exceeds max size."));
      return;
    }

    const requestId = `${ctxId}:inv-${++invokeSeq}`;
    rt.__invokeSeq = invokeSeq;
    const request: InvokeRequest = {
      v: ZAPP_SERVICE_PROTOCOL_VERSION,
      id: requestId,
      method,
      args,
      meta: { sourceCtxId: ctxId },
    };

    const timer = setTimeout(() => {
      delete invokePending[requestId];
      reject(new Error("Service invocation timed out."));
    }, 15000);

    invokePending[requestId] = { resolve, reject, timeout: timer };
    const ok = post("invoke_rpc", method, request);
    if (!ok) {
      clearTimeout(timer);
      delete invokePending[requestId];
      reject(new Error("Native invoke transport unavailable."));
    }
  });

const makeAbortError = (): Error => {
  const err = new Error("Sync wait aborted.");
  (err as Error & { name?: string }).name = "AbortError";
  return err;
};

rt.syncWait = (key: string, timeoutMs = 30000, signal?: AbortSignal): Promise<"notified" | "timed-out"> =>
  new Promise((resolve, reject) => {
    const trimmed = typeof key === "string" ? key.trim() : "";
    if (!trimmed) {
      reject(new Error("Sync key must be a non-empty string."));
      return;
    }
    if (signal?.aborted) {
      reject(makeAbortError());
      return;
    }
    const requestId = `${ctxId}:sync-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const timeoutValue =
      timeoutMs == null || Number.isNaN(Number(timeoutMs)) ? null : Math.floor(Number(timeoutMs));
    const boundedTimeout = timeoutValue == null ? null : Math.max(1, Math.min(300000, timeoutValue));
    const request: SyncWaitRequest = {
      id: requestId,
      key: trimmed,
      timeoutMs: boundedTimeout,
      meta: { sourceCtxId: ctxId },
    };
    const timer =
      boundedTimeout == null
        ? undefined
        : setTimeout(() => {
            delete syncPending[requestId];
            reject(new Error("Sync wait transport timed out."));
          }, boundedTimeout + 5000);
    syncPending[requestId] = { resolve, reject, timeout: timer };
    const ok = post("sync", "wait", request);
    if (!ok) {
      if (timer) clearTimeout(timer);
      delete syncPending[requestId];
      reject(new Error("Native sync transport unavailable."));
      return;
    }

    if (signal) {
      const onAbort = (): void => {
        const pending = syncPending[requestId];
        if (!pending) return;
        if (pending.timeout) clearTimeout(pending.timeout);
        delete syncPending[requestId];
        post("sync", "cancel", { id: requestId, meta: { sourceCtxId: ctxId } });
        reject(makeAbortError());
      };
      signal.addEventListener("abort", onAbort, { once: true });
    }
  });

rt.syncNotify = (key: string, count = 1): boolean => {
  const trimmed = typeof key === "string" ? key.trim() : "";
  if (!trimmed) return false;
  const boundedCount = Math.max(1, Math.min(65535, Math.floor(count)));
  return post("sync", "notify", {
    key: trimmed,
    count: boundedCount,
    meta: { sourceCtxId: ctxId },
  });
};

rt.syncCancel = (id: string): boolean => {
  const requestId = typeof id === "string" ? id.trim() : "";
  if (!requestId) return false;
  return post("sync", "cancel", {
    id: requestId,
    meta: { sourceCtxId: ctxId },
  });
};

rt.emit = (name: string, payload: unknown): boolean =>
  post("emit", name, {
    __zapp_internal_meta: { sourceCtxId: ctxId },
    data: payload,
  });

rt.onEvent = (name: string, handler: EventHandler): number => {
  const id = ++_lastId;
  (_listeners[name] ??= []).push({ id, fn: handler });
  return id;
};

rt.offEvent = (name: string, id: number): void => {
  const existing = _listeners[name] ?? [];
  _listeners[name] = existing.filter((entry) => entry.id !== id);
};

rt.onceEvent = (name: string, handler: EventHandler): number => {
  const id = ++_lastId;
  (_listeners[name] ??= []).push({ id, fn: handler, once: true });
  return id;
};

rt.offAllEvents = (name?: string): void => {
  if (name) {
    delete _listeners[name];
  } else {
    Object.keys(_listeners).forEach((k) => delete _listeners[k]);
  }
};

const rewriteToBundledWorker = (url: URL): string => {
  const ext = url.pathname.split(".").pop()?.toLowerCase();
  if (ext !== "ts" && ext !== "tsx") return url.toString();
  const toBundledUrl = (mappedPath: string): string => {
    const normalized = mappedPath.startsWith("/") ? mappedPath : `/${mappedPath}`;
    if (url.protocol === "zapp:") {
      return `zapp://app${normalized}`;
    }
    return new URL(normalized, url).toString();
  };
  const manifest = symbolStore[Symbol.for("zapp.workerManifest")] as
    | Record<string, string>
    | undefined;
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
};

const resolveWorkerScriptURL = (scriptURL: string | URL): string =>
  scriptURL instanceof URL ? rewriteToBundledWorker(scriptURL) : scriptURL;

if (!rt.workerBridge) {
  const workerSubs: Record<string, WorkerSubscriptions> = {};
  let workerSeq = 0;
  const ownerFromBootstrap = symbolStore[OWNER_ID_SYMBOL];
  const ownerId =
    typeof ownerFromBootstrap === "string" && ownerFromBootstrap.length > 0
      ? ownerFromBootstrap
      : `owner-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  try {
    delete symbolStore[OWNER_ID_SYMBOL];
  } catch {
    // Ignore if host makes this non-configurable.
  }
  let ownedWorkerIds: string[] = [];

  const ensureSubs = (id: string): WorkerSubscriptions => {
    workerSubs[id] ??= { message: [], error: [], close: [] };
    return workerSubs[id];
  };

  const workerBridgeDispatch = (kind: string, workerId: string, payload: unknown): void => {
    const dispatchLater = (fn: () => void): void => {
      queueMicrotask(fn);
    };

    if (kind === "close") {
      const subs = workerSubs[workerId];
      dispatchLater(() => {
        if (subs) {
          for (const fn of subs.close) {
            try {
              fn(payload);
            } catch {
              // Isolate subscriber failures.
            }
          }
        }
        rt.workerBridge?.terminateWorker(workerId);
      });
      return;
    }
    const subs = workerSubs[workerId];
    if (!subs) return;
    let data = payload;
    if (typeof payload === "string") {
      try {
        data = JSON.parse(payload);
      } catch {
        // Keep raw string payload.
      }
    }

    const queue = kind === "error" ? subs.error : subs.message;
    dispatchLater(() => {
      for (const fn of queue) {
        try {
          fn(data);
        } catch {
          // Isolate subscriber failures.
        }
      }
    });
  };
  rt.__workerBridgeDispatch = workerBridgeDispatch;
  upsertBridge({ dispatchWorkerBridge: workerBridgeDispatch });

  rt.workerBridge = {
    createWorker(scriptUrl: string, options?: { shared?: boolean }): string {
      const shared = Boolean(options?.shared);
      const id = `${ownerId}:${ctxId}:zw-${++workerSeq}`;
      ensureSubs(id);
      ownedWorkerIds.push(id);
      post("worker", "create", { id, scriptUrl, ownerId, shared });
      return id;
    },
    postToWorker(workerId: string, data: unknown): void {
      post("worker", "post", { id: workerId, data, ownerId });
    },
    terminateWorker(workerId: string): void {
      post("worker", "terminate", { id: workerId, ownerId });
      ownedWorkerIds = ownedWorkerIds.filter((id) => id !== workerId);
      delete workerSubs[workerId];
    },
    subscribe(workerId: string, onMessage?: WorkerSubscriber, onError?: WorkerSubscriber, onClose?: WorkerSubscriber): () => void {
      const subs = ensureSubs(workerId);
      if (onMessage) subs.message.push(onMessage);
      if (onError) subs.error.push(onError);
      if (onClose) subs.close.push(onClose);
      return () => {
        const current = workerSubs[workerId];
        if (!current) return;
        if (onMessage) current.message = current.message.filter((fn) => fn !== onMessage);
        if (onError) current.error = current.error.filter((fn) => fn !== onError);
        if (onClose) current.close = current.close.filter((fn) => fn !== onClose);
      };
    },
  };

  const resetOwnerWorkers = (): void => {
    if (!ownedWorkerIds.length) return;
    post("worker", "reset_owner", { ownerId });
    ownedWorkerIds = [];
    for (const workerId of Object.keys(workerSubs)) {
      delete workerSubs[workerId];
    }
  };
  upsertBridge({
    resetOwnerWorkers,
    createWorker: rt.workerBridge.createWorker.bind(rt.workerBridge),
    postToWorker: rt.workerBridge.postToWorker.bind(rt.workerBridge),
    terminateWorker: rt.workerBridge.terminateWorker.bind(rt.workerBridge),
    subscribeWorker: rt.workerBridge.subscribe.bind(rt.workerBridge),
    resolveWorkerScriptURL,
  });

  g.addEventListener("beforeunload", resetOwnerWorkers);
  g.addEventListener("pagehide", resetOwnerWorkers);
}

// --- Window bridge ---

const pendingWindowCreates: Record<
  string,
  { resolve: (v: { id: string }) => void; reject: (e: Error) => void; timeout: ReturnType<typeof setTimeout> }
> = {};
let windowSeq = 0;

const windowCreate = (options: unknown): Promise<{ id: string }> =>
  new Promise((resolve, reject) => {
    const reqId = `${ctxId}:win-${++windowSeq}`;
    const timer = setTimeout(() => {
      delete pendingWindowCreates[reqId];
      reject(new Error("Window creation timed out."));
    }, 15000);
    pendingWindowCreates[reqId] = { resolve, reject, timeout: timer };
    post("window", "create", { requestId: reqId, options });
  });

const windowAction = (windowId: string, action: string, params?: Record<string, unknown>): void => {
  post("window", action, { windowId, ...params });
};

const appAction = (action: string): void => {
  post("app", action, {});
};

const dispatchWindowResult = (payload: unknown): void => {
  let parsed = payload;
  if (typeof payload === "string") {
    try { parsed = JSON.parse(payload); } catch { return; }
  }
  if (!parsed || typeof parsed !== "object") return;
  const result = parsed as { requestId?: string; id?: string; ok?: boolean; error?: string };
  if (typeof result.requestId !== "string") return;
  const pending = pendingWindowCreates[result.requestId];
  if (!pending) return;
  clearTimeout(pending.timeout);
  delete pendingWindowCreates[result.requestId];
  if (result.ok === false) {
    pending.reject(new Error(result.error ?? "Window creation failed."));
  } else {
    pending.resolve({ id: result.id ?? "" });
  }
};

const dispatchWindowEvent = (windowId: string, event: string): void => {
  ensurePublicZappBinding();

  const payload = { windowId, timestamp: Date.now() };

  const fireAndPrune = (eventName: string): void => {
    const handlers = _listeners[eventName];
    if (!handlers || handlers.length === 0) return;
    const remaining: typeof handlers = [];
    for (const entry of handlers) {
      try { entry.fn(payload); } catch { /* isolate */ }
      if (!entry.once) remaining.push(entry);
    }
    if (remaining.length > 0) {
      _listeners[eventName] = remaining;
    } else {
      delete _listeners[eventName];
    }
  };

  fireAndPrune(`__zapp_window:${windowId}:${event}`);
  fireAndPrune(`window:${event}`);
};

upsertBridge({
  windowCreate,
  windowAction,
  appAction,
  dispatchWindowResult,
  dispatchWindowEvent,
  _emit: rt.emit,
  _onEvent: rt.onEvent,
  _onceEvent: rt.onceEvent,
  _offEvent: rt.offEvent,
  _offAllEvents: rt.offAllEvents,
});

zapp.invoke = rt.invoke;
zapp.emit = rt.emit;
zapp.on = (name: string, handler: EventHandler): (() => void) => {
  const id = rt.onEvent?.(name, handler) ?? 0;
  return () => rt.offEvent?.(name, id);
};

const deliverEvent = (name: string, payload: unknown): void => {
  ensurePublicZappBinding();
  let parsed = payload;
  if (typeof payload === "string") {
    const s = payload.trim();
    const isJsonLike =
      (s.startsWith("{") && s.endsWith("}")) || (s.startsWith("[") && s.endsWith("]"));
    if (isJsonLike) {
      try {
        parsed = JSON.parse(payload);
      } catch {
        // Keep original string.
      }
    }
  }

  if (parsed && typeof parsed === "object") {
    const boxed = parsed as {
      __zapp_internal_meta?: { sourceCtxId?: string };
      data?: unknown;
    };
    if (boxed.__zapp_internal_meta?.sourceCtxId === ctxId) return;
    if (Object.prototype.hasOwnProperty.call(boxed, "data")) {
      parsed = boxed.data;
    }
  }

  const handlers = _listeners[name] ?? [];
  const remaining: ListenerEntry[] = [];
  for (const entry of handlers) {
    try {
      entry.fn(parsed);
    } catch {
      // Isolate listener failures.
    }
    if (!entry.once) {
      remaining.push(entry);
    }
  }
  if (remaining.length > 0) {
    _listeners[name] = remaining;
  } else {
    delete _listeners[name];
  }
};

const dispatchInvokeResult = (payload: unknown): void => {
  let parsed = payload;
  if (typeof payload === "string") {
    try {
      parsed = JSON.parse(payload);
    } catch {
      return;
    }
  }
  if (!parsed || typeof parsed !== "object") return;
  const response = parsed as InvokeResponse;
  if (typeof response.id !== "string" || response.id.length === 0) return;
  const pending = invokePending[response.id];
  if (!pending) return;
  clearTimeout(pending.timeout);
  delete invokePending[response.id];
  if (response.ok) {
    pending.resolve(response.result);
    return;
  }
  const code = response.error?.code ?? "INTERNAL_ERROR";
  const message = response.error?.message ?? "Service invocation failed";
  pending.reject(new Error(`${code}: ${message}`));
};

const dispatchSyncResult = (payload: unknown): void => {
  let parsed = payload;
  if (typeof payload === "string") {
    try {
      parsed = JSON.parse(payload);
    } catch {
      return;
    }
  }
  if (!parsed || typeof parsed !== "object") return;
  const result = parsed as SyncResultPayload;
  if (typeof result.id !== "string" || result.id.length === 0) return;
  const pending = syncPending[result.id];
  if (!pending) return;
  if (pending.timeout) clearTimeout(pending.timeout);
  delete syncPending[result.id];
  if (!result.ok) {
    pending.reject(new Error("Sync wait failed."));
    return;
  }
  if (result.status === "cancelled") {
    pending.reject(makeAbortError());
    return;
  }
  pending.resolve(result.status === "timed-out" ? "timed-out" : "notified");
};

upsertBridge({
  dispatchInvokeResult,
  dispatchSyncResult,
  deliverEvent,
  getConfig: () => (appConfig == null ? null : { ...appConfig }),
  invoke: async (request: unknown) => {
    const req = request as InvokeRequest;
    if (!req || typeof req !== "object") {
      throw new Error("Invalid invoke request");
    }
    if (typeof req.method !== "string") {
      throw new Error("Invalid service method");
    }
    const result = await rt.invoke?.(req.method, req.args);
    return {
      v: ZAPP_SERVICE_PROTOCOL_VERSION,
      id: req.id,
      ok: true,
      result,
    } satisfies InvokeResponse;
  },
  getServiceBindings: () => {
    const value = symbolStore[Symbol.for("zapp.bindingsManifest")];
    if (typeof value !== "string") return null;
    return value;
  },
  syncWait: async (request: unknown) => {
    const req = request as { key?: string; timeoutMs?: number | null; signal?: AbortSignal };
    return (
      rt.syncWait?.(req?.key ?? "", req?.timeoutMs === undefined ? 30000 : req.timeoutMs, req?.signal) ??
      Promise.reject(new Error("Sync unavailable"))
    );
  },
  syncNotify: (request: unknown) => {
    const req = request as { key?: string; count?: number };
    return rt.syncNotify?.(req?.key ?? "", req?.count ?? 1) ?? false;
  },
  syncCancel: (request: unknown) => {
    const req = request as { id?: string };
    return rt.syncCancel?.(req?.id ?? "") ?? false;
  },
});

Object.defineProperties(zapp, {
  invoke: { value: rt.invoke, enumerable: true, configurable: false, writable: false },
  syncWait: { value: rt.syncWait, enumerable: true, configurable: false, writable: false },
  syncNotify: { value: rt.syncNotify, enumerable: true, configurable: false, writable: false },
  syncCancel: { value: rt.syncCancel, enumerable: true, configurable: false, writable: false },
  emit: { value: rt.emit, enumerable: true, configurable: false, writable: false },
  on: { value: zapp.on, enumerable: true, configurable: false, writable: false },
});
Object.freeze(zapp);
ensurePublicZappBinding();

const WINDOW_ID_SYMBOL = Symbol.for("zapp.windowId");
const WINDOW_READY_SYMBOL = Symbol.for("zapp.windowReady");
const winSymbolStore = g as unknown as Record<symbol, unknown>;

const fireReady = (): void => {
  if (winSymbolStore[WINDOW_READY_SYMBOL]) return;
  winSymbolStore[WINDOW_READY_SYMBOL] = true;

  const windowId = winSymbolStore[WINDOW_ID_SYMBOL] as string | undefined;
  const handler = g.chrome?.webview;
  if (handler?.postMessage) {
    const payload = JSON.stringify({ windowId: windowId ?? "unknown" });
    handler.postMessage(`window\nready\n${payload}`);
  }

  dispatchWindowEvent(windowId ?? "unknown", "ready");
};

if (typeof document !== "undefined") {
  document.addEventListener("DOMContentLoaded", fireReady, { once: true });
  if (document.readyState !== "loading") {
    fireReady();
  }
}

export {};
