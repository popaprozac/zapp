// packages/runtime/app.ts
function getBridge() {
  return globalThis[Symbol.for("zapp.bridge")] ?? null;
}
var defaultConfig = {
  name: "Zapp App",
  applicationShouldTerminateAfterLastWindowClosed: false,
  webContentInspectable: true
};
var App = {
  getConfig() {
    return getBridge()?.getConfig?.() ?? defaultConfig;
  },
  quit() {
    getBridge()?.appAction?.("quit");
  },
  hide() {
    getBridge()?.appAction?.("hide");
  },
  show() {
    getBridge()?.appAction?.("show");
  }
};
// packages/runtime/windows.ts
var getBridge2 = () => globalThis[Symbol.for("zapp.bridge")] ?? null;
var nextEventId = 0;
var windowEventListeners = [];
function makeHandle(windowId) {
  const action = (name, params) => {
    const bridge = getBridge2();
    bridge?.windowAction?.(windowId, name, params);
  };
  return {
    get id() {
      return windowId;
    },
    minimize() {
      action("minimize");
    },
    maximize() {
      action("maximize");
    },
    unminimize() {
      action("unminimize");
    },
    unmaximize() {
      action("unmaximize");
    },
    toggleMinimize() {
      action("toggle_minimize");
    },
    toggleMaximize() {
      action("toggle_maximize");
    },
    close() {
      action("close");
    },
    setTitle(title) {
      action("set_title", { title });
    },
    setSize(width, height) {
      action("set_size", { width, height });
    },
    setPosition(x, y) {
      action("set_position", { x, y });
    },
    setFullscreen(on) {
      action("set_fullscreen", { on });
    },
    setAlwaysOnTop(on) {
      action("set_always_on_top", { on });
    },
    on(event, handler) {
      const id = ++nextEventId;
      windowEventListeners.push({ id, event: `${windowId}:${event}`, handler });
      return () => {
        const idx = windowEventListeners.findIndex((e) => e.id === id);
        if (idx !== -1)
          windowEventListeners.splice(idx, 1);
      };
    }
  };
}
var Window = {
  async create(options = {}) {
    const bridge = getBridge2();
    if (!bridge?.windowCreate) {
      throw new Error("Window bridge unavailable. Is the Zapp runtime loaded?");
    }
    const result = await bridge.windowCreate(options);
    return makeHandle(result.id);
  },
  current() {
    const ownerId = globalThis[Symbol.for("zapp.ownerId")];
    const contextOwnerId = globalThis[Symbol.for("zapp.currentWindowId")];
    const windowId = contextOwnerId ?? ownerId;
    if (!windowId) {
      throw new Error("Window.current() is only available in a webview context with an associated window.");
    }
    return makeHandle(windowId);
  }
};
// packages/runtime/worker.ts
function getBridge3() {
  const b = globalThis[Symbol.for("zapp.bridge")];
  if (!b?.createWorker) {
    throw new Error("Zapp worker bridge unavailable. " + "Make sure the webview bootstrap has loaded before importing @zapp/runtime.");
  }
  return b;
}
function rewriteToBundledWorker(url) {
  const ext = url.pathname.split(".").pop()?.toLowerCase();
  if (ext !== "ts" && ext !== "tsx")
    return url.toString();
  const toBundledUrl = (mappedPath) => {
    const normalized = mappedPath.startsWith("/") ? mappedPath : `/${mappedPath}`;
    if (url.protocol === "zapp:") {
      return `zapp://app${normalized}`;
    }
    return new URL(normalized, url).toString();
  };
  const manifest = globalThis[Symbol.for("zapp.workerManifest")];
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
function resolveWorkerScriptURL(scriptURL, importMetaUrl) {
  const bridge = getBridge3();
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

class Worker {
  id;
  scriptURL;
  onmessage = null;
  onerror = null;
  onclose = null;
  #listeners = {
    message: [],
    error: [],
    close: []
  };
  #pendingErrors = [];
  #unsubscribe = null;
  constructor(scriptURL, options) {
    const bridge = getBridge3();
    const resolved = resolveWorkerScriptURL(scriptURL, options?.importMetaUrl);
    this.scriptURL = resolved;
    this.id = bridge.createWorker(resolved, {
      shared: options?.shared === true
    });
    this.#unsubscribe = bridge.subscribeWorker(this.id, (payload) => {
      if (payload && typeof payload === "object" && "__zapp_channel" in payload) {
        const event2 = new MessageEvent("message", { data: payload });
        this.#emit("message", event2);
        return;
      }
      const event = new MessageEvent("message", { data: payload });
      this.onmessage?.(event);
      this.#emit("message", event);
    }, (payload) => {
      const errorPayload = payload;
      const event = new ErrorEvent("error", {
        message: errorPayload?.message ?? "Worker error",
        filename: errorPayload?.filename ?? "",
        lineno: errorPayload?.lineno ?? 0,
        colno: errorPayload?.colno ?? 0
      });
      this.#dispatchError(event);
    }, () => {
      const event = new Event("close");
      this.onclose?.(event);
      this.#emit("close", event);
    });
  }
  postMessage(data) {
    getBridge3().postToWorker(this.id, data);
  }
  send(channel, data) {
    this.postMessage({ __zapp_channel: channel, data });
  }
  receive(channel, handler) {
    const cb = (e) => {
      const payload = e.data;
      if (payload && typeof payload === "object" && payload.__zapp_channel === channel) {
        handler(payload.data);
      }
    };
    this.addEventListener("message", cb);
    return () => this.removeEventListener("message", cb);
  }
  terminate() {
    this.#unsubscribe?.();
    this.#unsubscribe = null;
    getBridge3().terminateWorker(this.id);
  }
  addEventListener(type, listener, options) {
    if (!listener)
      return;
    if (type !== "message" && type !== "error" && type !== "close")
      return;
    const list = this.#listeners[type];
    for (const entry of list) {
      if (entry.listener === listener)
        return;
    }
    const once = typeof options === "object" && options?.once === true;
    const signal = typeof options === "object" ? options.signal : undefined;
    if (signal?.aborted)
      return;
    list.push({ listener, once });
    if (type === "error")
      this.#flushPendingErrors();
    if (signal) {
      const onAbort = () => this.removeEventListener(type, listener);
      signal.addEventListener("abort", onAbort, { once: true });
    }
  }
  removeEventListener(type, listener) {
    if (!listener)
      return;
    if (type !== "message" && type !== "error" && type !== "close")
      return;
    const list = this.#listeners[type];
    for (let i = list.length - 1;i >= 0; i -= 1) {
      if (list[i]?.listener === listener)
        list.splice(i, 1);
    }
  }
  dispatchEvent(event) {
    if (!event || event.type !== "message" && event.type !== "error" && event.type !== "close")
      return true;
    this.#emit(event.type, event);
    return !event.defaultPrevented;
  }
  #emit(type, event) {
    const list = this.#listeners[type].slice();
    for (const entry of list) {
      if (typeof entry.listener === "function") {
        entry.listener(event);
      } else {
        entry.listener.handleEvent(event);
      }
      if (entry.once)
        this.removeEventListener(type, entry.listener);
    }
  }
  #dispatchError(event) {
    if (this.#listeners.error.length === 0 && this.onerror == null) {
      this.#pendingErrors.push(event);
      return;
    }
    this.onerror?.(event);
    this.#emit("error", event);
  }
  #flushPendingErrors() {
    if (this.#pendingErrors.length === 0)
      return;
    if (this.#listeners.error.length === 0 && this.onerror == null)
      return;
    const pending = this.#pendingErrors.splice(0);
    for (const event of pending) {
      this.onerror?.(event);
      this.#emit("error", event);
    }
  }
}

