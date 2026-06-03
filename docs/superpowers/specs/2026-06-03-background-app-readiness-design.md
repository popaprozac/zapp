# Background-app readiness (macOS) — design

**Date:** 2026-06-03
**Branch:** `feat/background-app-readiness` (to be created)
**Surfaced by:** the macOS feature-matrix audit (2026-06-03). macOS is broad and mature; the real gaps cluster in "production / lifecycle table-stakes." This spec takes the **Tier A** cluster **minus auto-update** (auto-update is backlogged while core features are built out) and adds the `setFocus` gap the user surfaced.

## Overview

Four small, thematically-unified features that make Zapp viable for the wedge profile — menu-bar / background / sync-engine apps (Linear/Granola/Raycast-shaped). All live in the app/lifecycle code region and share the existing `zapp_app_dispatch` event plumbing, so they ship as **one branch** with per-feature commits.

1. **Power monitor** — sleep/wake + screen lock/unlock events.
2. **App-quit / run-in-background** — document the existing run-in-background knob; add a cancelable `BEFORE_QUIT` quit guard.
3. **Auto-launch** — login-item register/query via `SMAppService`.
4. **`setFocus`** — raise a window *and* pull the app to the foreground.

### Design decisions (locked during brainstorming)

- **Q1 — quit/run-in-bg shape:** config knob (already exists) **+** app-level cancelable `BEFORE_QUIT` guard.
- **Q2 — auto-launch floor:** `SMAppService` behind `@available(macOS 13, *)`; graceful no-op returning `false` on macOS 12. **No** app-floor change, **no** helper bundle.
- **Q3 — power-monitor scope:** sleep/wake **+** screen lock/unlock now (all observer-based, no extra framework). IOKit AC/battery + Low Power Mode = **deferred follow-up**.
- **Q4 — platform scope:** macOS-only implementation; the runtime API exists on all platforms but **no-ops / returns `false`** on iOS/Windows (portable user code). Windows real impl → #167. iOS not aliased.
- **Q5 — testing:** pure-TS seams get `bun test`; native verified by build + manual hello-world smoke matrix.

---

## 1. Shared foundation — five new app events

Extend the existing app-event taxonomy. App-event IDs are offset from `ZAPP_APP_EVENT_BASE` (100); `108` (`THEME_CHANGED`) is the last used. Add:

| ID  | `AppEvent` enum | JS event name        |
|-----|-----------------|----------------------|
| 109 | `WILL_SLEEP`      | `app:will-sleep`       |
| 110 | `DID_WAKE`        | `app:did-wake`         |
| 111 | `SCREEN_LOCKED`   | `app:screen-locked`    |
| 112 | `SCREEN_UNLOCKED` | `app:screen-unlocked`  |
| 113 | `BEFORE_QUIT`     | `app:before-quit`      |

**Touch points:**
- `runtime/events.ts` — add the five `AppEvent` enum members, the `APP_EVENT_NAMES` entries, and widen the `AppEvents` string-union type.
- `native/app/app_events.zc` — add the five `case` mappings to the id→`js_name` switch (lines ~88–94). The three-layer fan-out (native callbacks → workers → webviews) then delivers them for free, so a headless sync worker can subscribe to `app:did-wake` with zero extra wiring.
- Native event-ID `#define`s (`ZAPP_EVENT_APP_WILL_SLEEP = 109`, …) added alongside the existing `ZAPP_EVENT_APP_*` defines.

**Payloads:** empty `{}` for all five (matching `reopen`/`active`).

**Note on `BEFORE_QUIT`:** it rides the dispatch fan-out *as a notification*, but the actual quit *gating* is separate logic in `applicationShouldTerminate:` (section 3b). Dispatch tells listeners "a quit was requested"; the guard flag decides whether termination proceeds.

---

## 2. Power monitor (sleep/wake + lock/unlock)

Pure events — **no new `App` methods**. `App.on(AppEvent.DID_WAKE, …)` works through the existing `Events` bus.

