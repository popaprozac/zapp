import {
  ZappError,
  registerBridgeErrorFactory,
  type BridgeErrorPayload,
} from "./errors";

export type ShellOperation = "openExternal" | "openPath" | "reveal" | "trash";

export interface ShellErrorPayload {
  message: string;
  operation?: ShellOperation;
  target?: string;
}

/** A native shell handoff or compiled external-URL policy check failed. */
export class ShellError extends ZappError {
  readonly operation?: ShellOperation;
  readonly target?: string;

  constructor(payload: ShellErrorPayload) {
    super({ code: "SHELL_ERROR", message: payload.message });
    this.name = "ShellError";
    this.operation = payload.operation;
    this.target = payload.target;
  }
}

registerBridgeErrorFactory("SHELL_ERROR", (payload: BridgeErrorPayload) => (
  new ShellError({
    message: payload.message,
    operation: payload.operation as ShellOperation | undefined,
    target: payload.target,
  })
));
