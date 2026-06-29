# N2c — Platform (os/formFactor/env) in Workers — Design

**Date:** 2026-06-28
**Branch:** `feat/ios-native-nav` (commit directly; UNMERGED)
**Program:** iOS Native Navigation, cycle N2 (Router), sub-cycle **c** (the final N2 piece; deferred from N0). Program doc: `docs/superpowers/specs/2026-06-27-ios-native-navigation-program-design.md`. N0/N1/N2a/N2b shipped.
**Status:** Approved (design) → writing-plans → SDD.

## Goal

Make `@zappdev/runtime`'s `Platform` work correctly inside **worker** code, with **full parity** to the webview: `Platform.os`/`isMacOS`/`isIOS`/`isWindows`, `Platform.formFactor`/`isPhone`/`isTablet`/`isDesktop`, and `Platform.env`/`isDev`/`isProd`. Today a worker has no `bootstrapConfig`, so `Platform` falls back to its defaults (`"macos"`/`"desktop"`/`"prod"`) — wrong on iOS/Windows or a dev build. After N2c, `Platform` is honest in workers. Last N2 sub-cycle; after it, N2 (Router) is complete → N3 (iOS native routing).

## The gap

`runtime/platform.ts` reads `globalThis[Symbol.for("zapp.bootstrapConfig")]` — `os` ← `permissions.platform`, `formFactor` ← top-level `formFactor`, `env` ← top-level `env`, with safe defaults when absent. **Webviews** get this config from native via a `WKUserScript` at document-start (`darwin/ios webview.m`, N0): `{formFactor, env, permissions:<permissions_bootstrap_json()>}`. **Workers** get no such carrier — a worker is a JS bundle the engine evals (zjs/bare), no `WKUserScript` — so `cfg()` is `undefined` and every `Platform` getter returns its default.

## Mechanism (chosen): engine sets it on `__zappBridge`; `worker.ts` publishes

Native is the source of truth (native-first). Each worker engine, when it builds the per-worker native `__zappBridge`, sets the config; the worker bootstrap (which already runs in every worker and already reads `__zappBridge`) publishes it as the standard `bootstrapConfig` global. Mirrors the webview carrier (native supplies the config), is engine-agnostic at the JS seam, and needs **zero `platform.ts` change**.

Rejected alternatives: host-evals-a-prelude (per-engine C string-building/escaping); Vite bundle-bake (inverts native-first — the JS bundler would encode a native build fact). Also rejected: a new build-time `zapp_build_platform()` scalar + a partial `permissions:{platform}` — unnecessary (os already lives in `permissions_bootstrap_json()`), and a partial permissions object would half-configure the worker's runtime `Permissions` API.

## §1 — Carrier shape: a faithful webview mirror (zero `platform.ts` change)

`bootstrap/worker.ts`, right after `const bridge = (self as any).__zappBridge` (and its `if (!bridge) return` guard), publishes the **same** shape the webview's `WKUserScript` builds:

```js
globalThis[Symbol.for("zapp.bootstrapConfig")] = {
  permissions: JSON.parse(bridge.permissions || '{"platform":"macos","active":false,"allow":[]}'),
  formFactor:  bridge.formFactor || "desktop",
  env:         bridge.env || "prod",
};
```

- **os** comes from `permissions.platform` (no new accessor) — `platform.ts`'s `read()` is unchanged.
- The `|| default` fallbacks match `platform.ts`'s own defaults, so older/absent native degrades safely.
- Carrying the **full** permissions manifest (not a partial `{platform}`) means the worker's runtime `Permissions` API now reflects the real allow-list — a correctness bonus. Worker permission **enforcement** is unchanged (native engine gates, PERM cycle); this only makes the JS-side view honest. The webview's `bootstrapConfig.permissions` is an inlined object literal; the worker's is `JSON.parse`d from a string prop — same end shape.
- `Platform.isPhone`/`isTablet`/`isDesktop` are honest in workers — no caveat.

## §2 — Sources of the three values (engines)

`native/worker/engines/zjs.c` and `bare.c` (the two worker engines; confirm no third spawn path), when constructing the per-worker native `__zappBridge`, set three string properties — they already `extern` generated symbols like `zapp_worker_bootstrap_script`, so these link cleanly:

- `__zappBridge.permissions = permissions_bootstrap_json()` — the existing native accessor the webview already uses; contains `platform` (→ os), `active`, `allow`. (A constant generated JSON string; safe to read from the worker thread.)
- `__zappBridge.env = zapp_build_is_dev() ? "dev" : "prod"` — existing accessor.
- `__zappBridge.formFactor = zapp_form_factor()` — a **new** small native accessor → `"desktop"` | `"phone"` | `"tablet"`:
  - **macOS**: constant `"desktop"`.
  - **iOS**: device idiom captured **once at app launch** (main thread) into a process global — `.pad`→`"tablet"`, else `"phone"`. `zapp_form_factor()` returns the cached value, so it is cheap and thread-safe from a worker pthread.
  - Semantics: device **idiom**, not a window size-class — exactly right for a windowless worker (no Slide-Over/compact wrinkle); a worker on iPad reports `"tablet"`.

