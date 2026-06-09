/**
 * WebView bootstrap — injected into WKWebView (macOS) and WebView2 (Windows).
 * Sets up the bridge between JavaScript and native code.
 *
 * Built by bootstrap/codegen.ts → minified → embedded as C string in .zapp/zapp_bootstrap.zc.
 */

(function () {
  const BRIDGE_KEY = Symbol.for("zapp.bridge");

  type PendingEntry = {
    resolve: (value: any) => void;
    reject: (reason: any) => void;
    timer?: ReturnType<typeof setTimeout>;
  };

  const pending: Record<number, PendingEntry> = {};
  let nextId = 1;
  const listeners: Record<string, Array<(payload: any) => void>> = {};

  function post(msg: string): void {
    if ((window as any).webkit?.messageHandlers?.zapp) {
      (window as any).webkit.messageHandlers.zapp.postMessage(msg);
    } else if ((window as any).chrome?.webview) {
      (window as any).chrome.webview.postMessage(msg);
    }
  }

  type WorkerEntry = {
    onmessage: ((event: { data: any }) => void) | null;
    _messageHandlers: Array<(event: { data: any }) => void>;
  };

  const bridge = {
    invoke(method: string, args?: Record<string, unknown>, opts?: { timeout?: number }) {
      const id = nextId++;
      if (nextId > 65535) nextId = 1;
      const timeout = opts?.timeout ?? 15000;
      let cancelled = false;

      const p: any = new Promise((resolve, reject) => {
        pending[id] = { resolve, reject };
        post(JSON.stringify({ t: 1, id, m: method, a: args || {} }));
        const timer = setTimeout(() => {
          if (pending[id]) {
            pending[id].reject(new Error("Timeout"));
            delete pending[id];
            post(JSON.stringify({ t: 7, id }));
          }
        }, timeout);
        pending[id].timer = timer;
      });

      p.cancel = () => {
        if (cancelled) return;
        cancelled = true;
        if (pending[id]) {
          clearTimeout(pending[id].timer);
          pending[id].reject(new Error("Cancelled"));
          delete pending[id];
          post(JSON.stringify({ t: 7, id }));
        }
      };

      return p;
    },

    emit(name: string, payload?: Record<string, unknown>): void {
      post(JSON.stringify({ t: 3, m: name, a: payload || {} }));
    },

    post(msg: string): void {
      post(msg);
    },

    on(name: string, handler: (payload: any) => void): () => void {
      if (!listeners[name]) listeners[name] = [];
      const wasEmpty = listeners[name].length === 0;
      listeners[name].push(handler);

      if (wasEmpty && (name.indexOf("window:") === 0 || name.indexOf("__notif:") === 0)) {
        post(JSON.stringify({ t: 4, m: "subscribe", a: { event: name } }));
      }

      return () => {
        listeners[name] = (listeners[name] || []).filter((h) => h !== handler);
        if (listeners[name].length === 0 && (name.indexOf("window:") === 0 || name.indexOf("__notif:") === 0)) {
          post(JSON.stringify({ t: 4, m: "unsubscribe", a: { event: name } }));
        }
      };
    },

    _onInvokeResult(id: number, ok: boolean, payload: string): void {
      const p = pending[id];
      if (!p) return;
      delete pending[id];
      if (ok) {
        try {
          p.resolve(JSON.parse(payload));
        } catch {
          p.resolve(payload);
        }
      } else {
        const err: any = new Error(payload);
        if (typeof payload === "string" && payload.startsWith("PERMISSION_DENIED:")) {
          err.code = "PERMISSION_DENIED";
          err.permission = payload.slice("PERMISSION_DENIED:".length);
        }
        p.reject(err);
      }
    },

    _onEvent(name: string, payload: string): void {
      const handlers = listeners[name] || [];
      let parsed: any = payload;
      try {
        parsed = JSON.parse(payload);
      } catch {}
      for (let i = 0; i < handlers.length; i++) {
        try {
          handlers[i](parsed);
        } catch (e) {
          console.error("[zapp] event handler error:", e);
        }
      }
    },

    dispatchWindowEvent(windowId: string, eventName: string, dataJson?: string): void {
      const evName = "window:" + eventName;
      const payload: Record<string, any> = { windowId, timestamp: Date.now() };
      if (dataJson) {
        try {
          const d = JSON.parse(dataJson);
          Object.assign(payload, {
            size: { width: d.width, height: d.height },
            position: { x: d.x, y: d.y },
          });
        } catch {}
      }
      bridge._onEvent(evName, JSON.stringify(payload));
    },

    dispatchPanelEvent(panelId: string, eventName: string, dataJson?: string): void {
      let data: any = undefined;
      if (dataJson) {
        try { data = JSON.parse(dataJson); } catch {}
      }
      // Routed to runtime/webview.ts via the "panel:<panelId>" event name.
      bridge._onEvent("panel:" + panelId, JSON.stringify({ event: eventName, data }));
    },

    // --- Worker lifecycle ---

    createWorker(scriptUrl: string, opts?: { engine?: string; name?: string }): string {
      const id = "w-" + nextId++;
      if (nextId > 65535) nextId = 1;
      bridge._workers[id] = { onmessage: null, _messageHandlers: [] };
      post(JSON.stringify({ t: 5, m: "create", a: { scriptUrl, workerId: id, engine: opts?.engine, name: opts?.name } }));
      return id;
    },

    // Workers.list() (webview context). Round-trips the framework
    // introspection route, which returns the registry as a JSON array;
    // `invoke` already JSON-parses the success payload, so this resolves
    // to an array of worker objects. The route ignores `a`.
    listWorkers() {
      return bridge.invoke("__zapp:workers-list", {});
    },

    postToWorker(workerId: string, data: any): void {
      post(JSON.stringify({ t: 5, m: "post", a: { workerId, data: JSON.stringify(data) } }));
    },

    terminateWorker(workerId: string): void {
      post(JSON.stringify({ t: 5, m: "terminate", a: { workerId } }));
    },

    // --- Shared Worker lifecycle ---

    createSharedWorker(scriptUrl: string): string {
      const id = "sw-" + nextId++;
      if (nextId > 65535) nextId = 1;
      bridge._workers[id] = { onmessage: null, _messageHandlers: [] };
      post(JSON.stringify({ t: 5, m: "create", a: { scriptUrl, workerId: id, shared: true } }));
      return id;
    },

    disconnectSharedWorker(workerId: string): void {
      post(JSON.stringify({ t: 5, m: "disconnect", a: { workerId } }));
    },

    // --- Sync wait/notify ---

    _syncPending: {} as Record<string, { resolve: (v: "notified" | "timed-out") => void; timer?: ReturnType<typeof setTimeout> }>,

    syncWait(key: string, timeoutMs?: number | null): Promise<"notified" | "timed-out"> {
      const id = "sync-" + nextId++ + "-" + Date.now();
      if (nextId > 65535) nextId = 1;

      return new Promise((resolve) => {
        bridge._syncPending[id] = { resolve };

        const a: Record<string, unknown> = { id, key };
        if (timeoutMs != null && timeoutMs > 0) a.timeoutMs = timeoutMs;
        post(JSON.stringify({ t: 6, m: "wait", a }));

        // Transport safety timeout (native timeout + buffer)
        if (timeoutMs != null && timeoutMs > 0) {
          bridge._syncPending[id].timer = setTimeout(() => {
            if (bridge._syncPending[id]) {
              delete bridge._syncPending[id];
              resolve("timed-out");
            }
          }, timeoutMs + 5000);
        }
      });
    },

    syncNotify(key: string, count?: number): void {
      post(JSON.stringify({ t: 6, m: "notify", a: { key, count: count ?? 1 } }));
    },

    dispatchSyncResult(payloadStr: string): void {
      let data: any;
      try { data = JSON.parse(payloadStr); } catch { return; }
      const entry = bridge._syncPending[data.id];
      if (!entry) return;
      if (entry.timer) clearTimeout(entry.timer);
      delete bridge._syncPending[data.id];
      entry.resolve(data.status);
    },

    _workers: {} as Record<string, WorkerEntry>,

    _onWorkerMessage(workerId: string, dataJson: string): void {
      const w = bridge._workers[workerId];
      if (!w) return;
      let parsed: any = dataJson;
      try {
        parsed = JSON.parse(dataJson);
      } catch {}
      const event = { data: parsed };
      if (w.onmessage) w.onmessage(event);
      const handlers = w._messageHandlers || [];
      for (let i = 0; i < handlers.length; i++) {
        try {
          handlers[i](event);
        } catch (e) {
          console.error("[zapp] worker message handler error:", e);
        }
      }
    },
  };

  (globalThis as any)[BRIDGE_KEY] = bridge;

  // Cleanup workers on page unload
  window.addEventListener("pagehide", () => {
    const ids = Object.keys(bridge._workers);
    for (let i = 0; i < ids.length; i++) {
      if (ids[i].startsWith("sw-")) {
        // Shared workers: disconnect (remove owner ref), don't terminate
        bridge.disconnectSharedWorker(ids[i]);
      } else {
        bridge.terminateWorker(ids[i]);
      }
    }
    bridge._workers = {};
  });

  // Drag region tracking. Walk up the DOM from the hovered element; the
  // first decisive rule wins. Order:
  //
  //   1. `--zapp-drag: no-drag` or `--zapp-drag: drag` — explicit override,
  //      wins over everything (lets users force an unusual choice).
  //   2. Native interactive tags (button, input, a, select, textarea) or
  //      `role=button` / `contenteditable` — auto-treated as no-drag so
  //      clicks / focus actually reach the control instead of being
  //      swallowed by `performWindowDragWithEvent:`. This matches Electron's
  //      `-webkit-app-region` convention.
  //   3. `data-zapp-drag-region` attribute — explicit drag handle.
  //
  // Without (2), putting a button inside `data-zapp-drag-region` absorbs
  // the click. Authors shouldn't have to paint `--zapp-drag: no-drag` on
  // every toolbar button; the sensible default is "interactive elements
  // win." Users who actually want a draggable button can still do so with
  // `style="--zapp-drag: drag"` on the element.
  let inDrag = false;
  document.addEventListener("mousemove", (e: MouseEvent) => {
    let el: HTMLElement | null = e.target as HTMLElement;
    let isDrag = false;
    while (el && el !== document.body && el !== (document as any)) {
      const style = window.getComputedStyle(el);
      const val = style.getPropertyValue("--zapp-drag").trim();
      if (val === "no-drag") {
        isDrag = false;
        break;
      }
      if (val === "drag") {
        isDrag = true;
        break;
      }
      const tag = el.tagName;
      if (
        tag === "BUTTON" ||
        tag === "INPUT" ||
        tag === "SELECT" ||
        tag === "TEXTAREA" ||
        (tag === "A" && el.hasAttribute("href")) ||
        el.getAttribute("role") === "button" ||
        el.isContentEditable
      ) {
        isDrag = false;
        break;
      }
      if (el.hasAttribute && el.hasAttribute("data-zapp-drag-region")) {
        isDrag = true;
        break;
      }
      el = el.parentElement;
    }
    if (isDrag !== inDrag) {
      inDrag = isDrag;
      post(JSON.stringify({ t: 4, m: "setDragRegion", a: { drag: inDrag } }));
    }
  });

  // Signal bridge is ready
  post(JSON.stringify({ t: 4, m: "ready" }));
})();
