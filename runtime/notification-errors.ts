import {
  ZappError,
  registerBridgeErrorFactory,
  type BridgeErrorPayload,
} from "./errors";

export type NotificationOperation =
  | "permissionStatus"
  | "requestPermission"
  | "show";

export interface NotificationErrorPayload {
  message: string;
  operation?: NotificationOperation;
}

/** A native notification operation failed after crossing the Zapp bridge. */
export class NotificationError extends ZappError {
  readonly operation?: NotificationOperation;

  constructor(payload: NotificationErrorPayload) {
    super({ code: "NOTIFICATION_ERROR", message: payload.message });
    this.name = "NotificationError";
    this.operation = payload.operation;
  }
}

registerBridgeErrorFactory("NOTIFICATION_ERROR", (payload: BridgeErrorPayload) => (
  new NotificationError({
    message: payload.message,
    operation: payload.operation as NotificationOperation | undefined,
  })
));
