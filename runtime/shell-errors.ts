import {
  ZappError,
  registerBridgeErrorFactory,
  type BridgeErrorPayload,
} from "./errors";

export type ShellOperation = "openExternal";

export interface ShellErrorPayload {
  message: string;
  operation?: ShellOperation;
  url?: string;
}

/** A native shell handoff or compiled external-URL policy check failed. */
export class ShellError extends ZappError {
  readonly operation?: ShellOperation;
  readonly url?: string;

  constructor(payload: ShellErrorPayload) {
    super({ code: "SHELL_ERROR", message: payload.message });
    this.name = "ShellError";
    this.operation = payload.operation;
    this.url = payload.url;
  }
}

registerBridgeErrorFactory("SHELL_ERROR", (payload: BridgeErrorPayload) => (
  new ShellError({
    message: payload.message,
    operation: payload.operation as ShellOperation | undefined,
    url: payload.url,
  })
));
