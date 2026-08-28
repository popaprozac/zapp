const ERROR_FACTORY_KEY = Symbol.for("zapp.errorFactory");

export interface ZappErrorPayload {
  code: string;
  message: string;
  permission?: string;
}

export class ZappInvocationError extends Error {
  readonly code: string;
  readonly permission?: string;

  constructor(payload: ZappErrorPayload) {
    super(payload.message);
    this.name = "ZappInvocationError";
    this.code = payload.code;
    this.permission = payload.permission;
  }
}

export class PermissionDeniedError extends ZappInvocationError {
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
      return new ZappInvocationError({
        code: parsed.code,
        message: parsed.message,
        ...(typeof parsed.permission === "string" && parsed.permission.length > 0
          ? { permission: parsed.permission }
          : {}),
      });
    }
  } catch {}
  return new Error(payload);
}

// The WebView bootstrap runs before application modules. Registering this
// factory lets native failures become the public runtime Error subclasses once
// an application imports any Zapp runtime surface. The bootstrap retains a
// descriptive structural fallback for responses arriving even earlier.
(globalThis as any)[ERROR_FACTORY_KEY] = errorFromBridgePayload;
