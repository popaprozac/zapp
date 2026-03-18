import { Events } from "./events";

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

export type WindowHandle = {
  readonly id: string;
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
  on(event: string, handler: () => void): () => void;
  /** Convenience method for "ready" event */
  onReady(handler: () => void): () => void;
}

type WindowBridge = {
  windowCreate?: (options: WindowOptions) => Promise<{ id: string }>;
  windowAction?: (windowId: string, action: string, params?: Record<string, unknown>) => void;
};

type WindowEventHandler = () => void;
type WindowEventEntry = { id: number; event: string; handler: WindowEventHandler };

const getBridge = (): WindowBridge | null =>
  ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as WindowBridge | undefined) ?? null;

let nextEventId = 0;
const windowEventListeners: WindowEventEntry[] = [];

function makeHandle(windowId: string): WindowHandle {
  const action = (name: string, params?: Record<string, unknown>) => {
    const bridge = getBridge();
    bridge?.windowAction?.(windowId, name, params);
  };

  return {
    get id() { return windowId; },
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
    on(event: string, handler: WindowEventHandler): () => void {
      const id = ++nextEventId;
      windowEventListeners.push({ id, event: `${windowId}:${event}`, handler });
      return () => {
        const idx = windowEventListeners.findIndex((e) => e.id === id);
        if (idx !== -1) windowEventListeners.splice(idx, 1);
      };
    },
    onReady(handler: WindowEventHandler): () => void {
      // Listen for "window-ready" event globally and filter by windowId
      return Events.on("window-ready", (payload) => {
        const p = payload as { windowId?: string };
        if (p?.windowId === windowId) {
          handler();
        }
      });
    },
  };
}

export function _dispatchWindowEvent(windowId: string, event: string): void {
  const key = `${windowId}:${event}`;
  for (const entry of windowEventListeners) {
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
