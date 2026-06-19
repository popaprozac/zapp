/**
 * Runtime platform check for conditional app logic (e.g. rendering an in-page
 * sidebar toggle on iOS where there's no native toolbar button yet).
 *
 * Reads the platform baked into the per-webview bootstrap manifest
 * (`globalThis[Symbol.for("zapp.bootstrapConfig")].permissions.platform`) — the
 * same value `permissions.ts` reads. The native layer injects it target-correct
 * ("macos" | "ios" | "windows"); defaults to "macos" if absent (e.g. SSR/tests).
 */
export type PlatformName = "macos" | "ios" | "windows";

function read(): PlatformName {
  const p = (globalThis as any)[Symbol.for("zapp.bootstrapConfig")]?.permissions?.platform;
  return p === "ios" || p === "windows" ? p : "macos";
}

export const Platform = {
  current(): PlatformName { return read(); },
  get isMacOS(): boolean { return read() === "macos"; },
  get isIOS(): boolean { return read() === "ios"; },
  get isWindows(): boolean { return read() === "windows"; },
};
