# Per-platform `webEngine` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `webEngine` be declared per build target (`webEngine: { macos: "chromium", windows: "system" }`), reusing the existing `PlatformValue<T>` convention; the plain string stays valid as an all-platforms default.

**Architecture:** Widen `webEngine` to `PlatformValue<WebEngine>` in `cli/src/config.ts`. `resolveWebEngine(config, target)` becomes a pure per-platform resolver; `platformSupportsChromium(target)` (macOS-only today) + a pure `resolveWebEngineForBuild(config, target)` do the "chromium on an unsupported platform → downgrade to system" decision (unit-testable). The one build-gate call site (`native.ts`) reads the effective engine and emits the warn. Docs get the cost model.

**Tech Stack:** TypeScript (Bun), `bun:test`.

## Global Constraints

- Branch `feat/per-platform-webengine` (off `feat/nim-native`). **NO merge to `feat/nim-native` without explicit ask** (Windows handoff).
- Backward-compatible: the plain-string `webEngine: "chromium"` must keep meaning "all platforms."
- **Zero change** to the macOS CEF path, the gated build, or the `system` byte-identical guarantee.
- Non-goals: no runtime `Platform.webEngine` API; no CEF-on-Windows/Linux *build* (config surface only — `chromium` still only compiles on macOS).
- Per-file `git add`; pre-existing unrelated WIP stays UNSTAGED. Commit trailer EXACTLY:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
  ```
- Always Bun, never Node. Model: Sonnet (mechanical from complete briefs).

## File Structure

```
cli/src/config.ts        # T1: WebEngine type, webEngine widening, resolvePlatformScalar,
                         #     resolveWebEngine(config,target), platformSupportsChromium(target),
                         #     resolveWebEngineForBuild(config,target), validateWebEngine widening
cli/src/config.test.ts   # T1: update existing resolveWebEngine tests + add per-platform tests
cli/src/native.ts        # T2: the one useCef gate — read effective engine + emit warn
cli/src/build-config.ts  # T2: fix one stale `resolveWebEngine(config)` comment
cli/src/cef.ts           # T2: fix one stale `resolveWebEngine(config)` comment
docs/api-reference.md    # T2: webEngine section — per-platform form + cost table + nuance
```

---

### Task 1 (Sonnet, TDD): config core — types, resolvers, predicate, validation

**Files:**
- Modify: `cli/src/config.ts` (`webEngine` field ~:649; `PlatformValue<T>` ~:769; `resolveWebEngine` ~:886; `validateWebEngine` ~:866)
- Test: `cli/src/config.test.ts` (existing `resolveWebEngine` tests ~:64-70)

**Interfaces:**
- Consumes: existing `PlatformValue<T>` (`config.ts:769` = `T | { macos?: T; ios?: T; windows?: T }`), `BuildTarget` (imported type-only from `./native`), `resolvePlatformValue`'s target-collapse pattern (`config.ts:806`).
- Produces (for T2):
  - `export type WebEngine = "system" | "chromium"`
  - `webEngine?: PlatformValue<WebEngine>` (was `"system" | "chromium"`)
  - `export function resolveWebEngine(config: Pick<ZappConfig,"webEngine">, target: BuildTarget): WebEngine` — PURE
  - `export function platformSupportsChromium(target: BuildTarget): boolean`
  - `export function resolveWebEngineForBuild(config: Pick<ZappConfig,"webEngine">, target: BuildTarget): { engine: WebEngine; downgraded: boolean }` — PURE (no stderr)
  - `validateWebEngine(engine?: ZappConfig["webEngine"]): void` — widened, pure shape/value check

- [ ] **Step 1 — RED: write the failing tests.** In `cli/src/config.test.ts`, REPLACE the two existing `resolveWebEngine` tests (~:64-70, which call `resolveWebEngine(config)` with no target) and ADD the new cases:

```ts
import {
  resolveNative, validateNative, validateWebEngine, resolveWebEngine,
  platformSupportsChromium, resolveWebEngineForBuild,
} from "./config";

// --- resolveWebEngine: string form applies to every target ---
test("resolveWebEngine string form applies to all targets", () => {
  expect(resolveWebEngine({ webEngine: "chromium" } as any, "macos")).toBe("chromium");
  expect(resolveWebEngine({ webEngine: "chromium" } as any, "windows")).toBe("chromium");
  expect(resolveWebEngine({ webEngine: "system" } as any, "macos")).toBe("system");
});

