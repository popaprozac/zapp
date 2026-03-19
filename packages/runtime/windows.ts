import { Events, WindowEvent, getWindowEventName, type WindowEventPayload } from "./events";

export interface WindowOptions {
  title?: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  url?: string;
  resizable?: boolean;
  closable?: boolean;
  minimizable?: boolean;
  maximizable?: boolean;
  fullscreen?: boolean;
  alwaysOnTop?: boolean;
  titleBarStyle?: "default" | "hidden" | "hiddenInset";
  visible?: boolean;
}

type WindowEventHandler = (payload?: WindowEventPayload) => void;

export type WindowHandle = {
  readonly id: string;
  show(): void;
  hide(): void;
  minimize(): void;
  maximize(): void;
  unminimize(): void;
  unmaximize(): void;
  toggleMinimize(): void;
  toggleMaximize(): void;
  close(): void;
  setTitle(title: string): void;
  setSize(width: number, height: number): void;
  setPosition(x: number, y: number): void;
  setFullscreen(on: boolean): void;
  setAlwaysOnTop(on: boolean): void;
  /** Legacy string-based event listener */
  on(event: string, handler: () => void): () => void;
  /** Typed event listener using WindowEvent enum */
  on(event: WindowEvent, handler: WindowEventHandler): () => void;
  /** One-time typed event listener */
  once(event: WindowEvent, handler: WindowEventHandler): () => void;
  /** Remove all listeners for a typed event */
  off(event: WindowEvent): void;
};

type WindowBridge = {
  windowCreate?: (options: WindowOptions) => Promise<{ id: string }>;
  windowAction?: (windowId: string, action: string, params?: Record<string, unknown>) => void;
};

type LegacyWindowEventEntry = { id: number; event: string; handler: () => void };

const getBridge = (): WindowBridge | null =>
  ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as WindowBridge | undefined) ?? null;

let nextLegacyEventId = 0;
const legacyWindowEventListeners: LegacyWindowEventEntry[] = [];

function makeHandle(windowId: string): WindowHandle {
  const action = (name: string, params?: Record<string, unknown>) => {
    const bridge = getBridge();
    bridge?.windowAction?.(windowId, name, params);
  };

  const isWindowReady = (): boolean => {
    const ss = globalThis as unknown as Record<symbol, unknown>;
    return ss[Symbol.for("zapp.windowReady")] === true;
  };

  const handleOn: WindowHandle["on"] = (event: WindowEvent | string, handler: WindowEventHandler) => {
    if (typeof event === "string") {
      const id = ++nextLegacyEventId;
      legacyWindowEventListeners.push({ id, event: `${windowId}:${event}`, handler: handler as () => void });
      return () => {
        const idx = legacyWindowEventListeners.findIndex((e) => e.id === id);
        if (idx !== -1) legacyWindowEventListeners.splice(idx, 1);
      };
    }
    const eventName = getWindowEventName(event);
    const off = Events.on(`window:${eventName}`, (payload) => {
      const p = payload as WindowEventPayload | undefined;
      if (p?.windowId === windowId) {
        handler(p);
      }
    });
    if (event === WindowEvent.READY && isWindowReady()) {
      queueMicrotask(() => handler({ windowId, timestamp: Date.now() }));
    }
    return off;
  };

  const handleOnce: WindowHandle["once"] = (event: WindowEvent, handler: WindowEventHandler) => {
    if (event === WindowEvent.READY && isWindowReady()) {
      queueMicrotask(() => handler({ windowId, timestamp: Date.now() }));
      return () => {};
    }
    const eventName = getWindowEventName(event);
    return Events.once(`window:${eventName}`, (payload) => {
      const p = payload as WindowEventPayload | undefined;
      if (p?.windowId === windowId) {
        handler(p);
      }
    });
  };

  const handleOff: WindowHandle["off"] = (event: WindowEvent) => {
    const eventName = getWindowEventName(event);
    Events.off(`window:${eventName}`);
  };

  return {
    get id() { return windowId; },
    show() { action("show"); },
    hide() { action("hide"); },
    minimize() { action("minimize"); },
    maximize() { action("maximize"); },
    unminimize() { action("unminimize"); },
    unmaximize() { action("unmaximize"); },
    toggleMinimize() { action("toggle_minimize"); },
    toggleMaximize() { action("toggle_maximize"); },
    close() { action("close"); },
    setTitle(title: string) { action("set_title", { title }); },
    setSize(width: number, height: number) { action("set_size", { width, height }); },
    setPosition(x: number, y: number) { action("set_position", { x, y }); },
    setFullscreen(on: boolean) { action("set_fullscreen", { on }); },
    setAlwaysOnTop(on: boolean) { action("set_always_on_top", { on }); },
    on: handleOn,
    once: handleOnce,
    off: handleOff,
  };
}

export function _dispatchWindowEvent(windowId: string, event: string): void {
  const key = `${windowId}:${event}`;
  for (const entry of legacyWindowEventListeners) {
    if (entry.event === key) {
      try { entry.handler(); } catch { /* isolate listener failures */ }
    }
  }
}

export interface WindowAPI {
  create(options?: WindowOptions): Promise<WindowHandle>;
  current(): WindowHandle;
}

export const Window: WindowAPI = {
  async create(options: WindowOptions = {}): Promise<WindowHandle> {
    const bridge = getBridge();
    if (!bridge?.windowCreate) {
      throw new Error("Window bridge unavailable. Is the Zapp runtime loaded?");
    }
    const result = await bridge.windowCreate(options);
    return makeHandle(result.id);
  },

  current(): WindowHandle {
    const symbolStore = globalThis as unknown as Record<symbol, unknown>;
    const windowId = symbolStore[Symbol.for("zapp.windowId")] as string | undefined;
    const ownerId = symbolStore[Symbol.for("zapp.ownerId")] as string | undefined;
    const contextWindowId = symbolStore[Symbol.for("zapp.currentWindowId")] as string | undefined;
    const id = windowId ?? contextWindowId ?? ownerId;
    if (!id) {
      throw new Error(
        "Window.current() is only available in a webview context with an associated window.",
      );
    }
    return makeHandle(id);
  },
};
