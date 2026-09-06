import {
  ZappError,
  registerBridgeErrorFactory,
  type BridgeErrorPayload,
} from "./errors";

export type FileOperation = "readText" | "writeText";

export interface FileErrorPayload {
  message: string;
  operation?: FileOperation;
  path?: string;
}

/** A checked Zapp text-file operation failed. */
export class FileError extends ZappError {
  readonly operation?: FileOperation;
  readonly path?: string;

  constructor(payload: FileErrorPayload) {
    super({ code: "FILE_ERROR", message: payload.message });
    this.name = "FileError";
    this.operation = payload.operation;
    this.path = payload.path;
  }
}

registerBridgeErrorFactory("FILE_ERROR", (payload: BridgeErrorPayload) => (
  new FileError({
    message: payload.message,
    operation: payload.operation as FileOperation | undefined,
    path: payload.path,
  })
));
