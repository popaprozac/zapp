# Background-App Readiness (macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Zapp viable for menu-bar / background / sync-engine macOS apps: power-monitor events (sleep/wake + screen lock/unlock), a cancelable `BEFORE_QUIT` quit guard, auto-launch-at-login, and a real `Window.setFocus` (raise + app activation).

**Architecture:** Each feature follows the established native-first chain — C/ObjC primitive → Zen-C/router wiring → TS runtime → docs. All four ride the existing `zapp_app_dispatch` app-event plumbing (`native/app/app_events.zc`) and the existing t:4 fire-and-forget / request-response bridge. macOS-only implementation; the runtime API is present-but-inert on iOS/Windows (raw blocks guard on `#ifdef __APPLE__`; Windows real impl deferred to #167).

**Tech Stack:** Objective-C (AppKit, `NSWorkspace`, `NSDistributedNotificationCenter`, `ServiceManagement`), Zen-C (`.zc`), TypeScript runtime, Bun (`bun test`), Vite plugin build.

**Branch:** `feat/background-app-readiness` (already created, spec committed). One branch, per-feature commits.

**Spec:** `docs/superpowers/specs/2026-06-03-background-app-readiness-design.md`

**Conventions used throughout:**
- **Native build verification:** success is ONLY when the LAST line of the build is `[zapp] build complete: …`. Vite's `✓ built` is NOT success. Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`.
- **Leave dirt alone:** do NOT stage `vendor/bare`, `vendor/txiki.js`, the untracked `native/worker/engines/zjs-cross-eval-test.c`, or the user's uncommitted `hello-world/src/main.ts` / `hello-world/zapp.config.ts` experiments. Stage only the files each task names.
- **Commit trailer:** every commit message ends with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Most native ObjC/Zen-C has **no unit harness** — those tasks verify by build + the manual smoke noted in each task. Only Task 1's event-name mapping is unit-tested (`bun test`).

---

## Task 1: Shared event foundation (5 new app events)

Adds five `AppEvent`s that every later feature dispatches. TDD on the TS mapping; native switch + ID macros verified by build.

**Files:**
- Modify: `runtime/events.ts` (enum `AppEvent`, `APP_EVENT_NAMES` map, `AppEvents` union type)
- Create: `runtime/events.test.ts`
- Modify: `native/app/app_events.zc` (id→js-name switch, ~lines 88–94)
- Modify: `native/platform/darwin/platform.m` (new ID macros, after line 30)

- [ ] **Step 1: Write the failing test**

Create `runtime/events.test.ts`:

```ts
import { test, expect } from "bun:test";
import { AppEvent, eventName } from "./events";

test("new background-app AppEvents map to their wire names", () => {
  expect(eventName(AppEvent.WILL_SLEEP)).toBe("app:will-sleep");
  expect(eventName(AppEvent.DID_WAKE)).toBe("app:did-wake");
  expect(eventName(AppEvent.SCREEN_LOCKED)).toBe("app:screen-locked");
  expect(eventName(AppEvent.SCREEN_UNLOCKED)).toBe("app:screen-unlocked");
  expect(eventName(AppEvent.BEFORE_QUIT)).toBe("app:before-quit");
});

test("existing AppEvent mapping is unchanged", () => {
  expect(eventName(AppEvent.THEME_CHANGED)).toBe("app:theme-changed");
  expect(eventName(AppEvent.REOPEN)).toBe("app:reopen");
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd /Users/zach/code/zapp && bun test runtime/events.test.ts`
Expected: FAIL — `AppEvent.WILL_SLEEP` is `undefined` (enum members don't exist yet), so `eventName(undefined)` returns `"unknown:undefined"`.

- [ ] **Step 3: Add the enum members**

In `runtime/events.ts`, the `AppEvent` enum currently ends at `THEME_CHANGED = 108`. Add the five new members directly after it:

```ts
  THEME_CHANGED = 108,
  WILL_SLEEP = 109,        // system about to sleep
  DID_WAKE = 110,          // system woke from sleep
  SCREEN_LOCKED = 111,     // screen locked
  SCREEN_UNLOCKED = 112,   // screen unlocked
  BEFORE_QUIT = 113,       // quit requested while a quit guard is armed
```

- [ ] **Step 4: Add the name-map entries**

In the `APP_EVENT_NAMES` record (right after `[AppEvent.THEME_CHANGED]: "app:theme-changed",`):

```ts
  [AppEvent.THEME_CHANGED]: "app:theme-changed",
  [AppEvent.WILL_SLEEP]: "app:will-sleep",
  [AppEvent.DID_WAKE]: "app:did-wake",
  [AppEvent.SCREEN_LOCKED]: "app:screen-locked",
  [AppEvent.SCREEN_UNLOCKED]: "app:screen-unlocked",
  [AppEvent.BEFORE_QUIT]: "app:before-quit",
```

- [ ] **Step 5: Widen the `AppEvents` union type**

Replace the existing `AppEvents` type line:

```ts
type AppEvents = "app:started" | "app:shutdown" | "app:reopen" | "app:open-url" | "app:active" | "app:inactive" | "app:theme-changed" | "app:will-sleep" | "app:did-wake" | "app:screen-locked" | "app:screen-unlocked" | "app:before-quit";
```

- [ ] **Step 6: Run the test, verify it passes**

Run: `cd /Users/zach/code/zapp && bun test runtime/events.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 7: Add native event-ID macros**

In `native/platform/darwin/platform.m`, immediately after line 30 (`#define ZAPP_EVENT_APP_THEME_CHANGED      108`):

```objc
#define ZAPP_EVENT_APP_WILL_SLEEP         109
#define ZAPP_EVENT_APP_DID_WAKE           110
#define ZAPP_EVENT_APP_SCREEN_LOCKED      111
#define ZAPP_EVENT_APP_SCREEN_UNLOCKED    112
#define ZAPP_EVENT_APP_BEFORE_QUIT        113
```

- [ ] **Step 8: Add the id→js-name switch cases**

In `native/app/app_events.zc`, the Layer-3 switch maps event IDs to JS event names (currently `case 104` … `case 108`). Add five cases after `case 108`:

```c
                case 108: js_name = "app:theme-changed"; break;
                case 109: js_name = "app:will-sleep"; break;
                case 110: js_name = "app:did-wake"; break;
                case 111: js_name = "app:screen-locked"; break;
                case 112: js_name = "app:screen-unlocked"; break;
                case 113: js_name = "app:before-quit"; break;
```

(These also flow to workers via Layer 2's `_dispatchAppEvent` automatically — no change needed there.)

- [ ] **Step 9: Build-verify**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: /Users/zach/code/zapp/hello-world/bin/hello-world (…)`

- [ ] **Step 10: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/events.ts runtime/events.test.ts native/app/app_events.zc native/platform/darwin/platform.m
git commit -m "$(cat <<'EOF'
feat(events): add WILL_SLEEP/DID_WAKE/SCREEN_LOCKED/UNLOCKED/BEFORE_QUIT app events

Five new AppEvent IDs (109-113) + name mappings, the native id->name
switch cases, and the platform.m ID macros. Foundation for the
background-app-readiness features. bun-tested mapping.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Power monitor (sleep/wake + screen lock/unlock)

Register macOS observers that fire the new events. No new runtime methods — `App.on(AppEvent.DID_WAKE, …)` works through the existing `Events` bus.

**Files:**
- Modify: `native/platform/darwin/platform.m` (observer registration in `applicationDidFinishLaunching`, four handler methods, teardown in `applicationWillTerminate`)

- [ ] **Step 1: Register the observers**

In `native/platform/darwin/platform.m`, inside `applicationDidFinishLaunching:`, immediately before the final `zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);` line, add:

```objc
    // Power / session observers. Sleep/wake come from NSWorkspace's own
    // notification center (NOT the default center); lock/unlock come from
    // the distributed center via the documented com.apple.screenIs* names.
    // All are torn down in applicationWillTerminate.
    NSNotificationCenter* wsCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [wsCenter addObserver:self selector:@selector(zappWillSleep:)
                     name:NSWorkspaceWillSleepNotification object:nil];
    [wsCenter addObserver:self selector:@selector(zappDidWake:)
                     name:NSWorkspaceDidWakeNotification object:nil];

    NSDistributedNotificationCenter* dist = [NSDistributedNotificationCenter defaultCenter];
    [dist addObserver:self selector:@selector(zappScreenLocked:)
                 name:@"com.apple.screenIsLocked" object:nil];
    [dist addObserver:self selector:@selector(zappScreenUnlocked:)
                 name:@"com.apple.screenIsUnlocked" object:nil];
```

- [ ] **Step 2: Add the four handler methods**

In the same `@implementation ZappAppDelegate` block (e.g. right after `applicationDidResignActive:`), add:

```objc
- (void)zappWillSleep:(NSNotification*)note     { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_WILL_SLEEP, "{}"); }
- (void)zappDidWake:(NSNotification*)note        { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_DID_WAKE, "{}"); }
- (void)zappScreenLocked:(NSNotification*)note   { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_SCREEN_LOCKED, "{}"); }
- (void)zappScreenUnlocked:(NSNotification*)note { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_SCREEN_UNLOCKED, "{}"); }
```

- [ ] **Step 3: Tear down the observers on terminate**

In `applicationWillTerminate:`, after the existing `effectiveAppearance` KVO removal block (around line 92, before `service_run_shutdown_all();`), add:

```objc
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
```

- [ ] **Step 4: Build-verify**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: …`

