type NativeBridge = Record<string, unknown> & {
  emitToHost?: (name: string, payload: unknown) => void;
  invokeToHost?: (method: string, payload: unknown) => void;
  setTimer?: (fn: () => void, ms: number, repeat: boolean) => number;
  clearTimer?: (id: number) => void;
  reportError?: (msg: string) => void;
  postMessage?: (data: unknown, targetId?: string) => void;
  closeWorker?: () => void;
  fetch?: (
    url: string,
    options: { method: string; headers: Record<string, string>; body?: string },
    resolve: (res: { status: number; statusText: string; headers: Record<string, string>; body: string; body_base64?: string }) => void,
    reject: (err: string) => void
  ) => void;
  getRandomValues?: (array: unknown) => unknown;
  randomUUID?: () => string;
  syncWait?: (request: { id: string; key: string; timeoutMs: number | null; targetWorkerId: string }) => void;
  syncNotify?: (request: { key: string; count: number; targetWorkerId: string }) => boolean;
  syncCancel?: (request: { id: string; targetWorkerId: string }) => boolean;
};

const g = globalThis as Record<string, unknown>;

// The native side sets __zappBridge with C-level functions (postMessage, fetch, setTimer, etc.).
// We take ownership of this SAME object and expose it as Symbol.for("zapp.bridge"),
// so that native dispatch (which looks up Symbol.for("zapp.bridge").dispatchMessage, etc.)
// and JS code (which looks up syncWait, etc.) all find everything in one place.
const bridge = (g.__zappBridge ?? {}) as NativeBridge;
try { delete g.__zappBridge; } catch {}

// Capture native sync C functions before we overwrite them with JS Promise wrappers
const nativeSyncWait = bridge.syncWait as ((req: { id: string; key: string; timeoutMs: number | null; targetWorkerId: string }) => void) | undefined;
const nativeSyncNotify = bridge.syncNotify as ((req: { key: string; count: number; targetWorkerId: string }) => boolean) | undefined;
const nativeSyncCancel = bridge.syncCancel as ((req: { id: string; targetWorkerId: string }) => boolean) | undefined;

const safeStr = (v: unknown): string => {
  if (typeof v === "string") return v;
  try { return String(v); } catch { return "unknown error"; }
};

const reportError = (err: unknown): void => {
  try {
    const msg = err instanceof Error ? err.message : safeStr(err);
    bridge.reportError?.(msg);
  } catch {
    try { bridge.reportError?.("Worker error"); } catch {}
  }
};

// --- Console (route to BOTH native NSLog AND original JSC console for Safari Inspector) ---
{
  const nativeLog = bridge.consoleLog as ((level: string, msg: string) => void) | undefined;
  if (nativeLog) {
    const origConsole = typeof g.console === "object" && g.console ? g.console as Record<string, (...a: unknown[]) => void> : null;
    const fmt = (...args: unknown[]): string =>
      args.map(a => {
        if (typeof a === "string") return a;
        try { return JSON.stringify(a); } catch { return String(a); }
      }).join(" ");
    const makeLogger = (level: string) => {
      const origFn = origConsole?.[level];
      return (...args: unknown[]) => {
        nativeLog(level, fmt(...args));
        if (typeof origFn === "function") try { origFn.apply(origConsole, args); } catch {}
      };
    };
    g.console = {
      log: makeLogger("log"),
      info: makeLogger("info"),
      warn: makeLogger("warn"),
      error: makeLogger("error"),
      debug: makeLogger("debug"),
      trace: makeLogger("trace"),
      dir: makeLogger("dir"),
      assert: (cond: unknown, ...args: unknown[]) => {
        if (!cond) {
          nativeLog("assert", "Assertion failed: " + fmt(...args));
          if (typeof origConsole?.assert === "function") try { origConsole.assert.call(origConsole, cond, ...args); } catch {}
        }
      },
      time: origConsole?.time ?? (() => {}),
      timeEnd: origConsole?.timeEnd ?? (() => {}),
      timeLog: origConsole?.timeLog ?? (() => {}),
      group: origConsole?.group ?? (() => {}),
      groupEnd: origConsole?.groupEnd ?? (() => {}),
      groupCollapsed: origConsole?.groupCollapsed ?? (() => {}),
      clear: origConsole?.clear ?? (() => {}),
      count: origConsole?.count ?? (() => {}),
      countReset: origConsole?.countReset ?? (() => {}),
      table: makeLogger("table"),
    };
  }
}

