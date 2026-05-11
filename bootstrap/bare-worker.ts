/**
 * Bare engine worker bootstrap — installs the JS-side methods on
 * `globalThis.__zappBridge` that the bare-jsc / bare-v8 / bare-quickjs /
 * bare-mqjs engines rely on. Counterpart to the per-engine bootstrap
 * shapes in jsc.m and txiki.c, but written here in TypeScript so it
 * gets the same review/edit ergonomics as the rest of the runtime
 * (and so all four bare variants share one JS source instead of each
 * carrying a copy).
 *
 * Bundle pipeline: `bootstrap/codegen.ts` minifies this into a C
 * string literal exposed as `zapp_bare_worker_bootstrap_script()`.
 * `native/worker/engines/bare.c:bare_worker_thread` runs the script
 * once, immediately after registering the host functions on
 * `__zappBridge` — so when this code references `b._invokeServiceRaw`,
 * `b._postToWebviewRaw`, etc., those native trampolines already exist.
 *
 * The fsAllowlist injection is intentionally NOT here — it depends on
 * build-time JSON (`zapp_build_fs_allowlist_json`) and stays as a
 * small inline snippet in bare.c just for that one assignment.
 */

declare const globalThis: any;
declare const Bare: any;

(function () {
  const b = globalThis.__zappBridge;
  if (!b) return;

  // --- Service invocation ---------------------------------------------
  // Args go through JSON.stringify on the way in (using JSC's JIT'd
  // JSON path, which is fast); the C trampoline reads the string and
  // hands it to `service_invoke_sync`. Result is a JSON string we
  // parse on the way out.
  //
  // We tried walking the JS value tree directly via libjs's
  // reflection API (matching jsc.m / txiki.c's "zero-JSON" path) —
  // it benched slower on realistic payloads because libjs's
  // js_get_named_property + js_typeof have per-call overhead that
  // dominates the cost. The string path is faster on bare specifically.
  b.invokeService = function (method: string, args?: unknown): unknown {
    const argJson = args === undefined || args === null
      ? "{}"
      : JSON.stringify(args);
    const resultJson = b._invokeServiceRaw(method, argJson);
    if (resultJson === undefined || resultJson === "" || resultJson === null) {
      return undefined;
    }
    try { return JSON.parse(resultJson); }
    catch { return resultJson; }
  };

  // --- Inbox-driven message dispatch ----------------------------------
  // bare.c's on_async_message drainer evaluates
  // `globalThis.__zappBridge._dispatchMessage(parsed)` after JSON.parsing
  // each postMessage payload. We then route to globalThis.onmessage
  // and the channel-router array (`_messageHandlers`) the worker
  // bootstrap installs.
  b._dispatchMessage = function (parsed: unknown): void {
    const ev = { data: parsed };
    if (typeof globalThis.onmessage === "function") {
      try { globalThis.onmessage(ev); }
      catch (e: any) { b.log("onmessage threw: " + (e && e.message || e)); }
    }
    const hs = globalThis._messageHandlers;
    if (Array.isArray(hs)) {
      for (let i = 0; i < hs.length; i++) {
        try { hs[i](ev); }
        catch (e: any) { b.log("messageHandler threw: " + (e && e.message || e)); }
      }
    }
  };

  // --- Event listener registry (Events.on / .emit / app events) -------
  const listeners: Record<string, Array<(d: unknown) => void>> = Object.create(null);
  b.on = function (name: string, fn: (d: unknown) => void): void {
    (listeners[name] = listeners[name] || []).push(fn);
  };
  b._onEvent = function (name: string, payload: string): void {
    const ls = listeners[name];
    if (!ls) return;
    let data: unknown;
    try { data = JSON.parse(payload); }
    catch { data = payload; }
    for (let i = 0; i < ls.length; i++) {
      try { ls[i](data); }
      catch (e: any) { b.log("event listener threw: " + (e && e.message || e)); }
    }
  };
  b._dispatchAppEvent = function (_id: number, _payload: string): void {
    // Worker bootstrap (zapp_worker_bootstrap_script) overwrites this
    // with the real handler that maps event_id → "app:..." names. The
    // assignment here is a placeholder so anything firing the event
    // before the bootstrap has run no-ops cleanly instead of throwing.
  };
  globalThis[Symbol.for("zapp.bridge")] = b;

  // --- Stringifying wrappers around the *Raw host functions -----------
  // The C trampolines all read their string args via
  // js_get_value_string_utf8, which coerces a JS object to
  // `"[object Object]"`. Without these wrappers, `Events.emit`,
  // `Workers.send`, and `postToWebview` would all deliver garbage
  // payloads to receivers (Counter would show `undefined` etc.).
  function _stringify(v: unknown): string {
    if (v === undefined || v === null) return "{}";
    if (typeof v === "string") return v;
    try { return JSON.stringify(v); }
    catch { return String(v); }
  }
  b.dispatchEventToAll = function (name: string, payload?: unknown): void {
    b._dispatchEventToAllRaw(name, _stringify(payload));
  };
  b.emitToHost = b.dispatchEventToAll;  // legacy alias
  b.postToWebview = function (payload: unknown): void {
    b._postToWebviewRaw(_stringify(payload));
  };

  // Web Worker convention: `self.postMessage(data)` is the standard
  // way for a worker to send a message to its owning context. The
  // shared worker bootstrap (bootstrap/worker.ts via
  // zapp_worker_bootstrap_script) defines `self.send(ch, data)` as
  // `self.postMessage({__zc:ch, d:data})` — so without this alias,
  // every worker that calls `send(...)` to reply to a `receive(...)`
  // throws silently because `postMessage` is undefined.
  // jsc.m and txiki.c install this same alias inside their per-engine
  // bridge setup; bare needs it here.
  globalThis.postMessage = function (data: unknown): void {
    b._postToWebviewRaw(_stringify(data));
  };

  // --- Uncaught exception isolation ----------------------------------
  // Bare's default `onuncaughtexception` (bare.js:178) calls
  // `bare.abort()` after printing the error — that sends SIGABRT and
  // kills the WHOLE host process, not just the offending worker.
  // Bare emits an `'uncaughtException'` (and `'unhandledRejection'`)
  // event before aborting; ANY listener returns truthy from emit() and
  // the abort is skipped. Install minimal listeners here that route
  // crashes through the existing `worker:crashed` event flow (UI gets
  // notified, supervisor records the failure) and let the host keep
  // running. Same for unhandled promise rejections.
  //
  // `_handleUserScriptError` is the same logic used by the user-script
  // try/catch wrapper (see below). Routes errors through three places:
  //   1. `b.log` → fprintf in bare.c → `[bare:<wid>] worker uncaught: ...`
  //      visible in the host stderr immediately on crash.
  //   2. `b.workerCrash` → dispatches `worker:crashed` event so any
  //      Events.on(...) listener in the app sees it.
  //   3. `console.error` fallback ONLY when bridge.log unexpectedly
  //      threw (bridge is set up before user code runs, but defensive).
  b._handleUserScriptError = function (err: any): void {
    const msg = (err && err.message) ? String(err.message) : String(err);
    const stack = (err && err.stack) ? String(err.stack) : "";
    let logged = false;
    try {
      if (typeof b.log === "function") {
        b.log("worker uncaught: " + msg + (stack ? ("\n" + stack) : ""));
        logged = true;
      }
    } catch (_) { /* fall through to console.error */ }
    try {
      if (typeof b.workerCrash === "function") b.workerCrash(msg, stack);
    } catch (_) { /* swallow — last-line defense */ }
    if (!logged) {
      try {
        if (typeof console !== "undefined" && (console as any).error) {
          (console as any).error("[zapp] worker uncaught: " + msg + "\n" + stack);
        }
      } catch (_) { /* swallow */ }
    }
  };

  if (typeof Bare !== "undefined" && typeof Bare.on === "function") {
    Bare.on("uncaughtException", b._handleUserScriptError);
    Bare.on("unhandledRejection", b._handleUserScriptError);
  }

  // --- Friendly placeholders for WHATWG globals ----------------------
  // Workers expect `fetch`, `WebSocket`, etc. to "just work". When the
  // user hasn't installed the underlying bare-* module yet OR hasn't
  // imported `@zappdev/runtime/worker-globals`, those are undefined
  // and any code referencing them throws a confusing ReferenceError.
  //
  // Install no-op placeholders that throw a CLEAR error pointing at
  // the install + import the user actually needs. The real
  // worker-globals shim (when imported) overwrites these.
  function _missingPackageError(api: string, pkg: string, subpath: string): () => never {
    const thrower = function () {
      throw new Error(
        `[zapp] ${api} is not available in this worker.\n` +
        `  Add to zapp.config.ts:  workerModules: ["${api.toLowerCase()}"]\n` +
        `  And install:           bun install ${pkg}\n` +
        `  (or import manually:   import "@zappdev/runtime/worker-globals${subpath}";)`
      );
    };
    // Sentinel so `bindGlobal` in runtime/worker-globals/_install.ts
    // knows it can overwrite this placeholder when the real shim runs.
    // Without this flag, bindGlobal sees `typeof globalThis.fetch ===
    // 'function'` and bails, leaving the thrower in place even when
    // bare-fetch IS installed and the workerModules prelude ran.
    (thrower as any).__zappPlaceholder = true;
    return thrower;
  }
  function _installPlaceholder(name: string, factory: () => () => never): void {
    if (typeof globalThis[name] !== "undefined") return;  // already provided
    try {
      Object.defineProperty(globalThis, name, {
        value: factory(),
        writable: true, configurable: true, enumerable: false,
      });
    } catch (_) { /* engine refused; live with it */ }
  }
  _installPlaceholder("fetch",     () => _missingPackageError("fetch",     "bare-fetch",  "/fetch"));
  _installPlaceholder("WebSocket", () => _missingPackageError("WebSocket", "bare-ws",     "/websocket"));
  // crypto / TextEncoder / URL — bare's bundled bootstrap usually
  // installs these via bare-url/bare-encoding/bare-console, so we
  // only fall back to placeholders if they're STILL missing after
  // bare's own setup ran.
  b.postToWorker = function (targetId: string, payload: unknown): void {
    b._postToWorkerRaw(targetId, _stringify(payload));
  };

  // --- Sync API (syncWait / syncNotify) -------------------------------
  // The native side uses `darwin_sync_handle` to register a wait,
  // then later calls `bridge.dispatchSyncResult(payload)` (see the
  // standard worker bootstrap for the resolver lookup) to deliver
  // the result. We just need to: generate a request id, wire the
  // resolver into _syncPending, and forward to native.
  b._syncSeq = b._syncSeq || 0;
  b._syncPending = b._syncPending || Object.create(null);
  b.syncWait = function (key: string, timeoutMs?: number): Promise<string> {
    if (!key) return Promise.resolve("timed-out");
    const id = b.workerId + ":sync-" + Date.now() + "-" + (++b._syncSeq);
    return new Promise<string>((resolve) => {
      b._syncPending[id] = resolve;
      b._registerWait(id, key, (timeoutMs == null || timeoutMs <= 0) ? -1 : timeoutMs);
    });
  };
  b.syncNotify = function (key: string, count?: number): void {
    if (!key) return;
    b._notifyHost(key, count == null ? 1 : count);
  };

  // --- Window creation ------------------------------------------------
  // Workers can spawn windows synchronously. The C side owns the main-
  // thread bounce; we just hand it stringified opts.
  b.createWindow = function (opts?: unknown): { windowId: string } {
    const optsJson = opts == null ? "{}" : JSON.stringify(opts);
    return b._createWindowRaw(optsJson);
  };
})();

// Empty export so TS treats this as a module (lets `globalThis` be
// re-declared without "all-files-in-scope" duplication errors).
export {};
