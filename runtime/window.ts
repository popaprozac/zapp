/**
 * Window — per-window handle with scoped event listening.
 *
 * @example
 * ```ts
 * import { Window, WindowEvent } from "@zappdev/runtime";
 *
 * // Default: visible:true → window auto-shows when content is ready,
 * // no manual show() needed. Just listen for events you actually care
 * // about (resize, focus, close, etc.).
 * const win = Window.current();
 * win.on(WindowEvent.RESIZE, (payload) => console.log(payload.size));
 *
 * // Want to delay showing yourself? Pass visible:false at create time
 * // and call win.show() when you're ready.
 * ```
 */

import { getBridge } from "./bridge";
import { WindowEvent, eventName, type WindowSizePayload, type WindowPayload, type ModalDismissedPayload } from "./events";

/**
 * Per-traffic-light state. `disabled` greys the button, `hidden` removes
 * it entirely (leaves a gap unless paired with a custom titlebar).
 */
export type ButtonState = "enabled" | "disabled" | "hidden";

/** macOS traffic light button states (close / minimize / zoom). */
export interface TrafficLights {
  close?: ButtonState;
  minimize?: ButtonState;
  zoom?: ButtonState;
}

/** Options for creating a window (mirrors native WindowOptions). */
export interface WindowOptions {
  title?: string;
  url?: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  /**
   * Cosmetic — does the user see the window? Default `true` (auto-shows
   * when the bridge bootstrap signals ready, eliminating white flash).
   * Pass `false` to create the window hidden; call `show()` later when
   * your app decides it's ready. The window is fully created either way.
   */
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
   * Atomic create-and-attach-as-sheet. Equivalent to creating the window
   * with `visible: false` then calling `parent.attachModal(modal)` — but
   * done in one native call so the modal never appears as a free-floating
   * window before the sheet wraps it. Pass either a `WindowHandle` or a
   * window ID string ("win-N").
   *
   * When set, `visible` is forced to `false` (the sheet's own appearance
   * is governed by `beginSheet:`, not the window's standalone visibility).
   *
   * @example
   * ```ts
   * const parent = Window.current();
   * const settings = await Window.create({
   *   title: "Settings", width: 500, height: 400,
   *   asSheetOf: parent,
   * });
   * // settings is now a sheet on parent — no manual attachModal needed.
   * ```
   */
  asSheetOf?: WindowHandle | string;
  /**
   * Per-button state for the macOS traffic lights. Takes precedence over
   * the legacy `closable` / `minimizable` / `maximizable` booleans (those
   * remain as sugar: `false` maps to the corresponding button's
   * `"disabled"` state).
   *
   * @example
   * ```ts
   * Window.create({
   *   trafficLights: { close: "enabled", minimize: "disabled", zoom: "hidden" },
   * });
   * ```
   */
  trafficLights?: TrafficLights;
  /**
   * macOS — accept clicks on an unfocused window so the first click both
   * activates the window and triggers the target control. Default: `true`.
   */
  acceptFirstMouse?: boolean;
  /**
   * Center the window on the active screen at create time. Overrides
   * `x` / `y` when both are set. With `frameAutosaveName`, the saved
   * frame still wins on restore — `autoCenter` is the first-launch
   * fallback before any saved state exists.
   */
  autoCenter?: boolean;
  /**
   * Persist the window's frame (position + size) under this name. AppKit
   * stores it in NSUserDefaults and restores it on next launch — the
   * framework just exposes the knob. Use a stable per-window identifier
   * (e.g. `"main"`, `"settings"`) so the right frame restores to the
   * right window. Empty/omitted means no autosave.
   *
   * @example
   * ```ts
   * Window.create({ frameAutosaveName: "main" });
   * ```
   */
  frameAutosaveName?: string;
}

/** Size events that include width/height/position data. */
type SizeEvent = WindowEvent.RESIZE | WindowEvent.MOVE | WindowEvent.MAXIMIZE | WindowEvent.RESTORE;

/** A handle to a specific window. */
export interface WindowHandle {
  readonly id: string;

  on(event: SizeEvent, handler: (payload: WindowSizePayload) => void): () => void;
  on(event: WindowEvent.MODAL_DISMISSED, handler: (payload: ModalDismissedPayload) => void): () => void;
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

  /**
   * Attach `modal` as a sheet on this window. The modal slides down from
   * this window's titlebar and blocks interaction with the parent (only)
   * until dismissed. Closing the modal — via its close button,
   * `modal.close()`, or `modal.destroy()` — auto-dismisses the sheet.
   *
   * Honored options on the modal: `title`, `url`, `width`, `height`,
   * `transparent`, `webContentInspectable`. Position, fullscreen,
   * borderless, titleBarStyle, trafficLights, and alwaysOnTop are
   * meaningless for sheets and ignored.
   *
   * @example
   * ```ts
   * const modal = await Window.create({
   *   title: "Settings",
   *   width: 500, height: 400,
   *   visible: false,        // create hidden so it appears as a sheet
   * });
   * Window.current().attachModal(modal);
   * ```
   *
   * Currently macOS-only; no-op on Windows until WebView2 modal support
   * lands.
   */
  attachModal(modal: WindowHandle): void;

  /**
   * Dismiss a modal sheet without closing the modal window. Use
   * `modal.close()` (or `modal.destroy()`) when you also want the modal
   * gone — that path auto-detaches anyway.
   */
  detachModal(modal: WindowHandle): void;
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

    attachModal(modal: WindowHandle) {
      // Pass string IDs straight through — the native router resolves
      // pointer-based window IDs ("win-0xPTR") to internal numeric IDs.
      // Parsing on the JS side would fail for the actual pointer format
      // and the action would silently no-op.
      windowAction("attachModal", { windowId, parentId: windowId, modalId: modal.id });
    },
    detachModal(modal: WindowHandle) {
      windowAction("detachModal", { windowId, parentId: windowId, modalId: modal.id });
    },
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
    // Normalize asSheetOf to its string window ID. The native side
    // resolves the JS-visible "win-0xPTR" string back to its internal
    // numeric ID via darwin_window_numeric_id_for_string.
    const normalized: Record<string, unknown> = { ...(opts ?? {}) };
    if (normalized.asSheetOf !== undefined) {
      const raw = normalized.asSheetOf as WindowHandle | string;
      const idStr = typeof raw === "string" ? raw : raw?.id;
      if (idStr) normalized.asSheetOf = idStr;
      else delete normalized.asSheetOf;
    }
    // Worker context: call the createWindow host directly (sync C call).
    const host = (globalThis as any).__zappBridge;
    if (host?.createWindow) {
      const r = host.createWindow(normalized) as { windowId: string };
      return createWindowHandle(r.windowId);
    }
    // Webview context: async IPC roundtrip through the WKWebView bridge.
    const result = await getBridge().invoke("__window:create", normalized) as { windowId: string };
    return createWindowHandle(result.windowId);
  },
};
