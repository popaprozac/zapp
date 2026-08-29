const ERROR_FACTORY_KEY = Symbol.for("zapp.errorFactory");

export interface ZappErrorPayload {
  code: string;
  message: string;
  permission?: string;
}

/** @internal Parsed transport metadata before a feature claims the error. */
export interface BridgeErrorPayload extends ZappErrorPayload {
  operation?: string;
  windowId?: string;
  service?: string;
  method?: string;
  errorType?: string;
  details?: unknown;
}

export class ZappError extends Error {
  readonly code: string;

  constructor(payload: ZappErrorPayload) {
    super(payload.message);
    this.name = "ZappError";
    this.code = payload.code;
  }
}

export class ZappInvocationError extends ZappError {
  readonly permission?: string;
  readonly service?: string;
  readonly method?: string;
  readonly errorType?: string;
  readonly details?: unknown;

  constructor(payload: BridgeErrorPayload) {
    super(payload);
    this.name = "ZappInvocationError";
    this.permission = payload.permission;
    this.service = payload.service;
    this.method = payload.method;
    this.errorType = payload.errorType;
    this.details = payload.details;
  }
}

export class PermissionDeniedError extends ZappError {
  readonly permission: string;

  constructor(permission: string, message?: string) {
    super({
      code: "PERMISSION_DENIED",
      message: message ?? (
        `[zapp] permission denied: "${permission}" — add it to ` +
        "`security.permissions` in zapp.config.ts"
      ),
      permission,
    });
    this.name = "PermissionDeniedError";
    this.permission = permission;
  }
}

type BridgeErrorFactory = (payload: BridgeErrorPayload) => ZappError;
const bridgeErrorFactories = new Map<string, BridgeErrorFactory>();

/** @internal Register the public error for a feature-specific bridge code. */
export function registerBridgeErrorFactory(
  code: string,
  factory: BridgeErrorFactory,
): void {
  bridgeErrorFactories.set(code, factory);
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

export function errorFromBridgePayload(payload: string): Error {
  if (payload.startsWith("PERMISSION_DENIED:")) {
    return new PermissionDeniedError(
      payload.slice("PERMISSION_DENIED:".length),
    );
  }
  try {
    const parsed = record(JSON.parse(payload));
    if (
      parsed
      && typeof parsed.code === "string"
      && typeof parsed.message === "string"
    ) {
      if (
        parsed.code === "PERMISSION_DENIED"
        && typeof parsed.permission === "string"
      ) {
        return new PermissionDeniedError(parsed.permission, parsed.message);
      }
      const normalized: BridgeErrorPayload = {
        code: parsed.code,
        message: parsed.message,
        ...(typeof parsed.permission === "string" && parsed.permission.length > 0
          ? { permission: parsed.permission }
          : {}),
        ...(typeof parsed.operation === "string" && parsed.operation.length > 0
          ? { operation: parsed.operation }
          : {}),
        ...(typeof parsed.windowId === "string" && parsed.windowId.length > 0
          ? { windowId: parsed.windowId }
          : {}),
        ...(typeof parsed.service === "string" && parsed.service.length > 0
          ? { service: parsed.service }
          : {}),
        ...(typeof parsed.method === "string" && parsed.method.length > 0
          ? { method: parsed.method }
          : {}),
        ...(typeof parsed.errorType === "string" && parsed.errorType.length > 0
          ? { errorType: parsed.errorType }
          : {}),
        ...(typeof parsed.details === "string" && parsed.details.length > 0
          ? { details: (() => {
            try { return JSON.parse(parsed.details as string); }
            catch { return parsed.details; }
          })() }
          : {}),
      };
      const factory = bridgeErrorFactories.get(normalized.code);
      return factory ? factory(normalized) : new ZappInvocationError(normalized);
    }
  } catch {}
  return new Error(payload);
}

// The WebView bootstrap runs before application modules. Registering this
// factory lets native failures become the public runtime Error subclasses once
// an application imports any Zapp runtime surface. The bootstrap retains a
// descriptive structural fallback for responses arriving even earlier.
(globalThis as any)[ERROR_FACTORY_KEY] = errorFromBridgePayload;
