import { Events, WindowEvent, getWindowEventName, type WindowEventPayload, type WindowSizeEventPayload } from "./events";

/** Options for creating a new window. */
export interface WindowOptions {
  /** Window title text. */
  title?: string;
  /** Initial width in logical pixels. */
  width?: number;
  /** Initial height in logical pixels. */
  height?: number;
  /** Initial x position on screen. */
  x?: number;
  /** Initial y position on screen. */
  y?: number;
  /** URL to load in the window. */
  url?: string;
  /** Whether the window can be resized by the user. */
  resizable?: boolean;
  /** Whether the window shows a close button. */
  closable?: boolean;
  /** Whether the window can be minimized. */
  minimizable?: boolean;
  /** Whether the window can be maximized. */
  maximizable?: boolean;
  /** Whether the window starts in fullscreen. */
  fullscreen?: boolean;
  /** Whether the window floats above other windows. */
  alwaysOnTop?: boolean;
  /** Title bar appearance style. */
  titleBarStyle?: "default" | "hidden" | "hiddenInset";
  /** Whether the window is visible on creation. */
  visible?: boolean;
}

/** Window events that carry size + position */
type SizeEvent =
  | WindowEvent.RESIZE
  | WindowEvent.MOVE
  | WindowEvent.MAXIMIZE
  | WindowEvent.RESTORE;

/** Handle for controlling an individual window instance. */
export type WindowHandle = {
  /** Unique identifier for this window. */
  readonly id: string;
  /** Show the window. */
  show(): void;
  /** Hide the window. */
  hide(): void;
  /** Minimize the window. */
  minimize(): void;
  /** Maximize the window. */
  maximize(): void;
  /** Restore the window from minimized state. */
  unminimize(): void;
  /** Restore the window from maximized state. */
  unmaximize(): void;
  /** Toggle between minimized and restored. */
  toggleMinimize(): void;
  /** Toggle between maximized and restored. */
  toggleMaximize(): void;
  /** Request the window to close (may be intercepted by close guards). */
  close(): void;
  /** Set the window title. */
  setTitle(title: string): void;
  /** Set the window size in logical pixels. */
  setSize(width: number, height: number): void;
  /** Set the window position on screen. */
  setPosition(x: number, y: number): void;
  /** Enter or exit fullscreen mode. */
  setFullscreen(on: boolean): void;
  /** Set whether the window floats above other windows. */
  setAlwaysOnTop(on: boolean): void;
  /** Force-close the window, bypassing all close guards */
  destroy(): void;
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

  let closeListenerCount = 0;

  const handleOn = (event: WindowEvent, handler: (payload: WindowEventPayload) => void): (() => void) => {
    const eventName = getWindowEventName(event);
    const off = Events.on(`window:${eventName}`, (payload) => {
      const p = payload as WindowEventPayload | undefined;
      if (p?.windowId === windowId) {
        handler(p);
      }
    });

    // Auto-guard: registering a CLOSE listener enables the native close guard
    if (event === WindowEvent.CLOSE) {
      closeListenerCount++;
      if (closeListenerCount === 1) {
        action("setCloseGuard", { guard: true });
      }
    }

    if (event === WindowEvent.READY && isWindowReady()) {
      queueMicrotask(() => handler({ windowId, timestamp: Date.now() }));
    }

    // Return unsubscribe that also manages the close guard
    return () => {
      off();
      if (event === WindowEvent.CLOSE) {
        closeListenerCount--;
        if (closeListenerCount <= 0) {
          closeListenerCount = 0;
          action("setCloseGuard", { guard: false });
        }
      }
    };
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
    destroy() { action("destroy"); },
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

/** API for creating and accessing windows. */
export interface WindowAPI {
  /** Create a new window with the given options. */
  create(options?: WindowOptions): Promise<WindowHandle>;
  /** Get a handle to the current webview's window. Throws in worker contexts. */
  current(): WindowHandle;
}

/** The singleton window management API instance. */
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
