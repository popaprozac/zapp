/**
 * Window — per-window handle with scoped event listening.
 *
 * @example
 * ```ts
 * import { Window, WindowEvent } from "@zappdev/runtime";
 *
 * const win = Window.current();
 * win.on(WindowEvent.READY, () => win.show());
 * win.on(WindowEvent.RESIZE, (payload) => console.log(payload.size));
 * ```
 */

import { getBridge } from "./bridge";
import { WindowEvent, eventName, type WindowSizePayload, type WindowPayload } from "./events";

/** Options for creating a window (mirrors native WindowOptions). */
export interface WindowOptions {
  title?: string;
  url?: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  visible?: boolean;
  resizable?: boolean;
  closable?: boolean;
  minimizable?: boolean;
  maximizable?: boolean;
  fullscreen?: boolean;
  borderless?: boolean;
  transparent?: boolean;
  alwaysOnTop?: boolean;
  titleBarStyle?: "default" | "hidden" | "hiddenInset";
  /**
   * macOS — accept clicks on an unfocused window so the first click both
   * activates the window and triggers the target control. Default: `true`.
   */
  acceptFirstMouse?: boolean;
}

/** Size events that include width/height/position data. */
type SizeEvent = WindowEvent.RESIZE | WindowEvent.MOVE | WindowEvent.MAXIMIZE | WindowEvent.RESTORE;

/** A handle to a specific window. */
export interface WindowHandle {
  readonly id: string;

  on(event: SizeEvent, handler: (payload: WindowSizePayload) => void): () => void;
  on(event: WindowEvent, handler: (payload: WindowPayload) => void): () => void;

  show(): void;
  hide(): void;
  close(): void;
  setTitle(title: string): void;
  setSize(width: number, height: number): void;
  setPosition(x: number, y: number): void;
  minimize(): void;
  maximize(): void;
  setFullscreen(on: boolean): void;
  setAlwaysOnTop(on: boolean): void;
  setCloseGuard(enabled: boolean): void;
  loadUrl(url: string): void;
}

/** Send a window action to native. Uses message type 4 (WINDOW_ACTION). */
function windowAction(action: string, args: Record<string, unknown> = {}): void {
  const bridge = getBridge();
  // Post raw message with t:4 for window actions (fire-and-forget)
  const msg = JSON.stringify({ t: 4, m: action, a: args });
  (bridge as any).post ? (bridge as any).post(msg) : bridge.emit("__window_action:" + action, args);
}

function createWindowHandle(windowId: string): WindowHandle {
  const bridge = getBridge();

  return {
    id: windowId,

    on(event: WindowEvent, handler: (payload: any) => void): () => void {
      const name = eventName(event);
      return bridge.on(name, (payload: any) => {
        if (payload?.windowId === windowId) {
          handler(payload);
        }
      });
    },

    show()                            { windowAction("show", { windowId }); },
    hide()                            { windowAction("hide", { windowId }); },
    close()                           { windowAction("close", { windowId }); },
    setTitle(title: string)           { windowAction("setTitle", { windowId, title }); },
    setSize(width: number, h: number) { windowAction("setSize", { windowId, width, height: h }); },
    setPosition(x: number, y: number) { windowAction("setPosition", { windowId, x, y }); },
    minimize()                        { windowAction("minimize", { windowId }); },
    maximize()                        { windowAction("maximize", { windowId }); },
    setFullscreen(on: boolean)        { windowAction("setFullscreen", { windowId, on }); },
    setAlwaysOnTop(on: boolean)       { windowAction("setAlwaysOnTop", { windowId, on }); },
    setCloseGuard(on: boolean)        { windowAction("setCloseGuard", { windowId, on }); },
    loadUrl(url: string)              { windowAction("loadUrl", { windowId, url }); },
  };
}

function getCurrentWindowId(): string | null {
  return (globalThis as any)[Symbol.for("zapp.windowId")] ?? null;
}

export const Window = {
  /** Get the current window handle. Only available in WebView context. */
  current(): WindowHandle {
    const id = getCurrentWindowId();
    if (!id) {
      throw new Error("[zapp] Window.current() is only available in WebView context. Use Window.create() in backend/workers.");
    }
    return createWindowHandle(id);
  },

  /** Create a new window. Returns a handle for the new window. */
  async create(opts?: Partial<WindowOptions>): Promise<WindowHandle> {
    // Worker context: call the createWindow host directly (sync C call).
    const host = (globalThis as any).__zappBridge;
    if (host?.createWindow) {
      const r = host.createWindow(opts ?? {}) as { windowId: string };
      return createWindowHandle(r.windowId);
    }
    // Webview context: async IPC roundtrip through the WKWebView bridge.
    const result = await getBridge().invoke("__window:create", opts ?? {}) as { windowId: string };
    return createWindowHandle(result.windowId);
  },
};