**Native (`native/platform/darwin/platform.m`):** register observers in `applicationDidFinishLaunching`, tear down in `applicationWillTerminate` (mirrors the existing `effectiveAppearance` KVO cleanup so there's no dangling observer at shutdown):

- `[[NSWorkspace sharedWorkspace] notificationCenter]`:
  - `NSWorkspaceWillSleepNotification` → `zapp_app_dispatch(109, "{}")`
  - `NSWorkspaceDidWakeNotification` → `zapp_app_dispatch(110, "{}")`
- `[NSDistributedNotificationCenter defaultCenter]`:
  - `com.apple.screenIsLocked` → `zapp_app_dispatch(111, "{}")`
  - `com.apple.screenIsUnlocked` → `zapp_app_dispatch(112, "{}")`

No extra frameworks (`NSWorkspace` is AppKit; `NSDistributedNotificationCenter` is Foundation). All four are observer-based; no polling, no run-loop sources.

**Deferred (explicit follow-up, not this cycle):** AC/battery power-source and Low Power Mode. Those come from **IOKit** (`IOPSNotificationCreateRunLoopSource`) + `NSProcessInfo.isLowPowerModeEnabled` — a different framework and run-loop-source model. Tracked as its own task.

---

## 3. App-quit / run-in-background

### 3a. Run-in-background (already exists — document it)

The control already ships: `applicationShouldTerminateAfterLastWindowClosed` on the native `AppConfig` (`native/app/app.zc:301`), honored by the macOS delegate (`platform.m:49`) and read on every platform via `app_get_bootstrap_application_should_terminate_after_last_window_closed()`. **hello-world already sets it `false`** (`hello-world/zapp/app.zc:117`) — i.e. closing the last window keeps the app alive (the menu-bar pattern).

**No new `zapp.config.ts` field.** The `AppConfig` is a literal constructed in the app's own `app.zc`; adding a parallel config field would create a second source of truth feeding the same native flag. Instead:
- **Document** `applicationShouldTerminateAfterLastWindowClosed` in `api-reference.md` as *the* run-in-background knob, with the menu-bar-app recipe (set `false`, hide the dock icon via `Dock.hideIcon()`, surface a `Tray`).
- This honors the native-first stance ("configuring in `app.zc` is fine") established in the build-manifest cycle.

**Deferred (noted, not built):** if JS-first discoverability of this flag becomes a real pain, a `zapp.config.ts` alias that injects into the generated config is a trivial follow-up.

### 3b. `BEFORE_QUIT` quit guard (new)

Modeled on the **existing window close-guard idiom** for consistency (`WindowHandle.setCloseGuard`).

**Runtime API (`runtime/app.ts`):**
```ts
App.setQuitGuard(enabled: boolean): void
App.quit(opts?: { force?: boolean }): void   // extends today's App.quit()
```

**Semantics:**
- `App.quit()` routes to native, which calls `[NSApp terminate:]` → triggers `applicationShouldTerminate:`.
- `applicationShouldTerminate:` checks a `zapp_quit_guard_enabled` flag:
  - **guard armed** → dispatch `AppEvent.BEFORE_QUIT` and return `NSTerminateCancel` (quit is cancelled).
  - **guard not armed** (default) → return `NSTerminateNow` (today's behavior — fully backward compatible).
- The app's `BEFORE_QUIT` handler runs its async "unsaved changes?" dialog, then calls `App.quit({ force: true })` to actually terminate. `force` sets a one-shot `zapp_force_quit` flag so `applicationShouldTerminate:` returns `NSTerminateNow` even with the guard armed.

**Why cancel-then-reissue, not `NSTerminateLater`:** it matches `setCloseGuard` exactly (the close button / Cmd-W fire `CLOSE` but don't close; the app calls `close()` to proceed) and avoids the `NSTerminateLater` footgun where forgetting to call `replyToApplicationShouldTerminate:` hangs the app mid-quit.

**Touch points:** `runtime/app.ts` (API), `native/app/router.zc` (route the `setQuitGuard` t:4 action + extend the `app:quit` handler with the `force` flag), `native/platform/darwin/platform.m` (`applicationShouldTerminate:` implementation + the two static flags).

---

## 4. Auto-launch (login item)

Runtime-only — auto-launch is a settings-screen toggle, not build-time config.

**Runtime API (`runtime/app.ts`):**
```ts
App.setLoginItem(enabled: boolean): Promise<boolean>   // returns success
App.getLoginItemEnabled(): Promise<boolean>
```

These return values, so they use the **request/response invoke path** (the same mechanism `Clipboard`/`Dialog` use to get a value back across the bridge), not the fire-and-forget t:4 path.

**Native:** `darwin_set_login_item(bool) -> bool` / `darwin_get_login_item() -> bool` backed by `SMAppService.mainApp` (`registerAndReturnError:` / `unregister`; `status == SMAppServiceStatusEnabled`) behind `@available(macOS 13, *)`. On macOS 12 both no-op and return `false`. Links **`ServiceManagement`** (add to the macOS platform frameworks).

**Parity:** iOS/Windows return `false`.

---

## 5. `setFocus`

**Runtime API:**
```ts
WindowHandle.setFocus(): void   // runtime/window.ts — raise window + activate app
App.activate(): void            // runtime/app.ts — activate app, no specific window (tray summon)
```

Both fire-and-forget (t:4). Native:
- `darwin_window_focus(handle)` → `[window makeKeyAndOrderFront:nil]` **+** `[NSApp activateIgnoringOtherApps:YES]`. The second call is the gap-closer: `makeKeyAndOrderFront` alone only raises *within* the app — `activateIgnoringOtherApps:` is what brings a background/menu-bar app to the foreground over whatever app is currently frontmost (the global-shortcut / tray-click "summon" case). The idiom already exists in `tray.m`/`dock.m`.
- `darwin_app_activate()` → `[NSApp activateIgnoringOtherApps:YES]` only.

**Touch points:** `runtime/window.ts` (`setFocus` via `windowAction`), `runtime/app.ts` (`activate` via `appAction`), `native/app/router.zc` (route both actions), `native/platform/darwin/window.m` (`darwin_window_focus`) + `platform.m`/`dock.m` neighbor for `darwin_app_activate`.

**Parity:** iOS no-op (single window, OS-managed foreground); Windows → #167.

---

## 6. Cross-cutting

### Parity / degradation (Q4-A)
All runtime symbols exist on every platform. Native impls are macOS-only:
- Power events never fire on iOS/Windows (no observers registered there).
- `setFocus` / `App.activate` no-op on iOS; Windows → #167.
- `setLoginItem` / `getLoginItemEnabled` return `false` on iOS/Windows.
- Quit guard + `BEFORE_QUIT`: macOS-only; the guard flag is simply never consulted on other platforms.

### Testing (Q5-A)
- **`bun test`:** the `AppEvent` enum ↔ event-name mapping in `events.ts` (the five new IDs map to the right `app:*` names; `eventName()` round-trips).
- **Native — hello-world manual smoke matrix:**
  1. **Auto-launch:** `App.setLoginItem(true)` → appears in System Settings ▸ General ▸ Login Items; `getLoginItemEnabled()` returns `true`; `setLoginItem(false)` removes it.
  2. **Sleep/wake:** `pmset sleepnow` (or lid close) → `app:did-wake` fires on resume; a headless worker subscriber also receives it.
  3. **Lock/unlock:** `⌃⌘Q` (lock) → `app:screen-locked`; unlock → `app:screen-unlocked`.
  4. **Quit guard:** with guard armed, Cmd-Q shows the app's confirm dialog and does *not* quit on Cancel; `App.quit({force:true})` quits.
  5. **`setFocus`:** bring another app frontmost, then trigger `setFocus` from a tray click / global shortcut → the Zapp window comes to the front over the other app.

### Docs
- `docs/api-reference.md`: new `AppEvent`s; `App.setLoginItem`/`getLoginItemEnabled`; `App.setQuitGuard`/`App.quit({force})`; `App.activate`; `WindowHandle.setFocus`; the `applicationShouldTerminateAfterLastWindowClosed` run-in-background knob + menu-bar-app recipe.
- hello-world: a small demo wiring (e.g. a tray-summoned window using `setFocus`, a quit guard, a `did-wake` log).

### Native-first order (per feature)
C primitive → Zen-C method → router → TS runtime → docs (the established sequence).

---

## Non-goals

- **Auto-update** (backlogged; decision spike already done in #164).
- **IOKit power-source / Low Power Mode** (deferred follow-up; different framework).
- **Windows implementations** (the #167 parity track).
- **iOS lifecycle aliasing** (its background/foreground model is separate and already covered by `app:active`/`app:inactive`).
- **A `zapp.config.ts` mirror for run-in-background** (the native `app.zc` field already covers it; trivial to add later if wanted).
- **Launch-hidden login-item option** (`SMAppService` doesn't cleanly support the legacy "start hidden" flag; out of scope).

## Related

- [[project_logging_verbosity_cycle]] / [[project_build_manifest_cycle]] — recent native-first cycles; same C→Zen-C→router→runtime→docs pattern and verify-by-smoke convention.
- [[feedback_native_first_implementation]] — the per-feature ordering this follows.
- [[project_gap_auto_update]] — the deferred Tier-A sibling.
- [[reference_unusernotificationcenter_bundle_guard]] / [[reference_wkwebview_teardown]] — prior `platform.m`/delegate-area work.
- The macOS feature-matrix audit (this session) — the source ranking that produced this scope.
