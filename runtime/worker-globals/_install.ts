// Marker the bare worker bootstrap (`bootstrap/bare-worker.ts`) stamps
// on the placeholder `fetch` / `WebSocket` / etc. it installs as a
// fallback. When a real shim later runs (via `workerModules` →
// auto-prepended import), it should overwrite the placeholder rather
// than respect it. Without this, the placeholder's "fetch is not
// available" thrower stays in place and `fetch(...)` blows up even
// though bare-fetch IS installed and linked.
const PLACEHOLDER_MARKER = "__zappPlaceholder";

// Internal helper: bind a value as a global if (a) the slot isn't
// already occupied with a real value (browser webview / older Bare
// may already have provided it) and (b) we actually got a non-null
// value. Used by every per-API install file in this directory so
// "missing module" / "already present" both fall through cleanly.
//
// We use Object.defineProperty rather than a plain assignment because
// some engines (notably JSC under strict mode) treat unconfigured
// global slots as read-only — defineProperty bypasses that. We also
// explicitly overwrite the bare-worker bootstrap's placeholder
// throwers when we see them — they exist only to surface a useful
// error when the user forgot to install + import, and lose to a
// real install.
export function bindGlobal(name: string, value: unknown): void {
  if (value == null) return;
  const current = (globalThis as any)[name];
  const isPlaceholder = typeof current === "function" && (current as any)[PLACEHOLDER_MARKER] === true;
  if (current !== undefined && !isPlaceholder) return;
  try {
    Object.defineProperty(globalThis, name, {
      value, writable: true, configurable: true, enumerable: false,
    });
  } catch {
    try { (globalThis as any)[name] = value; } catch {}
  }
}

// Synchronously load a bare-* module without letting the bundler trace
// the specifier statically. We hide the specifier behind a variable
// (and a Function constructor for the ones that REALLY need to escape
// rolldown's static analysis) so missing modules produce a clean
// `null` rather than a "cannot resolve" build error in user projects.
//
// Why sync, not async:
// - `await import(...)` at module top-level produces top-level await
//   in the bundled worker script. JSC's `JSEvaluateScript` (which
//   bare-jsc / legacy jsc.m use to load worker scripts) runs in
//   *script* context where top-level await is a SyntaxError. QuickJS
//   under txiki accepts it, but bare-jsc breaks. Synchronous
//   `require` is available in every Bare runtime (provided by
//   bare-module) and avoids the parse-time error entirely.
// - The Function-constructor escape is the only call shape reliably
//   invisible to both Vite/Rolldown's static-analysis AND TypeScript
//   — both honor `(0, eval)` / `new Function(...)` opacity.
export function tryRequire(spec: string): any | null {
  try {
    const requirer = new Function("s", "return require(s)");
    return requirer(spec);
  } catch {
    return null;
  }
}