// --- Polyfills (only what's missing) ---

if (typeof g.Event !== "function") {
  g.Event = function Event(this: Record<string, unknown>, type: string, init?: Record<string, unknown>) {
    this.type = String(type ?? "");
    this.defaultPrevented = false;
    if (init) for (const k of Object.keys(init)) this[k] = init[k];
  } as unknown;
}

if (typeof g.MessageEvent !== "function") {
  const _Event = g.Event as new (type: string, init?: Record<string, unknown>) => Record<string, unknown>;
  g.MessageEvent = function MessageEvent(this: Record<string, unknown>, type: string, init?: Record<string, unknown>) {
    _Event.call(this, type, init);
    this.data = init?.data;
    this.ports = init?.ports ?? [];
  } as unknown;
}

if (typeof g.AbortSignal !== "function") {
  function AbortSignalCtor(this: Record<string, unknown>) {
    this.aborted = false;
    this.reason = undefined;
    this._listeners = [] as Array<() => void>;
  }
  AbortSignalCtor.prototype.addEventListener = function (type: string, fn: () => void) {
    if (type === "abort" && typeof fn === "function") (this._listeners as Array<() => void>).push(fn);
  };
  AbortSignalCtor.prototype.removeEventListener = function (type: string, fn: () => void) {
    if (type === "abort") this._listeners = (this._listeners as Array<() => void>).filter((f: () => void) => f !== fn);
  };
  g.AbortSignal = AbortSignalCtor as unknown;
}

if (typeof g.AbortController !== "function") {
  const _Signal = g.AbortSignal as new () => Record<string, unknown>;
  g.AbortController = function AbortControllerCtor(this: Record<string, unknown>) {
    this.signal = new _Signal();
  } as unknown;
  (g.AbortController as { prototype: Record<string, unknown> }).prototype.abort = function (reason?: unknown) {
    const s = this.signal as Record<string, unknown>;
    if (s.aborted) return;
    s.aborted = true;
    s.reason = reason;
    const fns = ((s._listeners as Array<() => void>) ?? []).slice();
    s._listeners = [];
    for (const fn of fns) { try { fn(); } catch {} }
  };
}

// --- CustomEvent ---

if (typeof g.CustomEvent !== "function") {
  const _Event = g.Event as new (type: string, init?: Record<string, unknown>) => Record<string, unknown>;
  g.CustomEvent = function CustomEvent(this: Record<string, unknown>, type: string, init?: Record<string, unknown>) {
    _Event.call(this, type, init);
    this.detail = init?.detail ?? null;
  } as unknown;
  (g.CustomEvent as { prototype: Record<string, unknown> }).prototype = Object.create(
    (g.Event as { prototype: object }).prototype
  );
}

// --- TextEncoder / TextDecoder (native bridge) ---

