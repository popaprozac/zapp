# iOS A5 — App Events + Demo Surfaces — Design

**Status:** approved (brainstorm), pending plan
**Program:** iOS/iPadOS A+B+C parity sweep (see `docs/superpowers/specs/2026-06-26-ios-ipados-program-matrix.md`). Fifth correctness sub-cycle of Tier A (A1 + A2 + A4 SHIPPED; A3 deferred). Next after A5: survey the native-toolbar landscape (SP-4 + #643). Goal of the sweep: bring iOS up to feature-rich macOS, section by section, each sub-cycle ending in a kitchen-sink human-smoke gate.
**Branch:** `feat/nim-native` (UNMERGED). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Per-file `git add`. Bun.

## Global Constraints

- Branch `feat/nim-native`, kept UNMERGED. Trailer exactly `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Per-file `git add` only — never `git add -A`/`.` (pre-existing unrelated WIP under assets/, benchmarks/, vendor/, spikes/ stays unstaged).
- Bun, never Node. NO iOS simulator interaction in-session — build-only gates + human smoke on the user's device/sim.
- iOS build = arm64, min iOS 15.0; sim functional / device compile-only. Default iOS engine = zjs.
- **macOS is the parity reference** — `native/platform/darwin/*` app-event dispatch is NOT changed. The only cross-platform change is the shared worker-bootstrap map fix (which also benefits macOS).
- Native-first parity: restore the existing `AppEvent` contract on iOS; no new public API.

## Scope

Three independent pieces (one cycle):

1. **Native iOS app-event dispatch gaps** — dispatch `THEME_CHANGED`, `SCREEN_LOCKED`/`SCREEN_UNLOCKED`, and `SCREENS_CHANGED` on iOS via their UIKit equivalents (macOS already dispatches all three; iOS does not).
2. **Worker app-event map fix** (cross-platform bug found during exploration) — the worker bootstrap's id→name map covers only event ids 100–108, so 109–116 (incl. `POWER_STATE_CHANGED` 114 / `BATTERY_LEVEL_CHANGED` 115, lock, screens) are silently dropped for **workers on every platform**. This is why power reads as "invisible" in a worker context.
3. **Kitchen-sink demo surfaces** — (a) an "App Events" section (live `App.on(...)` log + `App.getPowerState()` readout) that makes the app events verifiable; (b) a `<zapp-webview>` demo section (the element is shipped; no demo exists).

## Why these, why now

A1/A2/A4 shipped. A5 closes the app-event parity gaps and — critically — adds the **validation surfaces** the 2026-06-26 grounding flagged as missing ("power IS dispatched but invisible; no demo surface for app/system events; no `<zapp-webview>` demo"). Without a surface, these events can't be smoke-verified; with one, they become part of the "try out Zapp" kitchen-sink. The native gaps are small, deterministic UIKit subscriptions with direct macOS parity.

## Reference: the AppEvent taxonomy (verified)

- Runtime enum `runtime/events.ts:72-91` (ids 100–116); `APP_EVENT_NAMES` map `events.ts:118-134`. Relevant ids: `REOPEN`=104, `OPEN_URL`=105, `DID_BECOME_ACTIVE`=106, `DID_RESIGN_ACTIVE`=107, `THEME_CHANGED`=108, `WILL_SLEEP`=109, `DID_WAKE`=110, `SCREEN_LOCKED`=111, `SCREEN_UNLOCKED`=112, `BEFORE_QUIT`=113, `POWER_STATE_CHANGED`=114, `BATTERY_LEVEL_CHANGED`=115, `SCREENS_CHANGED`=116.
- Native dispatch: `zapp_app_dispatch(event_id, data)` (`native/app/app_events.zc:42`) — 3-layer fan-out (native cbs / worker broadcast / webview `_onEvent`).
- iOS dispatch sites today: `native/platform/ios/platform.m` `ZappAppDelegate` (~:190) — STARTED/OPEN_URL/DID_BECOME_ACTIVE/DID_RESIGN_ACTIVE/SHUTDOWN; power/battery via `zapp_power_on_change()` (`platform.m:98-99`, `batteryMonitoringEnabled = YES` at `:200`); notifications via `ios/notification.m:88`. `darwin_get_theme()` exists at `ios/platform.m:111-114`.
- macOS reference: `native/platform/darwin/platform.m` — THEME via `NSApp` `effectiveAppearance` KVO (~:283-291); lock/unlock via `NSDistributedNotificationCenter` `com.apple.screenIs{Locked,Unlocked}` (~:334-335); screens via `NSApplicationDidChangeScreenParametersNotification` (~:336); REOPEN via `applicationShouldHandleReopen:` (~:316-319).
- Runtime subscribe surface: `App.on(AppEvent, handler)` (`runtime/app.ts:87-90`); power cache + `App.getPowerState()` (`runtime/app.ts:59-83`); webview delivery `_onEvent` (`bootstrap/webview.ts:113-126`); worker delivery `_dispatchAppEvent` (`bootstrap/worker.ts:104-124`, the buggy map at `:105-111`).
- KS section registry: `kitchen-sink/src/sections/registry.ts:22-42`; a section is `{ id, label, render(host) }`; adding one = new file + one import + one array entry.
- `<zapp-webview>`: `ZappWebviewElement` exported `runtime/index.ts:21`, `customElements.define("zapp-webview", …)` `runtime/webview.ts:195-197`; iOS native panel in `ios/webview.m`.

## Architecture decisions

- **THEME_CHANGED dedup (the one nuance).** macOS fires once via an app-level `NSApp` appearance observer. iOS appearance changes arrive through *per-VC* `traitCollectionDidChange:`, so multiple windows would emit duplicate app-level events. Decision: detect per-VC but **dedup at the dispatch helper** — a file-static "last dispatched `userInterfaceStyle`" compared on each call; emit `THEME_CHANGED` only when it actually changed, and only when `[tc hasDifferentColorAppearanceComparedToTraitCollection:previous]`. The sidebar window already overrides `traitCollectionDidChange:` (`ios/sidebar.m`); the plain (no-sidebar) window's root VC must also detect the change (its content VC needs a `traitCollectionDidChange:` override) — both funnel through the deduped helper.
- **Lock/unlock = device-lock semantics.** Use `UIApplicationProtectedDataWillBecomeUnavailableNotification` → `SCREEN_LOCKED` and `…ProtectedDataDidBecomeAvailableNotification` → `SCREEN_UNLOCKED` (subscribed once in `ZappAppDelegate`). This matches macOS's screen-lock semantics (the device locking), not the app foreground/background transitions (already covered by `DID_RESIGN_ACTIVE`/`DID_BECOME_ACTIVE`). Note: protected-data notifications only fire on devices with a passcode set — documented, expected.
- **Worker-map fix = derive, don't re-hardcode.** Rebuild `_dispatchAppEvent`'s id→name lookup in `bootstrap/worker.ts` from the shared `APP_EVENT_NAMES` map (the same source the webview path uses) so the worker and webview event surfaces can't drift again. This fixes 109–116 for workers on all platforms.
- **REOPEN stays N/A on iOS.** No clean UIKit equivalent (it's a dock-click concept); `DID_BECOME_ACTIVE` already covers foreground returns. Documented, not synthesized.
- **Nim `AppEvent` enum (109–116) — out of scope.** `native/nim/app_events.nim` already handles those ids as raw integers (`:64-72`); extending the enum is cosmetic and not required for A5. Leave it.

## Items

### T1 — Native iOS app-event dispatch + worker-map fix

**Files:** `native/platform/ios/platform.m` (lock/unlock + screens subscriptions in `ZappAppDelegate`); `native/platform/ios/window.m` and/or `native/platform/ios/sidebar.m` (THEME_CHANGED detection in the content VC `traitCollectionDidChange:` paths + the deduped dispatch helper); `bootstrap/worker.ts` (`_dispatchAppEvent` map).

- **THEME_CHANGED (108):** add a small file-static deduped helper (`zapp_ios_dispatch_theme_if_changed()`) that reads `darwin_get_theme()`, compares to the last dispatched value, and calls `zapp_app_dispatch(<THEME_CHANGED id>, <theme json>)` only on change. Call it from the sidebar VC's existing `traitCollectionDidChange:` (`ios/sidebar.m`) **and** from the plain no-sidebar window's content VC (add a `traitCollectionDidChange:` override there), each guarded by `hasDifferentColorAppearanceComparedToTraitCollection:`. Use the same event-id constant the existing iOS dispatch sites use.
- **SCREEN_LOCKED (111) / SCREEN_UNLOCKED (112):** in `ZappAppDelegate` (`applicationDidFinishLaunching:`), observe `UIApplicationProtectedDataWillBecomeUnavailableNotification` → dispatch 111 and `…DidBecomeAvailableNotification` → dispatch 112.
- **SCREENS_CHANGED (116):** observe `UIScreenDidConnectNotification` + `UIScreenDidDisconnectNotification` → dispatch 116.
- **Worker-map fix:** in `bootstrap/worker.ts`, replace the hardcoded 100–108 subset in `_dispatchAppEvent` with a lookup derived from `APP_EVENT_NAMES` so all dispatched app-event ids resolve to a name (no silent drop for 109–116). Cross-platform.
- *Verify:* iOS build `[zapp] build complete:`; macOS build unchanged + green; `bun run check`; `bun test cli/src` + `bun run test:native` (no regressions). **Human smoke (iPhone + iPad):** dark-mode toggle → `THEME_CHANGED`; lock the device (passcode set) → `SCREEN_LOCKED`/`UNLOCKED`; (screens-changed only if an external display is available — otherwise verified by code review). Verified through the T2 section's log.

### T2 — Kitchen-sink "App Events" section

**Files:** `kitchen-sink/src/sections/app-events.ts` (new); `kitchen-sink/src/sections/registry.ts` (import + array entry).

- A `Section` whose `render` subscribes `App.on(...)` for `THEME_CHANGED`, `DID_BECOME_ACTIVE`, `DID_RESIGN_ACTIVE`, `SCREEN_LOCKED`, `SCREEN_UNLOCKED`, `SCREENS_CHANGED`, `POWER_STATE_CHANGED`, `BATTERY_LEVEL_CHANGED`, `REOPEN`, `OPEN_URL`, appending each to a scrolling live log (name + payload + timestamp), and shows a `App.getPowerState()` readout (refreshed on `POWER_STATE_CHANGED`/`BATTERY_LEVEL_CHANGED`). Return a cleanup that unsubscribes all. This is the surface that makes T1 + the already-wired power verifiable.
- *Verify:* `bun run check`; iOS + macOS build. **Human smoke:** events land in the log live on iPhone/iPad (and macOS shows the macOS-applicable ones).

### T3 — Kitchen-sink `<zapp-webview>` demo section

**Files:** `kitchen-sink/src/sections/embedded-webview.ts` (new); `kitchen-sink/src/sections/registry.ts` (import + array entry).

- A `Section` that mounts a `<zapp-webview>` loading a sample URL, with a small control row (set URL + reload). Demonstrates the shipped embedded-webview element. Independent of T1/T2; also exercises the macOS path.
- *Verify:* `bun run check`; iOS + macOS build. **Human smoke:** the embedded webview renders + navigates on iPhone/iPad + macOS.

## Non-goals / deferred

- **REOPEN on iOS** — N/A (no clean UIKit equivalent); documented, not synthesized.
- **WILL_SLEEP / DID_WAKE / BEFORE_QUIT on iOS** — intentionally N/A (no system sleep; quit-guard is a no-op stub).
- **macOS app-event dispatch changes** — none; macOS already dispatches all of these. The only shared change is the worker-map fix (a strict improvement on macOS too).
- **Nim `AppEvent` enum 109–116** — cosmetic; handled as raw ints already.
- **New public API** — none; A5 wires existing `AppEvent`s on iOS + adds demo surfaces.

## Verification (cycle gates)

- `bun run check` clean; `bun test cli/src` + `bun run test:native` green.
- iOS-sim build (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`) and macOS build (`bun run build` → `[zapp] build complete:`) both green.
- **Human smoke (iPhone + iPad):** T1 events appear in the T2 App Events log (theme on dark-mode toggle; lock/unlock on device lock; power live); T3 embedded webview renders + navigates. macOS regression check: app-events log still works; existing power/theme on macOS unaffected.

## Task shape (for the plan)

- **T1 — Native iOS app-event dispatch + worker-map fix** — native ObjC (`ios/platform.m`, `ios/window.m`/`sidebar.m`) + the `bootstrap/worker.ts` map. Verified by build + human smoke (via T2's log).
- **T2 — KS App Events section** — TS, 2-file registry add. Verified by build + smoke.
- **T3 — KS `<zapp-webview>` demo section** — TS, 2-file registry add. Verified by build + smoke.

(T1 → T2 ordering is natural — T2 is the smoke surface for T1 — but T3 is fully independent and may land in any order. Each task ends in its own human-smoke gate.)
