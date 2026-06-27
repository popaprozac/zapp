# iOS A5 — App Events + Demo Surfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execution mode (subagent-driven) is pre-approved.

**Goal:** Dispatch the missing iOS app-level events (theme/lock/screens), fix the worker app-event map so power/lock/screens reach workers everywhere, and add kitchen-sink demo surfaces that make app events + embedded webviews visible.

**Architecture:** T1 adds three UIKit dispatch sites in the iOS app delegate / root VCs (mirroring the macOS hooks + payloads) behind a deduped theme helper, plus a one-line-class no-sidebar root VC, plus a worker-bootstrap map fix. T2/T3 are pure kitchen-sink TS sections (new file + one registry line each), no native change.

**Tech Stack:** Objective-C (UIKit), TypeScript (Bun), the Zapp runtime (`@zappdev/runtime`).

## Global Constraints

- Branch `feat/nim-native`, kept UNMERGED. Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Per-file `git add` only — never `git add -A`/`.` (pre-existing unrelated WIP under assets/, benchmarks/, vendor/, spikes/ must stay unstaged).
- Bun, never Node. NO iOS simulator interaction in-session — build-only gates + human smoke on the user's device/sim.
- iOS = arm64, min iOS 15.0; sim functional / device compile-only. Default iOS engine = zjs.
- **macOS is the parity reference** — `native/platform/darwin/*` is NOT modified. The only cross-platform change is the worker-bootstrap map (`bootstrap/worker.ts`), a strict improvement on macOS too.
- Match macOS payloads exactly: `THEME_CHANGED` → `{"theme":"dark"|"light"}`; `SCREEN_LOCKED`/`SCREEN_UNLOCKED`/`SCREENS_CHANGED` → `"{}"`.

## Non-smoke gates (run for each task)

- `bun run check` (tsc) — clean.
- `bun test cli/src` — green.
- `bun run test:native` — green (T1; confirms native Nim still compiles host-side).
- iOS-sim compile: `cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`.
- macOS build: `cd kitchen-sink && bun run build` → `[zapp] build complete:`.

---

## Task 1: Native iOS app-event dispatch + worker-map fix

**Files:**
- Modify: `native/platform/ios/platform.m` (theme dedup helper + cache init; lock/unlock/screens observers + selectors in `ZappAppDelegate`)
- Modify: `native/platform/ios/window.m` (a `ZappIOSRootViewController` subclass for the no-sidebar path so it detects theme changes)
- Modify: `native/platform/ios/sidebar.m` (call the theme helper from the existing `traitCollectionDidChange:`)
- Modify: `bootstrap/worker.ts` (extend `_dispatchAppEvent` id→name map to 109–116)

**Interfaces:**
- Produces: C functions `void zapp_ios_theme_init_cache(void)` and `void zapp_ios_dispatch_theme_if_changed(void)` (defined in `ios/platform.m`, called from `sidebar.m` + `window.m` via local `extern` decls).
- Consumes (exist): `int zapp_app_dispatch(int, const char*)`; `const char* darwin_get_theme(void)` (`ios/platform.m:111`, returns `"dark"`/`"light"`); `ZAPP_EVENT_APP_*` macros (`ios/platform.m:15-32`); the `ZappAppDelegate` `addObserver` + `removeObserver` pattern (`ios/platform.m:202-214`, `:246`).

- [ ] **Step 1: Add the deduped theme helper + cache init to `ios/platform.m`**

Add immediately after `darwin_get_theme()` (ends ~`ios/platform.m:114`):

