/**
 * Events — global event bus for cross-context communication.
 *
 * @example
 * ```ts
 * import { Events } from "@zappdev/runtime";
 *
 * // Listen for events
 * const off = Events.on("my-event", (data) => console.log(data));
 *
 * // Emit events (fire-and-forget, all listeners receive)
 * Events.emit("my-event", { hello: "world" });
 *
 * // Unsubscribe
 * off();
 * ```
 */

import { getBridge } from "./bridge";

/** Numeric identifiers for window events. */
export enum WindowEvent {
  READY = 0,
  FOCUS = 1,
  BLUR = 2,
  RESIZE = 3,
  MOVE = 4,
  CLOSE = 5,
  MINIMIZE = 6,
  MAXIMIZE = 7,
  RESTORE = 8,
  FULLSCREEN = 9,
  UNFULLSCREEN = 10,
  /** Fires on a parent window when an attached modal sheet dismisses.
   * Payload: `{ windowId, modalId, code, timestamp }`. `code` is the
   * NSModalResponse value (1 = OK, 0 = Cancel, -1000 = Stop, etc.). */
  MODAL_DISMISSED = 11,
}

/** App lifecycle events.
 * STARTED/SHUTDOWN are backend-only (fire before/after WebViews exist).
 * The rest are available in both frontend and backend. */
export enum AppEvent {
  STARTED = 100,       // backend-only
  SHUTDOWN = 101,      // backend-only
  REOPEN = 104,        // dock icon clicked
  OPEN_URL = 105,      // deep link opened
  DID_BECOME_ACTIVE = 106,
  DID_RESIGN_ACTIVE = 107,
  /** System-wide appearance changed — fires on light↔dark toggles
   * (System Settings → Appearance, auto schedule, or per-window
   * override). Payload: `{ theme: "light" | "dark" }`. */
  THEME_CHANGED = 108,
}

/** Map WindowEvent enum to string event names. */
const WINDOW_EVENT_NAMES: Record<number, string> = {
  [WindowEvent.READY]: "window:ready",
  [WindowEvent.FOCUS]: "window:focus",
  [WindowEvent.BLUR]: "window:blur",
  [WindowEvent.RESIZE]: "window:resize",
  [WindowEvent.MOVE]: "window:move",
  [WindowEvent.CLOSE]: "window:close",
  [WindowEvent.MINIMIZE]: "window:minimize",
  [WindowEvent.MAXIMIZE]: "window:maximize",
  [WindowEvent.RESTORE]: "window:restore",
  [WindowEvent.FULLSCREEN]: "window:fullscreen",
  [WindowEvent.UNFULLSCREEN]: "window:unfullscreen",
  [WindowEvent.MODAL_DISMISSED]: "window:modal-dismissed",
};

const APP_EVENT_NAMES: Record<number, string> = {
  [AppEvent.STARTED]: "app:started",
  [AppEvent.SHUTDOWN]: "app:shutdown",
  [AppEvent.REOPEN]: "app:reopen",
  [AppEvent.OPEN_URL]: "app:open-url",
  [AppEvent.DID_BECOME_ACTIVE]: "app:active",
  [AppEvent.DID_RESIGN_ACTIVE]: "app:inactive",
  [AppEvent.THEME_CHANGED]: "app:theme-changed",
};

/** Payload for window events that include size and position. */
export interface WindowSizePayload {
  windowId: string;
  timestamp: number;
  size: { width: number; height: number };
  position: { x: number; y: number };
}

/** Payload for simple window events (focus, blur, minimize, etc). */
export interface WindowPayload {
  windowId: string;
  timestamp: number;
}

/**
 * Payload for `WindowEvent.MODAL_DISMISSED` — fires on the parent window
 * when an attached modal sheet dismisses (close button, `modal.close()`,
 * `modal.destroy()`, or explicit `parent.detachModal(modal)`).
 *
 * `code` is the underlying NSModalResponse — 1 = OK, 0 = Cancel,
 * -1000 = Stop (default for self-closed modals), -1001 = Abort
 * (modal was attached elsewhere and was forcibly detached).
 */
export interface ModalDismissedPayload {
  windowId: string;       // the parent window
  modalId: string;        // the modal that dismissed
  code: number;           // NSModalResponse value
  timestamp: number;
}

/** Known window events that carry size+position data. */
type SizeEvents = "window:resize" | "window:move" | "window:maximize" | "window:restore";

/** Known window events without size data. */
type SimpleEvents = "window:ready" | "window:focus" | "window:blur" | "window:close"
  | "window:minimize" | "window:fullscreen" | "window:unfullscreen";

/** App event string names. */
type AppEvents = "app:started" | "app:shutdown" | "app:reopen" | "app:open-url" | "app:active" | "app:inactive" | "app:theme-changed";

/** All known event names. Arbitrary strings also work. */
export type EventName = SizeEvents | SimpleEvents | AppEvents | (string & {});

/** Resolve event name from enum to string. */
export function eventName(event: WindowEvent | AppEvent): string {
  return WINDOW_EVENT_NAMES[event] ?? APP_EVENT_NAMES[event] ?? `unknown:${event}`;
}

type EventHandler = (payload: any) => void;

export const Events = {
  /**
   * Subscribe to an event. Returns an unsubscribe function.
   */
  on(name: EventName, handler: EventHandler): () => void {
    return getBridge().on(name, handler);
  },

  /**
   * Emit a fire-and-forget event.
   *
   * - From a **webview**: dispatched locally to listeners in the same window
   *   (and to native listeners). Does not cross window boundaries.
   * - From the **backend** worker: broadcast to *every* open webview's
   *   listeners. This is the canonical pattern for pushing backend-owned
   *   state to all windows without per-window polling.
   * - From a **regular worker**: same as backend — broadcast to every webview.
   */
  emit(name: string, payload?: Record<string, unknown>): void {
    getBridge().emit(name, payload);
  },
};
