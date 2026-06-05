# Screen / Displays API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only `Screen` API (`getAll`/`getPrimary`/`getById`/`getCursorPoint` + `Window.getScreen()` + `AppEvent.SCREENS_CHANGED`) and standardize all window/screen coordinates on **top-left global**.

**Architecture:** Native-first. `darwin_screen_*` C primitives (`native/platform/darwin/screen.m`, NSScreen + NSJSONSerialization) emit `Display` JSON in top-left global coords via a shared `zapp_primary_screen_height()` flip; `window.m` converts set/get/create position to top-left using the same helper. A Zen-C `screen_route` handles `__screen:*` invoke methods (request/response, like `__zapp:workers-list`). The TS `Screen` namespace + `Window.getScreen()` wrap the invokes; `AppEvent.SCREENS_CHANGED` rides the existing app-event chain.

**Tech Stack:** Objective-C (NSScreen/CGDirectDisplay/NSJSONSerialization), Zen-C (`zc`), TypeScript (`bun:test`), Bun.

**Branch:** `feat/screen-api` (created, spec committed).

**Spec:** `docs/superpowers/specs/2026-06-05-screen-displays-api-design.md`

**Key invariant:** **top-left global** — origin at the primary display's top-left, y grows down. `Display.bounds`/`workArea`, cursor point, AND `Window.setPosition`/`getPosition`/`create({x,y})` all use it. Native converts via `y_topleft = Hp - y_bottomleft_topEdge` where `Hp = NSScreen.screens[0].frame.size.height`.

