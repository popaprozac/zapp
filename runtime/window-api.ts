/**
 * Focused frontend window API for the Z-owned Zapp runtime.
 *
 * This module intentionally does not re-export the legacy `Window` namespace
 * or the broader pre-rewrite handle. New capabilities enter this boundary only
 * after their native Z path and frontend contract are composed end to end.
 */

import {
  createWindow as createLegacyWindow,
  currentWindow as currentLegacyWindow,
  type WindowCreateOptions,
  type WindowEventSubscription,
  type WindowHandle as LegacyWindowHandle,
} from "./window";
import {
  WindowEvent as LegacyWindowEvent,
} from "./events";

export { WindowError } from "./window-errors";
export type {
  WindowErrorPayload,
  WindowOperation,
} from "./window-errors";
export type {
  WindowCreateOptions,
  WindowEventSubscription,
};

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

export interface WindowResizedEvent {
  readonly windowId: string;
  readonly size: WindowSize;
}

/** Window events implemented through the Z-owned native path. */
export const WindowEvent = {
  FOCUS: LegacyWindowEvent.FOCUS,
  BLUR: LegacyWindowEvent.BLUR,
  RESIZE: LegacyWindowEvent.RESIZE,
} as const;

export type WindowEvent = (typeof WindowEvent)[keyof typeof WindowEvent];

/** Identity-bearing frontend proxy for one native Zapp window. */
export interface WindowHandle {
  readonly id: string;

  subscribe(
    event: typeof WindowEvent.FOCUS,
    handler: (event: WindowFocusedEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.BLUR,
    handler: (event: WindowBlurredEvent) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.RESIZE,
    handler: (event: WindowResizedEvent) => void,
  ): WindowEventSubscription;

  show(): void;
  hide(): void;
  close(): void;
  setTitle(title: string): void;
}

type FocusedEventHandler =
  | ((event: WindowFocusedEvent) => void)
  | ((event: WindowBlurredEvent) => void)
  | ((event: WindowResizedEvent) => void);

/**
 * Project the broad pre-rewrite handle into the Z-owned frontend contract.
 *
 * Event projection is intentional: legacy bridge metadata such as delivery
 * timestamps and combined geometry never becomes an accidental part of the
 * focused API.
 */
class FocusedWindowHandle implements WindowHandle {
  readonly id: string;

  constructor(private readonly legacy: LegacyWindowHandle) {
    this.id = legacy.id;
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
    event: typeof WindowEvent.RESIZE,
    handler: (event: WindowResizedEvent) => void,
  ): WindowEventSubscription;
  subscribe(event: WindowEvent, handler: FocusedEventHandler): WindowEventSubscription {
    if (event === WindowEvent.RESIZE) {
      const receive = handler as (value: WindowResizedEvent) => void;
      return this.legacy.subscribe(LegacyWindowEvent.RESIZE, (value) => {
        receive({
          windowId: value.windowId,
          size: {
            width: value.size.width,
            height: value.size.height,
          },
        });
      });
    }

    const receive = handler as (value: WindowFocusedEvent | WindowBlurredEvent) => void;
    return this.legacy.subscribe(event, (value) => {
      receive({ windowId: value.windowId });
    });
  }

  show(): void { this.legacy.show(); }
  hide(): void { this.legacy.hide(); }
  close(): void { this.legacy.close(); }
  setTitle(title: string): void { this.legacy.setTitle(title); }
}

function focusedWindow(legacy: LegacyWindowHandle): WindowHandle {
  return new FocusedWindowHandle(legacy);
}

/** Return the identity-bearing handle for the current WebView window. */
export function currentWindow(): WindowHandle {
  return focusedWindow(currentLegacyWindow());
}

/** Ask the application-owned native WindowManager to realize a new window. */
export async function createWindow(
  options: WindowCreateOptions = {},
): Promise<WindowHandle> {
  return focusedWindow(await createLegacyWindow(options));
}
