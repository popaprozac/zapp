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
} from "./window";
import {
  WindowEvent as LegacyWindowEvent,
  type WindowPayload,
  type WindowSizePayload,
} from "./events";

export { WindowError } from "./window-errors";
export type {
  WindowErrorPayload,
  WindowOperation,
} from "./window-errors";
export type {
  WindowCreateOptions,
  WindowEventSubscription,
  WindowPayload,
  WindowSizePayload,
};

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
    event: typeof WindowEvent.FOCUS | typeof WindowEvent.BLUR,
    handler: (payload: WindowPayload) => void,
  ): WindowEventSubscription;
  subscribe(
    event: typeof WindowEvent.RESIZE,
    handler: (payload: WindowSizePayload) => void,
  ): WindowEventSubscription;

  show(): void;
  hide(): void;
  close(): void;
  setTitle(title: string): void;
}

/** Return the identity-bearing handle for the current WebView window. */
export function currentWindow(): WindowHandle {
  return currentLegacyWindow();
}

/** Ask the application-owned native WindowManager to realize a new window. */
export async function createWindow(
  options: WindowCreateOptions = {},
): Promise<WindowHandle> {
  return createLegacyWindow(options);
}