- [ ] **Step 5: Manual smoke (record result in the commit/PR notes)**

1. `cd /Users/zach/code/zapp/hello-world && bun run dev`
2. In the app's webview console (or a `did-wake` log), confirm: `pmset sleepnow` then wake → an `app:did-wake` listener fires; lock the screen (`⌃⌘Q`) → `app:screen-locked`; unlock → `app:screen-unlocked`.

(If no listener is wired in hello-world yet, this is verified end-to-end in Task 6's demo; for now confirm the build links and the app launches.)

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/platform.m
git commit -m "$(cat <<'EOF'
feat(app): power-monitor events — sleep/wake + screen lock/unlock (macOS)

NSWorkspace will-sleep/did-wake + NSDistributedNotificationCenter
com.apple.screenIs(Locked|Unlocked) observers dispatch app:will-sleep /
did-wake / screen-locked / screen-unlocked. Torn down on terminate.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `BEFORE_QUIT` quit guard + `App.quit({ force })`

App-level analog of the window close guard. Replaces the dead `emit("app:quit")` (it had no native consumer) with an explicit t:4 action.

**Files:**
- Modify: `native/platform/darwin/platform.m` (two static flags, `applicationShouldTerminate:`, two exported C fns)
- Modify: `native/app/router.zc` (app-level `setQuitGuard` + `quit` actions in `router_handle_window_action`)
- Modify: `runtime/app.ts` (`setQuitGuard`, rewrite `quit`)

- [ ] **Step 1: Add the static flags**

In `native/platform/darwin/platform.m`, right after line 11 (`static BOOL zapp_should_terminate_after_last_window_closed = NO;`):

```objc
static BOOL zapp_quit_guard_enabled = NO;
static BOOL zapp_force_quit = NO;
```

- [ ] **Step 2: Implement `applicationShouldTerminate:`**

In the `@implementation ZappAppDelegate` block (e.g. after `applicationShouldTerminateAfterLastWindowClosed:`), add:

```objc
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    (void)sender;
    // No guard, or a forced quit (App.quit({force:true})) → proceed.
    if (zapp_force_quit || !zapp_quit_guard_enabled) return NSTerminateNow;
    // Guard armed: tell JS a quit was requested and cancel this attempt.
    // The app runs its own (possibly async) confirmation, then re-issues
    // App.quit({force:true}) to actually terminate. Mirrors setCloseGuard;
    // avoids the NSTerminateLater "must reply or hang" footgun.
    zapp_app_dispatch(ZAPP_EVENT_APP_BEFORE_QUIT, "{}");
    return NSTerminateCancel;
}
```

- [ ] **Step 3: Export the C control functions**

Add near the other exported `darwin_*` C functions in `platform.m` (file scope, outside `@implementation`):

```objc
void darwin_set_quit_guard(bool enabled) {
    zapp_quit_guard_enabled = enabled ? YES : NO;
}

void darwin_app_quit(bool force) {
    if (force) zapp_force_quit = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
```

- [ ] **Step 4: Route the app-level actions in the router**

In `native/app/router.zc`, function `router_handle_window_action` (starts line 209). Insert the app-level lifecycle actions AFTER the `if !has_pre_args { return; }` line (257) and BEFORE `let win = app.window.get(window_id);` (260) — these don't need a window:

```zig
    // App-level lifecycle actions (no window handle needed). macOS-only;
    // raw blocks no-op elsewhere (Windows → #167).
    let is_set_quit_guard = action == "setQuitGuard";
    if is_set_quit_guard {
        let on_opt = pre_args.get_bool("enabled");
        let on: bool = false;
        if on_opt.is_some() { on = on_opt.unwrap(); }
        raw {
            #ifdef __APPLE__
            extern void darwin_set_quit_guard(bool enabled);
            darwin_set_quit_guard(on);
            #endif
        }
        return;
    }
    let is_quit = action == "quit";
    if is_quit {
        let force_opt = pre_args.get_bool("force");
        let force: bool = false;
        if force_opt.is_some() { force = force_opt.unwrap(); }
        raw {
            #ifdef __APPLE__
            extern void darwin_app_quit(bool force);
            darwin_app_quit(force);
            #endif
        }
        return;
    }
```

- [ ] **Step 5: Update the runtime `App` API**

In `runtime/app.ts`, replace the current `quit()` method (lines 57–60):

```ts
  /**
   * Quit the application.
   *
   * If a quit guard is armed via {@link App.setQuitGuard}, a plain
   * `App.quit()` is intercepted: the app stays open and fires
   * `AppEvent.BEFORE_QUIT` instead. Call `App.quit({ force: true })`
   * (e.g. after the user confirms in your "unsaved changes?" dialog) to
   * actually terminate.
   */
  quit(opts?: { force?: boolean }): void {
    appAction("quit", { force: opts?.force ?? false });
  },

  /**
   * Arm/disarm the app-level quit guard. When armed, Cmd-Q / the menu
   * Quit / `App.quit()` fire `AppEvent.BEFORE_QUIT` and do NOT terminate;
   * call `App.quit({ force: true })` to proceed. The App analog of
   * `WindowHandle.setCloseGuard`. macOS only.
   */
  setQuitGuard(enabled: boolean): void {
    appAction("setQuitGuard", { enabled });
  },
```

(Note: this drops the old `getBridge().emit("app:quit")` — it had no native handler. `appAction` is already defined at the top of `app.ts`.)

- [ ] **Step 6: Build-verify**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: …`

- [ ] **Step 7: Manual smoke**

In a dev run: `App.setQuitGuard(true)` + `App.on(AppEvent.BEFORE_QUIT, () => console.log("quit requested"))`. Cmd-Q → logs "quit requested" and the app stays open. `App.quit({ force: true })` → app quits.

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/platform.m native/app/router.zc runtime/app.ts
git commit -m "$(cat <<'EOF'
feat(app): cancelable BEFORE_QUIT quit guard + App.quit({force})

applicationShouldTerminate: fires app:before-quit and cancels when the
guard is armed; App.quit({force:true}) bypasses it. Mirrors the window
close-guard idiom. Replaces the dead emit("app:quit") with an explicit
t:4 action.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Auto-launch at login (`SMAppService`)

Runtime request/response API backed by `SMAppService.mainApp`, macOS 13+, graceful `false` on 12.

**Files:**
- Modify: `cli/src/build-config.ts` (link `ServiceManagement` on macOS, ~line 534)
- Modify: `native/platform/darwin/platform.m` (`#import` + `darwin_set_login_item` / `darwin_get_login_item`)
- Modify: `native/app/router.zc` (new `__app:` invoke branch + `router_handle_app`)
- Modify: `runtime/app.ts` (`setLoginItem` / `getLoginItemEnabled`)

- [ ] **Step 1: Link the ServiceManagement framework**

In `cli/src/build-config.ts`, in `generatePlatformConfig`, after the Carbon line (~534, `content += `//> macos: framework: Carbon\n`;`):

```ts
    // ServiceManagement — SMAppService.mainApp for App.setLoginItem (macOS 13+).
    content += `//> macos: framework: ServiceManagement\n`;
```

- [ ] **Step 2: Import the framework in platform.m**

At the top of `native/platform/darwin/platform.m`, with the other framework imports, add:

```objc
#import <ServiceManagement/ServiceManagement.h>
```

- [ ] **Step 3: Implement the login-item C functions**

Add at file scope in `platform.m` (outside `@implementation`):

```objc
bool darwin_set_login_item(bool enabled) {
    if (@available(macOS 13.0, *)) {
        SMAppService* svc = [SMAppService mainAppService];
        NSError* err = nil;
        BOOL ok = enabled ? [svc registerAndReturnError:&err]
                          : [svc unregisterAndReturnError:&err];
        return ok ? true : false;
    }
    return false; // login-item API unavailable on macOS 12
}

bool darwin_get_login_item(void) {
    if (@available(macOS 13.0, *)) {
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled ? true : false;
    }
    return false;
}
```

- [ ] **Step 4: Add the `__app:` invoke branch**

In `native/app/router.zc`, function `router_handle_message`, after the `__zapp:` prefix branch (line 60, before the `__protocol:respond` block at 66):

```zig
        // Check for __app: prefix (app-level request/response — login item, …)
        let is_app: bool = false;
        is_app = str::strncmp(parsed.method, "__app:", 6) == 0;
        if is_app {
            router_handle_app(parsed.method, parsed.args, parsed.has_args, window_id, parsed.request_id);
            return;
        }
```

- [ ] **Step 5: Implement `router_handle_app`**

Add a new function in `native/app/router.zc` (near `router_handle_zapp`, ~line 833). It mirrors the clipboard/zapp value-return pattern, ending in `dispatch_invoke_response`:

```zig
// __app:* request/response handlers. macOS-only; returns "false" elsewhere.
fn router_handle_app(method: string, args: JsonValue*, has_args: bool, window_id: int, request_id: int) -> void {
    let is_set = method == "__app:setLoginItem";
    let is_get = method == "__app:getLoginItem";
    if !is_set && !is_get { dispatch_invoke_response(window_id, request_id, false, "UNKNOWN"); return; }

    let result: bool = false;
    if is_set {
        let enabled: bool = false;
        if has_args {
            let e_opt = args.get_bool("enabled");
            if e_opt.is_some() { enabled = e_opt.unwrap(); }
        }
        raw {
            #ifdef __APPLE__
            extern bool darwin_set_login_item(bool enabled);
            result = darwin_set_login_item(enabled);
            #endif
        }
    } else {
        raw {
            #ifdef __APPLE__
            extern bool darwin_get_login_item(void);
            result = darwin_get_login_item();
            #endif
        }
    }

    if result { dispatch_invoke_response(window_id, request_id, true, "true"); }
    else      { dispatch_invoke_response(window_id, request_id, true, "false"); }
}
```

- [ ] **Step 6: Add the runtime methods**

In `runtime/app.ts`, inside the `App` object (after `quit`/`setQuitGuard`):

```ts
  /**
   * Enable or disable launch-at-login. Returns whether the change took
   * effect. macOS 13+; on macOS 12 this is a no-op that returns `false`.
   * iOS/Windows: `false`.
   */
  async setLoginItem(enabled: boolean): Promise<boolean> {
    return (await getBridge().invoke("__app:setLoginItem", { enabled })) as boolean;
  },

  /** Whether this app is registered to launch at login. */
  async getLoginItemEnabled(): Promise<boolean> {
    return (await getBridge().invoke("__app:getLoginItem")) as boolean;
  },
```

- [ ] **Step 7: Build-verify**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: …` (and `ServiceManagement` should appear under `--debug`, but `tail -1` success is the gate).

- [ ] **Step 8: Manual smoke**

Dev run: `await App.setLoginItem(true)` → app appears in System Settings ▸ General ▸ Login Items; `await App.getLoginItemEnabled()` → `true`; `setLoginItem(false)` → removed. (Login Items require a signed/bundled app; if the dev binary isn't bundled, confirm the calls resolve without throwing and return a boolean.)

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts native/platform/darwin/platform.m native/app/router.zc runtime/app.ts
git commit -m "$(cat <<'EOF'
feat(app): auto-launch at login via SMAppService (macOS 13+)

App.setLoginItem(enabled) / getLoginItemEnabled() backed by
SMAppService.mainApp behind @available(macOS 13); no-op false on 12.
New __app: request/response router branch + router_handle_app. Links
ServiceManagement on macOS.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `Window.setFocus` + `App.activate`

Raise a window and pull the app to the foreground — the global-shortcut / tray "summon" gap.

**Files:**
- Modify: `native/platform/darwin/window.m` (`darwin_window_focus`)
- Modify: `native/platform/darwin/window.h` (declaration)
- Modify: `native/window/window.zc` (`window_focus` Zen-C wrapper + extern decl; Windows no-op)
- Modify: `native/platform/darwin/platform.m` (`darwin_app_activate`)
- Modify: `native/app/router.zc` (`setFocus` window action + `activate` app action)
- Modify: `runtime/window.ts` (`setFocus` on `WindowHandle` interface + impl)
- Modify: `runtime/app.ts` (`activate`)

- [ ] **Step 1: Native `darwin_window_focus`**

In `native/platform/darwin/window.m`, after `darwin_window_minimize` (line 587), add:

```objc
void darwin_window_focus(void* handle) {
    if (!handle) return;
    NSWindow* window = (__bridge NSWindow*)handle;
    void (^run)(void) = ^{
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];  // raise the APP over others
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}
```

- [ ] **Step 2: Declare it in the header**

In `native/platform/darwin/window.h`, after line 55 (`void darwin_window_minimize(void* handle);`):

```c
void darwin_window_focus(void* handle);
```

- [ ] **Step 3: Zen-C wrapper + extern decl**

In `native/window/window.zc`:
- In the darwin `extern` block (where `darwin_window_minimize` is declared — grep `darwin_window_minimize` in this file), add the extern decl next to it:
  ```zig
  extern fn darwin_window_focus(handle: void*) -> void;
  ```
- In the darwin platform block, after line 727 (`fn window_minimize(...)`):
  ```zig
  fn window_focus(handle: void*) -> void { darwin_win::darwin_window_focus(handle); }
  ```
- In the Windows platform block, after line 781 (`fn window_minimize(...)` Windows variant), add a no-op (Windows impl deferred to #167):
  ```zig
  fn window_focus(handle: void*) -> void { /* no-op on Windows — see #167 */ }
  ```

- [ ] **Step 4: Native `darwin_app_activate`**

In `native/platform/darwin/platform.m`, at file scope:

```objc
void darwin_app_activate(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp activateIgnoringOtherApps:YES]; });
}
```

- [ ] **Step 5: Route both actions**

In `native/app/router.zc`:
- `setFocus` is a window action. Add the flag declaration next to `let is_set_always_on_top = …;` (~line 271):
  ```zig
  let is_set_focus = action == "setFocus";
  ```
  and the dispatch next to `if is_minimize { window_minimize(win.handle); return; }` (~line 583):
  ```zig
  if is_set_focus { window_focus(win.handle); return; }
  ```
- `activate` is an app-level action — add it to the app-level block from Task 3 (after the `setQuitGuard`/`quit` handlers, before the `win` lookup):
  ```zig
  let is_activate = action == "activate";
  if is_activate {
      raw {
          #ifdef __APPLE__
          extern void darwin_app_activate(void);
          darwin_app_activate();
          #endif
      }
      return;
  }
  ```

- [ ] **Step 6: Runtime `WindowHandle.setFocus`**

In `runtime/window.ts`:
- Add to the `WindowHandle` interface, next to `minimize(): void;` (line 194):
  ```ts
  /** Raise this window and bring the app to the foreground (macOS). */
  setFocus(): void;
  ```
- Add to the returned handle object, next to the other `windowAction` methods (~line 258):
  ```ts
  setFocus()                        { windowAction("setFocus", { windowId }); },
  ```

- [ ] **Step 7: Runtime `App.activate`**

In `runtime/app.ts`, inside the `App` object:

```ts
  /**
   * Bring the app to the foreground without targeting a specific window
   * (e.g. summon from a tray click). macOS only; no-op on iOS/Windows.
   */
  activate(): void {
    appAction("activate");
  },
```

- [ ] **Step 8: Build-verify**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: …`

- [ ] **Step 9: Manual smoke**

Dev run: bring another app (Finder) frontmost, then trigger `someWindow.setFocus()` (e.g. from a global shortcut or a tray click) → the Zapp window comes to the front over Finder. `App.activate()` raises the app with no specific window.

- [ ] **Step 10: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/window.m native/platform/darwin/window.h native/window/window.zc native/platform/darwin/platform.m native/app/router.zc runtime/window.ts runtime/app.ts
git commit -m "$(cat <<'EOF'
feat(window): Window.setFocus + App.activate (raise window + activate app)

darwin_window_focus does makeKeyAndOrderFront + activateIgnoringOtherApps
so a background/menu-bar app can summon its window over the frontmost
app (global shortcut / tray). App.activate() is the no-window companion.
Windows no-op (#167).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Docs + hello-world demo

**Files:**
- Modify: `docs/api-reference.md`
- Modify: `cli/README.md` (only if it documents `App`/lifecycle; otherwise skip)
- Modify: hello-world demo wiring — `hello-world/src/main.ts` and/or a worker (DO NOT clobber the user's uncommitted experiments; append a small, clearly-labeled demo block)

- [ ] **Step 1: Document the new APIs**

In `docs/api-reference.md`, add/extend the `App` and `Window` sections with:
- New `AppEvent`s: `WILL_SLEEP`, `DID_WAKE`, `SCREEN_LOCKED`, `SCREEN_UNLOCKED`, `BEFORE_QUIT` (with a sleep/wake sync-engine example and a `BEFORE_QUIT` + `setQuitGuard` + `quit({force})` confirm-dialog example).
- `App.setLoginItem(enabled)` / `App.getLoginItemEnabled()` (note macOS 13+, `false` on 12, needs a bundled/signed app to actually register).
- `App.setQuitGuard(enabled)` / `App.quit({ force })`.
- `App.activate()` and `WindowHandle.setFocus()`.
- A **"menu-bar / background app" recipe** documenting the existing `applicationShouldTerminateAfterLastWindowClosed` knob in `app.zc` (set `false`), combined with `Dock.hideIcon()`, a `Tray`, and `setFocus`/`activate` to summon.
- A short **"not on iOS/Windows yet"** note for these APIs (Windows → #167).

- [ ] **Step 2: hello-world demo wiring**

Append a small demo to hello-world (e.g. in `hello-world/src/main.ts`, clearly delimited with a comment) that:
- logs `app:did-wake` and `app:screen-locked`/`unlocked`,
- wires a "Quit" button through a `setQuitGuard` + `BEFORE_QUIT` confirm,
- has a tray/shortcut that calls `setFocus()`.

Keep it additive and labeled so it doesn't collide with the user's existing experiments in that file.

- [ ] **Step 3: Build-verify + full test suite**

```bash
cd /Users/zach/code/zapp && bun test runtime/events.test.ts && bun test cli/src
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1
```
Expected: events test PASS, cli suite PASS (29 baseline), build `[zapp] build complete: …`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md cli/README.md hello-world/src/main.ts
git commit -m "$(cat <<'EOF'
docs: background-app readiness — events, quit guard, login item, setFocus

api-reference additions + menu-bar-app recipe (documenting the existing
applicationShouldTerminateAfterLastWindowClosed knob) + a hello-world
demo wiring sleep/wake, quit guard, and setFocus.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- §1 five events → Task 1. ✅
- §2 power monitor (sleep/wake + lock/unlock) → Task 2. ✅
- §3a run-in-background (document existing knob, no new config) → Task 6 Step 1 recipe. ✅ (No config-validation task — correct per the reframe.)
- §3b BEFORE_QUIT guard + `quit({force})` → Task 3. ✅
- §4 auto-launch (SMAppService, 13+, false on 12, ServiceManagement) → Task 4. ✅
- §5 `setFocus` + `App.activate` → Task 5. ✅
- §6 parity (raw `#ifdef __APPLE__` guards; Windows no-op `window_focus`; `darwin_get_login_item` false elsewhere) → Tasks 3/4/5. ✅
- §6 testing (AppEvent↔name `bun test`; native by smoke) → Task 1 + per-task smokes. ✅
- §6 docs → Task 6. ✅
- Deferred (IOKit power-source, Windows impls, config alias) → correctly NOT tasked.

**Placeholder scan:** No TBD/TODO-as-work. Every code step shows exact code; the one "find via grep" reference (Task 5 Step 3 extern decl) names the exact grep target + file. ✅

**Type/name consistency:** `AppEvent.{WILL_SLEEP,DID_WAKE,SCREEN_LOCKED,SCREEN_UNLOCKED,BEFORE_QUIT}` and names `app:will-sleep/did-wake/screen-locked/screen-unlocked/before-quit` consistent across Tasks 1/2/3. `darwin_set_quit_guard`/`darwin_app_quit`/`darwin_app_activate`/`darwin_window_focus`/`darwin_set_login_item`/`darwin_get_login_item` consistent between their definitions (platform.m/window.m) and `extern` uses (router.zc). Method names `__app:setLoginItem`/`__app:getLoginItem` consistent between runtime (`app.ts`) and router (`router_handle_app`). `window_focus` Zen-C wrapper consistent between window.zc and router.zc. ✅
