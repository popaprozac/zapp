import {
  ZappError,
  registerBridgeErrorFactory,
  type BridgeErrorPayload,
} from "./errors";

export type ApplicationWorkerOperation = "send";

export interface ApplicationWorkerErrorPayload {
  code: string;
  message: string;
  operation?: ApplicationWorkerOperation;
  workerId?: string;
}

/** A configured application-worker operation failed. */
export class ApplicationWorkerError extends ZappError {
  readonly operation?: ApplicationWorkerOperation;
  readonly workerId?: string;

  constructor(payload: ApplicationWorkerErrorPayload) {
    super({ code: payload.code, message: payload.message });
    this.name = "ApplicationWorkerError";
    this.operation = payload.operation;
    this.workerId = payload.workerId;
  }
}

for (const code of ["WORKER_UNAVAILABLE", "WORKER_BUSY", "WORKER_ERROR"]) {
  registerBridgeErrorFactory(code, (payload: BridgeErrorPayload) => (
    new ApplicationWorkerError({
      code: payload.code,
      message: payload.message,
      operation: "send",
      workerId: payload.workerId,
    })
  ));
}
