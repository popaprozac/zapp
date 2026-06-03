# Power-source + Low-Power-Mode events (#282) — design

**Date:** 2026-06-03
**Branch:** `feat/power-state-events`
**Surfaced by:** the deferred Q3-C of the background-app-readiness cycle. That cycle shipped sleep/wake + screen lock/unlock (`NSWorkspace`/`NSDistributedNotificationCenter`, AppEvent IDs 109–112). This adds the AC/battery power-source + Low Power Mode signals, which come from a different mechanism (IOKit run-loop source on macOS; `UIDevice` on iOS) — letting sync engines defer heavy work on battery or in Low Power Mode.

## Decisions (locked during brainstorming)

- **Q1 — API model:** unified `POWER_STATE_CHANGED` event **+** a synchronous `App.getPowerState()` getter (mirrors `App.getTheme()`). Not Electron-style split transition events.
- **Q2 — state shape + firing:** `{ source, lowPowerMode, percent, charging }`; the event fires **only on `source` or `lowPowerMode` transitions**, never on battery-percentage drift. `percent` is a snapshot in the payload and live via the getter.
- **Q3 — platform scope:** **macOS + iOS, fully** (IOKit on macOS, `UIDevice` battery + `NSProcessInfo` low-power on iOS). Windows inert (→ #167).

## 1. State object + getter

```ts
interface PowerState {
  source: "ac" | "battery";
  lowPowerMode: boolean;
  percent: number | null;   // 0–100; null on a battery-less desktop Mac or when unknown
  charging: boolean;
}

App.getPowerState(): PowerState
```

`getPowerState()` mirrors `App.getTheme()`: a runtime-cached value seeded at startup from the bootstrap config (native computes the initial state and injects it the same way `theme` is injected), refreshed on every `app:power-state-changed` event. **Worker caveat** identical to theme: workers don't receive bootstrap config, so the cached value is the default until the first event arrives (native dispatches app events to workers via the existing fan-out).

**Unknown / inert default:** `{ source: "ac", lowPowerMode: false, percent: null, charging: false }` — "no known power constraint," so apps never throttle on missing data (Windows, or before the first read).

## 2. New event

`AppEvent.POWER_STATE_CHANGED = 114` → `"app:power-state-changed"`. Payload = the full `PowerState` JSON.

**Transition-only firing.** The OS notifications (IOKit / `UIDevice` battery) fire on *every* power-source change, including each percentage tick. The native handler recomputes the full state, compares `source` and `lowPowerMode` against the last-dispatched values, and dispatches `POWER_STATE_CHANGED` **only when one of those two changed**. A percentage-only change updates the cached state (so the getter is live) but does **not** dispatch. This keeps the event quiet.

## 3. Native — macOS (`native/platform/darwin/platform.m` + IOKit)

- **Link IOKit:** add `//> macos: framework: IOKit` in `generatePlatformConfig` (`cli/src/build-config.ts`), alongside the existing framework lines.
- **`darwin_get_power_state(void) -> const char*`** (returns a JSON string `{"source":"…","lowPowerMode":bool,"percent":N|null,"charging":bool}`):
  - `IOPSCopyPowerSourcesInfo()` → `IOPSCopyPowerSourcesList()` → for the first battery source, `IOPSGetPowerSourceDescription()`. Read `kIOPSPowerSourceStateKey` (`kIOPSACPowerValue` → `"ac"`, else `"battery"`), `kIOPSIsChargingKey`, `kIOPSCurrentCapacityKey` / `kIOPSMaxCapacityKey` → `percent = round(current/max*100)`.
  - **No battery source** (desktop Mac): `source = "ac"`, `percent = null`, `charging = false`.
  - `lowPowerMode = NSProcessInfo.processInfo.isLowPowerModeEnabled` (macOS 12+; our floor is 12.0).
  - Static buffer like `darwin_get_theme` (caller copies before next call), or heap-dup — match the existing pattern in the file.
- **Registration** in `applicationDidFinishLaunching`:
  - `IOPSNotificationCreateRunLoopSource(callback, context)` → `CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode)`. The C callback recomputes state and dispatches `POWER_STATE_CHANGED` only on a `source`/`lowPowerMode` transition (compares against file-static last-dispatched values).
  - `NSProcessInfoPowerStateDidChangeNotification` observer on `[NSNotificationCenter defaultCenter]` → same recompute+maybe-dispatch (covers Low Power Mode toggles, which IOPS may not surface).
- **Teardown** in `applicationWillTerminate`: `CFRunLoopRemoveSource` + `CFRelease` the source; the blanket `removeObserver:self` already added for the other observers covers the NSProcessInfo one.
- **Seed** initial state into the bootstrap config (same injection path as `theme`) so the webview getter is correct on first read.

## 4. Native — iOS (`native/platform/ios/platform.m` + UIDevice + NSProcessInfo)

- `UIDevice.currentDevice.batteryMonitoringEnabled = YES` at startup (required for `batteryState`/`batteryLevel`).
- **`darwin_get_power_state(void) -> const char*`** (iOS definition — same symbol name as macOS, so the iOS symbol-parity lint is satisfied):
  - `source`: `batteryState == UIDeviceBatteryStateCharging || …Full` → `"ac"`; `…Unplugged` → `"battery"`; `…Unknown` → `"ac"` (safe default).
  - `percent`: `batteryLevel >= 0 ? round(batteryLevel*100) : null` (`batteryLevel` is `-1` when unknown).
  - `charging`: `batteryState == UIDeviceBatteryStateCharging`.
  - `lowPowerMode`: `NSProcessInfo.processInfo.isLowPowerModeEnabled` (same API as macOS).
- **Registration:** observe `UIDeviceBatteryStateDidChangeNotification` + `NSProcessInfoPowerStateDidChangeNotification` → recompute + dispatch on `source`/`lowPowerMode` transition. (`UIDeviceBatteryLevelDidChangeNotification` updates the cache only — no dispatch.)
- Seed bootstrap config like macOS.

## 5. Runtime + event wiring

- `runtime/events.ts`: add `AppEvent.POWER_STATE_CHANGED = 114`, the `APP_EVENT_NAMES` entry `"app:power-state-changed"`, and widen the `AppEvents` union.
- `native/app/app_events.zc`: add `case 114: js_name = "app:power-state-changed"; break;`.
- Both `platform.m` files: add the `#define ZAPP_EVENT_APP_POWER_STATE_CHANGED 114` macro (in the same `#ifndef` block as the others, darwin + ios, for parity).
- `runtime/app.ts`: the `PowerState` interface (exported), `getPowerState()` (cached value seeded from bootstrap config + refreshed by an `Events.on("app:power-state-changed", …)` subscription at module load, exactly like `_theme`).

## 6. Windows

Inert. `getPowerState()` returns the unknown/inert default; the event never fires. `darwin_get_power_state` is Apple-only (defined in `darwin/` + `ios/`); no Windows symbol is needed because the runtime simply uses the cached default when no bootstrap power state and no events arrive. Real Windows power monitoring (`GetSystemPowerStatus` / `WM_POWERBROADCAST`) is part of the #167 Windows track.

## 7. Testing

- **`bun test`:** extend `runtime/events.test.ts` to assert `eventName(AppEvent.POWER_STATE_CHANGED) === "app:power-state-changed"`.
- **Symbol-parity lint:** `cli/src/ios-platform-parity.test.ts` (shipped in #281) automatically covers `darwin_get_power_state` — it's referenced from `.zc` and must be defined in **both** `darwin/` and `ios/` (which the B scope provides). No new test needed; it just has to stay green.
- **Build:** macOS `bun run build` → `[zapp] build complete:`, **and** (per the #281 convention, since this touches `native/`) `bun run build --platform ios-simulator` → `[zapp] build complete:`.
- **Manual smoke (macOS):** unplug/replug power → `app:power-state-changed` with `source` flip + correct `charging`; toggle Low Power Mode (System Settings ▸ Battery) → event with `lowPowerMode` flip; `App.getPowerState()` returns live values; a headless worker subscriber also receives the event.
- **Manual smoke (iOS):** Low Power Mode toggle on a device (the Simulator doesn't model battery well — note device-only). `getPowerState()` returns sane values.

## 8. Docs

`docs/api-reference.md`: document `AppEvent.POWER_STATE_CHANGED`, the `PowerState` interface, and `App.getPowerState()` with a battery-aware-throttling example (defer a heavy sync when `source === "battery"` or `lowPowerMode`). Note iOS support and the Windows-inert/`#167` status. Cross-reference the existing power-monitor events (sleep/wake, lock/unlock).

## Non-goals

- **Time-to-empty / time-to-full** — macOS reports these as `-1` ("calculating") too often to be useful (Q2-C, rejected).
- **Split transition events** (`on-ac`/`on-battery`) — the unified state + getter is the chosen model (Q1).
- **Windows implementation** — #167.
- **Per-percentage-tick events** — deliberately suppressed; use the getter for live percent.
- **Thermal state / `thermalState`** — out of scope; a separate signal if ever wanted.

## Related

- [[project_background_app_readiness_cycle]] — the parent cycle (sleep/wake + lock/unlock); this is its deferred Q3-C.
- [[feedback_verify_native_build]] — the macOS-build + parity-lint + ios-sim-build verification rule this follows.
- `cli/src/ios-platform-parity.test.ts` (#281) — auto-covers the `darwin_get_power_state` parity.
- #167 — Windows power monitoring.
