/**
 * Native build language gate.
 *
 * Nim is the DEFAULT native build on every target. `ZAPP_NATIVE_LANG=zc`
 * opts out to the legacy Zen-C build — a transitional escape hatch (e.g. the
 * Windows path until the Nim-Windows sprint lands). Any other value (unset,
 * "nim", anything else) resolves to Nim, so the default is fail-open.
 *
 * This is the single source of truth: every place that chose zc-vs-nim must
 * route through here so the default can never go inconsistent across the
 * build / asset-emitter / dev / package paths.
 */
export function useNimNative(): boolean {
  return process.env.ZAPP_NATIVE_LANG !== "zc";
}
