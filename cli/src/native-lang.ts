/**
 * Native build language gate.
 *
 * Nim is the DEFAULT native build on every target. `ZAPP_NATIVE_LANG=zc`
 * selects the legacy Zen-C implementation and `ZAPP_NATIVE_LANG=z` selects
 * the replacement Z core. Unknown values fail closed: silently compiling a
 * different native implementation makes performance and compatibility
 * evidence impossible to trust.
 *
 * This is the single source of truth: every place that chooses a native core must
 * route through here so the default can never go inconsistent across the
 * build / asset-emitter / dev / package paths.
 */
export type NativeLanguage = "nim" | "zc" | "z";

export function nativeLanguage(value = process.env.ZAPP_NATIVE_LANG): NativeLanguage {
  if (value === undefined || value === "" || value === "nim") return "nim";
  if (value === "zc" || value === "z") return value;
  throw new Error(
    `[zapp] unknown ZAPP_NATIVE_LANG=${JSON.stringify(value)}. Expected "nim", "zc", or "z".`,
  );
}
