import { Events, WindowEvent, getWindowEventName, type WindowEventPayload, type WindowSizeEventPayload } from "./events";

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

/** Window events that carry size + position */
type SizeEvent =
  | WindowEvent.RESIZE
  | WindowEvent.MOVE
  | WindowEvent.MAXIMIZE
  | WindowEvent.RESTORE;

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
  /** Typed event listener — size events get a payload with size + position */
  on(event: SizeEvent, handler: (payload: WindowSizeEventPayload) => void): () => void;
  /** Typed event listener — other window events get base payload */
  on(event: WindowEvent, handler: (payload: WindowEventPayload) => void): () => void;
  /** Typed one-time listener — size events */
  once(event: SizeEvent, handler: (payload: WindowSizeEventPayload) => void): () => void;
  /** Typed one-time listener — other window events */
  once(event: WindowEvent, handler: (payload: WindowEventPayload) => void): () => void;
  /** Remove all listeners for an event */
  off(event: WindowEvent): void;
};

type WindowBridge = {
  windowCreate?: (options: WindowOptions) => Promise<{ id: string }>;
  windowAction?: (windowId: string, action: string, params?: Record<string, unknown>) => void;
};

const getBridge = (): WindowBridge | null =>
  ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as WindowBridge | undefined) ?? null;

function makeHandle(windowId: string): WindowHandle {
  const action = (name: string, params?: Record<string, unknown>) => {
    const bridge = getBridge();
    bridge?.windowAction?.(windowId, name, params);
  };

  const isWindowReady = (): boolean => {
    const ss = globalThis as unknown as Record<symbol, unknown>;
    return ss[Symbol.for("zapp.windowReady")] === true;
  };

  const handleOn = (event: WindowEvent, handler: (payload: WindowEventPayload) => void): (() => void) => {
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

  const handleOnce = (event: WindowEvent, handler: (payload: WindowEventPayload) => void): (() => void) => {
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
    on: handleOn as WindowHandle["on"],
    once: handleOnce as WindowHandle["once"],
    off: handleOff,
  };
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
    if (symbolStore[Symbol.for("zapp.context")] === "worker") {
      throw new Error("Window.current() is not available in a worker context. Use Window.create() instead.");
    }
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
