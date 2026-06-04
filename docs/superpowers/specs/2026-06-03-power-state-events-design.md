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

`getPowerState()` mirrors `App.getTheme()`: a runtime-cached value seeded at startup from the bootstrap config (native computes the initial state and injects it the same way `theme` is injected), refreshed on **both** the `app:power-state-changed` and `app:battery-level-changed` events. Because the level event fires on every percent/charging change, **`getPowerState()` is effectively live for all four fields** — read it whenever you choose, at your own cadence. **Worker caveat** identical to theme: workers don't receive bootstrap config, so the cached value is the default until the first event arrives (native dispatches app events to workers via the existing fan-out).

**Unknown / inert default:** `{ source: "ac", lowPowerMode: false, percent: null, charging: false }` — "no known power constraint," so apps never throttle on missing data (Windows, or before the first read).

## 2. Two events — quiet transitions + a battery-level feed

The OS notifications (IOKit / `UIDevice`) fire on *every* power change, including each percent tick. The native handler reads the full state once, compares each signal against the cache, and fires **up to two** events so the noisy battery-level feed never clutters the rare source/low-power transitions:

- **`AppEvent.POWER_STATE_CHANGED = 114`** → `"app:power-state-changed"` — fires **only when `source` or `lowPowerMode` changes** (the quiet "should I throttle?" trigger). Payload = the full `PowerState`.
- **`AppEvent.BATTERY_LEVEL_CHANGED = 115`** → `"app:battery-level-changed"` — fires when **`percent` or `charging`** changes (≈ per 1%, minutes apart — not a firehose). Payload = the full `PowerState`. This is the battery-gauge feed; it also keeps the `getPowerState()` cache current so the getter stays live.

A single notification can fire both (e.g. unplug → `source` flips AND `charging`/`percent` semantics change). The runtime updates its `PowerState` cache from both event names.

## 3. Native — macOS (`native/platform/darwin/platform.m` + IOKit)

- **Link IOKit:** add `//> macos: framework: IOKit` in `generatePlatformConfig` (`cli/src/build-config.ts`), alongside the existing framework lines.
- **`darwin_get_power_state(void) -> const char*`** (returns a JSON string `{"source":"…","lowPowerMode":bool,"percent":N|null,"charging":bool}`):
  - `IOPSCopyPowerSourcesInfo()` → `IOPSCopyPowerSourcesList()` → for the first battery source, `IOPSGetPowerSourceDescription()`. Read `kIOPSPowerSourceStateKey` (`kIOPSACPowerValue` → `"ac"`, else `"battery"`), `kIOPSIsChargingKey`, `kIOPSCurrentCapacityKey` / `kIOPSMaxCapacityKey` → `percent = round(current/max*100)`.
  - **No battery source** (desktop Mac): `source = "ac"`, `percent = null`, `charging = false`.
  - `lowPowerMode = NSProcessInfo.processInfo.isLowPowerModeEnabled` (macOS 12+; our floor is 12.0).
  - Static buffer like `darwin_get_theme` (caller copies before next call), or heap-dup — match the existing pattern in the file.
- **Registration** in `applicationDidFinishLaunching`:
  - `IOPSNotificationCreateRunLoopSource(callback, context)` → `CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode)`. The C callback reads all four signals once and compares against the file-static cache: dispatches `POWER_STATE_CHANGED` if `source`/`lowPowerMode` changed, and `BATTERY_LEVEL_CHANGED` if `percent`/`charging` changed (either, both, or neither).
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
- **Registration:** observe `UIDeviceBatteryStateDidChangeNotification`, `UIDeviceBatteryLevelDidChangeNotification`, and `NSProcessInfoPowerStateDidChangeNotification` → each reads all four signals once and dispatches `POWER_STATE_CHANGED` on a `source`/`lowPowerMode` change and `BATTERY_LEVEL_CHANGED` on a `percent`/`charging` change.
- Seed bootstrap config like macOS.

## 5. Runtime + event wiring

- `runtime/events.ts`: add `AppEvent.POWER_STATE_CHANGED = 114` and `AppEvent.BATTERY_LEVEL_CHANGED = 115`, the `APP_EVENT_NAMES` entries `"app:power-state-changed"` / `"app:battery-level-changed"`, and widen the `AppEvents` union.
- `native/app/app_events.zc`: add `case 114: …"app:power-state-changed"…` and `case 115: …"app:battery-level-changed"…`.
- Both `platform.m` files: add `#define ZAPP_EVENT_APP_POWER_STATE_CHANGED 114` and `#define ZAPP_EVENT_APP_BATTERY_LEVEL_CHANGED 115` (same `#ifndef` block, darwin + ios, for parity).
- `runtime/app.ts`: the `PowerState` interface (exported), `getPowerState()` (cached value seeded from bootstrap config + refreshed by `Events.on(...)` subscriptions for **both** `"app:power-state-changed"` and `"app:battery-level-changed"` at module load, like `_theme`).

## 6. Windows

Inert. `getPowerState()` returns the unknown/inert default; the event never fires. `darwin_get_power_state` is Apple-only (defined in `darwin/` + `ios/`); no Windows symbol is needed because the runtime simply uses the cached default when no bootstrap power state and no events arrive. Real Windows power monitoring (`GetSystemPowerStatus` / `WM_POWERBROADCAST`) is part of the #167 Windows track.

## 7. Testing

- **`bun test`:** extend `runtime/events.test.ts` to assert `eventName(AppEvent.POWER_STATE_CHANGED) === "app:power-state-changed"`.
- **Symbol-parity lint:** does NOT cover this — `darwin_get_power_state` is called only from `.m` files (bootstrap seed + observers), not from any `.zc`, and `cli/src/ios-platform-parity.test.ts` scans `.zc` for `darwin_*` references. The lint just has to stay green (no new obligation). iOS parity is verified by the ios-simulator build below, which actually compiles+links `ios/platform.m`+`ios/webview.m`.
- **Build:** macOS `bun run build` → `[zapp] build complete:`, **and** (per the #281 convention, since this touches `native/`) `bun run build --platform ios-simulator` → `[zapp] build complete:` — this is the real iOS gate (each platform's `.m` files call their own `darwin_get_power_state`).
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
