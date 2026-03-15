export const ZAPP_WORKER_PROTOCOL_VERSION = 1;
export const ZAPP_SERVICE_PROTOCOL_VERSION = 1;

export type ZappWorkerControlType =
  | "zapp:worker:init"
  | "zapp:worker:post"
  | "zapp:worker:message"
  | "zapp:worker:error"
  | "zapp:worker:terminate";

export interface ZappWorkerEnvelope<T = unknown> {
  v: typeof ZAPP_WORKER_PROTOCOL_VERSION;
  t: ZappWorkerControlType;
  workerId: string;
  payload?: T;
}

export interface ZappWorkerInitPayload {
  scriptUrl: string;
  shared?: boolean;
}

export interface ZappWorkerPostPayload {
  data: unknown;
}

export interface ZappWorkerMessagePayload {
  data: unknown;
}

export interface ZappWorkerErrorPayload {
  message: string;
  stack?: string;
  filename?: string;
  lineno?: number;
  colno?: number;
}

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

export type ZappServiceErrorCode =
  | "BAD_REQUEST"
  | "INVALID_METHOD"
  | "UNAUTHORIZED"
  | "NOT_FOUND"
  | "INTERNAL_ERROR"
  | "TIMEOUT";

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

export interface ZappServiceInvokeError {
  code: ZappServiceErrorCode;
  message: string;
  details?: unknown;
}

export interface ZappServiceInvokeResponse {
  v: typeof ZAPP_SERVICE_PROTOCOL_VERSION;
  id: string;
  ok: boolean;
  result?: unknown;
  error?: ZappServiceInvokeError;
}
