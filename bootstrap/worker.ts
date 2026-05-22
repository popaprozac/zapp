/**
 * Worker bootstrap — injected into every JSC worker context (webview-spawned
 * and headless alike). All workers share the same API surface; the only
 * difference between a headless worker and a webview-owned one is whether
 * they have an owner window.
 *
 * Host objects set up by native (see jsc_setup_bridge in jsc.m):
 *   - invokeService(method, args) → JSValue (sync, direct C call)
 *   - postToWebview(data) → void (no-op in headless workers)
 *   - syncWait(key, timeoutMs), syncNotify(key, count)
 *   - dispatchEventToAll(name, payload) — broadcast to every webview
 *   - createWindow(opts) → number (returns windowId; works from any worker)
 *   - quit() — terminate the app
 *   - showNotification(title, body)
 *   - subscribeWindowEvent(windowId, eventId)
 *
 * This bootstrap adds:
 *   - A runtime bridge exposed via Symbol.for("zapp.bridge") so
 *     @zappdev/runtime's getBridge() works uniformly across contexts.
 *   - Channel API (self.send / self.receive) for webview-worker messaging.
 *   - App event listener registry + _dispatchAppEvent callback for headless
 *     workers that want to hear app:* lifecycle events.
 *   - dispatchSyncResult glue for Sync.wait()'s promise resolution.
 */

