/**
 * Runtime platform/form-factor/environment for conditional app logic.
 *
 * Reads the bootstrap manifest injected natively — by the webview's WKUserScript,
 * or, in a worker, published by `bootstrap/worker.ts` from the native `__zappBridge`
 * (os/formFactor/env). Source: `globalThis[Symbol.for("zapp.bootstrapConfig")]`:
 *   - os  ← permissions.platform (build-time target)
 *   - formFactor ← top-level formFactor (runtime; iOS device idiom; "desktop" on desktop)
 *   - env ← top-level env (build-time dev/prod)
 * Safe defaults when absent (SSR/tests/older native): os "macos", formFactor
 * "desktop", env "prod".
 */
export type PlatformName = "macos" | "ios" | "windows";
export type FormFactor = "desktop" | "phone" | "tablet";
export type AppEnv = "dev" | "prod";

function cfg(): any {
  return (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
}
function readOS(): PlatformName {
  const p = cfg()?.permissions?.platform;
  return p === "ios" || p === "windows" ? p : "macos";
}
function readFormFactor(): FormFactor {
  const f = cfg()?.formFactor;
  return f === "phone" || f === "tablet" ? f : "desktop";
}
function readEnv(): AppEnv {
  return cfg()?.env === "dev" ? "dev" : "prod";
}

export const Platform = {
  current(): PlatformName { return readOS(); },
  get os(): PlatformName { return readOS(); },
  get isMacOS(): boolean { return readOS() === "macos"; },
  get isIOS(): boolean { return readOS() === "ios"; },
  get isWindows(): boolean { return readOS() === "windows"; },
  get formFactor(): FormFactor { return readFormFactor(); },
  get isPhone(): boolean { return readFormFactor() === "phone"; },
  get isTablet(): boolean { return readFormFactor() === "tablet"; },
  get isDesktop(): boolean { return readFormFactor() === "desktop"; },
  get env(): AppEnv { return readEnv(); },
  get isDev(): boolean { return readEnv() === "dev"; },
  get isProd(): boolean { return readEnv() === "prod"; },
};
