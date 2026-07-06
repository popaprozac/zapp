# Per-platform `webEngine` config — design

**Date:** 2026-07-06
**Branch:** `feat/nim-native` (the Windows-handoff integration branch; CEF slice already merged at `2a00f51`)
**Type:** Config-surface feature (small, single-plan). Backward-compatible.
**Status:** design approved; pending spec review → writing-plans → SDD

## Goal

Let an app declare `webEngine` **per build target** — e.g. `webEngine: { macos: "chromium", windows: "system" }` — instead of one value for all platforms. The plain string form stays valid as an all-platforms default.

## Motivation (the cost model this encodes)

The point of `webEngine: "chromium"` (CEF, shipped on macOS) is **consistent Chromium rendering**. But the system webview *already is* Chromium on some platforms:

| Platform | System webview | Chromium consistency costs |
|---|---|---|
| **Windows** | WebView2 = **Chromium** (Edge runtime) | **$0 — `system` is already Chromium** |
| **macOS** | WKWebView (Safari) | +289 MB CEF |
| **Linux** (future) | WebKitGTK (varies) | +size CEF |

So the correct rule is: **bundle CEF only where the system webview isn't Chromium.** Per-platform `webEngine` lets the app state that directly, and makes the "Windows Chromium is free" fact explicit rather than folklore. It also directly shapes how the pending Windows port adopts CEF-vs-WebView2 (answer: WebView2, i.e. `system`).

## Current state

- `cli/src/config.ts`: `webEngine?: "system" | "chromium"` (single top-level string, `config.ts:649`).
- `resolveWebEngine(config)` (`config.ts:886`) — no platform arg; returns `"chromium"` iff `config.webEngine === "chromium"`, else `"system"`.
- `validateWebEngine(engine?)` (`config.ts:866`) — warns for `chromium` (macOS-only early-access), throws on unknown values.
- Consumed at one site: `cli/src/native.ts` — `useCef = resolveWebEngine(config) === "chromium" && target === "macos"`.
- **Precedent to reuse:** `PlatformValue<T>` (`config.ts:769`) = `T | { macos?: T; ios?: T; windows?: T }`, with `resolvePlatformValue<T>(v, key)` and the `resolveNative` target-collapse (`macos` / `ios-simulator`|`ios-device` → `ios` / else `windows`, `config.ts:806`).

## Design

### 1. Config type — reuse `PlatformValue<T>`

```ts
export type WebEngine = "system" | "chromium";
// in ZappConfig:
webEngine?: PlatformValue<WebEngine>;   // was: "system" | "chromium"
```

- **String form** (`webEngine: "chromium"`) → applies to all platforms (unchanged, backward-compatible).
- **Map form** (`webEngine: { macos: "chromium", windows: "system" }`) → per-platform; a **missing key ⇒ `"system"`** (the default).

This is the identical shape/semantics of `native.frameworks`/`linkFlags`/`sources`, so there is one config mental model, one type, and the same `macos`/`ios`/`windows` key vocabulary.

### 2. Resolver — `resolveWebEngine(config, target)` (pure)

Change the signature from `(config)` to `(config, target: BuildTarget)`. Keep it a **pure function with no side effects** (returns the raw resolved value — unit-testable without capturing stderr):

- Collapse `target → "macos" | "ios" | "windows"` exactly as `resolveNative` does (`ios-simulator`/`ios-device` → `ios`).
- String form → that value. Map form → `map[key] ?? "system"`.
- A scalar sibling of `resolvePlatformValue` (which is array-typed/`[]`-defaulted): either a small `resolvePlatformScalar<T>(v, key, fallback)` helper or inline the same collapse + lookup with a `"system"` fallback. Returns `WebEngine`.

### 3. Supported-platform downgrade + the warn (build-time)

A predicate `platformSupportsChromium(target): boolean` — **today `target === "macos"`** (the only platform with a CEF build). The build gate composes the pure resolution with the predicate:

