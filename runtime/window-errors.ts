import {
  ZappError,
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