```objc
// --- THEME_CHANGED dispatch (deduped) ---
// iOS appearance changes arrive per-VC via traitCollectionDidChange:; multiple
// windows would otherwise emit duplicate app-level THEME_CHANGED. Dedup here:
// dispatch only when the resolved theme actually changed. Mirrors the macOS
// single-observer behavior + payload ({"theme":"dark|light"}).
static char zapp_ios_last_theme[8] = "";

void zapp_ios_theme_init_cache(void) {
    const char* t = darwin_get_theme();
    strncpy(zapp_ios_last_theme, t, sizeof(zapp_ios_last_theme) - 1);
    zapp_ios_last_theme[sizeof(zapp_ios_last_theme) - 1] = '\0';
}

void zapp_ios_dispatch_theme_if_changed(void) {
    const char* t = darwin_get_theme();
    if (strcmp(t, zapp_ios_last_theme) == 0) return;
    strncpy(zapp_ios_last_theme, t, sizeof(zapp_ios_last_theme) - 1);
    zapp_ios_last_theme[sizeof(zapp_ios_last_theme) - 1] = '\0';
    char payload[64];
    snprintf(payload, sizeof(payload), "{\"theme\":\"%s\"}", t);
    zapp_app_dispatch(ZAPP_EVENT_APP_THEME_CHANGED, payload);
}
```

- [ ] **Step 2: Register lock/unlock/screens observers + init theme cache in `applicationDidFinishLaunching:`**

In `ios/platform.m`, inside `application:didFinishLaunchingWithOptions:`, immediately before `zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);` (`:214`), add:

```objc
    zapp_ios_theme_init_cache();
    // Device lock/unlock (passcode devices): protected-data availability —
    // the iOS analog of macOS's com.apple.screenIs{Locked,Unlocked}.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(zappScreenLocked:)
                                                 name:UIApplicationProtectedDataWillBecomeUnavailableNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(zappScreenUnlocked:)
                                                 name:UIApplicationProtectedDataDidBecomeAvailableNotification
                                               object:nil];
    // External display connect/disconnect → SCREENS_CHANGED.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(zappScreensChanged:)
                                                 name:UIScreenDidConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(zappScreensChanged:)
                                                 name:UIScreenDidDisconnectNotification
                                               object:nil];
```

(No `removeObserver` change needed — `applicationWillTerminate:` already calls `[[NSNotificationCenter defaultCenter] removeObserver:self]` at `:246`.)

- [ ] **Step 3: Add the selector methods to `ZappAppDelegate`**

In `ios/platform.m`, add these alongside the existing `zappPowerStateChanged:` method (~`:236`), matching the macOS `"{}"` payloads:

```objc
- (void)zappScreenLocked:(NSNotification*)note   { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_SCREEN_LOCKED, "{}"); }
- (void)zappScreenUnlocked:(NSNotification*)note { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_SCREEN_UNLOCKED, "{}"); }
- (void)zappScreensChanged:(NSNotification*)note { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_SCREENS_CHANGED, "{}"); }
```

- [ ] **Step 4: Call the theme helper from the sidebar window's trait hook (`sidebar.m`)**

In `ios/sidebar.m`, in `ZappIOSSplitViewController`'s `traitCollectionDidChange:` (the method at ~`:335`), add at the end of the method body (after `zapp_ios_update_content_leading(c);`):

```objc
    // App-level THEME_CHANGED (deduped in the helper — safe to call on any
    // trait change; only a real light/dark switch dispatches).
    extern void zapp_ios_dispatch_theme_if_changed(void);
    zapp_ios_dispatch_theme_if_changed();
```

- [ ] **Step 5: Add a no-sidebar root VC that detects theme changes (`window.m`)**

In `ios/window.m`, after the `ZappIOSSplitViewController` `@interface` declaration (~`:173`), add a small subclass:

```objc
// Root VC for the no-sidebar window. The sidebar path gets THEME_CHANGED from
// ZappIOSSplitViewController's traitCollectionDidChange:; the plain path needs
// its own override so a no-sidebar window also dispatches the app-level event.
@interface ZappIOSRootViewController : UIViewController
@end
@implementation ZappIOSRootViewController
- (void)traitCollectionDidChange:(UITraitCollection*)previous {
    [super traitCollectionDidChange:previous];
    extern void zapp_ios_dispatch_theme_if_changed(void);
    zapp_ios_dispatch_theme_if_changed();
}
@end
```

