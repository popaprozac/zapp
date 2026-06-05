# Screen / Displays API — design

**Date:** 2026-06-05
**Branch:** `feat/screen-api`
**Surfaced by:** the 2026-06-05 competitive gap analysis — Zapp had **no** displays API while Wails (`app.Screen.GetAll/GetPrimary/GetByID` + `window.GetScreen`) and Electrobun (`getAllDisplays`/`getPrimaryDisplay`/`getCursorScreenPoint`) both do. Read-mostly enumeration of displays + geometry, for multi-monitor window placement.

## Decisions (from brainstorming)

1. **Access model — async query + change event.** `await Screen.getAll()` etc. go through invoke (always fresh, no cache, no bootstrap injection); `App.on(AppEvent.SCREENS_CHANGED)` signals when to re-query. (Rejected: a `getPowerState`-style sync cached getter — more machinery for marginal benefit since displays change rarely.)
2. **Fields** per display: `id`, `name`, `bounds`, `workArea`, `scaleFactor`, `isPrimary`, `rotation`. (Rejected: minimal-without-name/rotation; and everything-incl-refresh/HDR as YAGNI for v1.)
3. **Extras included:** `Window.getScreen()` and `Screen.getCursorPoint()` (both cheap + high-value). Base `getAll`/`getPrimary`/`getById` always.
4. **Coordinate origin — TOP-LEFT GLOBAL everywhere.** Origin at the primary display's top-left, y grows down (web/Windows/iOS-consistent). This **also converts `Window.setPosition`/`getPosition`/`Window.create({x,y})` from the current macOS-native bottom-left to top-left** so window-on-screen placement works. Breaking change, acceptable pre-1.0. (Rejected: bottom-left-to-match-today; top-left-Screen-but-leave-Window — the latter guarantees a mirrored-Y placement bug.)

## API surface

New top-level `Screen` namespace + a `WindowHandle` method + an app event. The type is `Display` (the name `Screen` is the namespace).

```ts
import { Screen, Window, App, AppEvent } from "@zappdev/runtime";

export interface DisplayRect { x: number; y: number; width: number; height: number; }

export interface Display {
  id: string;                  // stable CGDirectDisplayID, stringified
  name: string;                // NSScreen.localizedName ("Built-in Retina Display")
  bounds: DisplayRect;         // full display rect, top-left global
  workArea: DisplayRect;       // usable area (minus menu bar + dock), top-left global
  scaleFactor: number;         // backingScaleFactor — 1 or 2
  isPrimary: boolean;          // the menu-bar/origin display
  rotation: 0 | 90 | 180 | 270;
}

await Screen.getAll();                 // Promise<Display[]>
await Screen.getPrimary();             // Promise<Display>
await Screen.getById(id: string);      // Promise<Display | null>
await Screen.getCursorPoint();         // Promise<{ x: number; y: number; display: Display }>
await win.getScreen();                 // Promise<Display> — display the window is currently on
App.on(AppEvent.SCREENS_CHANGED, () => { /* re-query + relayout */ });
```

