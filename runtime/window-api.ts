/**
 * Focused frontend window API for the Z-owned Zapp runtime.
 *
 * This module talks directly to the narrow bridge. It intentionally does not
 * import the pre-rewrite window implementation or expose its broader surface.
 */

import { getBridge } from "./bridge";
import { ensurePermission } from "./permissions";
import { WindowError } from "./window-errors";
import { showWindowContextMenu, type MenuItem } from "./menu-api";

/** Explicit top-left viewport CSS coordinates, e.g. MouseEvent.clientX/Y. */
export interface ContextMenuOptions {
  readonly x: number;
  readonly y: number;
}

export { WindowError } from "./window-errors";
export type {
  WindowErrorPayload,
  WindowOperation,
} from "./window-errors";

/** Frontend-safe options accepted by the Z-owned window factory. */
export interface WindowCreateOptions {
  title?: string;
  url?: string;
  width?: number;
  height?: number;
  visible?: boolean;
  resizable?: boolean;
}

/** Native window content dimensions in platform-independent logical units. */
export interface WindowSize {
  readonly width: number;
  readonly height: number;
}

export interface WindowFocusedEvent {
  readonly windowId: string;
}

export interface WindowBlurredEvent {
  readonly windowId: string;
}

export interface WindowMinimizedEvent {
  readonly windowId: string;
}

export interface WindowUnminimizedEvent {
  readonly windowId: string;
}

export interface WindowMaximizedEvent { readonly windowId: string; }
export interface WindowUnmaximizedEvent { readonly windowId: string; }
export interface WindowFullscreenEnteredEvent { readonly windowId: string; }
export interface WindowFullscreenExitedEvent { readonly windowId: string; }

export interface WindowResizedEvent {
  readonly windowId: string;
  readonly size: WindowSize;
}

/**
 * Read-only observation of a native navigation decision. Web content cannot
 * grant or cancel navigation; trusted Z subscribers own that authority.
 */
export interface WindowNavigationRequestedEvent {
  readonly windowId: string;
  readonly url: string;
  readonly mainFrame: boolean;
  readonly allowedByProfile: boolean;
  readonly cancelled: boolean;
}

/** Window events implemented through the Z-owned native path. */
export const WindowEvent = {
  FOCUS: 1,
  BLUR: 2,
  RESIZE: 3,
  NAVIGATION_REQUESTED: 4,
  MINIMIZED: 5,
  UNMINIMIZED: 6,
  MAXIMIZED: 7,
  UNMAXIMIZED: 8,
  FULLSCREEN_ENTERED: 9,
  FULLSCREEN_EXITED: 10,
} as const;

export type WindowEvent = (typeof WindowEvent)[keyof typeof WindowEvent];

/** One active window-event subscription. */
export interface WindowEventSubscription {
  /** Stop delivery. Repeated calls are harmless. */
  unsubscribe(): void;
}

/** Identity-bearing frontend proxy for one native Zapp window. */
export interface WindowHandle {
  readonly id: string;
  /** Present a native menu in this WebView; resolves on selection or dismissal. */
  showContextMenu(items: readonly MenuItem[], options: ContextMenuOptions): Promise<void>;