**Single source of truth for formFactor.** `webview.m` (darwin + iOS) currently computes formFactor inline in its config `WKUserScript`. It adopts `zapp_form_factor()` too, so webview and workers can't drift. `zapp_form_factor()` is defined to produce exactly the value `webview.m` produces today (iOS idiom / macOS `"desktop"`) — iOS webview behavior unchanged, covered by the iOS-compile gate + code-equivalence (no in-session iOS sim smoke). macOS webview formFactor stays `"desktop"`.

## §3 — Scope, components, testing, decomposition

**Files touched:**
- A native accessor `zapp_form_factor()` — darwin impl (`"desktop"`) + iOS impl (captured idiom) + the iOS launch-time capture site (app init).
- `native/worker/engines/zjs.c`, `native/worker/engines/bare.c` — set `permissions`/`formFactor`/`env` on `__zappBridge`.
- `native/platform/darwin/webview.m`, `native/platform/ios/webview.m` — adopt `zapp_form_factor()` for the config `WKUserScript`.
- `bootstrap/worker.ts` — publish the `bootstrapConfig` global.
- `runtime/platform.ts` — doc-comment only (note os/formFactor/env now carried into workers too).
- `runtime/platform.test.ts` — worker-shape config case.
- `docs/api-reference.md` — Platform-in-workers note.
- A kitchen-sink worker readout (`kitchen-sink/src/worker.ts` and/or the Workers section).

No CLI/codegen change (no new build-time accessor).

**Testing:**
- **T1 (TDD, bun):** `platform.test.ts` — a worker-shape `bootstrapConfig` `{permissions:{platform:"ios"}, formFactor:"phone", env:"dev"}` → `os="ios"`/`isIOS`, `formFactor="phone"`/`isPhone`, `env="dev"`/`isDev`; absent-config still defaults macos/desktop/prod. (This is the contract the native side fulfills; the engine/worker.ts wiring is proven by the T2 smoke.)
- **T2 macOS HUMAN SMOKE:** a worker logs `Platform.os` + `Platform.formFactor` + `Platform.env` → `os="macos"`, `formFactor="desktop"`, `env="dev"` under `bun run dev` (and `"prod"` in a built app). iOS compile stays green (idiom path via compile + code-equivalence, not sim smoke).
- Gates each task: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`); iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`). T1 also `bun test runtime/platform.test.ts`.

**Decomposition (each = SDD task, independently testable):**
- **T1 — native + bootstrap wiring (+ `platform.test.ts` worker-shape case):** `zapp_form_factor()` (darwin + iOS, launch-capture); `zjs.c` + `bare.c` set `permissions`/`formFactor`/`env` on `__zappBridge`; `webview.m` (darwin + iOS) adopt `zapp_form_factor()`; `worker.ts` publishes `bootstrapConfig`; `platform.test.ts` worker-shape case + `platform.ts` doc-comment. Gates incl. macOS build + iOS compile.
- **T2 — kitchen-sink worker `Platform` readout + docs + macOS human smoke.**

(Two tasks — the dropped CLI emitter collapsed the former T1/T2 into one native+bootstrap task.)

## Decisions (confirmed)

1. **Mechanism A** — engine sets the config on `__zappBridge`; `worker.ts` publishes. Native-first, engine-agnostic JS seam, zero `platform.ts` change.
2. **Faithful webview mirror** — carry the full `permissions_bootstrap_json()` (os comes from `permissions.platform`; no new build accessor; worker runtime `Permissions` becomes honest as a bonus) + `formFactor` + `env`.
3. **Full parity incl. formFactor** — workers get os + formFactor + env (no caveat); formFactor = device idiom (windowless-worker-correct).
4. **`zapp_form_factor()` is the single source** — `webview.m` adopts it too (dedup; included in N2c, not deferred).
5. **formFactor captured at launch** (main thread) → thread-safe worker reads.
6. **Demo + macOS smoke** — a worker logs the three values; macOS-provable; iOS compile-only.

## Out of scope / deferred

- Per-worker platform/permission overrides; any worker-side size-class notion (workers have no window — idiom only).
- N3 iOS native routing.
- The kitchen-sink-tsc gate gap (#763) — separate.

## Risks

1. **`zapp_form_factor()` thread-safety / iOS idiom read off-main** → mitigated by capturing the idiom once at launch (main thread) into a process global; the accessor returns the cached value. macOS is a constant.
2. **`webview.m` formFactor refactor on a no-iOS-smoke cycle** → `zapp_form_factor()` defined to produce the exact value webview.m produces today; iOS-compile gate + code-equivalence cover it; macOS webview formFactor stays `"desktop"`.
3. **Engine parity** — both zjs and bare must set the props (else a bare worker reports defaults); T1 covers both; confirm there is no third worker spawn path.
4. **Worker runtime `Permissions` now reflects the manifest** (it previously saw no config) → intentional improvement; enforcement is native + unchanged; the manifest is the same one the webview uses. Confirm no worker path relied on the empty-config behavior.

## Constraints

Branch `feat/ios-native-nav` (commit directly), UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun; native-first parity (native accessor + engines; mirror the webview carrier shape; `feedback_nim_zc_parity` — the Nim build is the default, keep any shared codegen in lockstep, though N2c adds no codegen); macOS is the testable reference; iOS must keep COMPILING; NO iOS simulator interaction in-session; worker-engine parity (zjs default + bare); NO git worktree, NO `git commit --amend`, NO merge. Gates: `bun run check`, `bun test cli/src`, `bun run test:native`, macOS build, iOS compile.