Then in the no-sidebar materialize branch, change the root VC allocation at `ios/window.m:309` from:

```objc
            UIViewController* root = [[UIViewController alloc] init];
```

to:

```objc
            UIViewController* root = [[ZappIOSRootViewController alloc] init];
```

(Leave the `root` variable type as `UIViewController*` — only the allocated class changes.)

- [ ] **Step 6: Fix the worker app-event map (`bootstrap/worker.ts`)**

In `bootstrap/worker.ts`, `bridge._dispatchAppEvent` (~`:104`), replace the `eventMap` object (currently ids 100–108 + 102/103) with the full set so 109–116 stop being dropped for workers on every platform:

```ts
    const eventMap: Record<number, string> = {
      // Keep in sync with APP_EVENT_NAMES (runtime/events.ts) + the internal
      // notification ids 102/103. Bootstrap bundles are standalone (no imports),
      // so this is mirrored rather than derived. 109-116 were previously dropped
      // for workers (incl. power 114/115) — this is the fix.
      100: "app:started", 101: "app:shutdown",
      102: "app:notification-click", 103: "app:notification-action",
      104: "app:reopen", 105: "app:open-url",
      106: "app:active", 107: "app:inactive",
      108: "app:theme-changed",
      109: "app:will-sleep", 110: "app:did-wake",
      111: "app:screen-locked", 112: "app:screen-unlocked",
      113: "app:before-quit",
      114: "app:power-state-changed", 115: "app:battery-level-changed",
      116: "app:screens-changed",
    };
```

(Leave the rest of `_dispatchAppEvent` — the `name`/parse/listener loop + the 102/103 `__notif:*` special-case — unchanged.)

- [ ] **Step 7: Run host gates**

Run: `bun run check && bun test cli/src && bun run test:native`
Expected: all green (TS typechecks; native Nim still compiles host-side — these are ObjC/TS-only changes).

- [ ] **Step 8: Build iOS**

Run: `cd kitchen-sink && bun run build --platform ios`
Expected: `[zapp] build complete:`.

- [ ] **Step 9: Build macOS (parity untouched)**

Run: `cd kitchen-sink && bun run build`
Expected: `[zapp] build complete:`.

- [ ] **Step 10: Commit**

```bash
git add native/platform/ios/platform.m native/platform/ios/window.m native/platform/ios/sidebar.m bootstrap/worker.ts
git commit -F - <<'EOF'
feat(ios): dispatch THEME_CHANGED + lock/unlock + screens-changed app events

iOS was missing app-level dispatch for THEME_CHANGED (108),
SCREEN_LOCKED/UNLOCKED (111/112) and SCREENS_CHANGED (116) — macOS dispatches
all three. Add them via UIKit hooks (traitCollectionDidChange:, protected-data
notifications, UIScreen connect/disconnect), matching the macOS payloads, with a
deduped theme helper (per-VC trait callbacks would otherwise double-fire).
Also fix the worker bootstrap app-event map: it covered only ids 100-108, so
109-116 (incl. POWER 114/115, lock, screens) were silently dropped for workers
on ALL platforms — extended to the full set. REOPEN stays N/A on iOS.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

- [ ] **Step 11: HUMAN SMOKE GATE — pause for the user (verified via Task 2's section)**

After T2 ships, on iPhone + iPad: toggle system dark mode → `THEME_CHANGED` appears in the App Events log; lock the device (passcode set) → `SCREEN_LOCKED` then `SCREEN_UNLOCKED`; power changes show live. (`SCREENS_CHANGED` only fires with an external display; otherwise it's verified by code review.) Because the smoke surface is T2, this gate is exercised after T2 — note it and proceed to T2.

---

## Task 2: Kitchen-sink "App Events" section

**Files:**
- Create: `kitchen-sink/src/sections/app-events.ts`
- Modify: `kitchen-sink/src/sections/registry.ts` (import + array entry)

**Interfaces:**
- Consumes (exist): `App.on(event: AppEvent, handler): () => void` (`runtime/app.ts`); `App.getPowerState(): PowerState` (`runtime/app.ts:247`); `AppEvent` enum (`runtime/events.ts`); the `Section` type `{ id, label, render(host): void | (() => void) }` (`kitchen-sink/src/sections/types.ts`); `card` from `../shell/ui`. All exported from `@zappdev/runtime` (`runtime/index.ts:17,22`).
- Pattern reference: `kitchen-sink/src/sections/window-log.ts` (event-log section that returns a teardown).

- [ ] **Step 1: Create the App Events section**

Create `kitchen-sink/src/sections/app-events.ts`:

```ts
import { App, AppEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct } from "../shell/ui";

