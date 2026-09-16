import type { WindowEventSubscription, WindowHandle } from "./window-api";
import type { TitleBarOptions } from "./window-titlebar";

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

/** Selected inline/root theme state. The owner is authoritative while attached. */
export interface RelatedWindowThemeOptions {
  /** Selected data-* attributes on document.documentElement. No event handlers or IDs. */
  attributes?: readonly string[];
  /** Individual root class tokens, not the entire class attribute. */
  classes?: readonly string[];
  /** Selected inline CSS custom-property declarations, not computed styles. */
  variables?: readonly string[];
}

/** A minimal same-origin document owned by the calling document. */
export interface RelatedWindowCreateOptions {
  title?: string;
  width?: number;
  height?: number;
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
  /** Default true. False keeps the published native window hidden until show(). */
  visible?: boolean;
  /** Independent creation policies, each defaulting to true. */
  resizable?: boolean;
  maximizable?: boolean;
  fullscreenable?: boolean;
  /** Child-local native chrome, not inherited from the owner's window. */
  titleBar?: TitleBarOptions;
  /** Default shared: live head-owned DOM styles, before child-local sheets. */
  styles?: "shared" | "independent";
  /** Omitted by default; no arbitrary root state is copied. */
  theme?: RelatedWindowThemeOptions;
}

/** One original document and its native controls; never retargeted. */
export interface RelatedWindowHandle extends WindowHandle {
  /** The original document. Never retargeted to a replacement page. */
  readonly document: Document;
  subscribe: WindowHandle["subscribe"] & ((
    event: typeof RelatedWindowEvent.INVALIDATED,
    handler: (event: RelatedWindowInvalidatedEvent) => void,
  ) => WindowEventSubscription);
}