if (typeof g.TextEncoder !== "function") {
  const nativeEncode = bridge.textEncode as ((s: string) => unknown) | undefined;
  g.TextEncoder = function TextEncoder() {} as unknown;
  (g.TextEncoder as { prototype: Record<string, unknown> }).prototype.encoding = "utf-8";
  (g.TextEncoder as { prototype: Record<string, unknown> }).prototype.encode = function (input?: string): unknown {
    if (!input) return new Uint8Array(0);
    if (nativeEncode) return nativeEncode(String(input));
    // JS fallback for environments without native bridge
    const str = String(input);
    const arr: number[] = [];
    for (let i = 0; i < str.length; i++) {
      let c = str.charCodeAt(i);
      if (c < 0x80) { arr.push(c); }
      else if (c < 0x800) { arr.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        const lo = str.charCodeAt(++i);
        c = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
        arr.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
      } else { arr.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
    }
    return new Uint8Array(arr);
  };
  (g.TextEncoder as { prototype: Record<string, unknown> }).prototype.encodeInto = function (
    input: string, dest: Uint8Array
  ): { read: number; written: number } {
    const encoded = (g.TextEncoder as { prototype: { encode: (s: string) => Uint8Array } }).prototype.encode(input) as Uint8Array;
    const written = Math.min(encoded.length, dest.length);
    dest.set(encoded.subarray(0, written));
    return { read: input.length, written };
  };
}

if (typeof g.TextDecoder !== "function") {
  const nativeDecode = bridge.textDecode as ((buf: unknown) => string) | undefined;
  g.TextDecoder = function TextDecoder() {} as unknown;
  (g.TextDecoder as { prototype: Record<string, unknown> }).prototype.encoding = "utf-8";
  (g.TextDecoder as { prototype: Record<string, unknown> }).prototype.decode = function (input?: unknown): string {
    if (!input) return "";
    if (nativeDecode) return nativeDecode(input);
    // JS fallback
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input as ArrayBuffer);
    const parts: string[] = [];
    let i = 0;
    while (i < bytes.length) {
      const b = bytes[i];
      if (b < 0x80) { parts.push(String.fromCharCode(b)); i++; }
      else if ((b & 0xe0) === 0xc0) { parts.push(String.fromCharCode(((b & 0x1f) << 6) | (bytes[i+1] & 0x3f))); i += 2; }
      else if ((b & 0xf0) === 0xe0) { parts.push(String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i+1] & 0x3f) << 6) | (bytes[i+2] & 0x3f))); i += 3; }
      else if ((b & 0xf8) === 0xf0) {
        const cp = ((b & 0x07) << 18) | ((bytes[i+1] & 0x3f) << 12) | ((bytes[i+2] & 0x3f) << 6) | (bytes[i+3] & 0x3f);
        const s = cp - 0x10000;
        parts.push(String.fromCharCode(0xd800 + (s >> 10), 0xdc00 + (s & 0x3ff)));
        i += 4;
      } else { parts.push("\ufffd"); i++; }
    }
    return parts.join("");
  };
}

// --- URL (native bridge) ---

if (typeof g.URL !== "function") {
  const nativeParse = (bridge as Record<string, unknown>).urlParse as
    ((url: string, base?: string) => { href: string; protocol: string; host: string; hostname: string; port: string; pathname: string; search: string; hash: string; origin: string; username: string; password: string } | null) | undefined;

  function URLCtor(this: Record<string, unknown>, url: string, base?: string) {
    const parsed = nativeParse?.(String(url), base != null ? String(base) : undefined);
    if (!parsed) throw new TypeError(`Invalid URL: ${url}`);
    this.href = parsed.href;
    this.protocol = parsed.protocol;
    this.host = parsed.host;
    this.hostname = parsed.hostname;
    this.port = parsed.port;
    this.pathname = parsed.pathname;
    this.search = parsed.search;
    this.hash = parsed.hash;
    this.origin = parsed.origin;
    this.username = parsed.username;
    this.password = parsed.password;
  }
  URLCtor.prototype.toString = function () { return this.href; };
  URLCtor.prototype.toJSON = function () { return this.href; };
  g.URL = URLCtor as unknown;
}

// --- atob / btoa (native bridge) ---

if (typeof g.atob !== "function") {
  const nativeAtob = (bridge as Record<string, unknown>).atob as ((s: string) => string) | undefined;
  g.atob = (encoded: string): string => {
    if (nativeAtob) return nativeAtob(String(encoded));
    throw new Error("atob not available");
  };
}

if (typeof g.btoa !== "function") {
  const nativeBtoa = (bridge as Record<string, unknown>).btoa as ((s: string) => string) | undefined;
  g.btoa = (data: string): string => {
    if (nativeBtoa) return nativeBtoa(String(data));
    throw new Error("btoa not available");
  };
}

// --- Headers class ---

if (typeof g.Headers !== "function") {
  function HeadersCtor(this: Record<string, unknown>, init?: Record<string, string> | Array<[string, string]>) {
    const map: Record<string, string> = {};
    if (Array.isArray(init)) {
      for (const [k, v] of init) map[String(k).toLowerCase()] = String(v);
    } else if (init && typeof init === "object") {
      for (const k of Object.keys(init)) map[k.toLowerCase()] = String(init[k]);
    }
    this._map = map;
  }
  HeadersCtor.prototype.get = function (name: string): string | null {
    return (this._map as Record<string, string>)[String(name).toLowerCase()] ?? null;
  };
  HeadersCtor.prototype.set = function (name: string, value: string): void {
    (this._map as Record<string, string>)[String(name).toLowerCase()] = String(value);
  };
  HeadersCtor.prototype.has = function (name: string): boolean {
    return String(name).toLowerCase() in (this._map as Record<string, string>);
  };
  HeadersCtor.prototype.delete = function (name: string): void {
    delete (this._map as Record<string, string>)[String(name).toLowerCase()];
  };
  HeadersCtor.prototype.forEach = function (cb: (v: string, k: string) => void): void {
    const m = this._map as Record<string, string>;
    for (const k of Object.keys(m)) cb(m[k], k);
  };
  HeadersCtor.prototype.entries = function* () {
    const m = this._map as Record<string, string>;
    for (const k of Object.keys(m)) yield [k, m[k]];
  };
  HeadersCtor.prototype[Symbol.iterator] = HeadersCtor.prototype.entries;
  g.Headers = HeadersCtor as unknown;
}