```ts
const requested = resolveWebEngine(config, target);          // pure
const useCef = requested === "chromium" && platformSupportsChromium(target);
if (requested === "chromium" && !platformSupportsChromium(target)) {
  // warn + fall back to system (this build proceeds on the system webview)
  clog.warn(`webEngine "chromium" is not yet available on ${target}; ` +
            `using system (${target === "windows" ? "WebView2 = Chromium" : "system webview"}).`);
}
```

- `webEngine: { windows: "chromium" }` built for Windows today → warns, builds on WebView2. **This also closes the whole-branch-review Minor** where `chromium` on a non-macOS target fell back *silently* — now it's a loud warn.
- On macOS, `useCef` behaves exactly as it does today (chromium → CEF, system → WKWebView), so the macOS CEF path and its `system` byte-identical guarantee are unchanged.

The warn/downgrade lives at the gate (or a thin `resolveWebEngineForBuild` wrapper), NOT inside the pure `resolveWebEngine`, so the resolver stays side-effect-free and unit-testable.

### 4. Validation — `validateWebEngine` widens, becomes pure shape/value checking

- Accept the map form: each present value of `{ macos, ios, windows }` must be `"system"` or `"chromium"`; anything else throws with the existing clear message.
- The **target-specific notices** (early-access, unsupported-platform) move to build time (where `target` is known) — §3. `validateWebEngine` becomes a pure shape/value validator (throws on garbage, no target-dependent warnings).

### 5. Docs

`docs/api-reference.md` `webEngine` section:
- Document the per-platform map form alongside the string form.
- Lead with the **cost table** (above): Windows `system` *is* Chromium (WebView2) — set `chromium` only where the system webview isn't (macOS today; Linux later).
- Document the **warn + fall-back-to-system** behavior for `chromium` on a platform without a CEF build.
- Note the one nuance: WebView2 is **evergreen** (floats with the user's Edge runtime) vs CEF **pinned** (bundled version). So `windows: "chromium"` is a *future* option for byte-pinned rendering — **not** needed for consistency (WebView2 already gives Chromium, free).

### 6. Non-goals

- **No runtime API** (`Platform.webEngine`) — build-time only; YAGNI.
- **No CEF-on-Windows/Linux build** — this is purely the config surface + resolver + validation + docs. `chromium` still only actually *compiles* on macOS; other platforms warn+fall-back.
- **No change** to the macOS CEF path, the gated build, or the `system` byte-identical guarantee.

## Components / files

- `cli/src/config.ts` — `WebEngine` type + `webEngine: PlatformValue<WebEngine>` + `resolveWebEngine(config, target)` (pure) + `platformSupportsChromium(target)` + widened `validateWebEngine` (+ optional `resolvePlatformScalar` helper).
- `cli/src/native.ts` — the one `useCef` call site: pass `target`; add the warn+downgrade when chromium is requested for an unsupported target.
- `cli/src/config.test.ts` — unit tests (below).
- `docs/api-reference.md` — the `webEngine` section (§5).

## Testing

- `resolveWebEngine(config, target)`: string form applies to all targets; map form resolves per platform; missing key → `"system"`; `ios-simulator`/`ios-device` → the `ios` key.
- `platformSupportsChromium`: `"macos"` → true; `"windows"`/`ios-*` → false.
- `validateWebEngine`: accepts string + map with valid values; throws on a garbage value in either form.
- Warn + fall-back: chromium requested for an unsupported target → effective engine is `system` **and** a warning is emitted (stderr spy).
- Regression: existing `webEngine: "chromium"` (string) on macOS still resolves to CEF; `system`/unset unchanged.

## Error handling

- Garbage config values → `validateWebEngine` throws with a clear message (existing behavior, extended to the map form).
- `chromium` on an unsupported target → warn + fall back to `system` (build proceeds). No hard error (per decision).

## Scope

One file of real logic (`config.ts`) + one gate call site (`native.ts`) + tests + docs. Single implementation plan, no decomposition.
