import type { WindowEventSubscription, WindowHandle } from "./window-api";

/** Terminal events for one related document, not generic native-window events. */
export const RelatedWindowEvent = {
  INVALIDATED: "related-window:invalidated",
} as const;

export type RelatedWindowEvent = (typeof RelatedWindowEvent)[keyof typeof RelatedWindowEvent];

export interface RelatedWindowInvalidatedEvent {
  readonly windowId: string;
  /** Human-readable explanation; use the event kind to classify invalidation. */
  readonly reason: string;
}

/** Approved contract; public related-window creation is not available yet. */
export interface RelatedWindowHandle extends WindowHandle {
  /** The original document. Never retargeted to a replacement page. */
  readonly document: Document;
  subscribe: WindowHandle["subscribe"] & ((
    event: typeof RelatedWindowEvent.INVALIDATED,
    handler: (event: RelatedWindowInvalidatedEvent) => void,
  ) => WindowEventSubscription);
}