// --- WebSocket (native bridge) ---

if (typeof g.WebSocket !== "function") {
  const wsConnect = (bridge as Record<string, unknown>).wsConnect as
    ((url: string, protocols: string[] | undefined, callback: (event: Record<string, unknown>) => void) => string) | undefined;
  const wsSend = (bridge as Record<string, unknown>).wsSend as
    ((wsId: string, data: unknown, isBinary: boolean) => void) | undefined;
  const wsClose = (bridge as Record<string, unknown>).wsClose as
    ((wsId: string, code?: number, reason?: string) => void) | undefined;

  const WS_CONNECTING = 0, WS_OPEN = 1, WS_CLOSING = 2, WS_CLOSED = 3;

  function WebSocketCtor(this: Record<string, unknown>, url: string, protocols?: string | string[]) {
    const self = this;
    self.url = String(url);
    self.readyState = WS_CONNECTING;
    self.bufferedAmount = 0;
    self.extensions = "";
    self.protocol = "";
    self.binaryType = "arraybuffer";
    self.onopen = null;
    self.onmessage = null;
    self.onerror = null;
    self.onclose = null;

    const eventListeners: Record<string, Array<(e: unknown) => void>> = {};

    self.addEventListener = (type: string, listener: (e: unknown) => void): void => {
      (eventListeners[type] ??= []).push(listener);
    };
    self.removeEventListener = (type: string, listener: (e: unknown) => void): void => {
      eventListeners[type] = (eventListeners[type] ?? []).filter(fn => fn !== listener);
    };
    self.dispatchEvent = (event: Record<string, unknown>): boolean => {
      const type = String(event?.type ?? "");
      const handler = self[`on${type}`] as ((e: unknown) => void) | null;
      if (typeof handler === "function") { try { handler(event); } catch {} }
      for (const fn of (eventListeners[type] ?? []).slice()) {
        try { fn(event); } catch {}
      }
      return true;
    };

    const protoArray = protocols == null ? undefined
      : typeof protocols === "string" ? [protocols]
      : protocols;

    if (!wsConnect) {
      (g.setTimeout as (fn: () => void, ms: number) => void)(() => {
        self.readyState = WS_CLOSED;
        const err = typeof g.Event === "function"
          ? new (g.Event as new (t: string) => Record<string, unknown>)("error")
          : { type: "error" };
        (self.dispatchEvent as (e: unknown) => void)(err);
      }, 0);
      return;
    }

    const wsId = wsConnect(String(url), protoArray, (event: Record<string, unknown>) => {
      const type = String(event.type ?? "");
      if (type === "open") {
        self.readyState = WS_OPEN;
        const evt = typeof g.Event === "function"
          ? new (g.Event as new (t: string) => Record<string, unknown>)("open")
          : { type: "open" };
        (self.dispatchEvent as (e: unknown) => void)(evt);
      } else if (type === "message") {
        if (self.readyState !== WS_OPEN) return;
        let data: unknown = event.data;
        const isBinary = event.binary === true;
        if (isBinary && Array.isArray(data)) {
          data = new Uint8Array(data as number[]).buffer;
        }
        const evt = typeof g.MessageEvent === "function"
          ? new (g.MessageEvent as new (t: string, i: { data: unknown }) => Record<string, unknown>)("message", { data })
          : { type: "message", data };
        (self.dispatchEvent as (e: unknown) => void)(evt);
      } else if (type === "error") {
        const evt = typeof g.Event === "function"
          ? new (g.Event as new (t: string) => Record<string, unknown>)("error")
          : { type: "error" };
        (self.dispatchEvent as (e: unknown) => void)(evt);
      } else if (type === "close") {
        self.readyState = WS_CLOSED;
        const evt = { type: "close", code: event.code ?? 1000, reason: event.reason ?? "", wasClean: event.wasClean ?? true };
        (self.dispatchEvent as (e: unknown) => void)(evt);
      }
    });

    (self as Record<string, unknown>)._wsId = wsId;
  }

  WebSocketCtor.prototype.send = function (data: unknown): void {
    if (this.readyState !== WS_OPEN) throw new Error("WebSocket is not open");
    const wsId = (this as Record<string, unknown>)._wsId as string;
    const isBinary = data instanceof ArrayBuffer || data instanceof Uint8Array;
    if (isBinary) {
      const bytes = data instanceof Uint8Array ? data : new Uint8Array(data as ArrayBuffer);
      wsSend?.(wsId, bytes, true);
    } else {
      wsSend?.(wsId, String(data), false);
    }
  };
  WebSocketCtor.prototype.close = function (code?: number, reason?: string): void {
    if (this.readyState === WS_CLOSED || this.readyState === WS_CLOSING) return;
    this.readyState = WS_CLOSING;
    const wsId = (this as Record<string, unknown>)._wsId as string;
    wsClose?.(wsId, code, reason);
  };
  WebSocketCtor.CONNECTING = WS_CONNECTING;
  WebSocketCtor.OPEN = WS_OPEN;
  WebSocketCtor.CLOSING = WS_CLOSING;
  WebSocketCtor.CLOSED = WS_CLOSED;
  WebSocketCtor.prototype.CONNECTING = WS_CONNECTING;
  WebSocketCtor.prototype.OPEN = WS_OPEN;
  WebSocketCtor.prototype.CLOSING = WS_CLOSING;
  WebSocketCtor.prototype.CLOSED = WS_CLOSED;

  g.WebSocket = WebSocketCtor as unknown;
}

