/**
 * Focused frontend window API for the Z-owned Zapp runtime.
 *
 * This module talks directly to the narrow bridge. It intentionally does not
 * import the pre-rewrite window implementation or expose its broader surface.
 */

import { getBridge, type ZappBridge } from "./bridge";
import { createRelatedWindowBinding } from "./related-window";
import { RelatedWindowEvent, type RelatedWindowHandle, type RelatedWindowCreateOptions } from "./related-window-contract";
import { ensurePermission } from "./permissions";
import { WindowError } from "./window-errors";
import { checkSizeOptions, positiveDimension } from "./window-sizing";
import { checkedTitleBar, type TitleBarOptions } from "./window-titlebar";
export type { TitleBarOptions, TitleBarStyle } from "./window-titlebar";
import { showWindowContextMenu, type MenuItem } from "./menu-api";

/** Explicit top-left viewport CSS coordinates, e.g. MouseEvent.clientX/Y. */
export interface ContextMenuOptions {
  readonly x: number;
  readonly y: number;
}

export { WindowError, RelatedWindowInvalidatedError } from "./window-errors";
export type {
  WindowErrorPayload,
  WindowOperation,
  RelatedWindowInvalidatedErrorPayload,
} from "./window-errors";
export { RelatedWindowEvent } from "./related-window-contract";
export type { RelatedWindowHandle, RelatedWindowInvalidatedEvent, RelatedWindowCreateOptions, RelatedWindowThemeOptions } from "./related-window-contract";

/** Frontend-safe options accepted by the Z-owned window factory. */
export interface WindowCreateOptions {
  title?: string;
  url?: string;
  width?: number;
  height?: number;
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
  visible?: boolean;
  resizable?: boolean;
  /** Allow maximizing/zooming. Independent of interactive edge resizing. */
  maximizable?: boolean;
  /** Allow entering native fullscreen. Does not prevent leaving fullscreen. */
  fullscreenable?: boolean;
  titleBar?: TitleBarOptions;
}

/** Native window content dimensions in platform-independent logical units. */
export interface WindowSize {
  readonly width: number;
  readonly height: number;
}

/** Outer-frame top-left in logical desktop units, relative to the primary display's top-left. */
export interface WindowPosition {
  readonly x: number;
  readonly y: number;
}