test("resolveWebEngine defaults to system when unset", () => {
  expect(resolveWebEngine({} as any, "macos")).toBe("system");
  expect(resolveWebEngine({} as any, "windows")).toBe("system");
});

// --- resolveWebEngine: map form resolves per platform, missing key => system ---
test("resolveWebEngine map form resolves per platform", () => {
  const cfg = { webEngine: { macos: "chromium", windows: "system" } } as any;
  expect(resolveWebEngine(cfg, "macos")).toBe("chromium");
  expect(resolveWebEngine(cfg, "windows")).toBe("system");
});

test("resolveWebEngine map form: missing key defaults to system", () => {
  const cfg = { webEngine: { macos: "chromium" } } as any; // no windows/ios key
  expect(resolveWebEngine(cfg, "windows")).toBe("system");
  expect(resolveWebEngine(cfg, "ios-simulator")).toBe("system");
});

test("resolveWebEngine collapses both iOS subtargets to the ios key", () => {
  const cfg = { webEngine: { ios: "chromium" } } as any;
  expect(resolveWebEngine(cfg, "ios-simulator")).toBe("chromium");
  expect(resolveWebEngine(cfg, "ios-device")).toBe("chromium");
});

// --- platformSupportsChromium: macOS only today ---
test("platformSupportsChromium is macOS-only today", () => {
  expect(platformSupportsChromium("macos")).toBe(true);
  expect(platformSupportsChromium("windows")).toBe(false);
  expect(platformSupportsChromium("ios-simulator")).toBe(false);
  expect(platformSupportsChromium("ios-device")).toBe(false);
});

// --- resolveWebEngineForBuild: downgrade chromium -> system on unsupported target ---
test("resolveWebEngineForBuild keeps chromium on macOS", () => {
  expect(resolveWebEngineForBuild({ webEngine: "chromium" } as any, "macos"))
    .toEqual({ engine: "chromium", downgraded: false });
});

test("resolveWebEngineForBuild downgrades chromium to system on an unsupported target", () => {
  expect(resolveWebEngineForBuild({ webEngine: { windows: "chromium" } } as any, "windows"))
    .toEqual({ engine: "system", downgraded: true });
});

test("resolveWebEngineForBuild leaves system alone everywhere", () => {
  expect(resolveWebEngineForBuild({} as any, "windows"))
    .toEqual({ engine: "system", downgraded: false });
});

// --- validateWebEngine: accepts string + map, throws on garbage ---
test("validateWebEngine accepts string and map forms", () => {
  expect(() => validateWebEngine("chromium")).not.toThrow();
  expect(() => validateWebEngine("system")).not.toThrow();
  expect(() => validateWebEngine(undefined)).not.toThrow();
  expect(() => validateWebEngine({ macos: "chromium", windows: "system" } as any)).not.toThrow();
});

test("validateWebEngine throws on a garbage value in either form", () => {
  expect(() => validateWebEngine("blink" as any)).toThrow(/webEngine/);
  expect(() => validateWebEngine({ windows: "blink" } as any)).toThrow(/webEngine/);
});
```

- [ ] **Step 2 — run tests, verify RED.** Run: `bun test cli/src/config.test.ts`. Expected: FAIL (`platformSupportsChromium`/`resolveWebEngineForBuild` not exported; `resolveWebEngine` arity/behavior mismatch).

- [ ] **Step 3 — GREEN: widen the type.** In `cli/src/config.ts`, add the `WebEngine` type near `PlatformValue` (after ~:775) and change the field (~:649):

```ts
export type WebEngine = "system" | "chromium";
```
```ts
  // was: webEngine?: "system" | "chromium";
  webEngine?: PlatformValue<WebEngine>;
```
(Keep the existing JSDoc above the field; update the type line + a sentence noting the per-platform map form — see Step 7.)

- [ ] **Step 4 — GREEN: scalar resolver + `resolveWebEngine` + predicate.** In `cli/src/config.ts`, replace the current `resolveWebEngine` (~:886) with the scalar sibling of `resolvePlatformValue` plus the two new exports. Mirror `resolveNative`'s target-collapse (`:806`):

```ts
// Scalar sibling of resolvePlatformValue (which is array-typed / []-defaulted):
// a bare value applies to every platform; a map is looked up per key.
function resolvePlatformScalar<T>(
  v: PlatformValue<T> | undefined,
  key: "macos" | "ios" | "windows",
  fallback: T,
): T {
  if (v === undefined) return fallback;
  if (typeof v === "object" && v !== null) {
    return (v as { macos?: T; ios?: T; windows?: T })[key] ?? fallback;
  }
  return v as T; // bare value → all platforms
}