// --- Timers ---

g.setTimeout = ((handler: unknown, ms?: number, ...args: unknown[]): number => {
  if (typeof handler !== "function") return 0;
  return bridge.setTimer?.(() => (handler as Function)(...args), Number(ms ?? 0), false) ?? 0;
}) as unknown;

g.clearTimeout = ((id?: number): void => {
  if (typeof id === "number") bridge.clearTimer?.(id);
}) as unknown;

g.setInterval = ((handler: unknown, ms?: number, ...args: unknown[]): number => {
  if (typeof handler !== "function") return 0;
  return bridge.setTimer?.(() => (handler as Function)(...args), Number(ms ?? 0), true) ?? 0;
}) as unknown;

g.clearInterval = g.clearTimeout;

// --- postMessage / onmessage / close ---

g.postMessage = (data: unknown): void => { bridge.postMessage?.(data); };
g.close = (): void => { bridge.closeWorker?.(); };

// --- Crypto ---

if (typeof g.crypto === "undefined") {
  g.crypto = {
    getRandomValues: (a: unknown) => bridge.getRandomValues?.(a) ?? a,
    randomUUID: (): string => bridge.randomUUID?.() ?? "00000000-0000-0000-0000-000000000000",
  };
}

// --- Fetch ---

{
  const _Headers = g.Headers as (new (init?: Record<string, string>) => Record<string, unknown>) | undefined;
  const _TextEncoder = g.TextEncoder as (new () => { encode: (s: string) => Uint8Array }) | undefined;

  const makeResponse = (
    bodyContent: string,
    status: number,
    statusText: string,
    headerMap: Record<string, string>,
  ): Record<string, unknown> => {
    const hdrs = _Headers ? new _Headers(headerMap) : headerMap;
    let bodyUsed = false;
    const consumeBody = (): string => {
      if (bodyUsed) throw new TypeError("Body already consumed");
      bodyUsed = true;
      return bodyContent;
    };
    return {
      ok: status >= 200 && status < 300,
      status,
      statusText,
      headers: hdrs,
      url: "",
      redirected: false,
      type: "basic",
      bodyUsed: false,
      text: () => { const t = consumeBody(); return Promise.resolve(t); },
      json: () => { const t = consumeBody(); return Promise.resolve(JSON.parse(t)); },
      arrayBuffer: () => {
        const t = consumeBody();
        if (_TextEncoder) {
          const enc = new _TextEncoder();
          return Promise.resolve(enc.encode(t).buffer);
        }
        const buf = new ArrayBuffer(t.length);
        const view = new Uint8Array(buf);
        for (let i = 0; i < t.length; i++) view[i] = t.charCodeAt(i) & 0xff;
        return Promise.resolve(buf);
      },
      blob: () => Promise.reject(new Error("Blob not supported in this context")),
      clone: () => makeResponse(bodyContent, status, statusText, headerMap),
    };
  };

  if (typeof g.fetch === "undefined") {
    g.fetch = (input: unknown, init?: Record<string, unknown>): Promise<unknown> =>
      new Promise((resolve, reject) => {
        let url = "", method = "GET", headers: Record<string, string> = {}, body: string | undefined;

        if (typeof input === "string") url = input;
        else if (input && typeof input === "object") {
          const r = input as Record<string, unknown>;
          if (typeof r.url === "string") {
            url = r.url;
            method = (r.method as string) || "GET";
            body = r.body as string | undefined;
          } else if (typeof (r as { href?: string }).href === "string") {
            url = (r as { href: string }).href;
          }
        }
        if (init) {
          if (init.method) method = init.method as string;
          if (init.body) {
            if (typeof init.body === "string") body = init.body;
            else if (init.body instanceof ArrayBuffer || init.body instanceof Uint8Array) {
              const bytes = init.body instanceof Uint8Array ? init.body : new Uint8Array(init.body);
              const td = g.TextDecoder as (new () => { decode: (b: Uint8Array) => string }) | undefined;
              body = td ? new td().decode(bytes) : String.fromCharCode(...bytes);
            } else {
              body = JSON.stringify(init.body);
            }
          }
          if (init.headers && typeof init.headers === "object") {
            if (typeof (init.headers as Record<string, unknown>).forEach === "function") {
              (init.headers as { forEach: (cb: (v: string, k: string) => void) => void }).forEach(
                (v, k) => { headers[k] = String(v); }
              );
            } else {
              for (const [k, v] of Object.entries(init.headers as Record<string, string>)) headers[k] = String(v);
            }
          }
        }

        if (!bridge.fetch) return reject(new Error("fetch not available"));

        bridge.fetch(url, { method, headers, body }, (res) => {
          let bodyContent = res.body ?? "";
          if (res.body_base64 && typeof g.atob === "function") {
            try { bodyContent = (g.atob as (s: string) => string)(res.body_base64); } catch {}
          }
          resolve(makeResponse(bodyContent, res.status, res.statusText, res.headers));
        }, (err) => reject(new Error(err)));
      });
  }
}