/** Rectangle in logical desktop units: primary top-left origin, x right, y down. */
export interface Bounds {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** Immutable snapshot. IDs are opaque and need not survive reconnects or restarts. */
export interface Display {
  readonly id: string;
  readonly bounds: Bounds;
  readonly workArea: Bounds;
  readonly scaleFactor: number;
  readonly isPrimary: boolean;
}

function boundsSnapshot(value: unknown): Bounds | undefined {
  if (!isRecord(value) || !Number.isFinite(value.x) || !Number.isFinite(value.y)
    || typeof value.width !== "number" || !Number.isFinite(value.width) || value.width < 0
    || typeof value.height !== "number" || !Number.isFinite(value.height) || value.height < 0) return;
  return Object.freeze({ x: value.x as number, y: value.y as number, width: value.width, height: value.height });
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
  /** Read native content dimensions, not cached or requested dimensions. */
  getSize(): Promise<WindowSize>;
  /** Request content size; native limits clamp it. Resolves on handling, not animation completion. */
  setSize(size: WindowSize): Promise<void>;
  /** Measure the actual outer-frame position, not a pending placement request. */
  getPosition(): Promise<WindowPosition>;
  /** Measure the actual outer frame, excluding shadows; getSize() measures content. */
  getBounds(): Promise<Bounds>;
  /** Display containing most of the window, or null offscreen. Closed windows reject. */
  getDisplay(): Promise<Display | null>;
  /** Finite, signed logical coordinates. Deferred while maximized/fullscreen; does not focus. */
  setPosition(position: WindowPosition): Promise<void>;
  /** Center geometrically in the current display's work area; deferred until ordinary presentation. */
  center(): Promise<void>;
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

function windowAction(action: string, args: UnknownRecord, target = getBridge()): void {
  const bridge = target as ReturnType<typeof getBridge> & {
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
  constructor(readonly id: string, private readonly bound?: { bridge: ZappBridge; assertActive(): void }) {}

  private bridge(): ZappBridge {
    this.bound?.assertActive();
    return this.bound?.bridge ?? getBridge();
  }

  private action(name: string, args: UnknownRecord = {}): void {
    windowAction(name, { windowId: this.id, ...args }, this.bridge());
  }

  showContextMenu(items: readonly MenuItem[], options: ContextMenuOptions): Promise<void> {
    return showWindowContextMenu(this.id, items, options, this.bound);
  }

  async getSize(): Promise<WindowSize> {
    const value = await this.bridge().invoke("__window:get-size", { windowId: this.id });
    if (!isRecord(value) || !positiveDimension(value.width) || !positiveDimension(value.height)) {
      throw new WindowError({ operation: "getSize", windowId: this.id, message: "Native window returned invalid content dimensions." });
    }
    return { width: value.width, height: value.height };
  }

  async setSize(size: WindowSize): Promise<void> {
    if (!isRecord(size) || !positiveDimension(size.width) || !positiveDimension(size.height)) {
      throw new TypeError("Window size requires positive u32 width and height in logical units.");
    }
    await this.bridge().invoke("__window:set-size", { windowId: this.id, size: { width: size.width, height: size.height } });
  }

  async getPosition(): Promise<WindowPosition> {
    const value = await this.bridge().invoke("__window:get-position", { windowId: this.id });
    if (!isRecord(value) || !Number.isFinite(value.x) || !Number.isFinite(value.y)) {
      throw new WindowError({ operation: "getPosition", windowId: this.id, message: "Native window returned invalid coordinates." });
    }
    return { x: value.x as number, y: value.y as number };
  }

  async setPosition(position: WindowPosition): Promise<void> {
    if (!isRecord(position) || !Number.isFinite(position.x) || !Number.isFinite(position.y)) {
      throw new TypeError("Window position requires finite x and y in logical units.");
    }
    await this.bridge().invoke("__window:set-position", { windowId: this.id, position: { x: position.x, y: position.y } });
  }

  async getBounds(): Promise<Bounds> {
    const value = boundsSnapshot(await this.bridge().invoke("__window:get-bounds", { windowId: this.id }));
    if (!value) throw new WindowError({ operation: "getBounds", windowId: this.id, message: "Native window returned invalid bounds." });
    return value;
  }

  async getDisplay(): Promise<Display | null> {
    const value = await this.bridge().invoke("__window:get-display", { windowId: this.id });
    if (value === null) return null;
    const bounds = isRecord(value) ? boundsSnapshot(value.bounds) : undefined;
    const workArea = isRecord(value) ? boundsSnapshot(value.workArea) : undefined;
    if (!isRecord(value) || typeof value.id !== "string" || !value.id || !bounds || !workArea
      || bounds.width <= 0 || bounds.height <= 0
      || typeof value.scaleFactor !== "number" || !Number.isFinite(value.scaleFactor) || value.scaleFactor <= 0
      || typeof value.isPrimary !== "boolean") {
      throw new WindowError({ operation: "getDisplay", windowId: this.id, message: "Native window returned an invalid display snapshot." });
    }
    return Object.freeze({ id: value.id, bounds, workArea, scaleFactor: value.scaleFactor, isPrimary: value.isPrimary });
  }

  async center(): Promise<void> {
    await this.bridge().invoke("__window:center", { windowId: this.id });
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
    const cleanup = this.bridge().on(WINDOW_EVENT_NAMES[event], (value) => {
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

  show(): void { this.action("show"); }
  focus(): void { this.action("focus"); }
  minimize(): void { this.action("minimize"); }
  unminimize(): void { this.action("unminimize"); }
  maximize(): void { this.action("maximize"); }
  unmaximize(): void { this.action("unmaximize"); }
  setFullscreen(value: boolean): void {
    this.action("setFullscreen", { fullscreen: value });
  }
  hide(): void { this.action("hide"); }
  close(): void { this.action("close"); }
  setTitle(title: string): void {
    this.action("setTitle", { title });
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
  checkSizeOptions(options);
  for (const key of ["resizable", "maximizable", "fullscreenable"] as const) {
    if (options[key] !== undefined && typeof options[key] !== "boolean") throw new TypeError(`Window ${key} must be a boolean.`);
  }
  const titleBar = checkedTitleBar(options.titleBar);
  const checked = titleBar === undefined ? { ...options } : { ...options, titleBar };
  const host = (globalThis as any).__zappBridge;
  const result = host?.createWindow
    ? host.createWindow(checked)
    : await getBridge().invoke("__window:create", checked as UnknownRecord);
  const windowId = isRecord(result) ? result.windowId : undefined;
  return new FocusedWindowHandle(requiredWindowId(windowId, "create"));
}

/** Create a minimal same-origin document with its own native bridge. */
export async function createRelatedWindow(options: RelatedWindowCreateOptions = {}): Promise<RelatedWindowHandle> {
  const binding = await createRelatedWindowBinding(options);
  const handle = new FocusedWindowHandle(binding.id, {
    bridge: binding.bridge, assertActive: () => binding.lifetime.assertActive(),
  });
  const subscribe = handle.subscribe.bind(handle);
  Object.defineProperty(handle, "document", { value: binding.document, enumerable: true });
  Object.defineProperty(handle, "subscribe", { value: (event: WindowEvent | typeof RelatedWindowEvent.INVALIDATED, handler: any) =>
    event === RelatedWindowEvent.INVALIDATED ? binding.lifetime.subscribe(handler) : subscribe(event as any, handler) });
  // Native retirement can occur between the binding's and public continuation.
  binding.lifetime.assertActive();
  return handle as unknown as RelatedWindowHandle;
}