**Conventions:**
- Stage ONLY the files each task names. Never `git add -A`. Never stage `vendor/*`, `hello-world/*` (except T8, which is verify-only — no hello-world commit), `node_modules`, `native/worker/engines/zjs-cross-eval-test.c`, `benchmarks/*`.
- Build success = LAST line `[zapp] build complete: <path>` (NOT Vite's `✓ built`). `bun run build` does NOT type-check — run `bun run check` separately.
- `#ifdef __APPLE__` is true on iOS; every `darwin_*` referenced from `.zc` needs an iOS def (`native/platform/ios/*.m`) or the iOS link fails + `cli/src/ios-platform-parity.test.ts` flags it.
- Native JSON is built with **NSJSONSerialization** (no fixed `char[]` buffers — avoids the truncation-bug family). Returned C strings are `strdup`'d; the Zen-C route `free()`s them (mirrors `__zapp:workers-list`).
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## Task 1: `AppEvent.SCREENS_CHANGED` event chain

**Files:**
- Modify: `runtime/events.ts` (add enum member + name)
- Modify: `native/app/app_events.zc` (id→name case)
- Modify: `native/platform/darwin/platform.m` (macro + observer)
- Modify: `native/platform/ios/platform.m` (macro only)

- [ ] **Step 1: Add the enum member + name (`runtime/events.ts`)**

In the `AppEvent` enum, after `BATTERY_LEVEL_CHANGED = 115,` add:
```ts
  SCREENS_CHANGED = 116,   // displays added/removed/reconfigured
```
In `APP_EVENT_NAMES`, after the `BATTERY_LEVEL_CHANGED` line add:
```ts
  [AppEvent.SCREENS_CHANGED]: "app:screens-changed",
```

- [ ] **Step 2: Map the id in `native/app/app_events.zc`**

In the `switch (event_id)` block, after `case 115: js_name = "app:battery-level-changed"; break;` add:
```c
    case 116: js_name = "app:screens-changed"; break;
```

- [ ] **Step 3: Darwin macro + observer (`native/platform/darwin/platform.m`)**

After `#define ZAPP_EVENT_APP_BATTERY_LEVEL_CHANGED 115` add:
```objc
#define ZAPP_EVENT_APP_SCREENS_CHANGED       116
```
Find where the screen lock/unlock observers are registered (the `com.apple.screenIsLocked` block, ~line 254). Right after them, register the screen-parameters observer on the **default** center (NSApplication posts this one, not the distributed center):
```objc
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(zappScreensChanged:)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
```
Then add the selector method next to the existing `zappScreenLocked:` / `zappScreenUnlocked:` methods (mirror their shape — they call `zapp_app_dispatch`):
```objc
- (void)zappScreensChanged:(NSNotification*)note {
    (void)note;
    zapp_app_dispatch(ZAPP_EVENT_APP_SCREENS_CHANGED, "{}");
}
```
(`zapp_app_dispatch(int event_id, const char* data)` is already declared/used by the lock observers.)

- [ ] **Step 4: iOS macro for symmetry (`native/platform/ios/platform.m`)**

After `#define ZAPP_EVENT_APP_BATTERY_LEVEL_CHANGED 115` add the same line:
```objc
#define ZAPP_EVENT_APP_SCREENS_CHANGED       116
```
(No iOS observer in v1 — external-display hot-plug deferred. Macro kept for block symmetry.)

- [ ] **Step 5: Verify check + build**

```bash
cd /Users/zach/code/zapp
bun run check 2>&1 | grep -c 'error TS'                       # 0
cd hello-world && bun run build 2>&1 | tail -1                 # [zapp] build complete:
```

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/events.ts native/app/app_events.zc native/platform/darwin/platform.m native/platform/ios/platform.m
git commit -m "$(cat <<'EOF'
feat(screen): AppEvent.SCREENS_CHANGED (116) + display-reconfig observer

NSApplicationDidChangeScreenParametersNotification (macOS) dispatches the
new app event so apps can re-query displays on monitor plug/unplug or
resolution change. iOS macro added for symmetry (no observer in v1).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: macOS screen query primitives (`screen.m`)

**Files:**
- Create: `native/platform/darwin/screen.m`
- Modify: `cli/src/native.ts` (register in darwin `getPlatformSources`)
- Modify: `native/build.zc` (macOS cflags)

- [ ] **Step 1: Write `native/platform/darwin/screen.m`**

```objc
// macOS display enumeration. Emits Display JSON in TOP-LEFT GLOBAL coords
// (origin = primary display's top-left, y down). NSScreen is bottom-left
// global, so every y flips around the primary screen height. JSON is built
// with NSJSONSerialization (no fixed buffers). Returned strings are strdup'd;
// the Zen-C route frees them.
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

// Primary display height — the reference for bottom-left <-> top-left flips.
// Shared with window.m (extern) so window position uses the same origin.
double zapp_primary_screen_height(void) {
    NSArray<NSScreen*>* screens = [NSScreen screens];
    if (screens.count == 0) return 0.0;
    return screens[0].frame.size.height;
}

static NSDictionary* zapp_rect_topleft(NSRect r, double Hp) {
    // r is bottom-left global; top-edge in top-left global = Hp - (y + height).
    return @{
        @"x": @((int)r.origin.x),
        @"y": @((int)(Hp - (r.origin.y + r.size.height))),
        @"width": @((int)r.size.width),
        @"height": @((int)r.size.height),
    };
}

static NSDictionary* zapp_display_dict(NSScreen* s, double Hp) {
    CGDirectDisplayID did =
        (CGDirectDisplayID)[[s.deviceDescription objectForKey:@"NSScreenNumber"] unsignedIntValue];
    NSString* name = @"Display";
    if (@available(macOS 10.15, *)) { if (s.localizedName) name = s.localizedName; }
    return @{
        @"id": [NSString stringWithFormat:@"%u", (unsigned)did],
        @"name": name,
        @"bounds": zapp_rect_topleft(s.frame, Hp),
        @"workArea": zapp_rect_topleft(s.visibleFrame, Hp),
        @"scaleFactor": @(s.backingScaleFactor),
        @"isPrimary": @(CGDisplayIsMain(did) != 0),
        @"rotation": @((int)CGDisplayRotation(did)),
    };
}

static const char* zapp_json_strdup(id obj) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return NULL;
    NSString* s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ? strdup([s UTF8String]) : NULL;
}

const char* darwin_screen_list_json(void) {
    @autoreleasepool {
        double Hp = zapp_primary_screen_height();
        NSMutableArray* arr = [NSMutableArray array];
        for (NSScreen* s in [NSScreen screens]) [arr addObject:zapp_display_dict(s, Hp)];
        return zapp_json_strdup(arr);
    }
}

const char* darwin_screen_cursor_json(void) {
    @autoreleasepool {
        double Hp = zapp_primary_screen_height();
        NSPoint pt = [NSEvent mouseLocation]; // bottom-left global
        NSScreen* hit = nil;
        for (NSScreen* s in [NSScreen screens]) {
            if (NSPointInRect(pt, s.frame)) { hit = s; break; }
        }
        if (!hit) hit = [NSScreen mainScreen];
        NSDictionary* out = @{
            @"x": @((int)pt.x),
            @"y": @((int)(Hp - pt.y)),
            @"display": zapp_display_dict(hit, Hp),
        };
        return zapp_json_strdup(out);
    }
}

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);

const char* darwin_screen_for_window_json(int32_t window_id) {
    @autoreleasepool {
        double Hp = zapp_primary_screen_height();
        void* wp = darwin_window_get_by_numeric_id(window_id);
        NSScreen* s = nil;
        if (wp) s = ((__bridge NSWindow*)wp).screen;
        if (!s) s = [NSScreen mainScreen];
        return zapp_json_strdup(zapp_display_dict(s, Hp));
    }
}
```

- [ ] **Step 2: Register in the app build source list (`cli/src/native.ts`)**

In `getPlatformSources`, in the **darwin** list (after the `panel.m` entry, ~line 62), add:
```ts
      path.join(darwinDir, "screen.m"),
```

- [ ] **Step 3: Register in the standalone framework build (`native/build.zc`)**

Append ` platform/darwin/screen.m` to the macOS cflags source line (the one ending `... platform/darwin/panel.m`):
```
//> macos: cflags: platform/darwin/platform.m platform/darwin/window.m platform/darwin/webview.m platform/darwin/panel.m platform/darwin/screen.m
```

- [ ] **Step 4: Verify the macOS build compiles screen.m**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3
```
Expect `[zapp] build complete:` (the `darwin_screen_*` are compiled-but-uncalled until Task 5 — fine). Fix any clang errors in screen.m and rebuild; report fixes.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/screen.m cli/src/native.ts native/build.zc
git commit -m "$(cat <<'EOF'
feat(screen): macOS display query primitives (darwin_screen_*)

NSScreen enumeration -> Display JSON in top-left global coords (flip via
shared zapp_primary_screen_height). list / cursor / for_window via
NSJSONSerialization (no fixed buffers). Registered in getPlatformSources
+ build.zc.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Window position → top-left (the breaking change)

**Files:**
- Modify: `native/platform/darwin/window.m` (`darwin_window_set_position`, `darwin_window_get_position`, the create-frame origin)

- [ ] **Step 1: Convert `darwin_window_set_position`**

Replace:
```objc
void darwin_window_set_position(void* handle, int32_t x, int32_t y) {
    [(__bridge NSWindow*)handle setFrameOrigin:NSMakePoint(x, y)];
}
```
with:
```objc
extern double zapp_primary_screen_height(void);

void darwin_window_set_position(void* handle, int32_t x, int32_t y) {
    // x,y are top-left global; setFrameOrigin wants bottom-left.
    NSWindow* w = (__bridge NSWindow*)handle;
    CGFloat blY = zapp_primary_screen_height() - (CGFloat)y - w.frame.size.height;
    [w setFrameOrigin:NSMakePoint((CGFloat)x, blY)];
}
```
(If `window.m` already has an `extern double zapp_primary_screen_height(void);` from another edit, don't duplicate it — declare it once near the top.)

- [ ] **Step 2: Convert `darwin_window_get_position`**

Replace:
```objc
void darwin_window_get_position(void* handle, int32_t* out_x, int32_t* out_y) {
    NSRect frame = [(__bridge NSWindow*)handle frame];
    *out_x = (int32_t)frame.origin.x;
    *out_y = (int32_t)frame.origin.y;
}
```
with:
```objc
void darwin_window_get_position(void* handle, int32_t* out_x, int32_t* out_y) {
    NSRect frame = [(__bridge NSWindow*)handle frame];
    *out_x = (int32_t)frame.origin.x;
    *out_y = (int32_t)(zapp_primary_screen_height() - frame.origin.y - frame.size.height);
}
```

- [ ] **Step 3: Convert the create-frame origin (READ FIRST)**

In `darwin_window_create`, the frame is built as:
```objc
NSRect frame = NSMakeRect(wopts_x(opts), wopts_y(opts), wopts_width(opts), wopts_height(opts));
```
**Read the surrounding function first** to find the auto-center / default-placement handling (`wopts_auto_center`). Convert the y for the **explicit-position case only**, preserving auto-center/default. Replace the `NSMakeRect(...)` line with:
```objc
CGFloat _createTopY = (CGFloat)wopts_y(opts);
CGFloat _createBLY = zapp_primary_screen_height() - _createTopY - (CGFloat)wopts_height(opts);
NSRect frame = NSMakeRect(wopts_x(opts), _createBLY, wopts_width(opts), wopts_height(opts));
```
Then confirm: if `wopts_auto_center(opts)` (or the existing centering path) runs after this and overrides the origin, the conversion is harmless (discarded). If the code treats `x==0 && y==0` as "let the OS place it", keep that guard intact — only convert when a real position is set. (The verification in Step 4 checks both an explicit-position window and an auto-centered one.)

- [ ] **Step 4: Verify the macOS build + a coordinate sanity check**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2
```
Expect `[zapp] build complete:`. Manual check (report it): a `Window.create({ x: 50, y: 50, width: 400, height: 300 })` should put the window's **top-left** ~50px from the screen's top-left (not the bottom); a `Window.create({ autoCenter: true })` (or no x/y) should still center. (Full visual verify is the user's smoke in Task 8.)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/window.m
git commit -m "$(cat <<'EOF'
feat(window)!: top-left global window coordinates

BREAKING: Window.setPosition/getPosition/create({x,y}) now use top-left
global origin (was macOS-native bottom-left), matching the new Screen API
so a window can be placed on a display by its bounds. Converts via the
shared zapp_primary_screen_height flip; auto-center preserved.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: iOS screen stubs (singular display)

**Files:**
- Create: `native/platform/ios/screen.m`
- Modify: `cli/src/native.ts` (register in iOS `getPlatformSources`)

- [ ] **Step 1: Write `native/platform/ios/screen.m`**

iOS has one logical display. Real-but-singular via `UIScreen.mainScreen`; `bounds==workArea`, `isPrimary:true`, `rotation:0`, no cursor.
```objc
// iOS display info — singular (UIScreen.mainScreen). External-display
// hot-plug deferred. Signatures match the macOS darwin_screen_* (the shared
// router.zc references them under #ifdef __APPLE__, true on iOS too).
#import <UIKit/UIKit.h>
#import <stdint.h>

static NSDictionary* zapp_ios_display_dict(void) {
    UIScreen* s = [UIScreen mainScreen];
    CGRect b = s.bounds;
    NSDictionary* rect = @{ @"x": @0, @"y": @0,
                            @"width": @((int)b.size.width), @"height": @((int)b.size.height) };
    return @{
        @"id": @"main", @"name": @"Built-in",
        @"bounds": rect, @"workArea": rect,
        @"scaleFactor": @(s.scale), @"isPrimary": @YES, @"rotation": @0,
    };
}

static const char* zapp_ios_json_strdup(id obj) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return NULL;
    NSString* s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ? strdup([s UTF8String]) : NULL;
}

const char* darwin_screen_list_json(void) {
    @autoreleasepool { return zapp_ios_json_strdup(@[ zapp_ios_display_dict() ]); }
}
const char* darwin_screen_cursor_json(void) {
    @autoreleasepool {
        return zapp_ios_json_strdup(@{ @"x": @0, @"y": @0, @"display": zapp_ios_display_dict() });
    }
}
const char* darwin_screen_for_window_json(int32_t window_id) {
    (void)window_id;
    @autoreleasepool { return zapp_ios_json_strdup(zapp_ios_display_dict()); }
}
```

- [ ] **Step 2: Register in the iOS source list (`cli/src/native.ts`)**

In `getPlatformSources`, in the **iOS** list (after the `panel.m` entry, ~line 91), add:
```ts
      path.join(iosDir, "screen.m"),
```

- [ ] **Step 3: Verify the iOS-sim build**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator 2>&1 | tail -3
```
Expect `[zapp] build complete:`. (If the iOS toolchain is unavailable, syntax-check: `clang -fsyntax-only -x objective-c native/platform/ios/screen.m -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)"` → no output. Report which path.)

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/screen.m cli/src/native.ts
git commit -m "$(cat <<'EOF'
feat(screen): iOS singular display (UIScreen)

darwin_screen_* on iOS report one display (UIScreen.mainScreen);
bounds==workArea, isPrimary, no cursor. Matches the macOS signatures so
the shared router links on iOS. External-display hot-plug deferred.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Zen-C routing (`screen.zc` + router + app wiring)

**Files:**
- Create: `native/screen/screen.zc`
- Modify: `native/app/app.zc` (import)
- Modify: `native/app/router.zc` (`__screen:` dispatch)

- [ ] **Step 1: Write `native/screen/screen.zc`**

Mirrors `router_handle_zapp`'s `dispatch_invoke_response` + `free` pattern. Returns `true` if it handled the method.
```rust
// Screen/display query routing. router.zc delegates __screen:* invoke
// methods here; these call the darwin_screen_* C primitives and respond via
// dispatch_invoke_response (request/response, like __zapp:workers-list).
import "std/json.zc";

fn screen_route(method: string, window_id: int, request_id: int, args: JsonValue*) -> bool {
    if method == "__screen:list" {
        let json: string = NULL;
        raw {
            #ifdef __APPLE__
            extern char* darwin_screen_list_json(void);
            json = darwin_screen_list_json();
            #endif
        }
        if json == NULL { dispatch_invoke_response(window_id, request_id, true, "[]"); return true; }
        dispatch_invoke_response(window_id, request_id, true, json);
        raw { free((void*)json); }
        return true;
    }
    if method == "__screen:cursor" {
        let json: string = NULL;
        raw {
            #ifdef __APPLE__
            extern char* darwin_screen_cursor_json(void);
            json = darwin_screen_cursor_json();
            #endif
        }
        if json == NULL { dispatch_invoke_response(window_id, request_id, false, "null"); return true; }
        dispatch_invoke_response(window_id, request_id, true, json);
        raw { free((void*)json); }
        return true;
    }
    if method == "__screen:forWindow" {
        let target: int = -1;
        let wid_opt = args.get_string("windowId");
        if wid_opt.is_some() {
            let ws: string = wid_opt.unwrap();
            raw {
                #ifdef __APPLE__
                extern int32_t darwin_window_numeric_id_for_string(const char* wid);
                target = (int)darwin_window_numeric_id_for_string((const char*)ws);
                #endif
            }
        }
        let json: string = NULL;
        raw {
            #ifdef __APPLE__
            extern char* darwin_screen_for_window_json(int32_t window_id);
            json = darwin_screen_for_window_json(target);
            #endif
        }
        if json == NULL { dispatch_invoke_response(window_id, request_id, false, "null"); return true; }
        dispatch_invoke_response(window_id, request_id, true, json);
        raw { free((void*)json); }
        return true;
    }
    return false;
}
```

- [ ] **Step 2: Import from `native/app/app.zc`**

Next to `import "../window/window.zc";` (and the panel import added earlier), add:
```rust
import "../screen/screen.zc";
```

- [ ] **Step 3: Delegate `__screen:` in `router.zc`**

In `router_handle_message`, find the `is_zapp` block (the `str::strncmp(parsed.method, "__zapp:", 7)` check, ~line 54-60). Immediately AFTER that block, add:
```rust
    let is_screen: bool = false;
    is_screen = str::strncmp(parsed.method, "__screen:", 9) == 0;
    if is_screen {
        screen_route(parsed.method, window_id, parsed.request_id, parsed.args);
        return;
    }
```
(`window_id`, `parsed.request_id`, `parsed.method`, `parsed.args` are all in scope there — same as the `__zapp:` path. For `__screen:list`/`cursor`, `args` is unused; for `forWindow` the runtime always sends `{windowId}`.)

- [ ] **Step 4: Verify macOS build + iOS parity + iOS-sim build**

```bash
cd /Users/zach/code/zapp
cd hello-world && bun run build 2>&1 | tail -2                       # [zapp] build complete:
cd /Users/zach/code/zapp && bun test ./cli/src/ios-platform-parity.test.ts 2>&1 | tail -3   # pass
cd hello-world && bun run build --platform ios-simulator 2>&1 | tail -2   # [zapp] build complete:
```
Expect: macOS links `darwin_screen_*`; parity passes (iOS defs present); iOS-sim links. If `zc` errors on `screen.zc`, reconcile against how `router.zc`'s `router_handle_zapp` does the same (e.g. `free((void*)json)` in a `raw` block, `str::strncmp`) — report any fix.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/screen/screen.zc native/app/app.zc native/app/router.zc
git commit -m "$(cat <<'EOF'
feat(screen): Zen-C screen_route + router/app wiring

screen.zc routes __screen:list/cursor/forWindow to darwin_screen_* via
dispatch_invoke_response (frees the strdup'd JSON); router.zc delegates
after the __zapp: prefix; app.zc imports it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: TS runtime — `Screen` namespace + `Window.getScreen()` (TDD for filters)

**Files:**
- Create: `runtime/screen.ts`
- Create: `runtime/screen.test.ts`
- Modify: `runtime/window.ts` (`getScreen()`)
- Modify: `runtime/index.ts` (export)

- [ ] **Step 1: Write the failing test (`runtime/screen.test.ts`)**

```ts
import { test, expect } from "bun:test";
import { findPrimary, findById, type Display } from "./screen";

const d = (id: string, isPrimary = false): Display => ({
  id, name: id, bounds: { x: 0, y: 0, width: 100, height: 100 },
  workArea: { x: 0, y: 0, width: 100, height: 100 },
  scaleFactor: 2, isPrimary, rotation: 0,
});

test("findPrimary returns the isPrimary display", () => {
  const list = [d("a"), d("b", true), d("c")];
  expect(findPrimary(list)?.id).toBe("b");
});
test("findPrimary falls back to the first display if none flagged", () => {
  expect(findPrimary([d("a"), d("b")])?.id).toBe("a");
});
test("findPrimary returns null for an empty list", () => {
  expect(findPrimary([])).toBeNull();
});
test("findById matches by id, null when absent", () => {
  const list = [d("a"), d("b", true)];
  expect(findById(list, "b")?.id).toBe("b");
  expect(findById(list, "zzz")).toBeNull();
});
```

- [ ] **Step 2: Run — expect FAIL (no module)**

`cd /Users/zach/code/zapp && bun test ./runtime/screen.test.ts` → FAIL (cannot find `./screen`).

- [ ] **Step 3: Write `runtime/screen.ts`**

```ts
/**
 * Screen — enumerate displays + their geometry. All coordinates are
 * TOP-LEFT GLOBAL (origin at the primary display's top-left, y down),
 * matching Window.setPosition/getPosition, so a window can be placed on a
 * display by its bounds. Async (queries native each call); subscribe to
 * AppEvent.SCREENS_CHANGED to re-query on monitor plug/unplug.
 */
import { getBridge } from "./bridge";

export interface DisplayRect { x: number; y: number; width: number; height: number; }

export interface Display {
  id: string;
  name: string;
  bounds: DisplayRect;
  workArea: DisplayRect;
  scaleFactor: number;
  isPrimary: boolean;
  rotation: 0 | 90 | 180 | 270;
}

export interface CursorPoint { x: number; y: number; display: Display; }

// invoke() may return an already-parsed object or a JSON string depending on
// payload; coerce defensively either way.
function coerce<T>(r: unknown): T {
  return (typeof r === "string" ? JSON.parse(r) : r) as T;
}

// Pure (unit-tested) selectors over a display list. ---
export function findPrimary(displays: Display[]): Display | null {
  return displays.find((d) => d.isPrimary) ?? displays[0] ?? null;
}
export function findById(displays: Display[], id: string): Display | null {
  return displays.find((d) => d.id === id) ?? null;
}

async function getAll(): Promise<Display[]> {
  return coerce<Display[]>(await getBridge().invoke("__screen:list")) ?? [];
}

export const Screen = {
  /** All connected displays. */
  getAll,
  /** The primary (menu-bar) display, or null if none. */
  async getPrimary(): Promise<Display | null> {
    return findPrimary(await getAll());
  },
  /** A display by id, or null if not found. */
  async getById(id: string): Promise<Display | null> {
    return findById(await getAll(), id);
  },
  /** Current mouse location + the display it's on. (macOS; iOS returns {0,0}.) */
  async getCursorPoint(): Promise<CursorPoint> {
    return coerce<CursorPoint>(await getBridge().invoke("__screen:cursor"));
  },
};
```

- [ ] **Step 4: Run — expect PASS**

`bun test ./runtime/screen.test.ts` → 4 pass.

- [ ] **Step 5: Add `Window.getScreen()` (`runtime/window.ts`)**

At the top, add to the existing imports:
```ts
import type { Display } from "./screen";
```
In the `WindowHandle` interface, after `loadUrl(url: string): void;` add:
```ts
  /** The display this window is currently on (top-left global coords). */
  getScreen(): Promise<Display>;
```
In `createWindowHandle`'s returned object, after the `loadUrl(...)` line add (uses the closured `bridge` + `windowId`):
```ts
    async getScreen(): Promise<Display> {
      const r = await bridge.invoke("__screen:forWindow", { windowId });
      return (typeof r === "string" ? JSON.parse(r) : r) as Display;
    },
```

- [ ] **Step 6: Export from `runtime/index.ts`**

After the `Window` export line, add:
```ts
export { Screen, type Display, type DisplayRect, type CursorPoint } from "./screen";
```

- [ ] **Step 7: Type gate + tests**

```bash
cd /Users/zach/code/zapp
bun run check 2>&1 | grep -c 'error TS'        # 0
bun test ./runtime/screen.test.ts 2>&1 | tail -2   # 4 pass
```

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/screen.ts runtime/screen.test.ts runtime/window.ts runtime/index.ts
git commit -m "$(cat <<'EOF'
feat(screen): Screen namespace + Window.getScreen() runtime

Screen.getAll/getPrimary/getById/getCursorPoint over __screen:* invokes;
pure findPrimary/findById (bun-tested); Window.getScreen() returns the
window's current Display. All top-left global. Exported from runtime/index.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Docs

**Files:**
- Modify: `docs/api-reference.md` (Screen section + top-left coordinate note)

- [ ] **Step 1: Add the Screen section**

In `docs/api-reference.md`, after the `Window` section (match the file's `##` heading depth), add:
```markdown
## Screen (displays)

Enumerate displays + geometry. All coordinates are **top-left global** —
origin at the primary display's top-left, y grows down — the same system
`Window.setPosition`/`getPosition`/`create({x,y})` use, so you can place a
window on a display by its bounds.

```ts
import { Screen, Window, App, AppEvent } from "@zappdev/runtime";

const displays = await Screen.getAll();      // Display[]
const primary  = await Screen.getPrimary();  // Display | null
const byId     = await Screen.getById(id);   // Display | null
const cursor   = await Screen.getCursorPoint(); // { x, y, display }
const onScreen = await Window.current().getScreen(); // Display

// open a window centered on the display under the cursor:
const c = await Screen.getCursorPoint();
await Window.create({
  x: c.display.workArea.x + (c.display.workArea.width - 400) / 2,
  y: c.display.workArea.y + (c.display.workArea.height - 300) / 2,
  width: 400, height: 300,
});

// re-layout when displays change (monitor plug/unplug, resolution change):
App.on(AppEvent.SCREENS_CHANGED, async () => relayout(await Screen.getAll()));
```

**`Display`:** `id` (stable), `name`, `bounds` `{x,y,width,height}`, `workArea`
(minus menu bar/dock), `scaleFactor` (1 or 2), `isPrimary`, `rotation`
(0/90/180/270).

**Platform:** macOS full. iOS reports one display (`UIScreen`); `getCursorPoint`
returns `{0,0}`. Windows: empty list (stub).
```

- [ ] **Step 2: Add the breaking-change note to the Window section**

In the `Window` section, near `setPosition`/`getPosition` (or as a short callout), add:
```markdown
> **Coordinates are top-left global** (origin at the primary display's
> top-left, y down) — consistent with the `Screen` API. (Changed from the
> earlier macOS-native bottom-left in the Screen/Displays release.)
```

- [ ] **Step 3: Verify fences + commit**

```bash
cd /Users/zach/code/zapp
grep -c '```' docs/api-reference.md   # even
git add docs/api-reference.md
git commit -m "$(cat <<'EOF'
docs(screen): document the Screen API + top-left coordinate convention

Screen.getAll/getPrimary/getById/getCursorPoint + Window.getScreen() +
SCREENS_CHANGED, the Display shape, platform notes, and the Window
top-left coordinate change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Full verification + smoke snippet

**Files:** none committed (verify-only; hello-world has uncommitted user WIP — do NOT commit it).

- [ ] **Step 1: Full gate**

```bash
cd /Users/zach/code/zapp
bun run check 2>&1 | grep -c 'error TS'                       # 0
bun run test:all 2>&1 | tail -6                                # TS + native + check green
cd hello-world && bun run build 2>&1 | tail -1                 # [zapp] build complete:
bun run build --platform ios-simulator 2>&1 | tail -1         # [zapp] build complete:
```

- [ ] **Step 2: Hand off the manual smoke snippet**

Report this snippet for the user to paste into a webview context and run via `bun run dev` (macOS, ideally multi-monitor):
```ts
import { Screen, Window, App, AppEvent } from "@zappdev/runtime";
console.log("displays", await Screen.getAll());
console.log("primary", await Screen.getPrimary());
console.log("cursor", await Screen.getCursorPoint());
console.log("this window on", await Window.current().getScreen());
App.on(AppEvent.SCREENS_CHANGED, async () => console.log("screens changed", await Screen.getAll()));
// placement check (top-left): should land ~50px from the screen's TOP-left:
await Window.create({ x: 50, y: 50, width: 400, height: 300, title: "top-left @ 50,50" });
```
Checklist: `getAll` lists displays with sensible top-left `bounds`/`workArea`; `isPrimary` on exactly one; `scaleFactor` 1/2; the new window lands at the **top**-left (not bottom); `getScreen()` returns the right display; unplug/replug a monitor or change resolution fires `SCREENS_CHANGED`. Multi-monitor needed for full coverage.

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- Async `Screen.getAll/getPrimary/getById/getCursorPoint` → Task 6. ✅
- `Window.getScreen()` → Task 6. ✅
- `AppEvent.SCREENS_CHANGED` (event chain + observer) → Task 1. ✅
- `Display` fields {id,name,bounds,workArea,scaleFactor,isPrimary,rotation} → Tasks 2 (native dict) + 6 (type). ✅
- Top-left global everywhere incl. Window position breaking change → Tasks 2/3 (native flip via shared `zapp_primary_screen_height`). ✅
- Native-first chain (darwin screen.m → screen.zc → router → TS → docs) → Tasks 2/5/6/7. ✅
- macOS-first + iOS singular + Windows stub (empty) → Tasks 2/4/5. ✅
- bun:test for getById/getPrimary filtering → Task 6. ✅
- Verification (check/test:all/macOS+ios builds) → Task 8 (+ per-task). ✅
- Non-goals (refresh/HDR, display config, iOS hot-plug, Windows real) → respected. ✅

**Placeholder scan:** No TBD. Task 3 Step 3 says "read the function first" for the create-frame auto-center interaction — that's an unavoidable integration point (the centering logic wasn't in the extracted excerpt), and the exact conversion line + the rule (convert explicit position, preserve auto-center) are given. Not a vague placeholder.

**Type/name consistency:** `Display`/`DisplayRect`/`CursorPoint`, `findPrimary`/`findById`, `darwin_screen_list_json`/`cursor_json`/`for_window_json`, `zapp_primary_screen_height`, route strings `__screen:list`/`cursor`/`forWindow`, event id `116` + `app:screens-changed` + `ZAPP_EVENT_APP_SCREENS_CHANGED` — all consistent across native, Zen-C, and TS. `dispatch_invoke_response(window_id, request_id, ok, payload)` matches the verified signature. The `coerce`/inline-parse handles invoke's string-or-object return uniformly.
