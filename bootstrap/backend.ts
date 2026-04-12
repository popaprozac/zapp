/**
 * Backend worker bootstrap — injected into the privileged backend JS context.
 *
 * Sets up event dispatch and the `Zapp` global for user-friendly API.
 * Host objects available on __zappBridge:
 *   - invokeService(method, args) → JSValue
 *   - syncWait(key, timeoutMs), syncNotify(key, count)
 *   - showNotification(title, body)
 *   - createWindow(opts)
 *   - quit()
 *
 * JSC only for now. txiki.js opt-in later for web APIs (fetch, WebSocket, timers).
 */

(function () {
  const bridge = (self as any).__zappBridge;
  if (!bridge) return;

  const listeners: Record<string, Array<(data: unknown) => void>> = {};

  // Event registration
  bridge.on = function (event: string, handler: (data: unknown) => void) {
    if (!listeners[event]) listeners[event] = [];
    listeners[event].push(handler);
    return () => {
      listeners[event] = (listeners[event] || []).filter((h) => h !== handler);
    };
  };

  // Called by native when app events fire (via jsc_backend_eval_js)
  bridge._dispatchAppEvent = function (eventId: number, dataJson: string) {
    const eventMap: Record<number, string> = {
      100: "app:started",
      101: "app:shutdown",
      102: "app:notification-click",
      103: "app:notification-action",
      104: "app:reopen",
      105: "app:open-url",
      106: "app:active",
      107: "app:inactive",
    };
    const name = eventMap[eventId];
    if (!name) return;
    let data: unknown = dataJson;
    try {
      data = JSON.parse(dataJson);
    } catch {}
    const handlers = listeners[name] || [];
    for (let i = 0; i < handlers.length; i++) {
      try {
        handlers[i](data);
      } catch (e) {
        console.error("[backend]", e);
      }
    }

    // Also dispatch notification events under __notif: names
    // so Notification.on("click"/"action") from @zappdev/runtime works
    if (eventId === 102) {
      const notifHandlers = listeners["__notif:click"] || [];
      for (const h of notifHandlers) try { h(data); } catch (e) { console.error("[backend]", e); }
    } else if (eventId === 103) {
      const notifHandlers = listeners["__notif:action"] || [];
      for (const h of notifHandlers) try { h(data); } catch (e) { console.error("[backend]", e); }
    }
  };

  // Window event name → event ID mapping (for backend subscription)
  const windowEventIds: Record<string, number> = {
    "window:ready": 0, "window:focus": 1, "window:blur": 2,
    "window:resize": 3, "window:move": 4, "window:close": 5,
    "window:minimize": 6, "window:maximize": 7, "window:restore": 8,
    "window:fullscreen": 9, "window:unfullscreen": 10,
  };

  // Expose as Symbol.for('zapp.bridge') so @zappdev/runtime works in the backend.
  // The runtime's getBridge() looks for this symbol on globalThis.
  const runtimeBridge = {
    on(name: string, handler: (data: unknown) => void) {
      const off = bridge.on(name, handler);

      // If subscribing to a window event, tell native to forward to backend
      const eventId = windowEventIds[name];
      if (eventId !== undefined && bridge.subscribeWindowEvent) {
        // Subscribe all windows (pass -1 for "all")
        bridge.subscribeWindowEvent(-1, eventId);
      }

      return off;
    },
    emit(name: string, payload?: Record<string, unknown>) {
      // Broadcast to every webview via the native dispatchEventToAll bridge.
      // Each webview's bridge._onEvent picks it up and fans out to listeners
      // registered with Events.on(name, ...).
      if (typeof bridge.dispatchEventToAll === "function") {
        bridge.dispatchEventToAll(name, payload ?? {});
      }
    },
    invoke(method: string, args?: Record<string, unknown>) {
      // Use host object for sync service invocation
      const result = bridge.invokeService(method, args);
      return Promise.resolve(result);
    },
    post(msg: string) {
      // No WebView to post to — no-op in backend
    },
    // Sync primitives — forward to the native host objects so Sync.wait /
    // Sync.notify work from the backend the same way they work in workers.
    syncWait(key: string, timeoutMs?: number | null) {
      if (typeof bridge.syncWait !== "function") {
        throw new Error("Sync bridge is unavailable.");
      }
      return bridge.syncWait(key, timeoutMs ?? -1);
    },
    syncNotify(key: string, count?: number) {
      if (typeof bridge.syncNotify !== "function") return;
      bridge.syncNotify(key, count ?? 1);
    },
    // Called by native Layer 3 when dispatching window events to backend
    _onEvent(name: string, payload: string) {
      const handlers = listeners[name] || [];
      let parsed: unknown = payload;
      try { parsed = JSON.parse(payload); } catch {}
      for (let i = 0; i < handlers.length; i++) {
        try { handlers[i](parsed); } catch (e) { console.error("[backend]", e); }
      }
    },
  };
  (globalThis as any)[Symbol.for("zapp.bridge")] = runtimeBridge;

  // Convenience global — the user-facing API (legacy, still works)
  (self as any).Zapp = {
    on: bridge.on,
    invokeService: bridge.invokeService,
    createWindow: bridge.createWindow,
    showNotification: bridge.showNotification,
    quit: bridge.quit,
  };
})();