// Collapse BuildTarget → the narrow per-platform key (both iOS subtargets → "ios"),
// identical to resolveNative's collapse.
function webEnginePlatformKey(target: BuildTarget): "macos" | "ios" | "windows" {
  return target === "macos" ? "macos"
    : (target === "ios-simulator" || target === "ios-device") ? "ios"
    : "windows";
}

// Resolve the requested webEngine for a target. PURE. Default "system".
export function resolveWebEngine(
  config: Pick<ZappConfig, "webEngine">,
  target: BuildTarget,
): WebEngine {
  return resolvePlatformScalar<WebEngine>(config.webEngine, webEnginePlatformKey(target), "system");
}

// Which targets have a real CEF build today. macOS-only for now (Windows uses
// WebView2 = Chromium; Linux CEF is future).
export function platformSupportsChromium(target: BuildTarget): boolean {
  return target === "macos";
}

// The engine a build should actually use, plus whether "chromium" was downgraded
// to "system" because the target has no CEF build. PURE (no logging — the caller
// emits the warning so this stays unit-testable).
export function resolveWebEngineForBuild(
  config: Pick<ZappConfig, "webEngine">,
  target: BuildTarget,
): { engine: WebEngine; downgraded: boolean } {
  const requested = resolveWebEngine(config, target);
  if (requested === "chromium" && !platformSupportsChromium(target)) {
    return { engine: "system", downgraded: true };
  }
  return { engine: requested, downgraded: false };
}
```
(If `BuildTarget` is not already imported in `config.ts`, add a type-only import from `./native` — the file already references it in `resolveNative`, so it is available.)

- [ ] **Step 5 — GREEN: widen `validateWebEngine` to pure shape/value checking.** Replace the current body (~:866) — drop the target-specific early-access `process.stderr.write` (that notice moves to build time in T2); keep only structural validation:

```ts
// Validate the webEngine field shape/values. Pure: throws on a bad value in
// either the string or the per-platform map form. Target-specific notices
// (early-access, unsupported-platform) are emitted at build time (native.ts),
// where the build target is known.
export function validateWebEngine(engine?: ZappConfig["webEngine"]): void {
  if (engine === undefined) return;
  const checkValue = (v: unknown, where: string) => {
    if (v === undefined) return;
    if (v !== "system" && v !== "chromium") {
      throw new Error(
        `[zapp] webEngine${where}: "${String(v)}" is not a valid value. Use "system" or "chromium".`,
      );
    }
  };
  if (typeof engine === "object" && engine !== null) {
    const m = engine as { macos?: unknown; ios?: unknown; windows?: unknown };
    checkValue(m.macos, ".macos");
    checkValue(m.ios, ".ios");
    checkValue(m.windows, ".windows");
  } else {
    checkValue(engine, "");
  }
}
```
The existing `validateWebEngine(config.webEngine)` call in `loadConfig` (~:956) is unchanged (still validates shape at load).

- [ ] **Step 6 — run tests, verify GREEN.** Run: `bun test cli/src/config.test.ts` → PASS. Then `bunx tsc --noEmit` (in `cli/`) → clean.

- [ ] **Step 7 — update the field JSDoc.** Above `webEngine` (~:635-648), update the doc block: note the value may be a string (all platforms) OR a per-platform map `{ macos, ios, windows }` (missing key ⇒ `"system"`); keep the "~289 MB / early-access / macOS-only chromium build" facts. Keep it to the existing comment's length.

- [ ] **Step 8 — Commit** (`config.ts` + `config.test.ts`, per-file).

---

### Task 2 (Sonnet): wire the build gate + fix stale comments + docs

**Files:**
- Modify: `cli/src/native.ts` (the `useCef` gate ~:1221-1222)
- Modify: `cli/src/build-config.ts` (stale comment ~:333), `cli/src/cef.ts` (stale comment ~:2)
- Modify: `docs/api-reference.md` (`webEngine` section)

**Interfaces:**
- Consumes (from T1): `resolveWebEngineForBuild(config, target)`, `platformSupportsChromium(target)`.

- [ ] **Step 1 — wire the gate.** In `cli/src/native.ts`, replace the current dynamic import + `useCef` line (~:1221-1222):

```ts
  const { resolveWebEngineForBuild, platformSupportsChromium } = await import("./config");
  const { engine, downgraded } = resolveWebEngineForBuild(config, target);
  if (downgraded) {
    const hint = target === "windows" ? "WebView2 = Chromium" : "the system webview";
    process.stderr.write(
      `[zapp] webEngine "chromium" is not yet available on ${target}; using system (${hint}).\n`,
    );
  } else if (engine === "chromium" && platformSupportsChromium(target)) {
    process.stderr.write(`[zapp] webEngine:"chromium" is early-access (macOS)\n`);
  }
  const useCef = engine === "chromium" && platformSupportsChromium(target);
