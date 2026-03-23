/** Current version of the worker wire protocol. */
export const ZAPP_WORKER_PROTOCOL_VERSION = 1;
/** Current version of the service invocation protocol. */
export const ZAPP_SERVICE_PROTOCOL_VERSION = 1;

/** Discriminator strings for worker control messages. */
export type ZappWorkerControlType =
  | "zapp:worker:init"
  | "zapp:worker:post"
  | "zapp:worker:message"
  | "zapp:worker:error"
  | "zapp:worker:terminate";

/** Envelope wrapping all worker control messages on the wire. */
export interface ZappWorkerEnvelope<T = unknown> {
  v: typeof ZAPP_WORKER_PROTOCOL_VERSION;
  t: ZappWorkerControlType;
  workerId: string;
  payload?: T;
}

/** Payload for the worker init control message. */
export interface ZappWorkerInitPayload {
  scriptUrl: string;
  shared?: boolean;
}

/** Payload for posting data to a worker. */
export interface ZappWorkerPostPayload {
  data: unknown;
}

/** Payload for a message received from a worker. */
export interface ZappWorkerMessagePayload {
  data: unknown;
}

/** Payload describing a worker error. */
export interface ZappWorkerErrorPayload {
  message: string;
  stack?: string;
  filename?: string;
  lineno?: number;
  colno?: number;
}

/** Host-side bridge interface for managing workers from the native layer. */
export type ZappWorkerHostBridge = {
  createWorker(scriptUrl: string, options?: { shared?: boolean }): string;
  postToWorker(workerId: string, data: unknown): void;
  terminateWorker(workerId: string): void;
  subscribe(
    workerId: string,
    onMessage: (data: unknown) => void,
    onError: (error: ZappWorkerErrorPayload) => void,
  ): () => void;
};

/** Standard error codes returned by service invocations. */
export type ZappServiceErrorCode =
  | "BAD_REQUEST"
  | "INVALID_METHOD"
  | "UNAUTHORIZED"
  | "NOT_FOUND"
  | "INTERNAL_ERROR"
  | "TIMEOUT";

/** A request to invoke a named service method. */
export interface ZappServiceInvokeRequest {
  v: typeof ZAPP_SERVICE_PROTOCOL_VERSION;
  id: string;
  method: string;
  args: unknown;
  meta: {
    sourceCtxId: string;
    capability?: string;
  };
}

/** Structured error returned from a failed service invocation. */
export interface ZappServiceInvokeError {
  code: ZappServiceErrorCode;
  message: string;
  details?: unknown;
}

/** Response envelope from a service invocation. */
export interface ZappServiceInvokeResponse {
  v: typeof ZAPP_SERVICE_PROTOCOL_VERSION;
  id: string;
  ok: boolean;
  result?: unknown;
  error?: ZappServiceInvokeError;
}