- `getAll` is the one native enumeration (`__screen:list`). `getPrimary` returns the `isPrimary` entry; `getById` filters by id — **both client-side from `getAll`** (no extra round trip). `getCursorPoint` (`__screen:cursor`) and `Window.getScreen()` (`__screen:forWindow`) are their own native queries, each returning a full `Display` so callers don't need a second call.
- All async (request/response, mirroring `Workers.list()`'s `__zapp:workers-list` route). Workers can call them too (invoke works in both contexts).

## Coordinate model (the breaking change)

**Top-left global**, origin at the primary display's top-left, y down. Applies to `Display.bounds`, `Display.workArea`, `getCursorPoint`, **and** `Window.setPosition`/`getPosition`/`Window.create({x,y})`.

- **Native conversion:** macOS global space is bottom-left (origin = primary's bottom-left, y up). A shared helper converts using the **primary screen height** `Hp = NSScreen.screens[0].frame.size.height`:
  - rect top edge: `y_topleft = Hp - (frame.origin.y + frame.size.height)`.
  - point: `y_topleft = Hp - y_bottomleft`.
  - window set-position (given top-left `y` + window height `wh`): `origin.y = Hp - y - wh` before `setFrameOrigin:`.
  - window get-position: `y = Hp - frame.origin.y - frame.size.height`.
- **Why primary height is the reference:** top-left global origin is defined as the primary display's top-left corner; since primary's bottom-left is the global (0,0), the primary's top is at `Hp`, so every conversion flips around `Hp`. Secondary displays live in the same unified global space, so the same `Hp` flip is correct for them too.
- **Breaking change scope:** the public `Window.setPosition`/`getPosition` + `Window.create({x,y})` change meaning (bottom-left → top-left). Internal native positioning (tray popover, sheets) uses native coords directly and is **unaffected**. The plan greps for `setPosition`/`getPosition`/create-`x`/`y` consumers and updates them; hello-world appears to use only `setSize` (verify in plan). Documented prominently in `api-reference.md`.

## Events

`AppEvent.SCREENS_CHANGED` — fires on monitor plug/unplug, resolution change, or arrangement change. No payload (re-query on fire). Wired through the established app-event path:
- `AppEvent.SCREENS_CHANGED` + entry in `APP_EVENT_NAMES` (`runtime/events.ts`).
- id→name case in `native/app/app_events.zc`.
- `ZAPP_EVENT_APP_SCREENS_CHANGED` macro in **both** `native/platform/darwin/platform.m` and `native/platform/ios/platform.m`.
- A `NSApplicationDidChangeScreenParametersNotification` observer (darwin) dispatching it via `zapp_app_dispatch`. iOS observer stubbed (external-display hot-plug deferred).

## Native-first chain & scope

- **C primitives** — `native/platform/darwin/screen.m` (reuses NSScreen, mirroring `tray.m`'s `visibleFrame`/`mainScreen` usage):
  - `const char* darwin_screen_list_json(void)` — JSON array of all displays (top-left converted).
  - `const char* darwin_screen_cursor_json(void)` — `{x,y,displayId}` for `NSEvent.mouseLocation` (top-left).
  - `const char* darwin_screen_for_window_json(int32_t window_id)` — the `Display` for a window's `NSWindow.screen`.
  - the screen-params-changed observer (here or in `platform.m`).
  - Window-position conversion in `native/platform/darwin/window.m` (`darwin_window_set_position`/`get_position` + the create path's x/y).
  - Registered in `cli/src/native.ts getPlatformSources` (darwin + ios) and `native/build.zc` macOS cflags.
- **iOS** — `native/platform/ios/screen.m`: real-but-singular via `UIScreen.mainScreen` (one display; `bounds==workArea`, `isPrimary:true`, `rotation:0`, `name:"Built-in"`, `scaleFactor:UIScreen.scale`). cursor → returns the primary display with point `{0,0}` (no mouse on iOS). for-window → the one display. iOS window-position fns stay no-op (already stubbed).
- **Zen-C** — `native/screen/screen.zc`: a `screen_route(method, request_id, window_id, args) -> bool` handling the `__screen:list`/`__screen:cursor`/`__screen:forWindow` **invoke methods** (request/response via `dispatch_invoke_response`, like `__zapp:workers-list`); imported from `native/app/app.zc`; called from `router.zc`'s invoke-method dispatch.
- **TS runtime** — `runtime/screen.ts` (`Screen` namespace + `Display`/`DisplayRect` types); `Window.getScreen()` added to `WindowHandle` (`runtime/window.ts`) + the Window-position top-left doc update; `AppEvent.SCREENS_CHANGED` (`runtime/events.ts`); exported from `runtime/index.ts`.
- **Docs** — `docs/api-reference.md`: a `Screen` section + the **top-left coordinate convention** note (with the Window-position breaking-change callout).
- **Platform:** macOS-first; iOS real-singular; Windows stubs. The `darwin_screen_*` + new `darwin_window_*` symbols referenced from `.zc` need iOS defs (the `ios-platform-parity` lint enforces this).

## Verification

- `bun run check` 0; `bun run test:all` green — incl. a `bun:test` unit for `getById`/`getPrimary` client-side filtering (pure logic over a `Display[]`) and the ios-parity lint.
- macOS `bun run build` → `[zapp] build complete:`; iOS-sim build → `[zapp] build complete:` (stubs link).
- Manual smoke (hello-world): `Screen.getAll()` lists displays with correct top-left bounds/workArea; `getPrimary`/`getById`/`getCursorPoint`/`win.getScreen()` return sane values; `Window.create({x,y})` places at the expected top-left point on the target display; unplug/replug a monitor (or toggle resolution) fires `SCREENS_CHANGED`. Multi-monitor needed for full coverage.

## Non-goals (v1)

- Refresh rate / HDR / colorSpace fields (extra CGDisplayMode/EDR queries — defer).
- Programmatic display configuration (set resolution/arrangement) — read-only API.
- iOS external-display hot-plug events (observer stubbed); Windows real impl.
- A sync cached accessor (async is the model).

## Related

- `~/.claude/plans/polished-mapping-ullman.md` + the 2026-06-05 gap analysis — the trigger (Screens/displays was a ranked gap).
- [[project_embeddable_webviews_cycle]] — the NSView/NSScreen bottom-left-origin lesson that motivates the explicit top-left convention here.
- [[project_power_state_events_cycle]] — the App getter + AppEvent pattern (`getPowerState` precedent; SCREENS_CHANGED rides the same app-event path).
- [[reference_ios_symbol_parity_gate]] — the darwin_*→ios-stub rule for the new symbols.
- [[feedback_native_first_implementation]] — the C → Zen-C → router → TS → docs chain.
