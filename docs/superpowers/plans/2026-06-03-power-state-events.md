# Power-State Events Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `AppEvent.POWER_STATE_CHANGED` + `App.getPowerState()` returning `{ source, lowPowerMode, percent, charging }` — IOKit on macOS, `UIDevice`+`NSProcessInfo` on iOS — so apps can defer heavy work on battery or in Low Power Mode.

**Architecture:** A single new app event (ID 114) rides the existing `zapp_app_dispatch` fan-out; `App.getPowerState()` mirrors `App.getTheme()` (runtime-cached value seeded from the bootstrap config, refreshed on the event). Native computes the state via IOKit (macOS) / UIDevice (iOS) and dispatches **only on `source`/`lowPowerMode` transitions** (not percentage drift).

**Tech Stack:** Objective-C (IOKit `IOPowerSources`, `NSProcessInfo`, AppKit/UIKit `UIDevice`), Zen-C, TypeScript runtime, Bun (`bun:test`).

**Branch:** `feat/power-state-events` (created, spec committed).

**Spec:** `docs/superpowers/specs/2026-06-03-power-state-events-design.md`

**Conventions:**
- Stage ONLY the files each task names. Never `git add -A`. Never stage `vendor/bare`, `vendor/txiki.js`, `native/worker/engines/zjs-cross-eval-test.c`, `hello-world/src/main.ts`, `hello-world/zapp.config.ts`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Build success = LAST line is `[zapp] build complete: …` (NOT Vite's `✓ built`). macOS: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`.
- **Note on the parity lint:** `darwin_get_power_state` is called only from `.m` files (bootstrap + observers), not from any `.zc`, so `cli/src/ios-platform-parity.test.ts` does NOT cover it. iOS verification rests on the **ios-simulator build** (Task 3), which compiles+links `ios/platform.m`+`ios/webview.m`.
- Transient `bun test` `EMFILE`/`ProcessFdQuotaExceeded`/`Cannot find module` = fd exhaustion; re-run in a fresh process (`ulimit -n 4096` first).

---

## Task 1: Event + runtime getter (TDD)

**Files:**
- Modify: `runtime/events.ts` (enum, name map, union)
- Modify: `runtime/events.test.ts` (mapping test)
- Modify: `runtime/app.ts` (`PowerState` type + `getPowerState()`)
- Create: `runtime/app.test.ts`
- Modify: `native/app/app_events.zc` (switch case 114)
- Modify: `native/platform/darwin/platform.m` and `native/platform/ios/platform.m` (ID macro)

- [ ] **Step 1: Write the failing tests**

In `runtime/events.test.ts`, add to the existing "new background-app AppEvents…" test (or as a new test) an assertion for 114:
```ts
test("POWER_STATE_CHANGED maps to app:power-state-changed", () => {
  expect(eventName(AppEvent.POWER_STATE_CHANGED)).toBe("app:power-state-changed");
});
```

Create `runtime/app.test.ts`:
```ts
import { test, expect } from "bun:test";
import { App } from "./app";

test("getPowerState returns the inert default outside a Zapp webview", () => {
  // No bootstrap config + no bridge → the safe "no known constraint" default.
  expect(App.getPowerState()).toEqual({
    source: "ac",
    lowPowerMode: false,
    percent: null,
    charging: false,
  });
});
```

- [ ] **Step 2: Run, verify they fail**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/events.test.ts ./runtime/app.test.ts`
Expected: FAIL — `AppEvent.POWER_STATE_CHANGED` undefined and `App.getPowerState` not a function.

- [ ] **Step 3: Add the event to `runtime/events.ts`**

In the `AppEvent` enum, after `BEFORE_QUIT = 113,`:
```ts
  BEFORE_QUIT = 113,       // quit requested while a quit guard is armed
  POWER_STATE_CHANGED = 114, // AC/battery or Low Power Mode changed
```
In `APP_EVENT_NAMES`, after the `BEFORE_QUIT` entry:
```ts
  [AppEvent.BEFORE_QUIT]: "app:before-quit",
  [AppEvent.POWER_STATE_CHANGED]: "app:power-state-changed",
```
Replace the `AppEvents` union type line to append the new name:
```ts
type AppEvents = "app:started" | "app:shutdown" | "app:reopen" | "app:open-url" | "app:active" | "app:inactive" | "app:theme-changed" | "app:will-sleep" | "app:did-wake" | "app:screen-locked" | "app:screen-unlocked" | "app:before-quit" | "app:power-state-changed";
```

- [ ] **Step 4: Add `PowerState` + `getPowerState()` to `runtime/app.ts`**

Near the top of `runtime/app.ts`, after the existing `_theme` cache block (the block that ends with the `Events.on("app:theme-changed", …)` try/catch), add a parallel power-state cache block:
```ts
/** Snapshot of the device's power state. See {@link App.getPowerState}. */
export interface PowerState {
  source: "ac" | "battery";
  lowPowerMode: boolean;
  percent: number | null;
  charging: boolean;
}

const _powerDefault: PowerState = { source: "ac", lowPowerMode: false, percent: null, charging: false };
let _powerState: PowerState = { ..._powerDefault };

function _coercePowerState(v: any): PowerState {
  if (!v || typeof v !== "object") return { ..._powerDefault };
  return {
    source: v.source === "battery" ? "battery" : "ac",
    lowPowerMode: v.lowPowerMode === true,
    percent: typeof v.percent === "number" ? v.percent : null,
    charging: v.charging === true,
  };
}

{
  const cfg = (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
  if (cfg && cfg.powerState) _powerState = _coercePowerState(cfg.powerState);
  try {
    Events.on("app:power-state-changed", (data: any) => {
      _powerState = _coercePowerState(data);
    });
  } catch { /* bridge not available — fine for non-Zapp imports */ }
}
```
Then add the getter to the `App` object (e.g. after `getTheme()`):
```ts
  /**
   * Current device power state — synchronous, backed by an in-memory cache
   * seeded at startup and refreshed on every `AppEvent.POWER_STATE_CHANGED`.
   * `percent` is `null` on a battery-less desktop Mac. macOS + iOS; on
   * Windows (and before the first read) returns the inert default
   * `{ source: "ac", lowPowerMode: false, percent: null, charging: false }`.
   *
   * @example
   * ```ts
   * const p = App.getPowerState();
   * if (p.source === "battery" || p.lowPowerMode) deferHeavySync();
   * App.on(AppEvent.POWER_STATE_CHANGED, (s) => updateThrottle(s));
   * ```
   *
   * **Worker caveat** (same as `getTheme`): workers don't receive bootstrap
   * config, so this is the default until the first event arrives.
   */
  getPowerState(): PowerState {
    return { ..._powerState };
  },
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/events.test.ts ./runtime/app.test.ts`
Expected: PASS.

- [ ] **Step 6: Add the native switch case + ID macros**

In `native/app/app_events.zc`, after `case 113: js_name = "app:before-quit"; break;`:
```c
                case 114: js_name = "app:power-state-changed"; break;
```
In BOTH `native/platform/darwin/platform.m` and `native/platform/ios/platform.m`, after the `#define ZAPP_EVENT_APP_BEFORE_QUIT 113` line (match each file's existing column alignment):
```objc
#define ZAPP_EVENT_APP_POWER_STATE_CHANGED 114
```

- [ ] **Step 7: Build-verify (macOS)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: …` (nothing calls `darwin_get_power_state` yet — this only adds the macro + case + TS).

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/events.ts runtime/events.test.ts runtime/app.ts runtime/app.test.ts native/app/app_events.zc native/platform/darwin/platform.m native/platform/ios/platform.m
git commit -m "$(cat <<'EOF'
feat(app): POWER_STATE_CHANGED event + App.getPowerState() (runtime)

AppEvent 114 + name mapping + native switch/macros, and the PowerState
type + cached getPowerState() (mirrors getTheme: bootstrap-seeded,
event-refreshed). Native producers land next. bun-tested mapping + default.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: macOS native — IOKit power source + Low Power Mode

**Files:**
- Modify: `cli/src/build-config.ts` (link `IOKit`)
- Modify: `native/platform/darwin/platform.m` (`darwin_get_power_state`, registration, teardown)
- Modify: `native/platform/darwin/webview.m` (seed `powerState` into bootstrap config)

- [ ] **Step 1: Link the IOKit framework**

In `cli/src/build-config.ts`, in `generatePlatformConfig`, after the `ServiceManagement` line (`content += `//> macos: framework: ServiceManagement\n`;`):
```ts
    // IOKit — IOPowerSources for App.getPowerState() AC/battery monitoring.
    content += `//> macos: framework: IOKit\n`;
```

- [ ] **Step 2: Add IOKit imports**

At the top of `native/platform/darwin/platform.m`, with the other `#import` lines:
```objc
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
```

- [ ] **Step 3: Implement `darwin_get_power_state` + the transition helper**

Add at file scope in `platform.m` (outside `@implementation`, near `darwin_get_theme`):
```objc
// Returns the current power state as a JSON object literal. Static buffer —
// callers (bootstrap seed + event dispatch) copy immediately on the main thread.
const char* darwin_get_power_state(void) {
    static char buf[160];
    BOOL low = NSProcessInfo.processInfo.isLowPowerModeEnabled;
    const char* source = "ac";
    int percent = -1;          // -1 → emit null
    BOOL charging = NO;

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob) {
        CFArrayRef list = IOPSCopyPowerSourcesList(blob);
        if (list) {
            if (CFArrayGetCount(list) > 0) {
                CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
                if (d) {
                    CFStringRef st = CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey));
                    if (st && CFEqual(st, CFSTR(kIOPSBatteryPowerValue))) source = "battery";
                    CFBooleanRef chg = CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
                    if (chg && CFBooleanGetValue(chg)) charging = YES;
                    CFNumberRef cur = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey));
                    CFNumberRef max = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey));
                    int c = 0, m = 0;
                    if (cur) CFNumberGetValue(cur, kCFNumberIntType, &c);
                    if (max) CFNumberGetValue(max, kCFNumberIntType, &m);
                    if (m > 0) percent = (c * 100 + m / 2) / m;   // integer round, no <math.h>
                }
            }
            CFRelease(list);
        }
        CFRelease(blob);
    }

    if (percent >= 0) {
        snprintf(buf, sizeof(buf),
            "{\"source\":\"%s\",\"lowPowerMode\":%s,\"percent\":%d,\"charging\":%s}",
            source, low ? "true" : "false", percent, charging ? "true" : "false");
    } else {
        snprintf(buf, sizeof(buf),
            "{\"source\":\"%s\",\"lowPowerMode\":%s,\"percent\":null,\"charging\":%s}",
            source, low ? "true" : "false", charging ? "true" : "false");
    }
    return buf;
}

// --- transition gating ---------------------------------------------------
// Only `source` and `lowPowerMode` transitions dispatch an event; percentage
// drift updates nothing (the getter reads live state via bootstrap/JS cache).
static char zapp_power_last_source[16] = "";
static int  zapp_power_last_low = -1;
static CFRunLoopSourceRef zapp_power_rls = NULL;

// Compute just the two transition signals (source + low-power).
static void zapp_power_signals(const char** out_source, int* out_low) {
    *out_low = NSProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0;
    const char* source = "ac";
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob) {
        CFArrayRef list = IOPSCopyPowerSourcesList(blob);
        if (list) {
            if (CFArrayGetCount(list) > 0) {
                CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
                CFStringRef st = d ? CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey)) : NULL;
                if (st && CFEqual(st, CFSTR(kIOPSBatteryPowerValue))) source = "battery";
            }
            CFRelease(list);
        }
        CFRelease(blob);
    }
    *out_source = source;
}

// Seed the cache without dispatching (call once at registration).
static void zapp_power_init_cache(void) {
    const char* source; int low;
    zapp_power_signals(&source, &low);
    strncpy(zapp_power_last_source, source, sizeof(zapp_power_last_source) - 1);
    zapp_power_last_low = low;
}

// Recompute + dispatch only on a source/low-power transition.
static void zapp_power_maybe_dispatch(void) {
    const char* source; int low;
    zapp_power_signals(&source, &low);
    if (strcmp(source, zapp_power_last_source) == 0 && low == zapp_power_last_low) return;
    strncpy(zapp_power_last_source, source, sizeof(zapp_power_last_source) - 1);
    zapp_power_last_source[sizeof(zapp_power_last_source) - 1] = '\0';
    zapp_power_last_low = low;
    zapp_app_dispatch(ZAPP_EVENT_APP_POWER_STATE_CHANGED, darwin_get_power_state());
}

// IOKit run-loop-source callback.
static void zapp_power_iops_cb(void* ctx) { (void)ctx; zapp_power_maybe_dispatch(); }
```

- [ ] **Step 4: Register the IOKit source + NSProcessInfo observer**

In `applicationDidFinishLaunching:`, immediately after the NSWorkspace/distributed observer registration block added in the background-app-readiness cycle (and before the final `zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);`), add:
```objc
    // Power-state monitoring: IOKit run-loop source for AC/battery, plus the
    // NSProcessInfo notification for Low Power Mode toggles. Seed the cache
    // first so the first real transition compares correctly (webviews get the
    // initial state via the bootstrap config; workers default until an event).
    zapp_power_init_cache();
    zapp_power_rls = IOPSNotificationCreateRunLoopSource(zapp_power_iops_cb, NULL);
    if (zapp_power_rls) {
        CFRunLoopAddSource(CFRunLoopGetMain(), zapp_power_rls, kCFRunLoopDefaultMode);
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(zappPowerStateChanged:)
                                                 name:NSProcessInfoPowerStateDidChangeNotification
                                               object:nil];
```
Add the handler method inside `@implementation ZappAppDelegate` (near the other `zapp*` handlers):
```objc
- (void)zappPowerStateChanged:(NSNotification*)note { (void)note; zapp_power_maybe_dispatch(); }
```

- [ ] **Step 5: Teardown**

In `applicationWillTerminate:`, after the existing observer-removal lines, add:
```objc
    if (zapp_power_rls) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), zapp_power_rls, kCFRunLoopDefaultMode);
        CFRelease(zapp_power_rls);
        zapp_power_rls = NULL;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
```

- [ ] **Step 6: Seed `powerState` into the bootstrap config (`darwin/webview.m`)**

Open `native/platform/darwin/webview.m`. Find the bootstrap-config object literal built around line 838 (the `snprintf`/format that contains `theme:'%@'` and ends the `Symbol.for('zapp.bootstrapConfig')` object). Read the FULL statement first. Add a `powerState:%s` field to that object literal, fed by `darwin_get_power_state()` (which returns a valid JSON object literal — safe to inject unquoted as a JS object). Concretely:
- Add `extern const char* darwin_get_power_state(void);` near the existing `extern const char* darwin_get_theme(void);`-style externs in this file (or at the top of the function).
- In the format string, insert `,powerState:%s` immediately after the `theme:'%@'` field (before the closing `}` / the trailing `%@` slot), and add `darwin_get_power_state()` as the corresponding argument in the correct position.
- Because `darwin_get_power_state()` returns `{"source":"ac",...}` (double-quoted JSON, valid JS), inject it with `%s` (NOT wrapped in single quotes).

- [ ] **Step 7: Build-verify (macOS)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: …`. If IOKit symbols don't resolve, confirm Step 1's framework line landed in `generatePlatformConfig`.

- [ ] **Step 8: Manual smoke (record in commit/PR notes)**

`bun run dev`; in the webview console: `App.getPowerState()` returns the real state; unplug/replug power → an `app:power-state-changed` listener fires with `source` flipped + correct `charging`; toggle System Settings ▸ Battery ▸ Low Power Mode → event with `lowPowerMode` flipped.

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts native/platform/darwin/platform.m native/platform/darwin/webview.m
git commit -m "$(cat <<'EOF'
feat(app): macOS power-state monitoring via IOKit + NSProcessInfo

darwin_get_power_state reads IOPowerSources (source/percent/charging) +
isLowPowerModeEnabled; an IOPSNotificationCreateRunLoopSource + the
NSProcessInfoPowerStateDidChange observer dispatch POWER_STATE_CHANGED
only on source/low-power transitions. Seeds powerState into the bootstrap
config. Links IOKit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: iOS native — UIDevice battery + Low Power Mode

**Files:**
- Modify: `native/platform/ios/platform.m` (`darwin_get_power_state`, monitoring, observers, teardown)
- Modify: `native/platform/ios/webview.m` (seed `powerState` into bootstrap config)

- [ ] **Step 1: Implement the iOS `darwin_get_power_state`**

Add at file scope in `native/platform/ios/platform.m` (UIKit + Foundation are already imported):
```objc
// iOS power state from UIDevice battery + NSProcessInfo low-power. Same symbol
// name as the macOS definition (each platform compiles its own .m). Static
// buffer — callers copy immediately on the main thread.
const char* darwin_get_power_state(void) {
    static char buf[160];
    UIDevice* dev = [UIDevice currentDevice];
    BOOL low = NSProcessInfo.processInfo.isLowPowerModeEnabled;
    UIDeviceBatteryState st = dev.batteryState;
    const char* source = (st == UIDeviceBatteryStateUnplugged) ? "battery" : "ac"; // charging/full/unknown → ac
    BOOL charging = (st == UIDeviceBatteryStateCharging);
    float level = dev.batteryLevel;     // 0.0–1.0, or -1 when unknown
    int percent = (level >= 0.0f) ? (int)(level * 100.0f + 0.5f) : -1;

    if (percent >= 0) {
        snprintf(buf, sizeof(buf),
            "{\"source\":\"%s\",\"lowPowerMode\":%s,\"percent\":%d,\"charging\":%s}",
            source, low ? "true" : "false", percent, charging ? "true" : "false");
    } else {
        snprintf(buf, sizeof(buf),
            "{\"source\":\"%s\",\"lowPowerMode\":%s,\"percent\":null,\"charging\":%s}",
            source, low ? "true" : "false", charging ? "true" : "false");
    }
    return buf;
}

// --- transition gating (mirrors darwin/platform.m) ---
static char zapp_power_last_source[16] = "";
static int  zapp_power_last_low = -1;

static void zapp_power_signals(const char** out_source, int* out_low) {
    *out_low = NSProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0;
    UIDeviceBatteryState st = [UIDevice currentDevice].batteryState;
    *out_source = (st == UIDeviceBatteryStateUnplugged) ? "battery" : "ac";
}
static void zapp_power_init_cache(void) {
    const char* source; int low;
    zapp_power_signals(&source, &low);
    strncpy(zapp_power_last_source, source, sizeof(zapp_power_last_source) - 1);
    zapp_power_last_low = low;
}
static void zapp_power_maybe_dispatch(void) {
    const char* source; int low;
    zapp_power_signals(&source, &low);
    if (strcmp(source, zapp_power_last_source) == 0 && low == zapp_power_last_low) return;
    strncpy(zapp_power_last_source, source, sizeof(zapp_power_last_source) - 1);
    zapp_power_last_source[sizeof(zapp_power_last_source) - 1] = '\0';
    zapp_power_last_low = low;
    zapp_app_dispatch(ZAPP_EVENT_APP_POWER_STATE_CHANGED, darwin_get_power_state());
}
```

- [ ] **Step 2: Enable battery monitoring + register observers**

In `native/platform/ios/platform.m`'s `applicationDidFinishLaunching:` (before its `zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);`), add:
```objc
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    zapp_power_init_cache();
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(zappPowerStateChanged:)
                                                 name:UIDeviceBatteryStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(zappPowerStateChanged:)
                                                 name:NSProcessInfoPowerStateDidChangeNotification
                                               object:nil];
