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
    signal?: AbortSignal;
    abort?: () => void;
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

  function takePending(id: number): PendingEntry | undefined {
    const entry = pending[id];
    if (!entry) return undefined;
    delete pending[id];
    if (entry.timer !== undefined) clearTimeout(entry.timer);
    if (entry.signal && entry.abort) {
      entry.signal.removeEventListener("abort", entry.abort);
    }
    return entry;
  }

  function abortError(reason?: unknown): Error {
    if (reason instanceof Error) return reason;
    const error = new Error(reason === undefined ? "Cancelled" : String(reason));
    error.name = "AbortError";
    return error;
  }

  function cancelPending(id: number, reason?: unknown): void {
    const entry = takePending(id);
    if (!entry) return;
    entry.reject(abortError(reason));
    post(JSON.stringify({ t: 7, id }));
  }

  function invocationError(payload: string): Error {
    const factory = (globalThis as any)[Symbol.for("zapp.errorFactory")];
    if (typeof factory === "function") return factory(payload);
    let parsed: Record<string, unknown> | undefined;
    try {
      const value = JSON.parse(payload);
      if (value !== null && typeof value === "object" && !Array.isArray(value)) {
        parsed = value as Record<string, unknown>;
      }
    } catch {}
    if (
      parsed
      && typeof parsed.code === "string"
      && typeof parsed.message === "string"
    ) {
      const error: any = new Error(parsed.message);
      error.name = parsed.code === "PERMISSION_DENIED"
        ? "PermissionDeniedError"
        : "ZappInvocationError";
      error.code = parsed.code;
      if (typeof parsed.permission === "string" && parsed.permission.length > 0) {
        error.permission = parsed.permission;
      }
      if (typeof parsed.service === "string" && parsed.service.length > 0) {
        error.service = parsed.service;
      }
      if (typeof parsed.method === "string" && parsed.method.length > 0) {
        error.method = parsed.method;
      }
      if (typeof parsed.errorType === "string" && parsed.errorType.length > 0) {
        error.errorType = parsed.errorType;
      }
      if (typeof parsed.details === "string" && parsed.details.length > 0) {
        try { error.details = JSON.parse(parsed.details); }
        catch { error.details = parsed.details; }
      }
      return error;
    }
    const error: any = new Error(payload);
    if (payload.startsWith("PERMISSION_DENIED:")) {
      error.name = "PermissionDeniedError";
      error.code = "PERMISSION_DENIED";
      error.permission = payload.slice("PERMISSION_DENIED:".length);
    }
    return error;
  }

  type WorkerEntry = {
    onmessage: ((event: { data: any }) => void) | null;
    _messageHandlers: Array<(event: { data: any }) => void>;
  };

  const bridge = {
    invoke(
      method: string,
      args?: Record<string, unknown>,
      opts?: { timeout?: number; signal?: AbortSignal },
    ) {
      const id = nextId++;
      if (nextId > 65535) nextId = 1;
      const timeout = opts?.timeout ?? 15000;
      let cancelled = false;
      const signal = opts?.signal;

      const p: any = new Promise((resolve, reject) => {
        if (signal?.aborted) {
          cancelled = true;
          reject(abortError(signal.reason));
          return;
        }
        const entry: PendingEntry = { resolve, reject, signal };
        if (signal) {
          entry.abort = () => {
            cancelled = true;
            cancelPending(id, signal.reason);
          };
          signal.addEventListener("abort", entry.abort, { once: true });
        }
        pending[id] = entry;
        post(JSON.stringify({ t: 1, id, m: method, a: args || {} }));
        const timer = setTimeout(() => {
          const timedOut = takePending(id);
          if (!timedOut) return;
          timedOut.reject(new Error("Timeout"));
          post(JSON.stringify({ t: 7, id }));
        }, timeout);
        entry.timer = timer;
      });

      p.cancel = () => {
        if (cancelled) return;
        cancelled = true;
        cancelPending(id);
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
      const p = takePending(id);
      if (!p) return;
      if (ok) {
        try {
          p.resolve(JSON.parse(payload));
        } catch {
          p.resolve(payload);
        }
      } else {
        p.reject(invocationError(payload));
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
          if (eventName === "navigation-requested") {
            Object.assign(payload, {
              url: d.url,
              mainFrame: d.mainFrame,
              allowedByProfile: d.allowedByProfile,
              cancelled: d.cancelled,
            });
            bridge._onEvent(evName, JSON.stringify(payload));
            return;
          }
          // sidebar-resized / inspector-resized carry a bare width (no height)
          // and use the top-level `width` payload contract (Sidebar/Inspector
          // ResizedPayload); everything else is the generic window-resize/move
          // size+position shape.
          const bareWidth = eventName === "sidebar-resized" || eventName === "inspector-resized";
          if (!bareWidth) {
            Object.assign(payload, {
              size: { width: d.width, height: d.height },
              position: { x: d.x, y: d.y },
            });
          } else if (typeof d.width === "number") {
            payload.width = d.width;
          }
        } catch {}
      }
      bridge._onEvent(evName, JSON.stringify(payload));
    },

    dispatchMenuCommand(ownerToken: string, commandId: string): void {
      bridge._onEvent("__zapp:menu-command", JSON.stringify({
        ownerToken,
        commandId,
      }));
    },

    dispatchPanelEvent(panelId: string, eventName: string, dataJson?: string): void {
      let data: any = undefined;
      if (dataJson) {
        try { data = JSON.parse(dataJson); } catch {}
      }
      // Routed to runtime/webview.ts via the "panel:<panelId>" event name.
      bridge._onEvent("panel:" + panelId, JSON.stringify({ event: eventName, data }));
    },

    dispatchApplicationWorkerMessage(
      workerId: string,
      channel: string,
      payload: string,
    ): void {
      const name = "__zapp:application-worker:" + encodeURIComponent(workerId)
        + ":" + encodeURIComponent(channel);
      bridge._onEvent(name, payload);
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

  // Cleanup workers on page unload — terminate every worker this webview owns.
  window.addEventListener("pagehide", () => {
    const ids = Object.keys(bridge._workers);
    for (let i = 0; i < ids.length; i++) {
      bridge.terminateWorker(ids[i]);
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
  // iOS windows aren't user-draggable (no performWindowDragWithEvent), so
  // drag-region tracking is dead weight there. Skip it on iOS. Platform comes
  // from the bootstrap-config carrier the native webview injects — it is
  // added to WKUserContentController BEFORE the bootstrap script, so the
  // symbol is guaranteed present when this IIFE runs.
  const _cfg = (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
  const _isIOS = _cfg?.permissions?.platform === "ios";
  if (!_isIOS) {
    // Two intents, tracked separately:
    //   inDrag     — pointer is over a draggable region (move the window). Set by
    //                app-region:drag / --zapp-drag:drag / data-zapp-drag-region,
    //                AND by data-zapp-titlebar (a title bar is draggable too).
    //   inTitlebar — pointer is over the window TITLE BAR (data-zapp-titlebar):
    //                draggable AND double-click-to-maximize. A generic drag region
    //                is NOT a title bar, so it never dblclick-maximizes.
    let inDrag = false;
    let inTitlebar = false;
    document.addEventListener("mousemove", (e: MouseEvent) => {
      let el: HTMLElement | null = e.target as HTMLElement;
      let isDrag = false;
      let isTitlebar = false;
      while (el && el !== document.body && el !== (document as any)) {
        const style = window.getComputedStyle(el);
        const val = style.getPropertyValue("--zapp-drag").trim();
        if (val === "no-drag") {
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
          break;
        }
        if (el.hasAttribute && el.hasAttribute("data-zapp-titlebar")) {
          isDrag = true;
          isTitlebar = true;
          break;
        }
        if (el.hasAttribute && el.hasAttribute("data-zapp-drag-region")) {
          isDrag = true;
          break;
        }
        el = el.parentElement;
      }
      if (isDrag !== inDrag || isTitlebar !== inTitlebar) {
        inDrag = isDrag;
        inTitlebar = isTitlebar;
        post(JSON.stringify({ t: 4, m: "setDragRegion", a: { drag: inDrag, titlebar: inTitlebar } }));
      }
    });

    // Windows chrome model (WebView2). Detected by the chrome.webview transport
    // (the bootstrapConfig has no permissions.platform on Windows — Apple-only),
    // the same signal `post()` keys off.
    //   - data-zapp-titlebar → NATIVE: the framework maps it to CSS
    //     `-webkit-app-region: drag`, which WebView2's IsNonClientRegionSupport
    //     turns into a real caption region — drag + double-click-maximize + the
    //     right-click system menu, all handled by the OS. App markup stays
    //     platform-agnostic (no -webkit-app-region in app CSS).
    //   - data-zapp-drag-region / --zapp-drag:drag → MOVE-ONLY: native app-region
    //     can't express "drag without dblclick", so plain drag regions keep the JS
    //     gesture (post beginDrag past a 4px move; no dblclick). Titlebars are
    //     skipped here — the OS owns those.
    const _isWin = !(window as any).webkit?.messageHandlers?.zapp
      && !!(window as any).chrome?.webview?.postMessage;
    if (_isWin) {
      // Bridge data-zapp-titlebar → native app-region (interactive descendants
      // opt out). Applied on DOMContentLoaded — document-start runs before the
      // real <html> exists (same reason as the metrics injection).
      const applyTitlebarCss = () => {
        const s = document.createElement("style");
        s.textContent =
          "[data-zapp-titlebar]{-webkit-app-region:drag}" +
          "[data-zapp-titlebar] button,[data-zapp-titlebar] input,[data-zapp-titlebar] select," +
          "[data-zapp-titlebar] textarea,[data-zapp-titlebar] a[href]," +
          "[data-zapp-titlebar] [role=button],[data-zapp-titlebar] [contenteditable=true]" +
          "{-webkit-app-region:no-drag}" +
          // Web-rendered caption buttons (min/max/close). A GDI child HWND can't
          // composite over the DirectComposition webview on vibrant/transparent
          // windows, so we draw them here. Native reserves their width via
          // --zapp-window-controls-inset-right and pushes per-button state +
          // maximized glyph via the data-zapp-window-controls / -maximized attrs.
          "[data-zapp-winctl]{position:fixed;top:0;right:0;display:flex;" +
          "height:var(--zapp-titlebar-height,32px);z-index:2147483647;-webkit-app-region:no-drag}" +
          "[data-zapp-winctl] button{width:46px;height:100%;border:0;margin:0;padding:0;" +
          "background:transparent;font-family:'Segoe MDL2 Assets','Segoe Fluent Icons';" +
          "font-size:10px;line-height:1;color:#000;display:flex;align-items:center;" +
          "justify-content:center;cursor:default;-webkit-app-region:no-drag}" +
          "[data-zapp-winctl] button:hover{background:rgba(0,0,0,0.06)}" +
          "[data-zapp-winctl] button.zapp-close:hover{background:#e81123;color:#fff}" +
          "[data-zapp-winctl] button[disabled]{opacity:0.35}" +
          // Native parity: caption-button glyphs dim when the window loses focus
          // (data-zapp-window-focused pushed from WM_ACTIVATE).
          "html[data-zapp-window-focused=\"0\"] [data-zapp-winctl] button:not(:hover){opacity:0.45}" +
          "@media (prefers-color-scheme:dark){[data-zapp-winctl] button{color:#fff}" +
          "[data-zapp-winctl] button:hover{background:rgba(255,255,255,0.09)}}";
        (document.head || document.documentElement).appendChild(s);

        // Caption buttons render only where native set a non-zero inset (the
        // content/host webview, at the window's right edge). Segoe MDL2 glyphs:
        // minimize E921, maximize E922, restore E923, close E8BB.
        const GLYPH: Record<string, string> = {
          minimize: "", maximize: "", restore: "", close: "",
        };
        const wv = (window as any).chrome && (window as any).chrome.webview;
        const renderWindowControls = () => {
          const root = document.documentElement;
          const inset = parseInt(
            getComputedStyle(root).getPropertyValue("--zapp-window-controls-inset-right"), 10) || 0;
          const desc = root.getAttribute("data-zapp-window-controls") || "";
          let cluster = document.querySelector("[data-zapp-winctl]") as HTMLElement | null;
          if (inset <= 0) { if (cluster) cluster.remove(); return; }
          if (desc.length < 3) {
            // NATIVE (DWM) caption buttons (empty desc): render NOTHING over the
            // button corner. DWM draws the buttons; the title-bar drag region must
            // stay app-region:drag there so WebView2 forwards the NC hit-tests to
            // the host's WM_NCHITTEST (→ HTMIN/MAX/CLOSE → DWM hover + Snap). The
            // inset var still reserves the width so app content pads around them.
            if (cluster) cluster.remove();
            return;
          }
          if (!cluster) {
            cluster = document.createElement("div");
            cluster.setAttribute("data-zapp-winctl", "");
            (document.body || document.documentElement).appendChild(cluster);
          }
          const maxed = root.getAttribute("data-zapp-window-maximized") === "1";
          // desc = [min,max,close]; 'e' enabled, 'd' disabled, 'h' hidden.
          const defs = [
            { key: "minimize", st: desc[0], glyph: GLYPH.minimize, cls: "" },
            { key: "maximize", st: desc[1], glyph: maxed ? GLYPH.restore : GLYPH.maximize, cls: "" },
            { key: "close", st: desc[2], glyph: GLYPH.close, cls: "zapp-close" },
          ];
          cluster.innerHTML = defs.filter((b) => b.st !== "h").map((b) =>
            `<button data-ctl="${b.key}" class="${b.cls}"${b.st === "d" ? " disabled" : ""}>${b.glyph}</button>`,
          ).join("");
          cluster.querySelectorAll("button").forEach((btn) => {
            btn.addEventListener("click", () => {
              if ((btn as HTMLButtonElement).disabled) return;
              if (wv) wv.postMessage("window-control:" + btn.getAttribute("data-ctl"));
            });
          });
        };
        renderWindowControls();
        // Native updates the attrs on maximize/restore + windowControls changes.
        new MutationObserver(renderWindowControls).observe(document.documentElement, {
          attributes: true,
          attributeFilter: ["data-zapp-window-controls", "data-zapp-window-maximized"],
        });
      };
      if (document.readyState !== "loading") applyTitlebarCss();
      else document.addEventListener("DOMContentLoaded", applyTitlebarCss);

      // Move-only drag for plain drag regions (NOT titlebars — native owns those).
      let dragStart: { x: number; y: number } | null = null;
      document.addEventListener("mousedown", (e: MouseEvent) => {
        if (e.button === 0 && inDrag && !inTitlebar) dragStart = { x: e.screenX, y: e.screenY };
      });
      document.addEventListener("mousemove", (e: MouseEvent) => {
        if (!dragStart) return;
        if (Math.abs(e.screenX - dragStart.x) > 4 || Math.abs(e.screenY - dragStart.y) > 4) {
          dragStart = null;
          post(JSON.stringify({ t: 4, m: "beginDrag", a: {} }));
        }
      });
      const _clearDrag = () => { dragStart = null; };
      document.addEventListener("mouseup", _clearDrag);
      document.addEventListener("mouseleave", _clearDrag);

      // File drag-drop (parity with macOS): handle EXTERNAL FILE drags via HTML5
      // and route to native, which resolves absolute paths (ICoreWebView2File.
      // GetPath) and emits the file-drop-* window events. preventDefault on a file
      // drag stops WebView2 navigating to the file; NON-file drags fall through so
      // in-page HTML5 DnD keeps working (matching darwin's call-super path).
      const _wv = (window as any).chrome.webview;
      const _isFileDrag = (e: DragEvent) =>
        !!e.dataTransfer && Array.from(e.dataTransfer.types).includes("Files");
      let _lastOver = 0;
      document.addEventListener("dragenter", (e: DragEvent) => {
        if (!_isFileDrag(e)) return;
        e.preventDefault();
        const items = e.dataTransfer!.items;
        let n = 0;
        if (items) for (let i = 0; i < items.length; i++) if (items[i].kind === "file") n++;
        _wv.postMessage(`file-drop-enter:${n}:${e.clientX}:${e.clientY}`);
      });
      document.addEventListener("dragover", (e: DragEvent) => {
        if (!_isFileDrag(e)) return;
        e.preventDefault();                       // THIS stops the file:// navigation
        e.dataTransfer!.dropEffect = "copy";
        const now = Date.now();
        if (now - _lastOver >= 16) { _lastOver = now; _wv.postMessage(`file-drop-over:${e.clientX}:${e.clientY}`); }
      });
      document.addEventListener("dragleave", (e: DragEvent) => {
        if (!_isFileDrag(e) || e.relatedTarget !== null) return;   // relatedTarget null = left the window
        _wv.postMessage(`file-drop-leave:${e.clientX}:${e.clientY}`);
      });
      document.addEventListener("drop", (e: DragEvent) => {
        if (!_isFileDrag(e)) return;
        e.preventDefault();
        const files = e.dataTransfer!.files;
        if (files && files.length)
          _wv.postMessageWithAdditionalObjects(`file-drop:${e.clientX}:${e.clientY}`, Array.from(files) as any);
      });
    }
  }

  // Double-click a drag region → window zoom (toggle maximize) is handled
  // NATIVELY in the macOS WKWebView subclass (mouseDown, clickCount == 2): a
  // drag region consumes mouseDown for window-dragging and never forwards the
  // clicks to the web layer, so a DOM dblclick listener here would never fire on
  // a drag region. `Window.zoom()` remains available for programmatic toggling.
  // (Re-add a JS path only for a platform whose drag regions surface DOM clicks.)

  // Signal bridge is ready
  post(JSON.stringify({ t: 4, m: "ready" }));
})();