const MAX = 50;

export const appEventsSection: Section = {
  id: "app-events",
  label: "App Events",
  render(host) {
    host.appendChild(card({
      title: "App lifecycle & system events",
      intro:
        "A live log of APP-level events via App.on(...): theme change, " +
        "active/inactive, device lock/unlock, display changes, power/battery, " +
        "reopen, and open-url. Distinct from the Window log (window-scoped) and " +
        "the Events bus (app pub/sub). Toggle system dark mode, lock the device, " +
        "or change power to see events here.",
      buttons: [{ act: "clear", label: "Clear log" }],
      note:
        "<b>Platform note:</b> some events are platform-specific — " +
        "<code>will-sleep</code>/<code>did-wake</code> and <code>before-quit</code> " +
        "are macOS-only; <code>reopen</code> is macOS (dock click). On iOS, lock/unlock " +
        "fire only on devices with a passcode, and screens-changed needs an external display.",
    }));

    const power = document.createElement("div");
    power.className = "kv";
    power.style.cssText = "font-family:monospace; font-size:12px; margin:8px 0;";
    host.appendChild(power);
    const renderPower = () => {
      const p = App.getPowerState();
      power.textContent = `power: source=${p.source} charging=${p.charging} ` +
        `percent=${p.percent ?? "?"} lowPowerMode=${p.lowPowerMode}`;
    };
    renderPower();

    const log = document.createElement("div");
    log.className = "kv";
    log.style.cssText = "max-height:320px; overflow:auto; font-family:monospace; font-size:12px; line-height:1.5;";
    log.innerHTML = `<div class="muted" data-empty>waiting for app events…</div>`;
    host.appendChild(log);

    const append = (label: string, payload: unknown) => {
      log.querySelector("[data-empty]")?.remove();
      const row = document.createElement("div");
      const t = new Date().toLocaleTimeString();
      row.textContent = `${t}  ${label}  ${payload !== undefined && payload !== null ? JSON.stringify(payload) : ""}`.trimEnd();
      log.appendChild(row);
      while (log.childElementCount > MAX) log.firstElementChild!.remove();
      log.scrollTop = log.scrollHeight;
    };

    const sub = (ev: AppEvent, label: string) =>
      App.on(ev, (d?: any) => { append(label, d); });

    const off = [
      sub(AppEvent.THEME_CHANGED, "theme-changed"),
      sub(AppEvent.DID_BECOME_ACTIVE, "active"),
      sub(AppEvent.DID_RESIGN_ACTIVE, "inactive"),
      sub(AppEvent.SCREEN_LOCKED, "screen-locked"),
      sub(AppEvent.SCREEN_UNLOCKED, "screen-unlocked"),
      sub(AppEvent.SCREENS_CHANGED, "screens-changed"),
      sub(AppEvent.REOPEN, "reopen"),
      sub(AppEvent.OPEN_URL, "open-url"),
      App.on(AppEvent.POWER_STATE_CHANGED, (d?: any) => { append("power-state-changed", d); renderPower(); }),
      App.on(AppEvent.BATTERY_LEVEL_CHANGED, (d?: any) => { append("battery-level-changed", d); renderPower(); }),
    ];

    onAct(host, "clear", () => {
      log.innerHTML = `<div class="muted" data-empty>waiting for app events…</div>`;
    });

    return () => { off.forEach((fn) => fn()); };
  },
};
```

(If `card`'s `note` field doesn't exist in this branch, drop the `note:` line — it was added in the sidebar polish; confirm `shell/ui.ts` has `note?` before using it, else omit.)

- [ ] **Step 2: Register the section**

In `kitchen-sink/src/sections/registry.ts`, add the import (alongside the others) and the array entry (place it next to `windowLogSection`):

```ts
import { appEventsSection } from "./app-events";
```
```ts
  windowLogSection,
  appEventsSection,