(function () {
  const bridge = (self as any).__zappBridge;
  if (!bridge) return;

  // Zero-overhead principle: we mutate __zappBridge in place to add the
  // methods the runtime expects (on, emit, invoke, post, _onEvent,
  // _dispatchAppEvent) and expose *that same object* under
  // Symbol.for("zapp.bridge"). No wrapper, no indirection — when the
  // runtime calls getBridge().invoke(...), it's hitting the native host
  // object's own property directly.
  //
  // The hottest path (Services.invoke → __zappBridge.invokeService) already
  // bypasses getBridge() entirely in runtime/services.ts, so it remains a
  // direct C call regardless. This setup ensures the remaining
  // runtime-API calls from worker contexts pay at most one JS property
  // read + function call, not a whole wrapper object hop.

  const listeners: Record<string, Array<(data: unknown) => void>> = {};

  const windowEventIds: Record<string, number> = {
    "window:ready": 0, "window:focus": 1, "window:blur": 2,
    "window:resize": 3, "window:move": 4, "window:close": 5,
    "window:minimize": 6, "window:maximize": 7, "window:restore": 8,
    "window:fullscreen": 9, "window:unfullscreen": 10,
  };

  bridge.on = function (event: string, handler: (data: unknown) => void) {
    if (!listeners[event]) listeners[event] = [];
    listeners[event].push(handler);
    const eventId = windowEventIds[event];
    if (eventId !== undefined && typeof bridge.subscribeWindowEvent === "function") {
      bridge.subscribeWindowEvent(-1, eventId); // -1 = all windows
    }
    return () => {
      listeners[event] = (listeners[event] || []).filter((h) => h !== handler);
    };
  };

  // Runtime's Events.emit calls bridge.emit — alias to the direct host.
  // No wrapper, just rename.
  bridge.emit = bridge.dispatchEventToAll;

  // Runtime's getBridge().invoke() — pure alias to invokeService (zero JS
  // overhead). Runtime APIs that need something other than a user service
  // (Window.create, Notification.*, Dock.*) detect worker context and call
  // the appropriate host dispatcher directly, so there's no branching here.
  bridge.invoke = bridge.invokeService;

  // Headless workers have no webview to post to; webview-owned workers
  // use postToWebview. Alias so getBridge().post(...) works either way.
  bridge.post = bridge.postToWebview ?? function () {};

  // Native-driven event dispatch callbacks.
  bridge._dispatchAppEvent = function (eventId: number, dataJson: string) {
    const eventMap: Record<number, string> = {
      100: "app:started", 101: "app:shutdown",
      102: "app:notification-click", 103: "app:notification-action",
      104: "app:reopen", 105: "app:open-url",
      106: "app:active", 107: "app:inactive",
      108: "app:theme-changed",
    };
    const name = eventMap[eventId];
    if (!name) return;
    let data: unknown = dataJson;
    try { data = JSON.parse(dataJson); } catch {}
    for (const h of listeners[name] || []) {
      try { h(data); } catch (e) { console.error("[worker]", e); }
    }
    if (eventId === 102) {
      for (const h of listeners["__notif:click"] || []) try { h(data); } catch (e) { console.error("[worker]", e); }
    } else if (eventId === 103) {
      for (const h of listeners["__notif:action"] || []) try { h(data); } catch (e) { console.error("[worker]", e); }
    }
  };

  // Forward an uncaught error to the supervisor (host side fires
  // worker:crashed + applies restart policy). The "Error:" prefix is
  // dropped from the message since the supervisor adds context anyway.
  function reportCrash(e: unknown) {
    const message = (e && typeof e === "object" && "message" in (e as any))
      ? String((e as any).message)
      : String(e);
    const stack = (e && typeof e === "object" && "stack" in (e as any))
      ? String((e as any).stack)
      : "";
    try { (bridge as any).workerCrash?.(message, stack); }
    catch (loopErr) { console.error("[worker]", loopErr); }
  }

  bridge._onEvent = function (name: string, payload: string) {
    let parsed: unknown = payload;
    try { parsed = JSON.parse(payload); } catch {}
    for (const h of listeners[name] || []) {
      try { h(parsed); } catch (e) {
        console.error("[worker]", e);
        reportCrash(e);
      }
    }
  };

  // Wrap setTimeout / setInterval so callbacks that throw route through
  // the supervisor instead of being dumped to stderr by the engine. This
  // is the single biggest source of "the throw escapes the bootstrap
  // try/catch and silently disappears" footguns. Both engines use this
  // shape — the wrap is engine-agnostic.
  const origSetTimeout = (globalThis as any).setTimeout?.bind(globalThis);
  if (origSetTimeout) {
    (globalThis as any).setTimeout = function (cb: (...a: any[]) => void, ms?: number, ...args: any[]) {
      return origSetTimeout(() => {
        try { cb(...args); } catch (e) { reportCrash(e); }
      }, ms);
    };
  }
  const origSetInterval = (globalThis as any).setInterval?.bind(globalThis);
  if (origSetInterval) {
    (globalThis as any).setInterval = function (cb: (...a: any[]) => void, ms?: number, ...args: any[]) {
      return origSetInterval(() => {
        try { cb(...args); } catch (e) { reportCrash(e); }
      }, ms);
    };
  }

  // Expose __zappBridge itself (not a wrapper) under the symbol the
  // runtime looks up. getBridge() returns the native host object directly.
  (globalThis as any)[Symbol.for("zapp.bridge")] = bridge;

  // Channel handler registry
  const channelHandlers: Record<string, Array<(data: unknown) => void>> = {};

  // self.send — post message on a named channel
  (self as any).send = function (channel: string, data: unknown) {
    (self as any).postMessage({ __zc: channel, d: data });
  };

  // self.receive — listen for messages on a named channel
  (self as any).receive = function (
    channel: string,
    handler: (data: unknown) => void
  ): () => void {
    if (!channelHandlers[channel]) channelHandlers[channel] = [];
    channelHandlers[channel].push(handler);
    return () => {
      channelHandlers[channel] = (channelHandlers[channel] || []).filter(
        (h) => h !== handler
      );
    };
  };

  // Channel routing handler — pushed into _messageHandlers so ObjC dispatch calls it
  const messageHandlers: Array<(event: { data: unknown }) => void> =
    (self as any)._messageHandlers || [];
  (self as any)._messageHandlers = messageHandlers;

  messageHandlers.push(function (ev: { data: unknown }) {
    const msg = ev.data as Record<string, unknown>;
    if (msg && msg.__zc && channelHandlers[msg.__zc as string]) {
      const hs = channelHandlers[msg.__zc as string];
      for (let i = 0; i < hs.length; i++) {
        try {
          hs[i](msg.d);
        } catch (e) {
          console.error(e);
        }
      }
    }
  });

  // dispatchSyncResult — called by native sync.m via jsc_worker_eval_js after
  // a wait completes (either notified or timed-out). Looks up the resolver
  // stashed by the syncWait host object and resolves the pending promise.
  bridge.dispatchSyncResult = function (payloadStr: string) {
    let data: any;
    try {
      data = JSON.parse(payloadStr);
    } catch {
      return;
    }
    const pending = bridge._syncPending;
    if (!pending || typeof data?.id !== "string") return;
    const resolver = pending[data.id];
    if (!resolver) return;
    delete pending[data.id];
    try {
      resolver(data.status);
    } catch (e) {
      console.error("[zapp] syncWait resolver threw:", e);
    }
  };
})();