```
Add the handler inside `@implementation ZappAppDelegate`:
```objc
- (void)zappPowerStateChanged:(NSNotification*)note { (void)note; zapp_power_maybe_dispatch(); }
```

- [ ] **Step 3: Teardown**

In `native/platform/ios/platform.m`'s `applicationWillTerminate:` (add the method if it doesn't exist, mirroring the macOS delegate; if it exists, append):
```objc
- (void)applicationWillTerminate:(UIApplication*)application {
    (void)application;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
```
(If `applicationWillTerminate:` already exists in this file, just add the `removeObserver:self` line to it rather than redefining it. Read the file first.)

- [ ] **Step 4: Seed `powerState` into the iOS bootstrap config (`ios/webview.m`)**

Open `native/platform/ios/webview.m`. Find the bootstrap-config object literal (the `snprintf` containing `applicationShouldTerminateAfterLastWindowClosed:%@` and the `Symbol.for('zapp.bootstrapConfig')`/`theme` fields — mirror of `darwin/webview.m`). Read the full statement. Add a `powerState:%s` field fed by `darwin_get_power_state()`:
- Add `extern const char* darwin_get_power_state(void);` near the top of the function / with the other externs.
- Insert `,powerState:%s` into the object literal and `darwin_get_power_state()` as the matching arg, exactly as done for `darwin/webview.m` in Task 2 Step 6 (the JSON is injected unquoted with `%s`).

- [ ] **Step 5: Verify — macOS build + parity lint stay green**

```bash
cd /Users/zach/code/zapp && bun test ./cli/src/ios-platform-parity.test.ts
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1
```
Expected: lint `2 pass` (unaffected — `darwin_get_power_state` isn't `.zc`-referenced); macOS build `[zapp] build complete:` (macOS doesn't compile `ios/*.m`, but confirms nothing else broke).

- [ ] **Step 6: Verify — iOS-simulator build (the real iOS gate for this task)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator 2>&1 | tail -1`
Expected: `[zapp] build complete: …`. This compiles+links `ios/platform.m`+`ios/webview.m`, confirming the iOS `darwin_get_power_state` resolves and the UIKit/NSProcessInfo calls compile. If the ios-simulator build is environment-blocked (no simulator/SDK), report that explicitly — the iOS code mirrors the verified macOS structure and the symbol is defined; flag for a human ios-sim build.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/platform.m native/platform/ios/webview.m
git commit -m "$(cat <<'EOF'
feat(app): iOS power-state monitoring via UIDevice + NSProcessInfo

iOS darwin_get_power_state from UIDevice battery (source/percent/charging,
batteryMonitoringEnabled) + isLowPowerModeEnabled; UIDeviceBatteryStateDidChange
+ NSProcessInfoPowerStateDidChange observers dispatch POWER_STATE_CHANGED on
transitions. Seeds powerState into the iOS bootstrap config.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Docs

**Files:**
- Modify: `docs/api-reference.md`

- [ ] **Step 1: Document the API**

In `docs/api-reference.md`, in the App section (near the other `AppEvent`s and `App.getTheme()`), add:
- `AppEvent.POWER_STATE_CHANGED` to the AppEvent table/list with the note "fires only on AC↔battery or Low Power Mode transitions, not on percentage drift."
- The `PowerState` interface (`source`, `lowPowerMode`, `percent: number | null`, `charging`).
- `App.getPowerState(): PowerState` — synchronous, cached, mirrors `getTheme`; note `percent` is `null` on a battery-less desktop Mac and that Windows returns the inert default.
- A battery-aware-throttling example: `if (App.getPowerState().source === "battery" || App.getPowerState().lowPowerMode) deferHeavySync();` plus an `App.on(AppEvent.POWER_STATE_CHANGED, …)` listener.
- A platform note: macOS + iOS supported; Windows inert (→ #167).
Match the file's existing heading levels and ` ```ts ` fence style. Read `runtime/app.ts` to confirm the exact `PowerState` shape + `getPowerState` signature before writing.

- [ ] **Step 2: Verify markdown + tests**

```bash
cd /Users/zach/code/zapp && grep -c '```' docs/api-reference.md   # even
bun test ./runtime/events.test.ts ./runtime/app.test.ts            # still pass
```

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "$(cat <<'EOF'
docs(api-reference): power-state events + App.getPowerState()

POWER_STATE_CHANGED, the PowerState interface, getPowerState(), a
battery-aware throttling example, and the macOS+iOS / Windows-inert (#167)
platform note.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- §1 state object + getter (mirrors getTheme, inert default) → Task 1 (type + getter) + Tasks 2/3 (bootstrap seed). ✅
- §2 event 114, transition-only firing → Task 1 (event) + Tasks 2/3 (`zapp_power_maybe_dispatch` source/low-power gating). ✅
- §3 macOS IOKit + NSProcessInfo + run-loop source + teardown + seed → Task 2. ✅
- §4 iOS UIDevice + NSProcessInfo + battery monitoring + observers + teardown + seed → Task 3. ✅
- §5 events.ts / app_events.zc / macros / app.ts wiring → Task 1. ✅
- §6 Windows inert (no Windows symbol; runtime default) → covered by design (no task needed; `darwin_get_power_state` is Apple-only, runtime falls back to default). ✅
- §7 testing (events mapping bun test; ios-sim build is the iOS gate — NOT the parity lint, corrected) → Tasks 1 + 3. ✅
- §8 docs → Task 4. ✅
- Non-goals (time-to-empty, split events, Windows impl, per-tick events, thermal) → none implemented. ✅

**Placeholder scan:** No TBD/placeholders. The two bootstrap-seed steps (Task 2 Step 6, Task 3 Step 4) describe the exact edit (add `extern`, insert `,powerState:%s` after `theme`, feed `darwin_get_power_state()`, inject unquoted) because the surrounding `snprintf` literal is long and must be read in-place to thread the new arg correctly — that is concrete instruction, not a placeholder.

**Type/name consistency:** `PowerState` fields (`source`/`lowPowerMode`/`percent`/`charging`), `darwin_get_power_state`, `zapp_power_maybe_dispatch`/`zapp_power_init_cache`/`zapp_power_signals`, event id `114` / `ZAPP_EVENT_APP_POWER_STATE_CHANGED` / `"app:power-state-changed"`, and the JSON key spelling are identical across Tasks 1–3 and the macOS/iOS implementations. The inert default `{ source:"ac", lowPowerMode:false, percent:null, charging:false }` matches between `runtime/app.ts` and the Task 1 test.
