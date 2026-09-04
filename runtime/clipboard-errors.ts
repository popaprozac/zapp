import {
  ZappError,
  registerBridgeErrorFactory,
  type BridgeErrorPayload,
} from "./errors";

export type ClipboardOperation = "readText" | "writeText" | "clear";

export interface ClipboardErrorPayload {
  message: string;
  operation?: ClipboardOperation;
}

/** A native clipboard operation failed after crossing the Zapp bridge. */
export class ClipboardError extends ZappError {
  readonly operation?: ClipboardOperation;

  constructor(payload: ClipboardErrorPayload) {
    super({ code: "CLIPBOARD_ERROR", message: payload.message });
    this.name = "ClipboardError";
    this.operation = payload.operation;
  }
}

registerBridgeErrorFactory("CLIPBOARD_ERROR", (payload: BridgeErrorPayload) => (
  new ClipboardError({
    message: payload.message,
    operation: payload.operation as ClipboardOperation | undefined,
  })
));