class SharedWorker {
  port;
  onerror = null;
  #inner;
  constructor(scriptURL, options) {
    this.#inner = new Worker(scriptURL, {
      ...options,
      shared: true
    });
    this.port = {
      postMessage: (data) => this.#inner.postMessage(data),
      onmessage: null,
      start: () => {},
      close: () => this.#inner.terminate(),
      addEventListener: (type, listener) => this.#inner.addEventListener(type, listener),
      removeEventListener: (type, listener) => this.#inner.removeEventListener(type, listener)
    };
    this.#inner.addEventListener("message", (e) => {
      this.port.onmessage?.(e);
    });
    this.#inner.addEventListener("error", (e) => {
      this.onerror?.(e);
    });
  }
  send(channel, data) {
    this.#inner.send(channel, data);
  }
  receive(channel, handler) {
    return this.#inner.receive(channel, handler);
  }
}
// packages/backend/app.ts
function getBridge4() {
  return globalThis[Symbol.for("zapp.bridge")] ?? null;
}
function isBackendContext() {
  return globalThis[Symbol.for("zapp.context")] === "backend";
}
var readyCallbacks = [];
var readyFired = false;
var configured = false;
var App2 = {
  getConfig() {
    return App.getConfig();
  },
  quit() {
    getBridge4()?.appAction?.("quit");
  },
  hide() {
    getBridge4()?.appAction?.("hide");
  },
  show() {
    getBridge4()?.appAction?.("show");
  },
  configure(config) {
    if (!isBackendContext()) {
      throw new Error("App.configure() is only available in the backend context.");
    }
    if (configured) {
      throw new Error("App.configure() can only be called once, before the app runs.");
    }
    configured = true;
    const b = getBridge4();
    b?.mergeConfig?.(config);
    b?.appConfigure?.(config);
  },
  onReady(callback) {
    if (readyFired) {
      try {
        callback();
      } catch {}
      return;
    }
    readyCallbacks.push(callback);
  },
  _fireReady() {
    if (readyFired)
      return;
    readyFired = true;
    for (const cb of readyCallbacks) {
      try {
        cb();
      } catch {}
    }
    readyCallbacks.length = 0;
  }
};
// example/backend.ts
console.log("[backend] starting");
App2.configure({
  name: "Example App",
  applicationShouldTerminateAfterLastWindowClosed: true
});
console.log("[backend] config:", App2.getConfig());
var win = await Window.create({
  title: "Window from Backend",
  width: 900,
  height: 600,
  x: 100,
  y: 100,
  visible: true
});
console.log("[backend] created window:", win.id);
