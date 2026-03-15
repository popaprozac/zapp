import {
  ZAPP_SERVICE_PROTOCOL_VERSION,
  type ZappServiceInvokeError,
  type ZappServiceInvokeRequest,
  type ZappServiceInvokeResponse,
} from "./protocol";

type Bridge = {
  invoke?: (req: ZappServiceInvokeRequest) => Promise<ZappServiceInvokeResponse>;
  getServiceBindings?: () => string | null;
};

const getBridge = (): Bridge | null =>
  ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as Bridge | undefined) ?? null;

const normalizeError = (error: unknown): ZappServiceInvokeError => {
  if (error && typeof error === "object") {
    const errObj = error as Record<string, unknown>;
    if (typeof errObj.code === "string" && typeof errObj.message === "string") {
      return {
        code: errObj.code as ZappServiceInvokeError["code"],
        message: errObj.message,
        details: errObj.details,
      };
    }
  }
  if (error instanceof Error) {
    return { code: "INTERNAL_ERROR", message: error.message };
  }
  return { code: "INTERNAL_ERROR", message: "Service invocation failed" };
};

const makeRequest = (method: string, args: unknown): ZappServiceInvokeRequest => ({
  v: ZAPP_SERVICE_PROTOCOL_VERSION,
  id: `svc-${Date.now()}-${Math.random().toString(36).slice(2)}`,
  method,
  args,
  meta: {
    sourceCtxId: `ctx-${Math.random().toString(36).slice(2)}`,
  },
});

export interface ServicesAPI {
  invoke<T = unknown>(method: string, args?: unknown): Promise<T>;
  getBindingsManifest(): unknown;
}

export const Services: ServicesAPI = {
  async invoke<T = unknown>(method: string, args?: unknown): Promise<T> {
    if (typeof method !== "string" || method.length === 0) {
      throw new Error("Service method must be a non-empty string.");
    }

    const bridge = getBridge();
    if (!bridge?.invoke) {
      throw new Error("Native invoke bridge is unavailable.");
    }

    const req = makeRequest(method, args ?? {});
    let response: ZappServiceInvokeResponse;
    try {
      response = await bridge.invoke(req);
    } catch (error) {
      const normalized = normalizeError(error);
      throw new Error(`${normalized.code}: ${normalized.message}`);
    }

    if (!response.ok) {
      const err = normalizeError(response.error);
      throw new Error(`${err.code}: ${err.message}`);
    }

    return response.result as T;
  },

  getBindingsManifest(): unknown {
    const raw = getBridge()?.getServiceBindings?.();
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  },
};