```

- [ ] **Step 3: Gates**

Run: `bun run check` → clean. Then `cd kitchen-sink && bun run build --platform ios` and `bun run build` → both `[zapp] build complete:`.

- [ ] **Step 4: Commit**

```bash
git add kitchen-sink/src/sections/app-events.ts kitchen-sink/src/sections/registry.ts
git commit -F - <<'EOF'
feat(kitchen-sink): App Events section (app.on log + power readout)

A live App.on(...) log for theme / active / inactive / lock / unlock /
screens-changed / power / battery / reopen / open-url, plus an
App.getPowerState() readout. Makes the app-level events (incl. the iOS
dispatch added this cycle) verifiable in the try-out app.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

- [ ] **Step 5: HUMAN SMOKE GATE — pause for the user**

iPhone + iPad: open the App Events section; toggle dark mode → `theme-changed` row; lock/unlock device → rows; power readout reflects state and updates. macOS: section works; theme/active/inactive/power rows appear. This also closes Task 1's smoke gate.

---

## Task 3: Kitchen-sink `<zapp-webview>` demo section

**Files:**
- Create: `kitchen-sink/src/sections/embedded-webview.ts`
- Modify: `kitchen-sink/src/sections/registry.ts` (import + array entry)
- Possibly modify: `kitchen-sink/zapp.config.ts` (grant `embed` permission — only if smoke shows it's blocked; see Step 1)

**Interfaces:**
- Consumes (exist): `Webview.create(opts: { src: string; bridge?: boolean; partition?: string }): ZappWebviewElement` (`runtime/webview.ts`, exported `runtime/index.ts:21`); the element's `loadURL(url)` + `reload()` methods (`runtime/webview.ts:92,97`); `card`/`onAct` from `../shell/ui`; the `Section` type.

- [ ] **Step 1: Confirm the `embed` permission**

`Webview.create` calls `ensurePermission("embed")`. The kitchen-sink `zapp.config.ts` currently declares no permissions block (so the default applies). Before writing, check `runtime/permissions.ts` / how `ensurePermission` resolves with no manifest. If the default is permissive (no block = all allowed), no config change is needed. If it denies, add an `embed` entry to a permissions array in `kitchen-sink/zapp.config.ts`. Resolve this concretely before Step 3 — it's the difference between the demo working and silently throwing.

- [ ] **Step 2: Create the embedded-webview section**

Create `kitchen-sink/src/sections/embedded-webview.ts`:

```ts
import { Webview } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct } from "../shell/ui";

const DEFAULT_URL = "https://example.com";

export const embeddedWebviewSection: Section = {
  id: "embedded-webview",
  label: "Embedded Webview",
  render(host) {
    host.appendChild(card({
      title: "Embedded <zapp-webview>",
      intro:
        "A native embedded web view (<zapp-webview>) hosted inside this page — " +
        "a real WKWebView panel on macOS/iOS, positioned to track the box below. " +
        "Set a URL or reload to drive it.",
      buttons: [
        { act: "load", label: "Load URL" },
        { act: "reload", label: "Reload" },
      ],
    }));

    const input = document.createElement("input");
    input.type = "text";
    input.value = DEFAULT_URL;
    input.style.cssText = "width:100%; box-sizing:border-box; margin:8px 0; font-family:monospace; font-size:12px; padding:6px;";
    host.appendChild(input);

    const frame = document.createElement("div");
    frame.style.cssText = "width:100%; height:360px; border:1px solid var(--border); border-radius:8px; overflow:hidden;";
    host.appendChild(frame);

    const wv = Webview.create({ src: DEFAULT_URL });
    wv.style.cssText = "width:100%; height:100%; display:block;";
    frame.appendChild(wv);

    onAct(host, "load", () => { const u = input.value.trim(); if (u) wv.loadURL(u); });
    onAct(host, "reload", () => wv.reload());

    return () => { wv.remove(); };
  },
};
```

- [ ] **Step 3: Register the section**

In `kitchen-sink/src/sections/registry.ts`, add:

```ts
import { embeddedWebviewSection } from "./embedded-webview";
```
```ts
  filedropSection,
  embeddedWebviewSection,
```

- [ ] **Step 4: Gates**

Run: `bun run check` → clean. Then `cd kitchen-sink && bun run build --platform ios` and `bun run build` → both `[zapp] build complete:`.

- [ ] **Step 5: Commit**

```bash
git add kitchen-sink/src/sections/embedded-webview.ts kitchen-sink/src/sections/registry.ts
git commit -F - <<'EOF'
feat(kitchen-sink): embedded <zapp-webview> demo section

Demos the shipped <zapp-webview> element: an embedded native WKWebView panel
with set-URL + reload controls. No native change; exercises the macOS + iOS
embedded-webview path in the try-out app.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

(If Step 1 required a `kitchen-sink/zapp.config.ts` permission change, `git add` that file in this commit too.)

- [ ] **Step 6: HUMAN SMOKE GATE — pause for the user**

iPhone + iPad + macOS: open the Embedded Webview section → the embedded page renders inside the box; "Load URL" navigates; "Reload" reloads. Switching away from the section tears the panel down (no orphan webview).

---

## Self-Review

**1. Spec coverage:**
- THEME_CHANGED iOS dispatch → T1 Steps 1,4,5. ✓
- SCREEN_LOCKED/UNLOCKED (protectedData) → T1 Steps 2,3. ✓
- SCREENS_CHANGED (UIScreen connect/disconnect) → T1 Steps 2,3. ✓
- Worker-map fix (109–116) → T1 Step 6. ✓
- REOPEN N/A → not dispatched (documented in commit + T2 platform note). ✓
- App Events demo (App.on log + getPowerState) → T2. ✓
- `<zapp-webview>` demo → T3. ✓
- macOS untouched → no `darwin/*` edits; macOS build gate in every task. ✓

**2. Placeholder scan:** No TBD/TODO. Two conditional steps are explicit, not placeholders: T2 Step 1's `note:` fallback (check `shell/ui.ts` has `note?`, else omit — it does on this branch after the sidebar polish) and T3 Step 1's `embed` permission check (concrete files + resolve-before-Step-3). Both are real "verify then act" steps with exact targets.

**3. Type consistency:** `zapp_ios_dispatch_theme_if_changed` / `zapp_ios_theme_init_cache` defined in `platform.m` (T1 S1), declared `extern` + called in `sidebar.m` (S4) and `window.m` (S5) with matching `void(void)` signatures. `Section` shape (`render` returns `void | (() => void)`) used consistently in T2/T3 (both return teardowns). `App.on`/`AppEvent`/`App.getPowerState`/`Webview.create`/`loadURL`/`reload` all match the verified runtime exports.

**Deviation from spec (flag at handoff):** the spec's architecture said the worker-map fix would "derive from `APP_EVENT_NAMES`." During planning I confirmed the bootstrap bundles are **standalone (zero imports)** — importing runtime/events into the worker bundle isn't the established pattern — so T1 Step 6 **mirrors** the full map (with a keep-in-sync comment) instead of importing. Same outcome (109–116 reach workers); safer for the worker bundle. Also: `APP_EVENT_NAMES` excludes the internal 102/103 notification ids, which the worker map must keep — another reason a literal map (incl. 102/103) is correct here.