```
(`useCef` semantics are unchanged for the shipped macOS path: chromium+macOS → CEF; system/other → WKWebView/system. The `if (useCef)` / `if (useCef && cefRoot)` blocks below at ~:1224 / ~:1338 are untouched.)

- [ ] **Step 2 — fix the two stale comments.** They reference the old single-arg signature:
  - `cli/src/build-config.ts:333` — change `resolveWebEngine(config)` → `resolveWebEngine(config, target)`.
  - `cli/src/cef.ts:2` — change `resolveWebEngine(config)` → `resolveWebEngine(config, target)`.

- [ ] **Step 3 — docs.** In `docs/api-reference.md`, update the `webEngine` section to document the per-platform form and lead with the cost model:

````markdown
### `webEngine`

Which web engine renders your windows. A string applies to every platform; a
per-platform map scopes it (a missing platform key defaults to `"system"`):

```ts
webEngine: "chromium"                              // all platforms
webEngine: { macos: "chromium", windows: "system" } // per-platform
```

- **`"system"`** *(default)* — the OS webview. **On Windows this is WebView2,
  which is Chromium** (Edge runtime) — so Windows already renders with Chromium
  at zero extra size. macOS = WKWebView (Safari), Linux = WebKitGTK.
- **`"chromium"`** *(macOS only, early-access)* — bundles CEF for
  Chrome-consistent rendering where the system webview isn't Chromium. Adds
  **~289 MB** to the `.app` (the strictly-opt-in cost).

**Bundle CEF only where the system webview isn't Chromium** — macOS today
(Linux later). On Windows, `"system"` (WebView2) already gives Chromium.

If `"chromium"` is requested for a platform with no CEF build yet (Windows /
Linux today), the build **warns and falls back to `"system"`**.

> WebView2 is evergreen (floats with the user's installed Edge runtime) while
> CEF is pinned to the bundled version. `windows: "chromium"` is a *future*
> option for byte-pinned rendering — not needed for Chromium consistency.
````
(Match the file's existing heading style; if a `webEngine` section already exists, replace it.)

- [ ] **Step 4 — full gates.** Run: `bunx tsc --noEmit` (in `cli/`) → clean; `bun test cli/src` → all pass (the T1 suite + the existing 113). Confirm no `native/` or build-output change (this task is CLI + docs only).

- [ ] **Step 5 — Commit** (`native.ts`, then `build-config.ts` + `cef.ts`, then `docs/api-reference.md`, per-file).

---

## Self-Review

**Spec coverage:** §1 config type → T1 Step 3; §2 `resolveWebEngine(config,target)` pure → T1 Step 4; §3 `platformSupportsChromium` + downgrade + warn → `resolveWebEngineForBuild` (T1 Step 4, pure/testable) + the stderr warn (T2 Step 1); §4 `validateWebEngine` pure widening → T1 Step 5; §5 docs → T2 Step 3; §6 non-goals honored (no runtime API, no CEF-on-Windows build, macOS path untouched). Every spec section maps to a step.

**Placeholder scan:** every code step shows complete code; the warn uses `process.stderr.write` (matching the existing webEngine-warning idiom at `config.ts:873`, not an unverified `clog` API). No TBD/TODO.

**Type consistency:** `WebEngine`, `resolveWebEngine(config, target)`, `platformSupportsChromium(target)`, `resolveWebEngineForBuild(config, target): { engine, downgraded }`, `webEnginePlatformKey`, `resolvePlatformScalar` used identically across T1 (definition + tests) and T2 (consumption). The `{ engine, downgraded }` shape matches between the resolver, the tests, and the native.ts destructure.

**Byte-identical guarantee:** T2 keeps `useCef` semantics identical for the shipped macOS path (chromium+macOS → CEF; everything else → system), so `system` builds and the macOS CEF path are unchanged — verified by "no native/build-output change" in T2 Step 4.
