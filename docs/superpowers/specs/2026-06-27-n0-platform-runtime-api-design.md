# N0 — Platform Runtime API — Design

**Date:** 2026-06-27
**Branch:** `feat/ios-native-nav` (commit directly; UNMERGED)
**Program:** first cycle of the iOS Native Navigation program (`docs/superpowers/specs/2026-06-27-ios-native-navigation-program-design.md`). Task #749.
**Status:** Approved (design) → writing-plans → SDD.

## Goal

Round out the runtime `Platform` export into the complete top-level conditional-logic surface app code uses to branch by platform — OS, **form factor** (iPhone vs iPad vs desktop), and **environment** (dev vs prod). It's the enabler for the program's opt-in conditionals and for the kitchen-sink showcases of everything built downstream. Native-first: every value originates on the native side. Back-compat: the existing `Platform.isIOS`/`isMacOS`/`isWindows`/`current()` keep working unchanged.

## Current state (from exploration)

- `runtime/platform.ts` reads `globalThis[Symbol.for("zapp.bootstrapConfig")].permissions.platform` (`"macos"|"ios"|"windows"`), **baked at build time** per target (`cli/src/build-config.ts:82`, `cli/src/native.ts:67`). Exposes `current()` + `isMacOS`/`isIOS`/`isWindows`.
- **Form factor (iPhone vs iPad) does not exist anywhere** — and it is inherently **runtime** (one iOS build runs on both; iPad form factor is decided on-device).
- **Env** is known natively (`zapp_build_is_dev()`, `build-config.ts:50`) but **not surfaced into the webview** bootstrapConfig.
- The bootstrapConfig carrier (`native/platform/darwin/webview.m` + `native/platform/ios/webview.m`) injects the per-webview config (incl. `permissions.platform`) — the single injection point to extend.
- Workers (`bootstrap/worker.ts`) have **no** bootstrapConfig — so `Platform` is webview-only today.

## API surface (`runtime/platform.ts`, fully back-compat)

```ts
export type PlatformName = "macos" | "ios" | "windows";          // unchanged
export type FormFactor   = "desktop" | "phone" | "tablet";
export type AppEnv       = "dev" | "prod";

Platform.os: PlatformName            // build-time (existing source)
Platform.formFactor: FormFactor      // runtime (iOS idiom; "desktop" on macOS/Windows)
Platform.env: AppEnv                 // build-time (dev/prod)

Platform.current(): PlatformName     // existing — returns os; kept
Platform.isMacOS / isIOS / isWindows // existing — kept
Platform.isPhone / isTablet / isDesktop   // new (derived from formFactor)
Platform.isDev / isProd              // new (derived from env)
```

Both strings (for `switch`) and booleans (the ergonomic `if (Platform.isIOS)` / `if (Platform.isPhone)` app code reaches for).

## Decisions

- **iPad = `os: "ios"` + `formFactor: "tablet"`** — NOT a separate `"ipados"` os. The build target is iOS (one build runs both); iPad-ness is the runtime form-factor axis. (`PlatformName` is unchanged.)
- **Both string + boolean accessors** (booleans derived from the strings; no separate source of truth).
- **Defaults** (absent config — SSR/tests/older native): `os` → `"macos"` (existing behavior), `formFactor` → `"desktop"`, `env` → `"prod"` (safe default — never accidentally expose dev affordances).

## Value sources (native-first)

- **`os`** — unchanged: `bootstrapConfig.permissions.platform` (build-time).
- **`env`** — the native carrier injects `bootstrapConfig.env` from `zapp_build_is_dev()` (build-time) at webview-create.
- **`formFactor`** — the **one new runtime value**: the native carrier injects `bootstrapConfig.formFactor` at webview-create — iOS reads `UIUserInterfaceIdiom` (`.phone` → `"phone"`, `.pad` → `"tablet"`); macOS/Windows → `"desktop"`.

Both new fields ride the **existing bootstrapConfig carrier** (`darwin/webview.m` + `ios/webview.m`) — the same path that already injects `permissions.platform`. `runtime/platform.ts` reads `os` from `permissions.platform` (unchanged) and `formFactor`/`env` from the new top-level `bootstrapConfig.formFactor`/`bootstrapConfig.env`.

## Components

| File | Change |
|---|---|
| `native/platform/darwin/webview.m` | inject `formFactor: "desktop"` + `env` (from `zapp_build_is_dev()`) into the per-webview bootstrapConfig. |
| `native/platform/ios/webview.m` | inject `formFactor` from `UIUserInterfaceIdiom` (`.pad`→tablet, else phone) + `env`. |
| `runtime/platform.ts` | `FormFactor`/`AppEnv` types; `formFactor`/`env` getters + `isPhone`/`isTablet`/`isDesktop`/`isDev`/`isProd`; read new fields with safe defaults; keep existing surface. |
| `runtime/platform.test.ts` | unit tests: os/formFactor/env + all booleans resolve from a mocked bootstrapConfig; defaults when absent. |
| `docs/api-reference.md` | document the rounded-out `Platform` surface (os/formFactor/env + booleans), the value sources, and the iPad=`ios`+`tablet` model. |

(Windows parity: `native/platform/windows/*` injects `formFactor:"desktop"` + `env` too, matching darwin — kept in scope so Windows isn't left behind, but iOS/macOS are the smoke targets.)

## Out of scope / deferred

- **Workers** — `Platform` in a worker context is **deferred to N2** (workers have no bootstrapConfig; os/env bake trivially into the worker bundle then, form-factor is the runtime piece). Pinned in the program doc's N2 scope.
- A distinct `"ipados"` os value.
- Size-class / multitasking-window granularity beyond phone/tablet/desktop (iPad multi-window is a separate future program).

## Testing & gates

- **`runtime/platform.test.ts`** unit tests (TDD): mock `bootstrapConfig`, assert os/formFactor/env strings + every boolean + the absent-config defaults.
- Gates: `bun run check`; `bun test cli/src`; `bun run test:native`; iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`); macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`).
- **Human smoke:** macOS reports `os:"macos"`, `formFactor:"desktop"`, `env` correct for dev vs prod build; iOS reports `os:"ios"` + `formFactor:"phone"` on iPhone / `"tablet"` on iPad. (A tiny kitchen-sink readout or console log suffices — full showcase section comes with later cycles.)

## Constraints

Branch `feat/ios-native-nav` (commit on it directly), UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun; native-first parity (native source → bootstrapConfig carrier → runtime → docs, same PR); NO iOS simulator interaction in-session (build-only gates + human smoke); macOS is the parity reference; docs updated in the same PR.
