import {
  ZappError,
  ZappInvocationError,
  registerBridgeErrorFactory,
  type BridgeErrorPayload,
} from "./errors";

export type WindowOperation = "create" | "close" | "navigate";

export interface WindowErrorPayload {
  message: string;
  operation?: WindowOperation;
  windowId?: string;
}

/** A native window operation failed after crossing the Zapp bridge. */
export class WindowError extends ZappError {
  readonly operation?: WindowOperation;
  readonly windowId?: string;

  constructor(payload: WindowErrorPayload) {
    super({ code: "WINDOW_ERROR", message: payload.message });
    this.name = "WindowError";
    this.operation = payload.operation;
    this.windowId = payload.windowId;
  }
}

registerBridgeErrorFactory("WINDOW_ERROR", (payload: BridgeErrorPayload) => (
  new WindowError({
    message: payload.message,
    operation: payload.operation as WindowOperation | undefined,
    windowId: payload.windowId,
  })
));

export interface RelatedWindowInvalidatedErrorPayload {
  readonly windowId: string;
  /** Human-readable explanation; not an exhaustive machine-readable reason enum. */
  readonly reason: string;
}

/** Work lost its owning related document, rather than failing inside a service. */
export class RelatedWindowInvalidatedError extends ZappError {
  readonly windowId: string;
  readonly reason: string;

  constructor(payload: RelatedWindowInvalidatedErrorPayload) {
    super({
      code: "RELATED_WINDOW_INVALIDATED",
      message: `Related window "${payload.windowId}" is no longer usable: ${payload.reason}`,
    });
    this.name = "RelatedWindowInvalidatedError";
    this.windowId = payload.windowId;
    this.reason = payload.reason;
  }
}

registerBridgeErrorFactory("RELATED_WINDOW_INVALIDATED", (payload: BridgeErrorPayload) => (
  payload.windowId && payload.reason
    ? new RelatedWindowInvalidatedError({ windowId: payload.windowId, reason: payload.reason })
    : new ZappInvocationError(payload)
));