// --- Zapp API (__zapp: emit, invoke, on) ---

type ZappListener = { id: number; fn: (payload: unknown) => void };
const zappListeners: Record<string, ZappListener[]> = {};
let zappNextId = 0;
const ctxId = `ctx-${Date.now()}-${Math.random().toString(36).slice(2)}`;
const getWorkerId = (): string => String((g as Record<string, unknown>).__zappWorkerDispatchId ?? "");

const zappApi = Object.freeze({
  emit: (name: string, payload?: unknown): boolean => {
    bridge.emitToHost?.(name, payload);
    return true;
  },
  invoke: (method: string, payload?: unknown): boolean => {
    bridge.invokeToHost?.(method, payload);
    return true;
  },
  on: (name: string, handler: (payload: unknown) => void): (() => void) => {
    const id = ++zappNextId;
    (zappListeners[name] ??= []).push({ id, fn: handler });
    return () => { zappListeners[name] = (zappListeners[name] ?? []).filter(e => e.id !== id); };
  },
});

try {
  Object.defineProperty(g, "__zapp", { value: zappApi, enumerable: true, configurable: false, writable: false });
} catch {
  g.__zapp = zappApi;
}

// --- Channel system (send/receive) ---

const channelListeners: Record<string, Array<(data: unknown, reply: (ch: string, d: unknown) => void) => void>> = {};

g.send = (channel: string, data: unknown): void => {
  (g.postMessage as (d: unknown) => void)({ __zapp_channel: channel, data });
};

g.receive = (channel: string, handler: (data: unknown, reply: (ch: string, d: unknown) => void) => void): (() => void) => {
  (channelListeners[channel] ??= []).push(handler);
  return () => { channelListeners[channel] = (channelListeners[channel] ?? []).filter(fn => fn !== handler); };
};

// --- Sync bridge (JS Promise wrappers over native C sync functions) ---

