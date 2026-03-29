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
  };

  // Expose as Symbol.for('zapp.bridge') so @zappdev/runtime works in the backend.
  // The runtime's getBridge() looks for this symbol on globalThis.
  const runtimeBridge = {
    on: bridge.on,
    emit(name: string, payload?: Record<string, unknown>) {
      // Backend emit — could forward to native or no-op
    },
    invoke(method: string, args?: Record<string, unknown>) {
      // Use host object for sync service invocation
      const result = bridge.invokeService(method, args);
      return Promise.resolve(result);
    },
    post(msg: string) {
      // No WebView to post to — no-op in backend
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