  subscribe(
    event: typeof WindowEvent.FOCUS,
    handler: (event: WindowFocusedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.BLUR,
    handler: (event: WindowBlurredEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.MINIMIZED,
    handler: (event: WindowMinimizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.UNMINIMIZED,
    handler: (event: WindowUnminimizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.MAXIMIZED,
    handler: (event: WindowMaximizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.UNMAXIMIZED,
    handler: (event: WindowUnmaximizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.FULLSCREEN_ENTERED,
    handler: (event: WindowFullscreenEnteredEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.FULLSCREEN_EXITED,
    handler: (event: WindowFullscreenExitedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.RESIZE,
    handler: (event: WindowResizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.NAVIGATION_REQUESTED,
    handler: (event: WindowNavigationRequestedEvent) => void,
  ): WindowEventSubscription;

  show(): void;
  /** Reveal/restore and request focus; observe FOCUS for native confirmation. */
  focus(): void;
  /** Request native minimization without closing the window. */
  minimize(): void;
  /** Undo minimization without explicitly requesting app activation or focus. */
  unminimize(): void;
  /** Request the platform's native standard enlarged frame (not fullscreen). */
  maximize(): void;
  /** Restore the ordinary frame. Deferred while native fullscreen is active. */
  unmaximize(): void;
  /** Request a desired fullscreen state; native completion events confirm it. */
  setFullscreen(value: boolean): void;
  hide(): void;
  close(): void;
  setTitle(title: string): void;
}

type FocusedEventHandler =
  | ((event: WindowFocusedEvent) => void)
  | ((event: WindowBlurredEvent) => void)
  | ((event: WindowMinimizedEvent) => void)
  | ((event: WindowUnminimizedEvent) => void)
  | ((event: WindowMaximizedEvent) => void)
  | ((event: WindowUnmaximizedEvent) => void)
  | ((event: WindowFullscreenEnteredEvent) => void)
  | ((event: WindowFullscreenExitedEvent) => void)
  | ((event: WindowResizedEvent) => void)
  | ((event: WindowNavigationRequestedEvent) => void);

type UnknownRecord = Record<string, unknown>;

const WINDOW_ID_KEY = Symbol.for("zapp.windowId");

const WINDOW_EVENT_NAMES: Record<WindowEvent, string> = {
  [WindowEvent.FOCUS]: "window:focus",
  [WindowEvent.BLUR]: "window:blur",
  [WindowEvent.MINIMIZED]: "window:minimized",
  [WindowEvent.UNMINIMIZED]: "window:unminimized",
  [WindowEvent.MAXIMIZED]: "window:maximized",
  [WindowEvent.UNMAXIMIZED]: "window:unmaximized",
  [WindowEvent.FULLSCREEN_ENTERED]: "window:fullscreen-entered",
  [WindowEvent.FULLSCREEN_EXITED]: "window:fullscreen-exited",
  [WindowEvent.RESIZE]: "window:resize",
  [WindowEvent.NAVIGATION_REQUESTED]: "window:navigation-requested",
};

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null;
}

function requiredWindowId(value: unknown, operation: "create" | "current"): string {
  if (typeof value === "string" && value.length > 0) return value;
  throw new WindowError({
    operation: operation === "create" ? "create" : undefined,
    message: operation === "current"
      ? "The current WebView does not have a native window identity."
      : "Native window creation returned an invalid window identity.",
  });
}

function windowAction(action: string, args: UnknownRecord): void {
  const bridge = getBridge() as ReturnType<typeof getBridge> & {
    post?: (message: string) => void;
  };
  const message = JSON.stringify({ t: 4, m: action, a: args });
  if (bridge.post) {
    bridge.post(message);
    return;
  }
  bridge.emit(`__window_action:${action}`, args);
}

function subscription(cleanup: () => void): WindowEventSubscription {
  let active = true;
  return {
    unsubscribe(): void {
      if (!active) return;
      active = false;
      cleanup();
    },
  };
}

class FocusedWindowHandle implements WindowHandle {
  constructor(readonly id: string) {}

  showContextMenu(items: readonly MenuItem[], options: ContextMenuOptions): Promise<void> {
    return showWindowContextMenu(this.id, items, options);
  }

  subscribe(
    event: typeof WindowEvent.FOCUS,
    handler: (event: WindowFocusedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.BLUR,
    handler: (event: WindowBlurredEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.MINIMIZED,
    handler: (event: WindowMinimizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.UNMINIMIZED,
    handler: (event: WindowUnminimizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.MAXIMIZED,
    handler: (event: WindowMaximizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.UNMAXIMIZED,
    handler: (event: WindowUnmaximizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.FULLSCREEN_ENTERED,
    handler: (event: WindowFullscreenEnteredEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.FULLSCREEN_EXITED,
    handler: (event: WindowFullscreenExitedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.RESIZE,
    handler: (event: WindowResizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.NAVIGATION_REQUESTED,
    handler: (event: WindowNavigationRequestedEvent) => void,
  ): WindowEventSubscription;
  subscribe(event: WindowEvent, handler: FocusedEventHandler): WindowEventSubscription {
    const cleanup = getBridge().on(WINDOW_EVENT_NAMES[event], (value) => {
      if (!isRecord(value) || value.windowId !== this.id) return;

      if (event === WindowEvent.RESIZE) {
        if (!isRecord(value.size)) return;
        const width = value.size.width;
        const height = value.size.height;
        if (typeof width !== "number" || typeof height !== "number") return;
        const receive = handler as (event: WindowResizedEvent) => void;
        receive({ windowId: this.id, size: { width, height } });
        return;
      }

      if (event === WindowEvent.NAVIGATION_REQUESTED) {
        const url = value.url;
        const mainFrame = value.mainFrame;
        const allowedByProfile = value.allowedByProfile;
        const cancelled = value.cancelled;
        if (
          typeof url !== "string"
          || typeof mainFrame !== "boolean"
          || typeof allowedByProfile !== "boolean"
          || typeof cancelled !== "boolean"
        ) return;
        const receive = handler as (
          event: WindowNavigationRequestedEvent
        ) => void;
        receive({
          windowId: this.id,
          url,
          mainFrame,
          allowedByProfile,
          cancelled,
        });
        return;
      }

      const receive = handler as (
        event: WindowFocusedEvent | WindowBlurredEvent | WindowMinimizedEvent | WindowUnminimizedEvent
          | WindowMaximizedEvent | WindowUnmaximizedEvent | WindowFullscreenEnteredEvent | WindowFullscreenExitedEvent,
      ) => void;
      receive({ windowId: this.id });
    });
    return subscription(cleanup);
  }

  show(): void { windowAction("show", { windowId: this.id }); }
  focus(): void { windowAction("focus", { windowId: this.id }); }
  minimize(): void { windowAction("minimize", { windowId: this.id }); }
  unminimize(): void { windowAction("unminimize", { windowId: this.id }); }
  maximize(): void { windowAction("maximize", { windowId: this.id }); }
  unmaximize(): void { windowAction("unmaximize", { windowId: this.id }); }
  setFullscreen(value: boolean): void {
    windowAction("setFullscreen", { windowId: this.id, fullscreen: value });
  }
  hide(): void { windowAction("hide", { windowId: this.id }); }
  close(): void { windowAction("close", { windowId: this.id }); }
  setTitle(title: string): void {
    windowAction("setTitle", { windowId: this.id, title });
  }
}

/** Return the identity-bearing handle for the current WebView window. */
export function currentWindow(): WindowHandle {
  return new FocusedWindowHandle(
    requiredWindowId((globalThis as any)[WINDOW_ID_KEY], "current"),
  );
}

/** Ask the application-owned native WindowManager to realize a new window. */
export async function createWindow(
  options: WindowCreateOptions = {},
): Promise<WindowHandle> {
  ensurePermission("window:create");
  const host = (globalThis as any).__zappBridge;
  const result = host?.createWindow
    ? host.createWindow(options)
    : await getBridge().invoke("__window:create", options as UnknownRecord);
  const windowId = isRecord(result) ? result.windowId : undefined;
  return new FocusedWindowHandle(requiredWindowId(windowId, "create"));
}