const syncPending: Record<string, { resolve: (v: string) => void; reject: (e: Error) => void; timer?: unknown }> = {};

// Overwrite the native C syncWait with a JS Promise wrapper.
// The native C function (captured as nativeSyncWait) sends the wire message;
// the JS wrapper tracks pending requests and resolves/rejects Promises.
(bridge as Record<string, unknown>).syncWait = (request: { key: string; timeoutMs: number | null; signal?: { aborted: boolean; addEventListener?: (t: string, fn: () => void) => void } }): Promise<string> =>
  new Promise((resolve, reject) => {
    const key = typeof request?.key === "string" ? request.key.trim() : "";
    if (!key) { reject(new Error("Sync key must be a non-empty string.")); return; }
    if (request?.signal?.aborted) { reject(new Error("Sync wait aborted.")); return; }

    const requestId = `${ctxId}:sync-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const timeout = request?.timeoutMs == null ? null : Math.max(1, Math.min(300000, Math.floor(Number(request.timeoutMs))));
    const timer = timeout == null ? undefined : (g.setTimeout as (fn: () => void, ms: number) => unknown)(() => {
      delete syncPending[requestId];
      reject(new Error("Sync wait transport timed out."));
    }, timeout + 5000);

    syncPending[requestId] = { resolve, reject, timer };
    nativeSyncWait?.({ id: requestId, key, timeoutMs: timeout, targetWorkerId: getWorkerId() });

    if (request?.signal?.addEventListener) {
      request.signal.addEventListener("abort", () => {
        const p = syncPending[requestId];
        if (!p) return;
        if (p.timer) (g.clearTimeout as (id: unknown) => void)(p.timer);
        delete syncPending[requestId];
        nativeSyncCancel?.({ id: requestId, targetWorkerId: getWorkerId() });
        reject(new Error("Sync wait aborted."));
      });
    }
  });

(bridge as Record<string, unknown>).syncNotify = (request: { key: string; count: number }): boolean => {
  const key = typeof request?.key === "string" ? request.key.trim() : "";
  if (!key) return false;
  return nativeSyncNotify?.({ key, count: Math.max(1, Math.min(65535, Math.floor(Number(request?.count ?? 1)))), targetWorkerId: getWorkerId() }) ?? false;
};

(bridge as Record<string, unknown>).syncCancel = (request: { id: string }): boolean => {
  const id = typeof request?.id === "string" ? request.id.trim() : "";
  if (!id) return false;
  return nativeSyncCancel?.({ id, targetWorkerId: getWorkerId() }) ?? false;
};

// --- Window bridge (workers can create windows via the native bridge) ---

const pendingWindowCreates: Record<
  string,
  { resolve: (v: { id: string }) => void; reject: (e: Error) => void; timer?: unknown }
> = {};
let windowSeq = 0;

(bridge as Record<string, unknown>).windowCreate = (options: unknown): Promise<{ id: string }> =>
  new Promise((resolve, reject) => {
    const reqId = `${ctxId}:win-${++windowSeq}`;
    const timer = (g.setTimeout as (fn: () => void, ms: number) => unknown)(() => {
      delete pendingWindowCreates[reqId];
      reject(new Error("Window creation timed out."));
    }, 15000);
    pendingWindowCreates[reqId] = { resolve, reject, timer };
    bridge.emitToHost?.("__zapp_window_create", JSON.stringify({ requestId: reqId, options }));
  });

(bridge as Record<string, unknown>).windowAction = (windowId: string, action: string, params?: Record<string, unknown>): void => {
  bridge.emitToHost?.("__zapp_window_action", JSON.stringify({ windowId, action, ...params }));
};

(bridge as Record<string, unknown>).appAction = (action: string): void => {
  bridge.emitToHost?.("__zapp_app_action", JSON.stringify({ action }));
};

bridge.dispatchWindowResult = (payload: unknown): void => {
  let parsed = payload;
  if (typeof parsed === "string") { try { parsed = JSON.parse(parsed); } catch { return; } }
  if (!parsed || typeof parsed !== "object") return;
  const result = parsed as { requestId?: string; id?: string; ok?: boolean; error?: string };
  if (typeof result.requestId !== "string") return;
  const pending = pendingWindowCreates[result.requestId];
  if (!pending) return;
  if (pending.timer) (g.clearTimeout as (id: unknown) => void)(pending.timer);
  delete pendingWindowCreates[result.requestId];
  if (result.ok === false) {
    pending.reject(new Error(result.error ?? "Window creation failed."));
  } else {
    pending.resolve({ id: result.id ?? "" });
  }
};

// Register as Symbol.for("zapp.bridge") — the single object for native and JS access
try {
  Object.defineProperty(g, Symbol.for("zapp.bridge"), { value: bridge, enumerable: false, configurable: true, writable: false });
} catch {
  (g as Record<symbol, unknown>)[Symbol.for("zapp.bridge")] = bridge;
}

// --- Bridge callbacks (called from native via Symbol.for("zapp.bridge").methodName) ---

const ports = new Map<string, { _id: string; postMessage: (d: unknown) => void; onmessage: ((e: unknown) => void) | null; onclose: ((e: unknown) => void) | null; start: () => void; close: () => void }>();

bridge.dispatchMessage = (data: unknown, sourceId?: string): void => {
  if (data && typeof data === "object" && (data as Record<string, unknown>).__zapp_channel) {
    const ch = (data as Record<string, unknown>).__zapp_channel as string;
    const inner = (data as Record<string, unknown>).data;
    const reply = (replyCh: string, replyData: unknown) => {
      if (sourceId) bridge.postMessage?.({ __zapp_channel: replyCh, data: replyData }, sourceId);
      else (g.postMessage as (d: unknown) => void)({ __zapp_channel: replyCh, data: replyData });
    };
    for (const fn of (channelListeners[ch] ?? []).slice()) { try { fn(inner, reply); } catch {} }
    return;
  }

  const event = typeof g.MessageEvent === "function"
    ? new (g.MessageEvent as new (t: string, i: { data: unknown }) => unknown)("message", { data })
    : { type: "message", data };

  if (typeof g.onmessage === "function") {
    try { (g.onmessage as (e: unknown) => void)(event); } catch (e) { reportError(e); }
  }
};

bridge.dispatchConnect = (id: string): void => {
  const port = {
    _id: id,
    postMessage: (data: unknown) => bridge.postMessage?.(data, id),
    onmessage: null as ((e: unknown) => void) | null,
    onclose: null as ((e: unknown) => void) | null,
    start() {},
    close() {},
  };
  ports.set(id, port);
  const event = typeof g.MessageEvent === "function"
    ? new (g.MessageEvent as new (t: string, i: { ports: unknown[] }) => unknown)("connect", { ports: [port] })
    : { type: "connect", ports: [port] };
  if (typeof (g as Record<string, unknown>).onconnect === "function") {
    try { ((g as Record<string, unknown>).onconnect as (e: unknown) => void)(event); } catch (e) { reportError(e); }
  }
};

bridge.dispatchDisconnect = (id: string): void => {
  const port = ports.get(id);
  if (port) {
    if (port.onclose) try { port.onclose({ type: "close" }); } catch {}
    ports.delete(id);
  }
};

bridge.dispatchSyncResult = (payload: unknown): void => {
  let p = payload;
  if (typeof p === "string") { try { p = JSON.parse(p); } catch { return; } }
  if (!p || typeof p !== "object") return;
  const r = p as { id?: string; ok?: boolean; status?: string };
  if (typeof r.id !== "string" || !r.id) return;
  const pending = syncPending[r.id];
  if (!pending) return;
  if (pending.timer) (g.clearTimeout as (id: unknown) => void)(pending.timer);
  delete syncPending[r.id];
  if (!r.ok) { pending.reject(new Error("Sync wait failed.")); return; }
  if (r.status === "cancelled") { pending.reject(new Error("Sync wait aborted.")); return; }
  pending.resolve(r.status === "timed-out" ? "timed-out" : "notified");
};

bridge.deliverEvent = (name: string, payload: unknown): void => {
  const queue = zappListeners[name];
  if (!queue || queue.length === 0) return;
  let data = payload;
  if (typeof data === "string") { try { data = JSON.parse(data); } catch {} }
  if (data && typeof data === "object") {
    const d = data as { __zapp_internal_meta?: { sourceCtxId?: string }; data?: unknown };
    if (d.__zapp_internal_meta) {
      if (d.__zapp_internal_meta.sourceCtxId === ctxId) return;
      data = d.data;
    }
  }
  for (const entry of queue.slice()) { try { entry.fn(data); } catch (e) { reportError(e); } }
};

export {};
