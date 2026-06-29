# Runtime API Reference

Comprehensive, prose-style reference for `@zappdev/runtime`. For a
compact agent-ready version of the same surface, see
[`llms.txt`](../llms.txt).

## Imports

```ts
import {
  // App lifecycle
  App,
  Events, AppEvent, type EventName,

  // Windows
  Window, WindowEvent, type WindowHandle, type WindowOptions,
  type WindowPayload, type WindowSizePayload,
  Webview, ZappWebviewElement, type PanelEvent, type WebviewCreateOptions,

  // Services (IPC to native Zen-C)
  Services, type InvokeOptions, type CancellablePromise,

  // Workers
  Worker, Workers, type WorkerMessageEvent,

  // Screen / displays
  Screen, type Display,

  // System integration
  Clipboard, type ClipboardFormat,
  Shortcuts,
  Tray, type TrayOptions, type TrayHandle, type AttachWindowOptions,
  Protocols, type ProtocolRequest, type ProtocolResponse, type ProtocolHandler,

  // Native UI
  Dialog, type OpenFileOptions, type SaveFileOptions, type MessageOptions,
  Menu, type MenuItemDef, type MenuHandle,
  ContextMenu, type ContextMenuOptions,
  Notification, type NotificationOptions, type ScheduleOptions, type PermissionStatus,
  Dock,

  // Cross-context coordination
  Sync, type SyncWaitOptions,

  // Helpers
  eventName,
} from "@zappdev/runtime";
```

## Context story

Same imports work in all three contexts. The runtime detects context
inline and picks the right path:

| Context | Services.invoke | Window.create | Notification / Dock |
|---|---|---|---|
| Webview | async IPC (~135 µs) | async IPC | async IPC |
| Worker (webview-spawned or headless) | direct C call (~5 µs) | direct C call | direct C call |

You don't write detection logic. Watch for one API difference:
**`Window.current()` throws from worker context**. Workers don't have a
"current" window — they're not inside one. Use `Window.create()` instead,
or pass a `windowId` through a service call to operate on a specific
existing window.

---

## `App`

### `App.quit(opts?: { force?: boolean }): void`

Terminates the application. On macOS, this fires the normal
`applicationShouldTerminate` delegate chain — if a window has a close
guard active, the quit will block until the guard is resolved.

If the **app-level quit guard** is armed via `App.setQuitGuard(true)`,
a plain `App.quit()` (or Cmd-Q / menu Quit) does **not** terminate —
it fires `AppEvent.BEFORE_QUIT` instead and leaves the app open. To
actually quit after confirming with the user, call `App.quit({ force:
true })`:

```ts
App.setQuitGuard(true);

App.on(AppEvent.BEFORE_QUIT, async () => {
  const r = await Dialog.message({
    title: "Unsaved changes",
    message: "Quit without saving?",
    buttons: ["Quit", "Cancel"],
    kind: "warning",
  });
  if (r.button === 0) {
    App.quit({ force: true });
  }
});
```

See [`App.setQuitGuard`](#appsetquitguardenabled-boolean-void) for
the full guard API.

### `App.openExternal(url: string): void`

Opens a URL in the system's default browser (not in the app's webview).

```ts
App.openExternal("https://example.com");
```

### `App.showItemInFolder(path: string): void`

Reveal a file or folder in Finder, with the item selected — same as
right-click → "Show in Finder". Fire-and-forget; silently no-ops if
the path is empty or doesn't exist. Path variables (`$userData`,
`~/`, etc.) are expanded the same way `app.fs.*` resolves them.

```ts
App.showItemInFolder("/Users/me/Downloads/zapp-app.dmg");
App.showItemInFolder("$userData/exports/report.pdf");
```

Note: passing a folder reveals the folder *inside its parent* (with
the folder selected), not the folder's contents. To open a folder
itself in Finder, use `App.openPath(folder)`.

Not gated by the FS allowlist — Finder reveal is a user-visible
action and doesn't mutate disk state.

### `App.openPath(path: string): void`

Open a file or folder using the system default application —
equivalent to a double-click in Finder. For URLs with schemes
(`https://`, `mailto:`, etc.) use `App.openExternal` instead; this
method takes filesystem paths only. Path variables are expanded.

```ts
App.openPath("/Users/me/Documents/notes.md");   // opens in default editor
App.openPath("/Users/me/Documents");             // opens folder in Finder
App.openPath("$userData/cache");                  // path-var expansion
```

Not gated by the FS allowlist — handing off to the default app is a
user-visible action that the user can cancel.

### `App.trashItem(path: string): void`

Move a file or folder to the user's Trash. Reversible via Finder's
"Put Back" command. Fire-and-forget; silent on failure — path missing,
permission denied, **or path not in `config.fs.allow`**. To confirm
removal, follow with `app.fs.exists(path)`. Path variables are
expanded.

```ts
App.trashItem("$userData/old-cache.db");
```

**Gated by the FS allowlist.** Same `config.fs.allow` list that gates
`app.fs.remove` — without this gate, JS could trash arbitrary paths
on disk, bypassing the allowlist that protects every other
path-mutating call. Files the user picks via `Dialog.openFile`
extend the session allowlist automatically, so the common
"user picks file → app trashes it" flow works out of the box.

### `App.on(event: AppEvent, handler): () => void`

Listen to app lifecycle events. Returns an unsubscribe function.

```ts
App.on(AppEvent.REOPEN, () => {
  // User clicked the dock icon while the app is running with no windows
  await Window.create({ title: "Welcome back", width: 600, height: 400 });
});

App.on(AppEvent.OPEN_URL, (data) => {
  console.log("deep link:", data.url);
});
```

The power/screen events are useful for sync-engine apps — pause
expensive work before the system sleeps and resume on wake:

```ts
import { App, AppEvent } from "@zappdev/runtime";

App.on(AppEvent.WILL_SLEEP, () => {
  syncEngine.pause();
});

App.on(AppEvent.DID_WAKE, () => {
  syncEngine.resume();
});

App.on(AppEvent.SCREEN_LOCKED, () => {
  // Optional: close authenticated sessions for security
  sessionManager.lock();
});

App.on(AppEvent.SCREEN_UNLOCKED, () => {
  sessionManager.unlock();
});
```

All four payloads are empty `{}` — there is no additional data beyond
the event itself.

For battery and Low Power Mode awareness, see
[`App.getPowerState()`](#apppowerstate) and
`AppEvent.POWER_STATE_CHANGED` / `AppEvent.BATTERY_LEVEL_CHANGED`
below.

### `App.setQuitGuard(enabled: boolean): void`

Arm or disarm the app-level quit guard. When armed, Cmd-Q / the menu
Quit item / `App.quit()` fire `AppEvent.BEFORE_QUIT` and do **not**
terminate the process. Call `App.quit({ force: true })` (e.g. after the
user confirms in an "unsaved changes?" dialog) to actually quit.

The quit guard is the app-wide analog of `WindowHandle.setCloseGuard`.
macOS only; no-op on iOS/Windows.

```ts
App.setQuitGuard(true);

App.on(AppEvent.BEFORE_QUIT, async () => {
  const r = await Dialog.message({
    title: "Unsaved changes",
    message: "Quit without saving?",
    buttons: ["Quit", "Cancel"],
    kind: "warning",
  });
  if (r.button === 0) {
    App.quit({ force: true });
  }
});
```

`BEFORE_QUIT` handlers are fire-and-forget — the framework discards the returned Promise, so wrap async work in `try/catch` inside the handler; an unhandled rejection will not be caught by the framework.

Disarm before force-quitting is not required — `App.quit({ force: true
})` bypasses the guard regardless of whether it is still armed.

### `App.activate(): void`

Bring the app to the foreground without targeting a specific window.
Useful for a tray-icon summon when no window is currently visible
(the app process is running but hidden). macOS only; no-op on
iOS/Windows.

```ts
tray.on("click", () => {
  App.activate();
});
```

To raise a *specific* window use `WindowHandle.setFocus()`.

### `App.setLoginItem(enabled: boolean): Promise<boolean>`

Enable or disable launch-at-login via `SMAppService`. Returns `true`
when the change took effect, `false` when it did not.

**Platform notes:**
- macOS 13+: backed by `SMAppService.mainApp`. Returns the actual
  result from the OS.
- macOS 12: no-op, always returns `false` (SMAppService API unavailable).
- iOS / Windows: always returns `false`.

**Bundle requirement.** The login item is registered against the app's
bundle ID. A raw unbundled binary (e.g. the `bin/` output of `zapp
build` run without packaging) has no bundle ID, so the call is a
no-op. Run `zapp package` and launch the resulting `.app` for the
setting to take effect.

```ts
const ok = await App.setLoginItem(true);
if (!ok) {
  console.warn("Login item could not be registered — is the app bundled?");
}
```

### `App.getLoginItemEnabled(): Promise<boolean>`

Whether this app is currently registered to launch at login.

```ts
const enabled = await App.getLoginItemEnabled();
console.log("launch at login:", enabled);
```

Returns `false` on macOS 12, iOS, and Windows (same conditions as
`setLoginItem`).

### `App.getConfig(): Record<string, unknown>`

Returns the config object the native bootstrap injected on window creation
(a subset of `zapp.config.ts` plus computed values). Mostly useful for
debugging — prefer reading specific config values from services if you
need them at runtime.

### `App.getTheme(): "light" | "dark"`

Current system appearance. Synchronous — backed by an in-memory cache
seeded at import time from the bootstrap config (so the first read after
launch is already correct, no flash) and refreshed on every
`AppEvent.THEME_CHANGED`.

Pair with the event for live updates:

```ts
import { App, AppEvent } from "@zappdev/runtime";

function applyTheme(theme: "light" | "dark") {
  document.documentElement.dataset.theme = theme;
}

applyTheme(App.getTheme());
App.on(AppEvent.THEME_CHANGED, ({ theme }) => applyTheme(theme));
```

**`AppEvent.THEME_CHANGED` fires** when the user toggles
System Settings → Appearance, when an auto-schedule flips
light↔dark, or when a per-window appearance override changes.
Payload: `{ theme: "light" | "dark" }`.

**Worker caveat.** Workers don't receive bootstrap config, so the
cached value defaults to `"light"` until the first
`app:theme-changed` event arrives. If a worker needs the theme
synchronously before then, gate that work on the first event.

### `PowerState`

Snapshot of the device's power state. Returned by `App.getPowerState()` and
carried as the payload for both `AppEvent.POWER_STATE_CHANGED` and
`AppEvent.BATTERY_LEVEL_CHANGED`.

```ts
interface PowerState {
  source: "ac" | "battery";  // current power source
  lowPowerMode: boolean;      // Low Power Mode enabled (macOS / iOS)
  percent: number | null;     // 0–100; null on a battery-less desktop Mac or when unknown
  charging: boolean;          // actively charging — false when full or unplugged
}
```

`percent` is `null` on a desktop Mac that has no battery (Mac mini,
Mac Pro, iMac, etc.) or on Windows. `charging` means *actively charging* —
it is `false` when the battery is already full, when the device is
unplugged, or on platforms where the value is unknown.

### `App.getPowerState(): PowerState`

Current device power state. Synchronous — backed by an in-memory cache
seeded at startup from the bootstrap config and refreshed on every
`AppEvent.POWER_STATE_CHANGED` **and** `AppEvent.BATTERY_LEVEL_CHANGED`.
The cache is therefore **live for all four fields** — call it at any polling
interval you choose (e.g. just before a heavy sync) without fear of stale
data.

```ts
import { App, AppEvent } from "@zappdev/runtime";

// Query on demand (e.g. before a heavy sync):
const p = App.getPowerState();
if (p.source === "battery" || p.lowPowerMode) deferHeavySync();

// React to AC/battery or Low Power Mode flips:
App.on(AppEvent.POWER_STATE_CHANGED, (s) => updateThrottle(s));

// React to the battery gauge:
App.on(AppEvent.BATTERY_LEVEL_CHANGED, (s) => {
  if (s.source === "battery" && s.percent !== null && s.percent <= 20) pauseUntilCharged();
});
```

**`AppEvent.POWER_STATE_CHANGED`** fires when `source` (AC↔battery) or
`lowPowerMode` changes — the quiet "should I throttle?" trigger. Payload:
`PowerState`.

**`AppEvent.BATTERY_LEVEL_CHANGED`** fires when `percent` or `charging`
changes (approximately every 1%, minutes apart — not a firehose). The
battery-gauge feed. Payload: `PowerState`.

Both events carry the full `PowerState` snapshot and both update the
`getPowerState()` cache.

**Platform support.** macOS (IOKit) and iOS (`UIDevice` battery +
`NSProcessInfo` Low Power Mode) are fully supported. On Windows, no events
fire and `getPowerState()` always returns the inert default
`{ source: "ac", lowPowerMode: false, percent: null, charging: false }`
(Windows power-monitoring wired in #167). Cross-reference the related power
lifecycle events: `AppEvent.WILL_SLEEP`, `AppEvent.DID_WAKE`,
`AppEvent.SCREEN_LOCKED`, and `AppEvent.SCREEN_UNLOCKED`.

**Worker caveat** (same as `getTheme`): workers don't receive bootstrap
config, so `getPowerState()` returns the default until the first power
event arrives. If a worker needs a real reading before then, gate the work
on the first `AppEvent.POWER_STATE_CHANGED` or
`AppEvent.BATTERY_LEVEL_CHANGED` event.

---

## `Events`

Global event bus used for cross-context communication.

### `Events.on(name: string, handler): () => void`

Register a listener. Returns an unsubscribe function.

```ts
const off = Events.on("my-app:ready", (payload) => console.log(payload));
// later:
off();
```

### `Events.emit(name: string, payload?: Record<string, unknown>): void`

Fire an event to all listeners.

**From a webview**: local-only — reaches listeners in the same window
and any native `Events.emit` subscriptions that have been installed.
Does NOT cross window boundaries.

**From a worker** (webview-spawned or headless): **broadcast** — every
open window gets the event. This is the canonical pattern for pushing
app-wide state updates to all UI.

### Event name enums

**`WindowEvent`** (window-scoped, numeric 0–10):
```
READY = 0, FOCUS = 1, BLUR = 2,
RESIZE = 3, MOVE = 4, CLOSE = 5,
MINIMIZE = 6, MAXIMIZE = 7, RESTORE = 8,
FULLSCREEN = 9, UNFULLSCREEN = 10
```

Attach with `WindowHandle.on(WindowEvent.X, handler)` (auto-scopes to the
window).

**`AppEvent`** (app-scoped, numeric 100+):
```
STARTED (100)          — before any window exists (workers only)
SHUTDOWN (101)         — after all windows close (workers only)
REOPEN (104)           — dock icon clicked, no window present
OPEN_URL (105)         — deep link fired
DID_BECOME_ACTIVE (106)
DID_RESIGN_ACTIVE (107)
THEME_CHANGED (108)    — see App.getTheme()
WILL_SLEEP (109)       — system is about to sleep (macOS)
DID_WAKE (110)         — system woke from sleep (macOS)
SCREEN_LOCKED (111)    — screen locked (macOS)
SCREEN_UNLOCKED (112)  — screen unlocked (macOS)
BEFORE_QUIT (113)      — quit requested while quit guard is armed (macOS)
POWER_STATE_CHANGED (114)   — AC/battery source or Low Power Mode changed; payload: PowerState
BATTERY_LEVEL_CHANGED (115) — battery percent or charging status changed; payload: PowerState
```

STARTED and SHUTDOWN fire before/after webview existence — listen for
them in a headless worker.

The power/screen events (WILL_SLEEP, DID_WAKE, SCREEN_LOCKED,
SCREEN_UNLOCKED) and BEFORE_QUIT are macOS-only today; they are no-ops
on iOS/Windows. POWER_STATE_CHANGED and BATTERY_LEVEL_CHANGED are
macOS + iOS; Windows fires no events and `App.getPowerState()` returns
the inert default (Windows power-monitoring tracked in #167). See the
[Background-app platform note](#background-app-platform-note) below.

### `eventName(event: WindowEvent | AppEvent): string`

Resolve an enum value to its string event name (`"window:ready"`,
`"app:started"`, etc.). Useful for debugging / logging.

### Worker lifecycle events

Three engine-fired events let webviews observe supervised headless workers:

- `worker:crashed` — fires on every uncaught throw in a worker (top-level eval OR async callback). Payload:
  ```ts
  { id: string; message: string; stack: string; incarnation: number }
  ```
- `worker:restarted` — fires after a successful restart (incarnation ≥ 2). Payload:
  ```ts
  { id: string; incarnation: number }
  ```
- `worker:gave-up` — fires once when the supervisor's `maxRetries` cap is exhausted. Payload:
  ```ts
  { id: string; finalIncarnation: number; retriesAttempted: number }
  ```

`incarnation` lets a UI correlate which restart cycle a crash belongs to.
Webviews wanting to gate sends on a clean worker should listen for
`worker:restarted` after a `worker:crashed`.

Restart is supervised when `restart: { maxRetries, withinMs }` is set on a
headless worker's config; see [Headless worker auto-restart](patterns.md#headless-worker-auto-restart)
for the full lifecycle pattern.

---

## `Window`

### `Window.current(): WindowHandle`

Returns a handle to the current window. **Webview-context only** —
throws in workers.

### `Window.create(opts?: Partial<WindowOptions>): Promise<WindowHandle>`

Create a new window. Works in all contexts.

- In workers: direct host-object C call. Returns a resolved Promise
  (sync under the hood).
- In webview: async IPC through WKWebView.

```ts
const w = await Window.create({
  title: "Second window",
  width: 800,
  height: 600,
  visible: false,
});
w.on(WindowEvent.READY, () => w.show());
```

> **iOS is single-window.** A `Window.create()` *without* `asSheetOf` is a no-op
> on iOS — it warns and returns the current window. Use a **sheet**
> (`Window.create({ asSheetOf: parent })`) or a **sidebar/inspector pane** for
> secondary surfaces. (Stacked top-level windows aren't an iOS pattern; iPad
> multi-window via `UIWindowScene` is planned.) macOS supports multiple windows
> normally.

### `WindowOptions`

```ts
{
  title?: string
  url?: string                    // override initial URL (default: app's root)
  width?: number
  height?: number
  x?: number
  y?: number
  visible?: boolean               // default: true — auto-shows when content is ready
  resizable?: boolean             // default: true
  closable?: boolean              // default: true   (sugar for trafficLights.close)
  minimizable?: boolean           // default: true   (sugar for trafficLights.minimize)
  maximizable?: boolean           // default: true   (sugar for trafficLights.zoom)
  fullscreen?: boolean            // default: false
  borderless?: boolean            // default: false
  transparent?: boolean           // default: false
  alwaysOnTop?: boolean           // default: false
  titleBarStyle?: "default" | "hidden" | "hiddenInset"
  trafficLights?: {
    close?:    "enabled" | "disabled" | "hidden"  // default: "enabled"
    minimize?: "enabled" | "disabled" | "hidden"
    zoom?:     "enabled" | "disabled" | "hidden"
  }
  acceptFirstMouse?: boolean      // default: true (macOS — first click both focuses and triggers)
  asSheetOf?: WindowHandle | string  // atomic create-and-attach as modal sheet
  // iOS sheet presentation (only meaningful with asSheetOf; no-op on macOS).
  presentation?: "page" | "form" | "fullscreen" | "bottomSheet"
  detents?: ("small" | "medium" | "large")[]  // iOS 15+; "small" is iOS 16+
  grabber?: boolean              // small drag-handle on the sheet (iOS 15+)
  autoCenter?: boolean            // center on active screen at create time (overrides x/y)
  frameAutosaveName?: string      // persist frame (position + size) to NSUserDefaults under this name
}
```

**Visibility model.** `visible` is cosmetic — the window is fully created
either way. With `visible: true` (default), the framework defers
`makeKeyAndOrderFront` until the bridge bootstrap signals ready (with
`didFinishNavigation` as a fallback). This eliminates the white-flash
that would otherwise show while the webview loads. Apps don't need to
wire `on(READY, () => show())` themselves — that pattern is no longer
needed. Pass `visible: false` if you want to defer showing yourself and
call `show()` manually when your app's logic decides it's time.

**Title bar (macOS).** `titleBarStyle` controls the title bar chrome — it is a
free, per-window cosmetic choice; the framework never forces a particular style.
`"default"` is a standard macOS title bar: the window title is shown, and a
toolbar (if present) renders as its own band below/around it — more chrome,
taller total height. `"hidden"` sets `NSWindowStyleMaskFullSizeContentView` +
a transparent titlebar and hides the title text, so content runs full-height and
the toolbar merges into a unified titlebar row (the Mail/Notes look). `"hiddenInset"`
is identical but keeps the title text visible. **Omitting `titleBarStyle` is
distinct from setting `"default"`.** When you omit it, a plain window gets a
standard title bar, but a window with a `sidebar` or `inspector` pane
automatically uses the unified hidden-title chrome (the standard macOS
sidebar-app look). Setting `titleBarStyle: "default"` *explicitly* opts a
sidebar/inspector window back into a standard title bar. Any of the three values
is first-class per window.
(Note: on a window that also has a `toolbar`, the toolbar's own `style`
governs the toolbar appearance, so `"hidden"` vs `"hiddenInset"` won't
differ visibly there.)

**Traffic lights:** per-button control over the macOS close/minimize/zoom
buttons. `"enabled"` is the default clickable state; `"disabled"` greys
the button; `"hidden"` removes it entirely (leaves a gap unless paired
with a custom titlebar). The legacy `closable` / `minimizable` /
`maximizable` booleans are sugar: `false` maps to the corresponding
button's `"disabled"` state. An explicit `trafficLights` object wins
over the legacy booleans.

```ts
// Custom titlebar — hide all three traffic lights, draw your own.
Window.create({
  titleBarStyle: "hidden",
  trafficLights: { close: "hidden", minimize: "hidden", zoom: "hidden" },
});

// Chromeless tool window — only close button, zoom greyed, minimize gone.
Window.create({
  trafficLights: { close: "enabled", minimize: "hidden", zoom: "disabled" },
});
```

### `WindowHandle`

```ts
readonly id: string
on(event: WindowEvent, handler): () => void

show(): void
hide(): void
close(): void

setTitle(title: string): void
setSize(width: number, height: number): void
setPosition(x: number, y: number): void

minimize(): void
setFocus(): void          // raise this window and bring app to foreground (macOS)
maximize(): void
setFullscreen(on: boolean): void
setAlwaysOnTop(on: boolean): void

setCloseGuard(on: boolean): void
  // When on: close button / Cmd-W / App.quit fire CLOSE event
  // but don't actually close. Call close() explicitly from the handler.

loadUrl(url: string): void

attachModal(modal: WindowHandle): void
detachModal(modal: WindowHandle): void
```

> **Coordinates are top-left global** (origin at the primary display's
> top-left, y down) — consistent with the `Screen` API. (Changed from the
> earlier macOS-native bottom-left in the Screen/Displays release.)

### Modal sheets

`attachModal` shows another window as a macOS sheet anchored to this
window's titlebar. The sheet blocks interaction with the parent only —
the rest of the app stays usable. Closing the modal (close button,
`modal.close()`, `modal.destroy()`) auto-dismisses the sheet.

**Recommended: `Window.create({ asSheetOf: parent })`** — atomic
create-and-attach in one call, no flash:

```ts
const parent = Window.current();
const settings = await Window.create({
  title: "Settings", width: 500, height: 400,
  asSheetOf: parent,
});
// settings is now a sheet on parent — no separate attachModal needed.

// Listen for dismissal on the parent:
parent.on(WindowEvent.MODAL_DISMISSED, ({ modalId, code }) => {
  if (modalId === settings.id) {
    // code: NSModalResponse value (1=OK, 0=Cancel, -1000=Stop, ...)
  }
});
```

**Manual attach** still works if you need to create-then-attach
separately (e.g. parent is selected at runtime):

```ts
const modal = await Window.create({
  title: "Settings",
  width: 500, height: 400,
  visible: false,                // create hidden so it doesn't briefly flash
});
Window.current().attachModal(modal);
// (attachModal also auto-hides a visible standalone modal as a fallback,
// but you'll see a brief flash — prefer asSheetOf or visible:false.)

// Optional explicit dismiss without closing the modal window:
// Window.current().detachModal(modal);
```

`MODAL_DISMISSED` fires on the **parent** when the sheet detaches — via
the modal's close button, `modal.close()`, `modal.destroy()`, or
explicit `parent.detachModal(modal)`. Payload: `{ windowId, modalId,
code, timestamp }` where `code` is the underlying NSModalResponse:
`1` = OK, `0` = Cancel, `-1000` = Stop (default for self-closed),
`-1001` = Abort (modal was forcibly detached because it was being
re-attached to a different parent).

**Honored `WindowOptions` on a modal:** `title`, `url`, `width`,
`height`, `transparent`, `webContentInspectable`. Position,
`fullscreen`, `borderless`, `titleBarStyle`, `trafficLights`, and
`alwaysOnTop` are meaningless for sheets and ignored.

**Platform support:** macOS only today. Windows is a no-op until
WebView2 modal support lands — design pending (Win32 has no clean
sheet equivalent; closest pattern is owned topmost child + `EnableWindow`
on the parent).

`on()` auto-filters — only fires for events targeting this specific window.
No manual windowId checking needed.

### Sidebar (native NSSplitViewItem)

Pass `sidebar` in `Window.create` to attach a real native sidebar to the
window. macOS renders it as an `NSSplitViewController` root with a
`.sidebar`-styled `NSSplitViewItem`: system sidebar material (liquid glass
on macOS 26, classic vibrancy on earlier releases), full-height under the
titlebar with proper traffic-light inset, system collapse animation, and a
resizable divider clamped to your configured min/max. iOS renders the same
`sidebar | content` split through a native `UISplitViewController` — side-by-side
on iPad-regular, and a **chrome-less master-detail** stack on iPhone-compact
(see [Sidebar on iOS](#sidebar-on-ios) below). Windows ignores it.

```ts
const win = await Window.create({
  title: "My App",
  width: 900, height: 600,
  sidebar: {
    url: "/sidebar",        // required — entry route for the sidebar webview
    width: 240,             // initial width (default 260)
    minWidth: 180,          // divider drag minimum (default 180)
    maxWidth: 400,          // divider drag maximum (default 400)
    collapsible: true,      // system collapse gestures allowed (default true)
    collapsed: false,       // start collapsed (default false)
    resizable: true,        // user can drag the divider (default true; false locks at `width`)
    presentation: "tile",   // "tile" (default) | "overlay" — see below
    backgroundColor: "#1e1e1e",  // solid backdrop (optional; `material` wins if both set)
    material: Material.Sidebar,  // background material (default Material.Sidebar)
  },
});
```

**`SidebarOptions` defaults**

| Option | Type | Default |
|---|---|---|
| `url` | `string` | — (required) |
| `width` | `number` | `260` |
| `minWidth` | `number` | `180` |
| `maxWidth` | `number` | `400` |
| `collapsible` | `boolean` | `true` |
| `collapsed` | `boolean` | `false` |
| `resizable` | `boolean` | `true` |
| `presentation` | `"tile" \| "overlay"` | `"tile"` |
| `backgroundColor` | `string` | — (material) |
| `material` | `Material` | `Material.Sidebar` |

`backgroundColor` accepts a CSS color **name** (`"teal"`, `"rebeccapurple"`),
`#rgb` / `#rrggbb` / `#rrggbbaa` hex, `rgb()`, or `rgba()` (parsed via Nim's
`std/colors`). It paints a solid backdrop behind the transparent pane webview
(the flat, non-vibrant path; `material` wins if both are set). For sidebar and
inspector panes an `rgba()` alpha is honored — the window background behind the
pane shows through. The **window** `backgroundColor` is always opaque (AppKit
ignores alpha on opaque windows). Invalid colors are ignored with a
`[zapp] invalid backgroundColor` warning. In Nim `app.nim` you may pass a
`std/colors` constant directly, e.g. `backgroundColor: colBlue`. macOS;
create-time.

**`presentation`** controls the sidebar split behavior on iPad-regular (maps to
`UISplitViewController.preferredSplitBehavior`):

- `"tile"` *(default)* — sidebar sits beside content; both columns are always
  on screen. Equivalent to `UISplitBehaviorTile`.
- `"overlay"` — sidebar floats over the content as a flyout and dismisses on an
  outside tap. Equivalent to `UISplitBehaviorOverlay`. Useful for transient
  navigation panels that should not permanently reduce the content area.

**Platform matrix for `presentation`:**

| Platform | Effect |
|---|---|
| iPad-regular | `tile` or `overlay` as specified |
| iPhone-compact | no-op — the split always collapses to a master-detail nav stack regardless of this option |
| macOS | no-op — `NSSplitViewController` tiles only; sidebar stays tiled-collapsible |
| Windows | no-op — sidebar not implemented |

> **iOS drag regions.** `data-zapp-drag-region` elements are inert on iOS —
> iOS windows are not user-draggable.

**`Material` const** — typed const for `NSVisualEffectMaterial` names:
`Material.Sidebar`, `Material.Titlebar`, `Material.Menu`,
`Material.Popover`, `Material.HudWindow`, `Material.FullScreenUI`,
`Material.Sheet`, `Material.ContentBackground`,
`Material.UnderWindowBackground`, `Material.UnderPageBackground`,
`Material.WindowBackground`. The `vibrancy` window option accepts the same
`Material` type; plain string literals still type-check for both.

> **Nim authoring:** chrome style fields are typed enums — `material: Material`
> (`Material.Sidebar`, `Material.HeaderView`, …), `presentation:
> SidebarPresentation` (`.Tile`/`.Overlay`), and toolbar `style: ToolbarStyle`
> (`.Unified`/`.UnifiedCompact`/`.Expanded`); `vibrancy: Material`. Leave a field
> at its `Default` (or `ToolbarStyle.Unified`) to get the native default. (The
> TS API uses the equivalent `Material` const + string-literal unions.)

#### Content background extension (macOS 26+)

`WindowOptions.backgroundExtension` controls how the *content* pane's
background relates to the floating Liquid Glass sidebar on macOS 26 and later.
This is a **create-time**, **sidebar-edge-only** option — it describes what
happens to the content pane beneath the sidebar glass, not the inspector (the
inspector sits edge-to-edge beside content, so there is nothing to extend under
or mirror there).

**`BackgroundExtension` enum:**

| Value | Behaviour |
|---|---|
| `"none"` *(default)* | Content sits beside the sidebar. The sidebar glass does not overlap the content pane. Today's behavior on all macOS versions. |
| `"extend"` | Content flows *under* the floating sidebar. The sidebar glass floats over the content's left edge. Apps keep foreground content clear by padding with `--zapp-safe-area-left` (see below). The divider tracks live in real time during resize. |
| `"mirror"` | `NSBackgroundExtensionView`: content is inset to the unobscured area and its left edge is mirrored and blurred *behind* the sidebar glass — the "poster" effect seen in Messages.app on macOS 26. Real content still bleeds under the titlebar/toolbar (the top is never mirrored — sidebar-edge only). |

**Version gating:** `"extend"` and `"mirror"` require macOS 26. On earlier
releases both modes fall back silently to `"none"`. The native Liquid Glass
itself is delivered by AppKit (`NSSplitViewController` sidebar) — Zapp rides the
OS treatment.

```ts
const win = await Window.create({
  title: "My App",
  width: 900, height: 600,
  backgroundExtension: "extend",   // "none" | "extend" | "mirror"  (macOS 26+)
  sidebar: { url: "/sidebar", width: 240 },
});
```

**Injected CSS variables**

On **macOS**, Zapp injects the following CSS custom properties into the **content
webview** (not the sidebar pane). They are re-injected after sidebar
collapse/resize and once after the window is shown. On **iOS**, these variables
are not injected — use `env(safe-area-inset-*)` directly, or the cross-platform
fallback idiom shown below (native injection on iOS is planned for A2):

| Variable | macOS source | Notes |
|---|---|---|
| `--zapp-safe-area-top` | `WKWebView.safeAreaInsets.top` | Titlebar/toolbar height |
| `--zapp-safe-area-left` | `WKWebView.safeAreaInsets.left` | Sidebar overlap in `"extend"` mode; 0 otherwise |
| `--zapp-safe-area-right` | `WKWebView.safeAreaInsets.right` | Inspector or system right inset |
| `--zapp-safe-area-bottom` | `WKWebView.safeAreaInsets.bottom` | System bottom inset |
| `--zapp-corner-inset` | Approximate value | Inset for the rounder macOS 26 window corners, so content near the corners is not clipped |

Use the cross-platform idiom to pad foreground content on both macOS and iOS
while letting your background flow edge-to-edge:

```css
.content-root {
  /* macOS: vars injected by Zapp. iOS: falls through to env() — both resolve correctly. */
  padding-top:    var(--zapp-safe-area-top,    env(safe-area-inset-top,    0px));
  padding-left:   var(--zapp-safe-area-left,   env(safe-area-inset-left,   0px));
  padding-right:  var(--zapp-safe-area-right,  env(safe-area-inset-right,  0px));
  padding-bottom: var(--zapp-safe-area-bottom, env(safe-area-inset-bottom, 0px));
}

.hero-background {
  /* Backgrounds bleed to all edges — the glass handles the visual blend */
  position: absolute;
  inset: 0;
}
```

**Mirror reflow scales with content weight**

In `"mirror"` mode, `NSBackgroundExtensionView` re-snapshots the (out-of-process)
`WKWebView` on each layout pass to produce the blurred-mirror edge — a cost that
`"extend"` and `"none"` don't incur. That snapshot scales with how heavy the
content webview is to reflow: a light/static page mirrors **live** as you drag the
sidebar divider; a heavy single-page app defers the reflow to drag-settle (mouseup),
and very heavy content can stall the mirror mid-drag. Verified by isolation — the
inspector pane, window `vibrancy`, and primary-vs-secondary window were each ruled
out; content complexity is the determinant. Prefer `"extend"` for guaranteed live
divider tracking; use `"mirror"` for the poster look, ideally on lighter content.

> **Inspector is out of scope by design.** The inspector pane is edge-to-edge
> glass *alongside* content (it does not float over it), so `backgroundExtension`
> does not apply to the inspector edge.

**`SidebarHandle`** — available as `win.sidebar` on the creator's
`Window.create` handle, and via `Window.current().sidebar` from **either
pane** of the window (main pane and sidebar pane alike). The rule is simply:
get a window handle — if its window has a sidebar, `.sidebar` is set.

```ts
win.sidebar?.toggle()           // collapse if expanded, expand if collapsed
win.sidebar?.collapse()
win.sidebar?.expand()
win.sidebar?.setWidth(220)      // programmatic resize

win.sidebar?.setCollapsible(false)  // disallow user collapse (programmatic toggle still works)
win.sidebar?.setResizable(false)    // lock the width — divider no longer drags

win.sidebar?.showContent()      // iPhone master-detail: reveal the content column (no-op on macOS/iPad)
win.sidebar?.showSidebar()      // iPhone master-detail: go back to the sidebar list (no-op on macOS/iPad)

win.sidebar?.collapsed          // reactive: tracks SIDEBAR_COLLAPSED/EXPANDED
win.sidebar?.width              // reactive: tracks SIDEBAR_RESIZED; seeded by create option
```

`showContent()` / `showSidebar()` drive the iPhone master-detail navigation
(see [Sidebar on iOS](#sidebar-on-ios)). They are no-ops on macOS and
iPad-regular, where both panes are always side-by-side.

`setCollapsible(bool)` / `setResizable(bool)` are macOS-only. iOS sidebar
collapse is size-class–driven by `UISplitViewController`; there is no
divider-drag affordance to gate, so these calls are no-ops on iOS.
`setWidth()` works programmatically on iOS: authoritative when `resizable:false`
(min==max lock), a best-effort preference when `resizable:true` (overridden by
a user drag — UIKit limitation; see [Sidebar on iOS](#sidebar-on-ios)).

**Identity rules.** Both panes see the same host window through
`Window.current()` — code in the sidebar can call
`Window.current().setTitle("…")`, `setSize`, etc. and it targets the host
window. The sidebar's own handle is `win.sidebar` (a `SidebarHandle`),
reachable the same way from either pane. Use `Window.isSidebar()` to tell
which pane you're in at runtime.

**Code inside the sidebar pane:**

```ts
import { Window, Events, WindowEvent } from "@zappdev/runtime";

// Are we in the sidebar?
if (Window.isSidebar()) {
  // Window.current() is still the HOST window handle:
  Window.current().setTitle("Updated from sidebar");

  // Reach the SidebarHandle:
  const sb = Window.current().sidebar!;
  sb.setWidth(300);

  // Cross-pane communication via Events:
  Events.emit("nav:selected", { route: "/settings" });
}
```

**Events** — fired on the host `WindowHandle`:

| Event | Payload | Notes |
|---|---|---|
| `WindowEvent.SIDEBAR_COLLAPSED` | `{ windowId, timestamp }` | Sidebar collapsed (button or programmatic) |
| `WindowEvent.SIDEBAR_EXPANDED` | `{ windowId, timestamp }` | Sidebar expanded |
| `WindowEvent.SIDEBAR_RESIZED` | `{ windowId, width, timestamp }` | Divider dragged — fires continuously |

`SIDEBAR_RESIZED` is how the main pane observes and persists the
user-chosen width. Inside the sidebar itself, the DOM `resize` event and
`window.innerWidth` already track the divider in real time — you don't
need the event there.

```ts
win.on(WindowEvent.SIDEBAR_RESIZED, ({ width }) => {
  localStorage.setItem("sidebarWidth", String(width));
});
win.on(WindowEvent.SIDEBAR_COLLAPSED, () => console.log("collapsed"));
```

The sidebar receives all host window events (focus, resize, close, etc.)
automatically — no separate subscription is needed.

**Teardown.** The sidebar lives for the window's lifetime. There is no
attach/detach API — pass `sidebar` at create time or not at all. Closing
the window destroys both panes.

**Not permission-gated.** `SidebarHandle` operations (`toggle`, `collapse`,
`expand`, `setWidth`) are window ops on an existing window. Like other
window ops, they are not gated by the `permissions` manifest.

**Worker subscriptions (v1 gap).** Sidebar events (`SIDEBAR_COLLAPSED`,
`SIDEBAR_EXPANDED`, `SIDEBAR_RESIZED`) do not reach worker-context
`Events` subscribers in v1. This is the same pre-existing gap as
`MODAL_DISMISSED`. Subscribe from a webview context instead.

**Window slots.** Each sidebar window occupies 2 of the 64 available
window slots (one for the host, one for the sidebar webview).

#### Sidebar on iOS

iOS hosts the same `sidebar | content` panes in a native
`UISplitViewController`. Behavior splits by horizontal size class:

- **iPad-regular** — both columns are visible side-by-side, just like macOS.
  `showContent()` / `showSidebar()` are no-ops (there's nothing to navigate
  to; both panes are already on screen).
- **iPhone-compact** — the split collapses to a **chrome-less master-detail**
  stack. There is **no native toolbar** (no system back chevron, no
  `toggleSidebar` button). The app launches on the sidebar list; selecting an
  item pushes the content full-screen. Move between the two columns with the
  `SidebarHandle`:
  - `showContent()` — reveal the content (detail) column. Call it from the
    sidebar pane right after a list item is tapped.
  - `showSidebar()` — return to the sidebar (master) list. Drive it from an
    in-page back control in the content pane. The system edge-swipe back gesture
    also returns to the list.

The flow on iPhone, end to end: land on the sidebar list → tap an item →
content reveals full-screen → tap your in-page "‹ Menu" / back button (or
edge-swipe) → back to the sidebar list.

Because there's no native chrome on iPhone, **the app supplies the back
affordance**. Gate it on `Platform.isIOS` so it renders only where it's needed:

```ts
import { Window, Platform } from "@zappdev/runtime";

// Sidebar pane — reveal the content column when an item is tapped.
if (Platform.isIOS) Window.current().sidebar?.showContent();

// Content pane — render an in-page back control (iOS only) that returns
// to the sidebar list. On macOS/iPad both panes are visible, so it's not
// rendered there.
if (Platform.isIOS) {
  const back = document.createElement("button");
  back.textContent = "‹ Menu";
  back.addEventListener("click", () => Window.current().sidebar?.showSidebar());
  document.body.prepend(back);
}
```

**`Platform` API** — runtime platform check for conditional app logic
(`@zappdev/runtime`). Values are injected native-first: the native layer bakes
them into the per-webview bootstrap manifest before any JS runs. Defaults apply
when the manifest is absent (SSR / unit tests).

`Platform` is **webview-only** today — workers do not yet receive the bootstrap
manifest (a later cycle).

```ts
import { Platform } from "@zappdev/runtime";

// OS string — "macos" | "ios" | "windows"
Platform.current()   // alias for Platform.os
Platform.os          // "macos" | "ios" | "windows"

// Form factor — "desktop" | "phone" | "tablet"
// macOS/Windows → "desktop"; iPhone → "phone"; iPad → "tablet"
// Note: iPad reports os:"ios" + formFactor:"tablet" (there is no "ipados" value).
Platform.formFactor

// Build environment — "dev" | "prod"
// "dev" under `bun run dev`; "prod" under `bun run build` / a packaged app.
Platform.env

// Boolean shorthands
Platform.isMacOS     // os === "macos"
Platform.isIOS       // os === "ios"
Platform.isWindows   // os === "windows"
Platform.isPhone     // formFactor === "phone"
Platform.isTablet    // formFactor === "tablet"
Platform.isDesktop   // formFactor === "desktop"
Platform.isDev       // env === "dev"
Platform.isProd      // env === "prod"
```

Example — gate a UI path on iPhone only:

```ts
if (Platform.isIOS && Platform.isPhone) {
  // render compact mobile layout
}
```

**macOS ↔ iOS degradations** (sidebar):

| Capability | macOS | iOS |
|---|---|---|
| Layout | `NSSplitViewController` side-by-side | `UISplitViewController` — side-by-side (iPad), master-detail (iPhone) |
| `showContent()` / `showSidebar()` | no-op (always side-by-side) | navigate the iPhone master-detail stack (no-op on iPad) |
| `material` / vibrancy | liquid glass / `NSVisualEffectMaterial` | deferred — flat background (future cycle) |
| `setCollapsible(...)` | disallows/allows user collapse | no-op (collapse is size-class–driven) |
| `setResizable(...)` | locks/unlocks the divider | no-op (no draggable divider) |
| `setWidth(px)` | authoritative — moves the real divider | authoritative when `resizable:false`; applies until user drags when `resizable:true` (see note below) |
| `presentation` / `setPresentation` | **ignored** — macOS always tiles | iOS/iPadOS-only: `"automatic"`, `"tile"`, `"overlay"` |
| Native toolbar (`toggleSidebar`, back chevron) | full NSToolbar | none — app renders its own back control (future cycle) |
| Back navigation | divider / toolbar toggle | in-page control + system edge-swipe |

> **Apple-native divergence — by design.** macOS (`NSSplitViewController`) and
> iPadOS (`UISplitViewController`) have genuinely different split models; Zapp
> surfaces each platform's native behavior rather than papering over the
> differences with a custom container.
>
> - **`presentation` / `setPresentation` is iOS/iPadOS-only.** On macOS,
>   `NSSplitViewController` always tiles (columns placed side-by-side); the
>   option is accepted in the config but ignored on macOS.
> - **`"tile"` on iPadOS is a _preference_, not a guarantee.** The system may
>   still present the sidebar as an overlay in narrow widths (e.g. portrait on a
>   small iPad) — this matches Apple's own adaptive split behavior (Mail, Notes)
>   and is not a Zapp bug.
> - **`setWidth(px)` semantics differ by platform.** On macOS it moves the
>   actual NSSplitView divider — the change is immediate and authoritative
>   (`AppKit: setPosition:ofDividerAtIndex:`). On iPadOS:
>   - **`resizable: false`** — `setWidth` is authoritative. The divider is
>     locked (`min == max == width`) so UIKit always honors the value.
>   - **`resizable: true`** — `setWidth` applies via
>     `preferredPrimaryColumnWidth` before the user has dragged the divider.
>     Once the user manually drags, UIKit stores an internal drag-pin that
>     overrides `preferredPrimaryColumnWidth`, and there is no public API to
>     clear it. `setWidth` becomes a no-op for the visual column after a drag
>     (though `SIDEBAR_RESIZED` still fires and reactive state stays in sync).
>     This is a UIKit limitation — `UISplitViewController` has no equivalent
>     of AppKit's `setPosition:ofDividerAtIndex:`. Use `resizable: false` when
>     programmatic width control must be authoritative on iPad.

### Inspector (macOS + iOS)

Pass `inspector` in `Window.create` to attach a trailing utility pane —
the right-hand "inspector" in Mail/Xcode/Notes — completing the
`sidebar | content | inspector` three-column shell. It is a web-content
pane (loads an app route like the sidebar) and mirrors the `SidebarHandle`:
declared at create, toggled/collapsed/resized at runtime.

**Platform behaviour:**

| Platform | Presentation |
|---|---|
| macOS / iPad (regular width) | Trailing pane beside content (NSSplitView / UISplitViewController column) |
| iPhone (compact width) | Sheet with medium + large detents and a grabber; summon-only (never shown at launch regardless of `collapsed: false`) |

- `setWidth(px)` applies to the iPad pane; it is ignored on the iPhone sheet
  (which is always full-width).
- **Known limitation:** the inspector host is chosen once at launch based on
  the initial size class. Live iPad ↔ compact transitions (e.g. Stage Manager
  resize, split-screen) do not re-host the pane as a sheet or vice-versa.
  This is a documented follow-up.

```ts
const win = await Window.create({
  url: "/",
  sidebar: { url: "/nav", width: 240 },
  inspector: { url: "/inspector", width: 300, collapsed: true },
  toolbar: {
    items: [
      { type: "toggleSidebar" },
      { type: "trackingSeparator" },                 // tracks the sidebar edge
      { id: "compose", icon: "sf:square.and.pencil", label: "Compose", action: () => {} },
      { type: "flexibleSpace" },
      { type: "trackingSeparator", pane: "inspector" }, // tracks the inspector edge
      { type: "toggleInspector" },                   // toggles the inspector
    ],
  },
});

const insp = Window.current().inspector!;
insp.toggle();
insp.setWidth(360);
win.on(WindowEvent.INSPECTOR_RESIZED, ({ width }) => console.log("inspector", width));
```

**Options:** `url` (required), `width` (default 280), `minWidth`/`maxWidth`
(180/400), `collapsible` (default true), `collapsed` (default false — set
true for the common "hidden until summoned" inspector), `resizable`
(default true; false locks the pane at `width`), `backgroundColor`
(solid backdrop — CSS name / `#rgb`/`#rrggbb`/`#rrggbbaa` / `rgb()` / `rgba()`;
`rgba()` alpha is honored; `material` wins if both set), `material`.

**Handle (`win.inspector`, present only when the window has one):**
`toggle()` / `collapse()` / `expand()` / `setWidth(px)` /
`setCollapsible(bool)` / `setResizable(bool)`, plus `collapsed`
and `width` (tracked from `INSPECTOR_COLLAPSED` / `INSPECTOR_EXPANDED` /
`INSPECTOR_RESIZED`). `Window.isInspector()` is true inside the inspector
pane.

`setCollapsible(bool)` / `setResizable(bool)` are macOS-only. iOS inspector
collapse is size-class–driven; there is no divider-drag affordance to gate,
so these calls are no-ops on iOS. `setWidth()` still works programmatically
on iOS (applies to the iPad pane; ignored on the iPhone sheet).

**Toolbar integration:** `{ type: "toggleInspector" }` adds a button (SF
symbol `sidebar.right`) that toggles the inspector;
`{ type: "trackingSeparator", pane: "inspector" }` aligns toolbar controls
to the content↔inspector divider. Both require the window to have an
inspector (warned + dropped otherwise).

A window with an inspector but no sidebar roots on a 2-item split (content
+ inspector); with both, a 3-item split. Each pane consumes one dispatch
slot.

### Toolbar (macOS)

Pass `toolbar` in `Window.create` to attach a real `NSToolbar`. With
`style: "unified"` (the default) the toolbar merges into the titlebar next
to the traffic lights — the standard modern-macOS look. macOS only; the
option is a no-op elsewhere.

```ts
const win = await Window.create({
  url: "/",
  sidebar: { url: "/nav", width: 240 },
  toolbar: {
    style: "unified",        // "unified" | "unifiedCompact" | "expanded"
    items: [
      { type: "toggleSidebar" },      // system button — icon, animation, behavior supplied by macOS
      { type: "trackingSeparator" },  // toolbar divider tracks the sidebar split
      { id: "compose", icon: "sf:square.and.pencil", label: "Compose",
        action: () => console.log("compose clicked") },
      { type: "flexibleSpace" },
      { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter" },
    ],
  },
});
```

**Items.** `type` defaults to `"button"`. Buttons require an `id` (it keys
click routing; letters/digits/`.`/`_`/`-` only, `zapp.`/`NSToolbar`
prefixes reserved, duplicates are an error), take an `icon`
(`sf:<symbol>` / file path / data URL — same resolver as menu icons), a
`label` (tooltip; visible text in the `expanded` style), and an optional
`action` callback. Buttons also take `enabled?: boolean` (default `true`; greyed out and
unclickable when `false`) and — on menu buttons — `indicator?: boolean`
(default `true`; `false` hides the pull-down chevron, the Messages-app
look). System types: `toggleSidebar`, `trackingSeparator`
(both require the window to have a `sidebar` — warned and dropped
otherwise), `space`, `flexibleSpace`.

**Item placement (macOS).** Every item accepts an optional `placement?:
"leading" | "center" | "trailing"` field (default `"leading"`). Items are
sorted into three groups and rendered as:

```
leading  |  flexibleSpace  |  center  |  flexibleSpace  |  trailing
```

The two `flexibleSpace` separators are inserted automatically between
non-empty groups — you do not need to add them manually. Within each group,
array order is preserved; `space` and `flexibleSpace` items remain usable
inside a group for fine-grained spacing. Example:

```ts
{ id: "filter", label: "Filter", placement: "trailing" }
```

`placement` is structural and cannot be patched via `updateItem` — call
`win.toolbar.setItems(...)` to move an item between slots.

On iOS, `placement` maps to the `UINavigationItem` leading/center/trailing
slots — see "Toolbar (iOS)" below. A `"bottom"` slot is a future follow-up.

**Title bar & toolbar layout.** `titleBarStyle` and `trackingSeparator` interact:

- Under `titleBarStyle: "hidden"` or `"hiddenInset"` the toolbar merges into the
  unified titlebar row (the Mail/Notes look). A `trackingSeparator` reflow —
  items shifting when the sidebar collapses — looks clean and natural here.
- Under `titleBarStyle: "default"` the toolbar renders as its own separate band
  below the standard title. The same `trackingSeparator` reflow still works
  correctly, but the larger visual jump is expected: the toolbar band is taller
  and the title text remains visible, so the shift reads more pronounced.
  This is not a bug — it is standard AppKit behavior in both configurations.
- `trackingSeparator` is opt-in. Omit it and toolbar items stay
  fixed/left-aligned regardless of pane collapse state.
- `hiddenInset` (title visible + unified bar) is the common choice for
  sidebar+toolbar apps and matches what Apple's own sidebar apps use, but
  `default` is fully valid if you want the standard title bar chrome.

**Item visual affordances (macOS 26+).** Four optional fields control button
appearance:

| Field | Type | Default | Notes |
|---|---|---|---|
| `style` | `"plain"` \| `"prominent"` | `"plain"` | `"prominent"` renders with a filled-capsule background (the macOS 26 Mail Compose look). |
| `tintColor` | `string` (hex) | accent color | Color for the prominent fill; only meaningful when `style: "prominent"`. Omit to inherit the app accent. |
| `badge` | `{count: number}` \| `{text: string}` \| `{dot: true}` \| `null` | none | Numeric, text, or dot badge rendered on the icon. `null` (or `badge: null` in a patch) clears a live badge. |
| `bordered` | `boolean` | `true` | `false` produces a flat borderless button (the Messages-app attachment-picker look). Universal — no macOS-26 gate. |

`style`, `tintColor`, and `badge` require macOS 26; on earlier releases they fall
back silently — `style`/`tintColor` render as plain, `badge` is hidden. `bordered`
works on all macOS versions. All four fields are also accepted by
`win.toolbar.updateItem(id, patch)` for live updates — the canonical use case is
incrementing a badge in response to new content:

```ts
// Initial item — prominent Compose + borderless badged Inbox
{ id: "compose", icon: "sf:square.and.pencil", label: "Compose",
  style: "prominent", tintColor: "#aa3bff",
  action: () => startCompose() },
{ id: "inbox", icon: "sf:tray", label: "Inbox", bordered: false,
  badge: { count: 0 },
  action: () => openInbox() },

// Live badge update — call from any webview pane holding the window handle
let count = 0;
win.toolbar.updateItem("inbox", { badge: { count: ++count } });

// Clear badge
win.toolbar.updateItem("inbox", { badge: null });
```

**Clicks — the menu pattern.** A button click broadcasts
`window:toolbar-clicked` with `{ windowId, id }` to every webview and
worker. Two ways to consume the same emit:

```ts
// 1. action callback — runs in the context that called Window.create
{ id: "compose", icon: "sf:square.and.pencil", action: () => { ... } }

// 2. window event — any pane of the window (or anyone holding a handle)
win.on(WindowEvent.TOOLBAR_CLICKED, ({ id }) => {
  if (id === "compose") startCompose();
});
```

The `toggleSidebar` button needs no wiring: macOS routes it to the split
view directly, and the existing `SIDEBAR_COLLAPSED` / `SIDEBAR_EXPANDED`
events still fire (same state as `win.sidebar.toggle()`).

**Layout metrics.** Pad fixed headers by `var(--zapp-titlebar-height)` —
it always means the full top chrome inset, and on toolbar windows it
updates to the unified titlebar+toolbar band height once the toolbar
attaches. `--zapp-toolbar-height` (`0px` without a toolbar) is the
measured height of the row containing the toolbar items: in the unified
styles that row IS the titlebar band (the two variables are equal, and
the traffic lights center in the same row); in the `expanded` style it's
the toolbar row below the title. Never add the two variables.

**Dynamic updates — `win.toolbar`.** Every `WindowHandle` carries a
`ToolbarHandle` (macOS + iOS; ops no-op on Windows):

```ts
const win = Window.current();

// Attach-or-replace the full item set. Attaches a toolbar when the window
// has none (late attach — style honored only then; warned + ignored on a
// live toolbar). An empty item set throws — use remove() to destroy.
win.toolbar.setItems([
  { id: "compose", icon: "sf:square.and.pencil", label: "Compose",
    action: () => startCompose() },
  { type: "flexibleSpace" },
  { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
    indicator: false,
    menu: filterMenu("all") },
]);

// Patch one item in place — the moving-checkmark case. menu REPLACES the
// pull-down; label/icon/enabled/indicator patch individually; action
// replaces the creator callback. Unknown id → native warn, no-op.
win.toolbar.updateItem("filter", { menu: filterMenu("unread") });
win.toolbar.updateItem("compose", { enabled: false });

// Destroy. Chrome metrics re-inject: --zapp-titlebar-height shrinks back
// to the bare-titlebar inset and --zapp-toolbar-height goes to 0px.
win.toolbar.remove();
```

`setItems` re-runs the create-time validation (ids, reserved prefixes,
action/menu exclusivity) and re-registers action callbacks in the calling
context, purging the window's previous registrations.

**Moving checkmark in a pull-down — use `radioGroup`.**

Add `radioGroup: "<name>"` to the items that share a checkmark. The runtime
moves the check automatically when any item fires — no `updateItem` call
required:

```ts
{ id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
  menu: [
    { id: "kf-all",     label: "All",     radioGroup: "filter", checked: true  },
    { id: "kf-unread",  label: "Unread",  radioGroup: "filter", checked: false },
    { id: "kf-flagged", label: "Flagged", radioGroup: "filter", checked: false },
  ] }
// Clicking "Unread" auto-checks it and unchecks "All" — zero extra code.
```

For manual cases (label, icon, or multi-field patches) use `ctx.update` inside
the item's action:

```ts
{ id: "kf-unread", label: "Unread", radioGroup: "filter", checked: false,
  action: (ctx) => {
    setFilter("unread");
    // Update a sibling status label in the toolbar at the same time:
    ctx?.window.toolbar.updateItem("status", { text: "Unread items" });
  } }
```

Caveats worth knowing:

- **Webview contexts only (v1).** Worker-held `WindowHandle`s carry the
  `toolbar` property, but worker window-actions don't reach the native
  router yet — call toolbar ops from a webview pane.
- **Menu-item ids are app-global.** `__menu:click` carries only the item
  id, so two windows using the same menu ids (`"all"`, `"unread"`, …)
  collide: the last registration wins, and one window's
  `setItems`/`remove` purges the shared id. Use per-window ids (or omit
  ids and let auto-ids handle it) in multi-window apps.
- **Converting a menu button to an action button** takes two calls:
  `updateItem(id, { menu: [] })` (drops the pull-down; the item rebuilds
  as a plain button), then `updateItem(id, { action })` — a single patch
  can't carry both.
- **Icons can be swapped but not cleared** — an empty `icon` string is
  stripped from the patch (an icon-only `""` patch throws "empty patch").

No search field; `allowsUserCustomization` is off.

### Toolbar (iOS)

On iOS, `win.toolbar.setItems(items)` populates the **content column's
`UINavigationItem`** — the native nav bar that UIKit renders at the top of
the content view controller. No flag is required; the bar appears as soon as
`setItems` is called. The bar is shown on the content column only; it is
hidden on the sidebar root (the nav list itself never grows a toolbar row).

**Placement → nav bar slots.**

| `placement` | UIKit target |
|---|---|
| `"leading"` (default) | `navigationItem.leftBarButtonItems` |
| `"center"` | `navigationItem.title` / `navigationItem.titleView` |
| `"trailing"` | `navigationItem.rightBarButtonItems` |

**Item type mapping.**

| Type | iOS rendering |
|---|---|
| `button` | `UIBarButtonItem` (SF symbol or label; `enabled` honored) |
| `toggleSidebar` | `UIBarButtonItem` with `sidebar.leading` SF symbol → calls `darwin_sidebar_toggle`. On iPad when the split is **expanded** (regular width), the system sidebar button is used instead and the manual button is omitted — exactly one toggle is shown. On iPhone (always collapsed) and iPad in compact/multitasking-narrow, the manual button is shown. |
| `toggleInspector` | `UIBarButtonItem` with `sidebar.trailing` SF symbol → calls `darwin_inspector_toggle`. |
| `label` | `center` placement → `navigationItem.title` (string) or a `UILabel` titleView; other placements → `UIBarButtonItem(customView:)`. |
| `segmented` | `UISegmentedControl` wrapped in `UIBarButtonItem(customView:)`. `selectionMode: "one"` → single-select; `"momentary"` → momentary. **`selectionMode: "any"` (multi-select) has no native nav-bar equivalent — it approximates to single-select on iOS.** Call this out in your UI if the distinction matters. |
| `group` | Flattened: each sub-item becomes its own `UIBarButtonItem` appended to the same placement bucket. iOS nav bars have no `NSToolbarItemGroup` equivalent. |
| `button` with `menu` | `UIBarButtonItem.menu` (`UIMenu` / `UIAction`, iOS 14+). Nested submenus become nested `UIMenu` instances. |
| `space` / `flexibleSpace` | `UIBarButtonItem` fixed/flexible space system items. |
| `trackingSeparator` | **Dropped on iOS** — no tracking-separator concept on `UINavigationItem`. Silently skipped. |

**Fields ignored on iOS nav bar** (silently no-op; pass them in the same
definition and they round-trip harmlessly): `badge`, `style: "prominent"`,
`tintColor`, `bordered`, `controlRepresentation`.

**Layout metrics.** `--zapp-toolbar-height` is injected into the content
webview once the nav bar is shown (mirrors macOS). Pad fixed content headers
by `var(--zapp-toolbar-height, 0px)` — the same variable works on both
platforms. The sidebar webview receives `--zapp-toolbar-height: 0` (it sits
outside the content nav controller).

**Events.** Toolbar clicks (`window:toolbar-clicked`), segmented selection
(`window:toolbar-group-selected`), and menu-item clicks reach all webview
panes. Worker delivery of toolbar events is a **known iOS gap** — wire
toolbar handlers from a webview pane for now.

**Caveats and follow-ups.**

- **No-sidebar windows** (windows created without a `sidebar:` option) do not
  yet have a nav controller to attach to — `setItems` is a safe no-op for
  them. Support is deferred to a future cycle.
- **`WindowOptions.toolbar` at create time** (the `Window.create({ toolbar: … })`
  path) is also deferred on iOS — use `win.toolbar.setItems(…)` after the
  window opens (the kitchen-sink shell does this).
- The iOS toolbar is rendered even when `titleBarStyle` differs; the
  `titleBarStyle` option is macOS-only and has no effect on iOS.

### Popovers (macOS)

A real `NSPopover` — bubble chrome, anchor arrow, transient auto-dismissal —
hosting your app's web content as a trusted pane (full bridge, identifies as
its window, Events crosses panes; detect a popover pane via `globalThis[Symbol.for('zapp.isPopover')]`). Persistent: the page loads once at create
and stays warm across show/hide, so state survives.

```ts
const pop = await win.createPopover({ url: "#filter-panel", width: 320, height: 400 });

pop.show(buttonElement);                 // anchored to a DOM element
pop.show({ toolbarItem: "compose" });    // anchored to a toolbar button (macOS 14+)
pop.show(mouseEvent);                    // at the click point
pop.show({ x: 40, y: 90, width: 120, height: 20 }, { edge: "right" });
pop.hide();                              // dismiss — webview stays warm
pop.destroy();                           // teardown + slot freed

win.on(WindowEvent.POPOVER_CLOSED, ({ popoverId }) => { ... }); // hide() AND transient dismissal
```

`behavior` controls dismissal: `"transient"` (default — outside click
closes), `"semitransient"`, `"applicationDefined"` (only your code closes
it). Element/MouseEvent anchors are measured in the calling pane, so call
`show(element)` from the pane that owns the element (rect anchors position
against the calling pane's viewport). Each popover consumes one dispatch
slot for its lifetime; ids are not recycled after `destroy()` (same
monotonic pool as windows).

### Pull-down toolbar menus

A `menu:` array on a toolbar button builds a real `NSMenuToolbarItem`
(Mail's filter button) — same `MenuItemDef` as `Menu`/`ContextMenu`/`Tray`,
same `action` callbacks:

```ts
{ id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
  menu: [
    { id: "all", label: "All", action: () => setFilter("all") },
    { id: "unread", label: "Unread", action: () => setFilter("unread") },
  ] }
```

### Toolbar grouping — segmented controls + item groups (macOS 10.15+)

Two `NSToolbarItemGroup`-backed item types let you cluster related controls:

**`type: "segmented"`** — a native `NSSegmentedControl` embedded in the toolbar.

| Field | Type | Default | Notes |
|---|---|---|---|
| `id` | `string` | required | Same rules as button ids. |
| `segments` | `SegmentDef[]` | required | At least one. Each segment takes `id?`, `label?`, `icon?` (`sf:…`/data-URL/path), and an `action: () => void` callback. Give each segment a `label` even when using an `icon` — AppKit uses the labels for the collapsed/overflow menu (icon-only segments collapse to a blank menu) and for accessibility. The native right-click "icon only / icon and text" customization is available for free. |
| `selectionMode` | `"one"` \| `"any"` \| `"momentary"` | `"momentary"` | `"one"` = radio; `"any"` = multi-select; `"momentary"` = no persistent highlight. |
| `selected` | `number \| number[]` | none | Initial selection — index for `"one"`, indices array for `"any"`. Ignored for `"momentary"`. |
| `controlRepresentation` | `"automatic"` \| `"expanded"` \| `"collapsed"` | `"automatic"` | Controls how the group collapses in the overflow menu. |

```ts
// selectOne view-switcher: clicking a segment selects it and fires its action
{ type: "segmented", id: "view", selectionMode: "one", selected: 0,
  segments: [
    { id: "grid", icon: "sf:square.grid.2x2", action: () => switchView("grid") },
    { id: "list", icon: "sf:list.bullet",     action: () => switchView("list") },
  ] }

// Momentary format group: no persistent highlight, each press fires its action
{ type: "segmented", id: "fmt", selectionMode: "momentary",
  segments: [
    { id: "bold",   icon: "sf:bold",   action: () => applyFmt("bold") },
    { id: "italic", icon: "sf:italic", action: () => applyFmt("italic") },
  ] }
```

**`TOOLBAR_GROUP_SELECTED` event** fires for all selection modes on every segment
activation. For `"one"`/`"any"`, `selected` reflects the new state; for `"momentary"` it
also fires on each press with `selected: false` (no persistent highlight — use it as a
group-level press signal, or rely on the per-segment `action`). In all modes the
segment's own `action` callback also runs.

```ts
win.on(WindowEvent.TOOLBAR_GROUP_SELECTED, ({ id, index, selected }) => {
  // id      — the segmented item's id
  // index   — segment index that was toggled
  // selected — boolean: the toggled index's new state (always true for "one";
  //            the toggle result for "any")
  console.log(`${id}: index ${index}, now ${selected}`);
});
```

`win.toolbar.updateItem(id, { selected })` sets the selection live (index or
indices; ignored for `"momentary"`).

**`type: "group"`** — wraps a flat list of toolbar items into a single
`NSToolbarItemGroup` cluster that collapses to an overflow menu when the window
narrows:

| Field | Type | Default | Notes |
|---|---|---|---|
| `id` | `string` | required | |
| `items` | `ToolbarItemDef[]` | required | Plain button items only; nesting groups is rejected. |
| `controlRepresentation` | `"automatic"` \| `"expanded"` \| `"collapsed"` | `"automatic"` | |

```ts
{ type: "group", id: "actions",
  items: [
    { id: "share",  icon: "sf:square.and.arrow.up", label: "Share",  action: () => share() },
    { id: "export", icon: "sf:arrow.down.doc",      label: "Export", action: () => exportDoc() },
  ] }
```

Clicks inside a `"group"` still fire `TOOLBAR_CLICKED` with the inner button's
`id` — no different from a standalone button.

> **macOS 10.15 floor.** Both `type: "segmented"` and `type: "group"` use
> `NSToolbarItemGroup` which is available from macOS 10.15 (Catalina).
> Zapp's minimum macOS target already covers this floor.

**`type: "label"`** — a read-only text string in the toolbar (an
`NSTextField` hosted in an `NSToolbarItem`). No action, no icon. Useful
for live status strings.

| Field | Type | Default | Notes |
|---|---|---|---|
| `id` | `string` | auto-assigned | Optional; required to `updateItem` later. |
| `text` | `string` | required | The displayed text. |

```ts
// Initial definition — e.g. after a filter pull-down
{ type: "label", id: "status", text: "All items" }

// Live update from any pane
win.toolbar.updateItem("status", { text: "Unread items" });
```

This pairs naturally with a `radioGroup` pull-down: each item's action
receives `ctx.window.toolbar.updateItem("status", { text: … })` to
reflect the current selection as readable text.

### Pick your surface

| You want | Use |
| --- | --- |
| Native menu items at a point (right-click, dropdown button) | `ContextMenu.show(items, { anchor })` |
| Native menu items from a toolbar button | toolbar item `menu:` |
| Your own web UI in a native bubble, anchored to anything | `win.createPopover` |

`ContextMenu.show`'s `anchor` and `popover.show` share the same `Anchor`
vocabulary (Element / `{x, y, width?, height?}` / MouseEvent).

### Router

A logical per-window navigation stack. The native layer (`routerstate.nim`) is
authoritative; the TS handle caches state from `ROUTE_CHANGED` events. No
visible nav chrome is added this cycle — wiring the toolbar back/forward
buttons is N2b.

**Available everywhere:** `Window.current().router`, `Window.get(id).router`,
or any handle returned by `Window.create` / `Window.all`.

```ts
const router = Window.current().router;

// Navigate
router.push("/settings");
router.push({ url: "/item", params: { id: 42 }, title: "Item" });
router.pop();
router.forward();
router.replace("/settings/account");   // replaces current entry in place
router.popToRoot();                    // jump back to the root entry

// Read cached state (updated from ROUTE_CHANGED events)
router.url;          // "/item"
router.params;       // { id: 42 } — or null
router.canGoBack;    // true
router.canGoForward; // false

// Subscribe (returns unsubscribe fn)
const off = router.on((e) => {
  console.log(e.kind, e.url, e.params, e.canGoBack, e.canGoForward);
});
off();

// Equivalent via WindowEvent
win.on(WindowEvent.ROUTE_CHANGED, (e) => console.log(e.url));
```

#### `RouteOptions`

```ts
interface RouteOptions {
  url: string;
  title?: string;                                       // hint for toolbar back-label (N2b)
  params?: Record<string, unknown>;                     // ephemeral — not in URL
  presentation?: "page" | "form" | "fullscreen" | "bottomSheet";  // iOS sheet style
}
```

`push` and `replace` accept either a `RouteOptions` object or a plain string
URL (`router.push("/path")` is equivalent to `router.push({ url: "/path" })`).

**URL vs params durability:** The URL is the durable, bookmarkable identity of
a route. `params` are ephemeral — they are not encoded in the URL and are lost
on hard reload. Use `params` for transient context (selected item, scroll
offset); use query-string or path segments for anything that must survive
refresh.

**Desktop vs iOS note:** On desktop, the router drives a logical history stack
that tracks `canGoBack`/`canGoForward`. Wiring these states to native toolbar
back/forward buttons lands in N2b (this cycle only delivers the stack and its
events). iOS native routing (UINavigationController) is a future milestone.

#### Desktop in-window navigation

On desktop the router drives **in-window** navigation: the route stack is logical
and content is swapped within the existing webview (there are no per-route
windows — that is iOS's model). Wire it like this:

- **Navigate:** call `Window.current().router.push("/section")` from anywhere
  (a sidebar button, a menu, a worker via `Window.get(id)`).
- **Render:** subscribe once and swap content on the event — never render
  directly from the click. In a multi-pane window the click happens in one
  webview (e.g. the sidebar) and the content lives in another, so the
  `ROUTE_CHANGED` broadcast is the only cross-pane channel:

  ```ts
  Window.current().router.on((e) => renderRoute(e.url));
  // First render / reload-restore — read the authoritative route async:
  Window.current().router.current().then((s) => renderRoute(s.url));
  ```

- **Back/forward toolbar buttons:** give them ids, then sync their enabled-state
  from the same event:

  ```ts
  // toolbar items:  { id: "back", action: () => win.router.pop() }, { id: "fwd", action: () => win.router.forward() }
  win.router.on((e) => {
    win.toolbar.updateItem("back", { enabled: e.canGoBack });
    win.toolbar.updateItem("fwd",  { enabled: e.canGoForward });
  });
  ```

**iOS / single-window:** `Window.create(opts)` without `asSheetOf` is a no-op that
returns the current window — **except** when `opts.url` is set, in which case it
becomes an in-window `router.push({ url, title, presentation })` (iOS is
single-window; use a sheet via `asSheetOf` for a modal surface). Native
UINavigationController routing on iPhone is a later cycle.

#### `Window.get(id: string): WindowHandle`

Return a handle for any open window by its id (`"win-1"`, etc.) without a
native round-trip. Works from webview, worker, or backend. The `.router`,
`.toolbar`, and base window ops (`show`, `setTitle`, etc.) all target the given
id. Sidebar/inspector ops are current-window-only in v1.

```ts
const h = Window.get("win-1");
h.router.push("/detail");
h.setTitle("Detail");
```

#### `Window.all(): Promise<WindowHandle[]>`

List all currently open windows. Backed by the `__zapp:windows-list` native
INVOKE.

```ts
const wins = await Window.all();
console.log(wins.map((w) => w.id));
```

#### `WindowEvent.ROUTE_CHANGED` (21)

Broadcast to **all** webviews and workers when a router stack changes for any
window (push/pop/forward/replace/popToRoot). Filter by `windowId` to scope to
a specific window — or use `win.on(WindowEvent.ROUTE_CHANGED, handler)` /
`win.router.on(handler)` which filter automatically.

**Payload:** `{ windowId, url, params, canGoBack, canGoForward, kind }`

| Field | Type | Notes |
|---|---|---|
| `windowId` | `string` | The window whose stack changed |
| `url` | `string` | Current URL after the navigation |
| `params` | `object \| null` | Ephemeral params (null when none) |
| `canGoBack` | `boolean` | Stack has entries before current |
| `canGoForward` | `boolean` | Stack has entries after current |
| `kind` | `"push" \| "pop" \| "forward" \| "replace" \| "popToRoot"` | Navigation type |

### `WindowHandle.setFocus(): void`

Raise this window to the front and bring the app to the foreground,
even if another application is currently frontmost. Internally calls
`makeKeyAndOrderFront:` (which makes a hidden window visible and
brings it forward) followed by `[NSApp activateIgnoringOtherApps:YES]`
(which raises the app over other applications). Because
`makeKeyAndOrderFront:` both shows and raises the window, a preceding
`show()` call is redundant — `setFocus()` alone is sufficient to
summon a hidden window.

macOS only; no-op on iOS/Windows.

```ts
// Tray-driven summon: setFocus() shows the panel if hidden AND brings
// it to the front — no separate show() needed.
const panel = await Window.create({
  title: "Quick panel",
  width: 320, height: 480,
  borderless: true, visible: false,
});

tray.on("click", () => {
  panel.setFocus(); // shows if hidden, raises, activates app
});
```

To bring the app forward *without* targeting a specific window (e.g.
when no window is currently open), use `App.activate()`.

---

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

---

## Webview (embedded webviews) — macOS + iOS

`<zapp-webview>` embeds a **full native webview** inside your page — like an
`<iframe>`, but it can load sites that block iframing (`X-Frame-Options` /
`frame-ancestors`) and runs in its own webview process. (In v1 the embed shares
the app's default session/data store — per-embed sessions are what the reserved
`partition` attribute will enable.)

```html
<zapp-webview src="https://example.com" style="width:360px;height:480px"></zapp-webview>
```
```ts
import { Webview } from "@zappdev/runtime";

const v = document.querySelector("zapp-webview") as import("@zappdev/runtime").ZappWebviewElement;
await /* host -> embed */ v.execJS("document.title");
v.postMessage({ hello: "embed" });               // host -> embed (a MessageEvent)
v.on("did-navigate", (d) => console.log("nav", d));
v.on("message", (d) => console.log("from embed", d)); // embed called window.zappHost.postMessage(d)
v.loadURL("https://wails.io"); v.reload(); v.goBack(); v.destroy();

// programmatic:
const v2 = Webview.create({ src: "https://example.com" });
document.querySelector(".sidebar")!.appendChild(v2);
```

**Attributes:** `src` (URL); `bridge` (reserved — app-origin bridge injection is
a follow-up; inert in v1); `partition` (reserved — named sessions are a follow-up;
inert in v1).

**Events** (via `.on(event, cb)` or DOM `CustomEvent`): `did-navigate` `{url}`,
`title-change` `{title}`, `load-finished`, `load-failed` `{code,description}`,
`message` (data from `window.zappHost.postMessage` in the embed).

**Security:** embeds are **sandboxed** — they do NOT get `__zappBridge`/Services.
Host↔embed communication is only `execJS`/`postMessage` ↔ `window.zappHost.postMessage`.

**Known limitations (v1).** The embed is a separate OS layer composited over your
page, so: (1) it can lag a frame on fast scroll ("swim"); (2) it always paints
**above** your DOM — app modals/dropdowns can't cover it; (3) it won't clip to
`overflow:hidden`/`border-radius` ancestors or follow CSS `transform`. Mitigations
are a planned follow-up. Windows is still a no-op (iOS is supported — see below).
DevTools can't be opened programmatically on macOS (right-click → Inspect Element).

**iOS.** Embedded webviews work on iOS with the same API and the same v1
limitations. One nuance: on iOS the native embed paints above the page (flat
z-order, like macOS), so app sheets/modals/popovers cannot cover an embed —
keep embeds clear of regions you'll overlay with native iOS UI. iPad
multi-window (UIScene) bucketing is a follow-up; iPhone single-window works today.

**Page zoom (iOS) — recommended: disable it.** The embed composites at a fixed
scale, so a **pinch-zoom of the host page** moves your DOM without moving the
embed (the visual viewport scales but `getBoundingClientRect` does not), and the
embed goes out of alignment until the next layout. Most app-style UIs want page
zoom off anyway — set it in your host page's viewport meta:
`<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">`.
Relatedly, give any text `<input>` near an embed `font-size: 16px` or larger —
iOS auto-zooms the page when focusing a smaller field, which triggers the same
desync. (The embed *does* track page **scroll**, element resize, and window
resize correctly; only live page-zoom is unsupported.)

---

## `Services`

Call native Zen-C handlers registered via `app.service.add(name, fn)` or
`app.service.register(name, state, &ServiceImpl{...})`.

### `Services.invoke<TReturn, TArgs>(method, args?, opts?): CancellablePromise<TReturn>`

Prefer the generated, fully-typed wrappers in `src/zapp/` (`import { greet } from "./zapp"`) — the codegen infers arg types from the handler body and return types from `// @zapp:returns` annotations (see [Zen-C services](zen-c-services.md)). `Services.invoke` is the lower-level escape hatch; both type parameters are optional and default to `unknown` / `Record<string, unknown>`.

```ts
const result = await Services.invoke<{ pong: number }>("ping");

// With args — type both the return and the args
const user = await Services.invoke<User, { id: number }>("user:get", { id: 123 });

// With options
const data = await Services.invoke("slow-op", {}, { timeout: 60000 });
```

`CancellablePromise<T>` adds a `.cancel()` method that rejects the
underlying promise with a cancellation error and tells native to abort
the pending invoke:

```ts
const p = Services.invoke("upload", { file: "..." });
cancelButton.addEventListener("click", () => p.cancel());
try {
  await p;
} catch (e) {
  console.log("cancelled:", e);
}
```

### `Services.invokeSync<T>(method, args?): T`

**Worker / backend only** — throws `"only available in workers and backend
contexts"` if called from a webview.

The handler runs **inline on the caller's thread** (the worker pthread),
with no round-trip to the main thread. This makes it the fastest path for
pure-compute services. Returns the raw result, not a Promise.

```ts
// in a worker or headless backend script
const r = Services.invokeSync<{ count: number }>("counter:get");
console.log(r.count);
```

**Important constraint — no App / UI access in the handler.** Because the
handler executes on the worker thread rather than the main thread, the
framework passes a **nil `App` context** to the service handler on this
path. Handlers called via `invokeSync` must not touch `App`, windows, or
any other native UI object — use them for pure computation (e.g. counters,
caches, data transforms). For service calls that need to read or mutate
App / window state from a worker, use the async `Services.invoke(...)`:
it marshals the call to the **main thread** where the real `App` is live,
so App / window / UI access is safe in the handler. Returns a `Promise`
(the result resolves once the main-thread handler returns).

> **Nim build:** `Services.invoke` from a worker dispatches to the main thread
> via `zapp_worker_invoke_on_main` and runs the handler with the real `App`.
> **Zen-C build:** worker `invoke` currently falls back to the sync inline
> path (nil app); main-thread dispatch for the Zen-C build is a future
> parity item.

**Context × path matrix:**

| Context | `Services.invoke` (async) | `Services.invokeSync` (inline) |
|---|---|---|
| Webview | ✅ runs on the main thread via the WebKit bridge (~135 µs) | ❌ throws |
| Worker / backend | ✅ marshals to main thread — handler runs with real App/UI (nim build); zc build falls back to inline | ✅ inline on the worker thread (~5 µs); handler must not touch App/UI |

Useful when you need tight loops against native services from a worker
without Promise overhead.

### `InvokeOptions`

```ts
{
  timeout?: number   // ms, default 15000
}
```

---

## `Worker`

Spawn JavaScript workers from a webview. (From inside another worker,
use `new Worker()` the same way.)

> **`SharedWorker` is not provided by `@zappdev/runtime`.** `new SharedWorker()`
> (without a Zapp import) is the platform-native web API (WKWebView / WebView2).
> For a Zapp-engine background worker that any window — or the backend — can
> talk to, use a **headless** worker (`zapp.config.ts` `headless`) plus the
> `Workers` namespace below; it's named, supervised, and app-scoped.

### `new Worker(scriptUrl: string, opts?: { name?: string })`

```ts
const w = new Worker("./my-worker.ts");
w.postMessage({ task: "compute", data: [1, 2, 3] });
w.onmessage = (e) => console.log("result:", e.data);
w.onerror = (err) => console.error(err);
w.terminate();

// Optional display name — surfaces in logs ([zapp/<name>] ...) and in
// Workers.list(), making it easy to tell workers apart while debugging.
const sync = new Worker("./sync.ts", { name: "sync-engine" });
```

`name` is a display-only label — it has no effect on routing or
identity (the worker is still addressed by its `id`). When set, the
framework's per-worker log lines use it (`[zapp/sync-engine] ...`) and
it appears as `WorkerInfo.name` in `Workers.list()`.

### Named channels (optional; typed routing layer)

```ts
w.send("compute", { data: [1, 2, 3] });
const off = w.receive("result", (data) => console.log(data));
off();
```

The channel API is sugar over `postMessage` / `onmessage` — no perf cost,
just avoids a switch statement in your handler.

### `Workers.terminate(id: string): void`

Terminate a worker by ID. Use this when you only have a string ID and
no live `Worker` handle — most commonly for **headless workers**
configured via `zapp.config.ts`'s `headless` map, since those are
started by the framework and never expose a JS-side `Worker` instance.

Recognised ID forms:
- `"w-N"` — dedicated worker instance (same effect as
  `worker.terminate()`).
- `"h-<key>"` — headless worker keyed by `zapp.config.ts`. For
  `headless: { sync: "..." }` the runtime ID is `"h-sync"`.

Unknown IDs are a silent no-op (native logs but doesn't throw).

```ts
import { Workers } from "@zappdev/runtime";

// Stop the headless sync worker — e.g. user toggled "Pause sync".
Workers.terminate("h-sync");
```

### `Workers.list(): Promise<WorkerInfo[]>`

Enumerate the active worker registry — a runtime debug / introspection
API. Returns one `WorkerInfo` per live worker (headless and dedicated).
Available from both webview and worker contexts; same shape
either way (the webview round-trips through native IPC, a worker calls
its host bridge directly — both resolve to the same array).

```ts
import { Workers } from "@zappdev/runtime";

const workers = await Workers.list();
console.log(JSON.stringify(workers, null, 2));
// [
//   {
//     "id": "h-supervised",
//     "name": "sync-engine",
//     "scriptUrl": "/_workers/_headless_supervised.mjs",
//     "engine": "zjs",
//     "shared": false,
//     "owners": [],
//     "supervisor": { "maxRetries": 2, "withinMs": 30000, "failCount": 0, "gaveUp": false }
//   },
//   { "id": "h-ticker", "scriptUrl": "...", "engine": "zjs", "shared": false, "owners": [] }
// ]
```

```ts
interface WorkerInfo {
  id: string;                    // runtime id — "h-<key>" (headless), "w-N" (dedicated)
  name?: string;                 // display label, if set (config or new Worker)
  scriptUrl: string;
  engine: "zjs" | "bare-jsc" | "bare-v8" | "bare-quickjs"
        | "bare-mqjs" | "bare-hermes" | "pending";  // "pending" = not yet resolved
  shared: boolean;
  owners: string[];              // owning window ids (empty for headless)
  supervisor?: {                 // present only for workers with a restart policy
    maxRetries: number;
    withinMs: number;
    failCount: number;
    gaveUp: boolean;
  };
}
```

### `Workers.get(id: string): WorkerHandle`

The complement to `list()` (discover) → `get()` (interact). Returns a
lightweight handle to a worker you didn't create — chiefly a **headless**
worker, which has no JS-side `Worker` instance. Instead of repeating the id to
`Workers.send`/`terminate`, hold a handle that mirrors the `Worker` instance
surface.

Synchronous and cheap — it just binds the id, no registry round-trip.
`send`/`postMessage`/`terminate` are fire-and-forget (an unknown or terminated
id is a silent no-op); `info()` is async and resolves to `null` if the worker
isn't running.

```ts
import { Workers } from "@zappdev/runtime";

const db = Workers.get("h-db");        // for headless: { db: "..." }
db.send("write", { row: { id: 1 } });  // → the worker's self.receive("write")
const info = await db.info();          // WorkerInfo | null
db.terminate();
```

```ts
interface WorkerHandle {
  readonly id: string;
  postMessage(data: unknown): void;
  send(channel: string, data: unknown): void;
  terminate(): void;
  info(): Promise<WorkerInfo | null>;
}
```

> Subscribing to messages *from* a worker via a handle (`handle.receive(...)`,
> webview ← headless) isn't available yet — a headless worker has no single
> owner webview, so it needs worker→subscriber addressing (planned follow-up).
> Today, the creating webview of a dedicated `new Worker()` receives via
> `worker.onmessage` / `worker.receive(...)` as usual.

`list()` is read-only — it reflects a point-in-time snapshot of the
registry. `name` is omitted when unset, and `supervisor` is omitted for
workers without a `restart` policy.

### Headless workers — `HeadlessWorkerConfig`

Headless workers are background JS threads the framework spawns at app
startup. They live in `zapp.config.ts`'s `headless` map and run for the
app's lifetime (subject to the optional supervisor restart policy).

```ts
// zapp.config.ts
import type { ZappConfig } from "@zappdev/cli/config";

const config: ZappConfig = {
  name: "my-app",
  identifier: "com.example.app",
  version: "0.1.0",
  headless: {
    ticker: {
      script: "src/workers/ticker.ts",
      engine: "zjs",        // optional; see "Engine selection" below
      bytecode: true,       // optional; only on bytecode-capable engines
    },
    supervised: {
      script: "src/workers/sync.ts",
      name: "sync-engine",  // optional display label (logs + Workers.list())
      engine: "bare-jsc",
      restart: { maxRetries: 2, withinMs: 30_000 },
    },
  },
};

export default config;
```

The keys (`ticker`, `supervised`) become the worker IDs at runtime, each
prefixed with `h-` — so `Workers.terminate("h-ticker")` stops the ticker.

The optional `name` is a display label independent of the key/ID: it's
what per-worker log lines use (`[zapp/sync-engine] ...` instead of
`[zapp/h-supervised] ...`) and what `Workers.list()` reports as
`WorkerInfo.name`. The key still defines the `h-<key>` ID you pass to
`Workers.terminate(...)`.

### Engine selection — `engine: "..."`

Each headless worker picks an engine. The discriminated-union type
constrains `bytecode` to engines that support AOT:

| Engine | Available `bytecode: true` | Notes |
|---|---|---|
| `"zjs"` | ✓ ships today | First-party, cross-platform, ~1 MB, recommended default. Direct value-marshalling host bridge. |
| `"bare-jsc"` | ✗ | System JSC on macOS — JIT with auto-merged entitlement. Smallest binary on Apple (~300–500 KB lighter than zjs). |
| `"bare-v8"` | ✗ | JIT for Windows / Linux. ~30 MB bundle increase. |
| `"bare-quickjs"` | ✗ | QuickJS interpreter (~1.5 MB). Cross-platform, no JIT. |
| `"bare-mqjs"` | ✗ | QuickJS-NG fork. Same shape as quickjs with different perf/feature profile. |
| `"bare-hermes"` | ✓ in type, runtime pending | Hermes AOT bytecode pipeline lands with the bare-hermes iOS work. |

Setting `bytecode: true` on a non-bytecode engine is a TypeScript compile
error. Setting an engine that isn't compiled in falls back through the
documented chain (`zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs
> bare-mqjs`); the framework logs the downgrade.

For the full taxonomy + when-to-pick guidance, see
[`docs/engines.md`](engines.md).

### Worker modules — `workerModules`

Bare-* engines don't ship web APIs intrinsically — `fetch`, `WebSocket`,
`crypto`, etc. come from à-la-carte `bare-*` packages. Declare the
capabilities your workers need in `zapp.config.ts` and the CLI installs
the matching packages, links the native bindings, and the Vite plugin
auto-imports the worker-globals shim.

```ts
const config: ZappConfig = {
  // ...
  workerModules: ["fetch", "websocket", "crypto"],
};
```

Capability → package → global:

| Capability | Package(s) | Worker global |
|---|---|---|
| `"fetch"` | `bare-fetch` | `fetch` |
| `"websocket"` | `bare-ws` | `WebSocket` |
| `"fs"` | `bare-fs` | (none — import from `@zappdev/runtime/bare/fs`) |
| `"streams"` | `bare-stream` | `ReadableStream`, `WritableStream`, `TransformStream` |
| `"crypto"` | `bare-crypto` | `crypto` |
| `"url"` | `bare-url` | `URL`, `URLSearchParams` |
| `"encoding"` | `bare-encoding` | `TextEncoder`, `TextDecoder` |

`workerModules` only affects bare-* engines. On `zjs`, the runtime layer
provides intrinsics as they mature; bare-* shims are skipped (the
declared module is a no-op for zjs workers). If you mix engines, the
intersection is what each worker actually gets — declare the union of
capabilities, and per-engine reality decides what runs.

`fs` is the only capability that doesn't expose a global — `bare-fs` is
imported explicitly via `import { readFile } from "@zappdev/runtime/bare/fs"`
because the Node-style `fs` module isn't a browser global. Allowlist
enforcement is in `runtime/bare/fs.ts` (paths must match
`zapp.config.ts`'s `fsAllowList`).

---

## Native build config

Your `zapp/build.zc` is **service code** — Zen-C imports,
`app.service.add(...)` registrations, and handler `fn`s. The framework
injects all platform boilerplate (system frameworks, link flags, ObjC
ARC, sysroot) into `.zapp/zapp_platform.zc` and derives worker engines
from `zapp.config.ts`'s `headless[].engine`, so the default template
carries no `//> framework:` / `//> link:` directives or
`ZAPP_WORKER_ENGINE_*` defines.

When you need to link beyond the defaults — a system framework, a raw
linker flag, or an extra native source file — declare it in the
`native:` block:

```ts
native: {
  frameworks: ["CoreLocation"],   // extra system frameworks (Apple)
  linkFlags: ["-lsqlite3"],       // raw linker flags
  sources: ["src/native/Foo.m"],  // extra source files compiled in
}
```

Each value also accepts a per-platform map to scope it to one OS:

```ts
native: {
  frameworks: { macos: ["CoreLocation"], ios: ["CoreLocation"] },
  linkFlags:  { macos: ["-lsqlite3"], windows: ["-lws2_32"] },
  sources:    { macos: ["src/native/Foo.m"] },
}
```

| Field | Type | Purpose |
|---|---|---|
| `frameworks` | `string[]` \| `{ macos?, ios?, windows? }` | System frameworks to link (Apple-only concept). |
| `linkFlags` | `string[]` \| `{ macos?, ios?, windows? }` | Raw linker flags (`-l…`, library paths). |
| `sources` | `string[]` \| `{ macos?, ios?, windows? }` | Extra native source files (`.m`/`.c`) compiled into the binary. |

The flat fields `extraFrameworks`, `extraLinkFlags`, and `nativeSources`
are **deprecated aliases** for `native.frameworks` / `native.linkFlags` /
`native.sources`. They still work and are merged with the grouped block,
but prefer `native:` in new code.

Raw `//> macos: framework: …` / `//> macos: link: …` directives in
`build.zc` (or any `.zc` the build scans) remain a supported power-user
escape hatch — the zc compiler still honors them — but they aren't needed
for normal linking and aren't emitted in the default templates.

### Authoring an app in Nim

The Nim build (`ZAPP_NATIVE_LANG=nim`) compiles an app's `zapp/app.nim`
as its native entry — it's **required** (the build errors if absent, like
`zapp/app.zc` for the zc build); there's no skeleton fallback. The default
zc build uses `zapp/app.zc` — that remains the default; the Nim build is
opt-in and macOS-only today.

The Nim app surface **mirrors `app.zc`**: managers live on `App`
(`a.service.add`, `a.window.create`), service handlers receive `app` as
their first argument (matching zc's `fn(app, args)`), and `newApp` maps
to `App::new`. More of the zc surface — managers (dock, tray, menu, …) and
App methods (`getTheme`, `openExternal`, `on`, …) — arrive on `app` as the
migration ports them; today the surface covers app + service + window.

```nim
import zapp

proc greet(app: App, args: JsonNode): string = "Hello from Zapp!"

proc onReady(id: cint, handle: pointer) {.cdecl.} =
  Window(id: id, handle: handle).show()   # reveal once content can paint (no flash)

proc runApp(): int =
  let a = newApp("my-app")                 # or newApp(AppConfig(name: "my-app", inspectable: Inspectable.Auto))
  a.service.add("greet", greet)            # handler reachable from the webview via Services.invoke("greet", …)

  let win = a.window.create(WindowOptions(
    title: "My App",
    visible: false,                        # deferred show; omit to show immediately
    inspectable: Inspectable.Auto,         # web inspector: on in dev, off in prod
    # sidebarUrl: "#sidebar", inspectorUrl: "#inspector",  # optional panes
  ))
  win.onReady(onReady)
  a.run()

quit(runApp())
```

Service handlers are `proc(app: App, args: JsonNode): string`, registered
with `a.service.add("name", handler)`; they're reachable from the webview
via `Services.invoke("name", …)`.

`a.window.create(WindowOptions(...))` returns a `Window` with methods
`win.show()` and `win.onReady(cb)`. Construction is the `WindowOptions(...)`
object literal — pass it directly to `a.window.create`; defaults live on
the type. Set `visible: false` and reveal with `onReady` to avoid the brief
empty-window flash (both are optional). The `onReady` callback must be a
top-level `{.cdecl.}` proc — it is registered as a C function pointer;
reconstruct the window inside it with `Window(id: id, handle: handle)`.

`inspectable` controls the web inspector and accepts the `Inspectable` enum:
`Inspectable.Auto` (dev → on, prod → off), `Inspectable.On`, `Inspectable.Off`,
or `Inspectable.Inherit`. Resolution is a cascade — most-specific wins:
**per-window explicit > AppConfig global > dev-vs-prod default**. The default
for `WindowOptions.inspectable` is `Inspectable.Inherit` (defer to the app
level); the default for `AppConfig.inspectable` is `Inspectable.Auto`.

Power users can still `import` native libraries via Nim pragmas and expose
them as services — first-class native extensibility, no C shim required.
TS stays the default home for app logic — UI lives in the webview and
background work in headless workers.

**Building & packaging.** `ZAPP_NATIVE_LANG=nim zapp build` (and `… zapp
package`) produce a **distributable** macOS binary: the web assets are
brotli-compressed and embedded directly into the executable via Nim's
stdlib `staticRead` (no sibling `dist/` needed at runtime), the build-config
is prod-shaped (web inspector off, `isDev` false), and `zapp package` emits
a self-contained `.app`. `… zapp dev` keeps the dev shape (filesystem assets,
inspector on). Embedded assets are decoded at runtime via Apple
`libcompression` — the same scheme handler the zc build uses, so the runtime
contract is identical. (The asset embed is now fully Nim-native — no Zen-C
involved in that layer.)

**Editor setup (nimsuggest / nimlangserver).** `zapp init` and every Nim build
generate a `zapp/nim.cfg` so your editor's Nim language server resolves
`import zapp` and the framework surface. It's a generated, gitignored artifact —
do not edit it; it's overwritten on each build. If you need custom Nim flags for
your app, add `zapp/app.nim.cfg` or `zapp/config.nims` (the CLI never touches
those). If your editor still can't resolve `import zapp`, run a build once to
(re)generate the cfg, then reload the Nim language server.

---

## `Dialog`

Native file + message dialogs.

### `Dialog.openFile(opts?): Promise<{ cancelled, paths? }>`

```ts
const r = await Dialog.openFile({
  title: "Pick an image",
  filters: [{ name: "Images", extensions: ["png", "jpg", "jpeg"] }],
  multiple: true,
});
if (!r.cancelled) {
  for (const path of r.paths!) {
    console.log(path);
  }
}
```

`OpenFileOptions`:
```ts
{
  title?: string
  defaultPath?: string
  filters?: Array<{ name: string; extensions: string[] }>
  multiple?: boolean      // default: false
  directory?: boolean     // default: false (true = directory picker instead of file)
}
```

### `Dialog.saveFile(opts?): Promise<{ cancelled, path? }>`

```ts
const r = await Dialog.saveFile({
  defaultName: "document.txt",
  filters: [{ name: "Text", extensions: ["txt"] }],
});
if (!r.cancelled) {
  await writeFile(r.path!);
}
```

### `Dialog.message(opts): Promise<{ button: number }>`

```ts
const r = await Dialog.message({
  title: "Confirm delete",
  message: "This will delete 10 items. Are you sure?",
  buttons: ["Delete", "Cancel"],
  kind: "warning",
});
if (r.button === 0) {
  await deleteItems();
}
```

`kind`: `"info"` (default) | `"warning"` | `"critical"`.

---

## `Menu`

Application menu bar. Call once at app startup (typically in
`src/main.ts` or a headless worker).

### `Menu.build(items: MenuItemDef[]): MenuHandle`

```ts
Menu.build([
  { role: "appMenu" },
  { label: "File", submenu: [
    { label: "New",   accelerator: "CmdOrCtrl+N", action: () => newDoc() },
    { label: "Open…", accelerator: "CmdOrCtrl+O", action: () => openDoc() },
    { type: "separator" },
    { label: "Quit", accelerator: "CmdOrCtrl+Q", action: () => App.quit() },
  ]},
  { label: "Edit", role: "editMenu" },
  { label: "Window", role: "windowMenu" },
]);
```

### `MenuItemDef`

```ts
{
  id?: string                                  // auto-generated if omitted
  label?: string
  type?: "normal" | "separator" | "checkbox"   // default: "normal"
  enabled?: boolean
  checked?: boolean
  radioGroup?: string                          // auto-radio: same-group items share one checkmark
  accelerator?: string                         // e.g. "CmdOrCtrl+N"
  role?:
    | "editMenu" | "windowMenu" | "appMenu"
    | "copy" | "cut" | "paste" | "selectAll"
    | "undo" | "redo" | "quit"
  action?: (ctx?: ActionContext) => void       // ctx carries id, window, update, checked
  submenu?: MenuItemDef[]
  icon?: string                                // "sf:gear" | "build/x.png" | "data:image/png;base64,…" (macOS)
  iconTemplate?: boolean                        // force template tint on/off
}
```

Roles auto-populate with the right system items:
- `"appMenu"` → About / Hide / Services / Quit (on macOS: full app menu)
- `"editMenu"` → Cut / Copy / Paste / Select All / Undo / Redo
- `"windowMenu"` → Minimize / Zoom / Bring All to Front / window list

When you only need one system item: `{ role: "copy" }`.

`action` fires on click. It receives an [`ActionContext`](#actioncontext) — use
`ctx.update({ checked })` to toggle a checkbox, or rely on `radioGroup` to move
a checkmark automatically. No need to wire up listeners separately —
`Menu.build` tracks them internally via the Events bus.

### `ActionContext`

`action` callbacks on the toolbar (buttons, pull-down items, segments), app
menus, and tray menus receive a `ctx` argument of this shape. (Context-menu
actions are the exception: they fire with **no** `ctx` — the menu is already
dismissed, so there is nothing to patch.)

```ts
interface ActionContext {
  /** The item's id. */
  id: string;
  /** The window the action fired in (Window.current()). */
  window: WindowHandle;
  /** Live per-item patch. Behavior varies by surface — see table below. */
  update(patch: { label?: string; checked?: boolean; enabled?: boolean; icon?: string }): void;
  /** For checkable items: the item's checked state as last set — uniform across
   *  toolbar, app, and tray menus. Read it to toggle: ctx.update({ checked: !ctx.checked }). */
  checked?: boolean;
  /** Segment actions also receive the activated segment index + its
   *  (transient) selected state. */
  index?: number;
  selected?: boolean;
}
```

`ctx` is optional in the callback signature (`(ctx?) => void`) so zero-arg
closures compile without change.

**`ctx.update` per surface:**

| Surface | Effect |
|---|---|
| Toolbar button | `win.toolbar.updateItem(id, patch)` |
| Toolbar pull-down item | Patches that item in the menu; rebuilds the pull-down in place |
| App menu item | Patches held tree + calls `Menu.build` (re-registers, same handle) |
| Tray menu item | Patches held tree + calls `tray.setMenu` |
| Context menu item | No-op — the menu is dismissed on click |

**`radioGroup` — automatic single-select checkmark.**

Add `radioGroup: "<name>"` to a set of menu items. When any one fires, the
runtime automatically moves the checkmark to it and clears the others — no
`ctx.update` needed:

```ts
Menu.build([
  { label: "View", submenu: [
    { id: "vw-grid", label: "Grid", radioGroup: "view", checked: true  },
    { id: "vw-list", label: "List", radioGroup: "view", checked: false },
  ]},
]);
// Clicking "List" auto-checks it and unchecks "Grid" — zero extra code.
```

`radioGroup` works across all menu surfaces: app menus, tray menus, and toolbar
pull-down menus.

**`ctx.update` for manual cases** (checkbox toggle, label change, etc.):

```ts
{ id: "notify", label: "Notifications", type: "checkbox", checked: true,
  action: (ctx) => {
    const next = !ctx?.checked;        // ctx.checked = last-set state
    ctx?.update({ checked: next });    // live — no setMenu/rebuild needed
  } }
```

This same toggle works unchanged on toolbar pull-down items, app menu items, and
tray menu items — `ctx.checked` carries the last-set checked state on all three.

### Menu item icons (macOS)

Any menu item — in an app menu, a context menu, or a tray menu — can show an
icon via `icon`:

```ts
{ label: "Settings", icon: "sf:gear", action }              // SF Symbol
{ label: "Brand",    icon: "build/logo.png" }               // file path (relative-resolved)
{ label: "Status",   icon: canvas.toDataURL("image/png") }  // dynamic PNG (data URL)
```

- **Template tinting:** `sf:` icons render as templates (monochrome, auto-tinted
  to the menu text + dark mode); file/data icons render full-color. Override with
  `iconTemplate: true | false`.
- Icons are sized to ~16px. A bad path/symbol logs and renders the item without an
  icon (no crash). macOS only — ignored on other platforms.

---

## `ContextMenu`

### `ContextMenu.show(items, options?): void`

One-shot native context menu. Use with right-click handlers:

```ts
document.getElementById("target")!.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  ContextMenu.show([
    { label: "Copy", role: "copy" },
    { label: "Paste", role: "paste" },
    { type: "separator" },
    { label: "Delete", action: () => handleDelete() },
  ]);
});
```

Position defaults to the coordinates of the last `contextmenu` event
the runtime captured from the document. To force a position:

```ts
ContextMenu.show(items, { x: 200, y: 300 });
```

Auto-cleanup: action listeners are one-shot (first click wins, others
ignored) and auto-removed after 30 s if nothing's clicked.

---

## `Notification`

Native system notifications with permission flow, action buttons, reply,
scheduling.

**Requires**: macOS app bundle + code signing. `zapp dev` adhoc-signs
for you; `zapp package` respects `zapp.config.ts → macos.signingIdentity`.

**Privacy permissions** (camera, microphone, location, photos, etc.)
require usage-description strings in `Info.plist`. Set them via
`zapp.config.ts → macos.usageDescriptions` — see [`patterns.md`
"Privacy usage descriptions"](patterns.md#privacy-usage-descriptions).

### Permission flow

```ts
const status = await Notification.requestPermission();
// "granted" | "denied" | "not-determined" | "provisional"

const current = await Notification.getPermissionStatus();
```

### Show / schedule

```ts
const id = await Notification.show({
  title: "New email",
  body: "Hey, are you free later?",
  sound: "default",
});

const scheduledId = await Notification.schedule({
  title: "Reminder",
  body: "Standup in 5 minutes",
  trigger: { seconds: 300 },
});
```

`NotificationOptions`:
```ts
{
  title: string
  subtitle?: string
  body?: string
  sound?: "default" | "none" | string
  threadId?: string           // group related notifications
  categoryId?: string         // requires registerCategory first
  data?: Record<string, unknown>
  attachment?: string         // file path or file:// URL
  id?: string                 // explicit ID for update/removeDelivered
}
```

### Categories with action buttons

```ts
await Notification.registerCategory({
  id: "message",
  actions: [
    { id: "reply", title: "Reply" },
    { id: "delete", title: "Delete", destructive: true },
  ],
  hasReplyField: true,
  replyPlaceholder: "Type…",
  replyButtonTitle: "Send",
});

await Notification.show({
  title: "From Alice",
  body: "Free for lunch?",
  categoryId: "message",
});
```

### Responses

```ts
Notification.on("response", (r) => {
  // r.id, r.actionId, r.userText (if reply field)
  // actionId is "DEFAULT" for plain click, or your action id
});
```

### Update / cancel / remove

```ts
await Notification.update("msg-123", {
  body: "Updated body",
});

await Notification.cancel("msg-123");           // cancel scheduled / delivered
await Notification.cancelAll();

await Notification.removeDelivered("msg-123");  // remove from Notification Center
await Notification.removeAllDelivered();
```

---

## `Dock` (macOS)

```ts
Dock.showIcon()
Dock.hideIcon()

Dock.setBadge("5")         // text badge
Dock.removeBadge()

Dock.bounce()              // default "informational" — bounces once
Dock.bounce("critical")    // keeps bouncing until activated

Dock.setIcon("/path/to/icon.png")
Dock.resetIcon()
```

On Windows, a taskbar-equivalent API is planned (see
[`../WINDOWS_PORTING.md`](../WINDOWS_PORTING.md)). Calls are no-ops until
that lands.

---

## `Tray` — menu-bar / status item (macOS)

A `Tray` is an icon in the macOS menu bar (top-right of the screen). Each
tray is either **menu-driven** (left-click opens a popup menu) or
**click-driven** (your handler runs on left/right click). Trays are owned
by the app, not by any window — they survive across window opens and
closes.

```ts
import { Tray, App, Window } from "@zappdev/runtime";

// Menu-driven
const status = Tray.create({
  icon: "build/menubar-icon.png",   // ~18×18 PNG, shown as-is
  tooltip: "My App",
  menu: [
    { label: "Open", action: () => Window.current().show() },
    { type: "separator" },
    { label: "Quit", role: "quit" },
  ],
});

// Click-driven (no `menu`)
const ping = Tray.create({ icon: "build/ping.png" });
ping.on("click",       () => console.log("clicked"));
ping.on("right-click", () => console.log("right-clicked"));
```

### `Tray.create(opts): TrayHandle`

```ts
{
  icon: string                // path to a ~18×18 PNG; shown as-is
  title?: string              // text next to the icon
  tooltip?: string            // hover tooltip
  menu?: MenuItemDef[]        // popup menu on click (omit for click events)
  template?: boolean          // default: false (WYSIWYG). true ONLY for a
                              // monochrome glyph — macOS auto-tints it for
                              // light/dark; applying it to a full-color icon
                              // renders a solid blob, not your icon.
}
```

The `icon` renders as-is by default. Relative paths resolve against the app's
working directory (dev) or bundle resources (packaged); if the file can't be
loaded, the framework logs `[zapp] tray: could not load icon …` and shows a
`?` placeholder. A large full-color image (e.g. a 1024×1024 app icon) is scaled
to menu-bar size — supply a small icon for a crisp result.

### `TrayHandle`

```ts
readonly id: number
setIcon(path: string, opts?: { template?: boolean }): void
setTitle(title: string): void
setTooltip(tooltip: string): void
setMenu(items: MenuItemDef[]): void
on(event: "click" | "right-click", handler: () => void): () => void
attachWindow(window: WindowHandle, opts?: AttachWindowOptions): void
detachWindow(): void
destroy(): void
```

### `attachWindow` — popover-style menu-bar apps

Attaches a borderless window to the tray icon. Left-click toggles the
window's visibility; the window auto-positions relative to the icon and
(by default) hides on blur. Coexists with `setMenu` — left-click drives
the window, right-click opens the menu.

```ts
const panel = await Window.create({
  title: "Stats",
  width: 320, height: 480,
  borderless: true, visible: false,
});
status.attachWindow(panel, { position: "centerBelow" });
```

`AttachWindowOptions`:
```ts
{
  position?: "centerBelow" | "centerAbove" | "rightCenter"  // default: centerBelow
  dismissOnBlur?: boolean                                    // default: true
  dismissOnOutsideClick?: boolean                            // default: true
  toggleOnClick?: boolean                                    // default: true
  offset?: { x?: number; y?: number }                        // default: { x: 0, y: 4 }
}
```

### Platform support

macOS only today. iOS has no menu-bar equivalent by design. Windows
system-tray support is a separate gap on the Windows-parity roadmap.

---

## Background-app / menu-bar app recipe

A background-app or pure menu-bar app combines three things:

1. **Keep the app alive after the last window closes** — set
   `applicationShouldTerminateAfterLastWindowClosed: false` in the
   `AppConfig` struct inside your `zapp/app.zc`, then pass it to
   `App::new(config)`. This is a native-first knob, not a
   `zapp.config.ts` field.

2. **Hide the Dock icon** — call `Dock.hideIcon()` in JS (from a
   worker or `src/main.ts`) to remove the app from the Dock entirely.
   Without a Dock icon the app is invisible to the user unless it has
   a tray.

3. **Tray + window summon** — create a `Tray` for the menu-bar
   presence, and use `WindowHandle.setFocus()` / `App.activate()` to
   bring the UI forward on click.

```ts
// src/main.ts (or a headless worker)
import { App, AppEvent, Dialog, Dock, Tray, Window } from "@zappdev/runtime";

// Hide Dock presence — pure menu-bar app.
Dock.hideIcon();

const panel = await Window.create({
  title: "Quick panel",
  width: 320, height: 480,
  borderless: true,
  visible: false,
});

const tray = Tray.create({
  icon: "build/menubar-icon.png",
  tooltip: "My App",
});
tray.attachWindow(panel, { position: "centerBelow" });

// Also wire a global shortcut so power users can summon without clicking.
// tray.on("click") is handled by attachWindow's toggleOnClick:true.

// Re-sync on wake; pause on sleep.
App.on(AppEvent.DID_WAKE, () => syncEngine.resume());
App.on(AppEvent.WILL_SLEEP, () => syncEngine.pause());

// Graceful quit with unsaved-changes guard.
App.setQuitGuard(true);
App.on(AppEvent.BEFORE_QUIT, async () => {
  // NOTE: BEFORE_QUIT handlers are fire-and-forget — the framework discards
  // the returned Promise. Wrap all async work in try/catch here; an unhandled
  // rejection will NOT be caught by the framework.
  if (!hasPendingChanges()) {
    App.quit({ force: true });
    return;
  }
  const r = await Dialog.message({
    title: "Quit",
    message: "There are pending changes. Quit anyway?",
    buttons: ["Quit", "Cancel"],
    kind: "warning",
  });
  if (r.button === 0) App.quit({ force: true });
});
```

**`applicationShouldTerminateAfterLastWindowClosed`** lives in your
`zapp/app.zc`, not in `zapp.config.ts`. Look for (or add) the
`AppConfig` literal in `app.zc`, then pass it to `App::new`:

```c
// zapp/app.zc
let config = AppConfig{
  name: "my-app",
  applicationShouldTerminateAfterLastWindowClosed: false,
  webContentInspectable: Zapp::inspectable_auto(),
  maxWorkers: 4,
  qjsStackSize: 0,
};
let app = App::new(config);
// ... register services, set up windows ...
return app.run();
```

This is intentionally a native-first surface — it controls the macOS
`NSApplicationDelegate` callback before any JS runs.

### Background-app platform note

The background-app APIs documented in this section are macOS-only
today:

| Feature | macOS | iOS | Windows |
|---|---|---|---|
| `AppEvent.WILL_SLEEP` / `DID_WAKE` | supported | — | Windows tracking #167 |
| `AppEvent.SCREEN_LOCKED` / `SCREEN_UNLOCKED` | supported | — | Windows tracking #167 |
| `AppEvent.BEFORE_QUIT` | supported | — | Windows tracking #167 |
| `AppEvent.POWER_STATE_CHANGED` / `BATTERY_LEVEL_CHANGED` | supported (IOKit) | supported (`UIDevice` + `NSProcessInfo`) | inert default, no events (#167) |
| `App.getPowerState()` | supported | supported | inert default (#167) |
| `App.setQuitGuard` | supported | no-op | no-op |
| `App.activate` | supported | no-op | no-op |
| `App.setLoginItem` / `getLoginItemEnabled` | macOS 13+ | `false` | `false` |
| `WindowHandle.setFocus` | supported | no-op | no-op |

iOS foreground/background transitions are covered by the existing
`AppEvent.DID_BECOME_ACTIVE` (`app:active`) and
`AppEvent.DID_RESIGN_ACTIVE` (`app:inactive`) events, which fire on
both platforms.

---

## `Clipboard`

Read and write the system clipboard. Works in webviews and workers —
worker contexts use a sync host-object fast path
(`__zappBridge.clipboard`) so they skip the IPC roundtrip; webviews
go through the bridge. The promise return shape is identical in both.

```ts
import { Clipboard } from "@zappdev/runtime";

await Clipboard.writeText("hello");
const text = await Clipboard.readText();   // "" if no text

await Clipboard.writeHtml("<b>bold</b>");
const html = await Clipboard.readHtml();   // "" if no HTML

if (await Clipboard.has("image")) {
  const png = await Clipboard.readImage(); // Uint8Array | null
}

const files = await Clipboard.readFiles(); // string[] of paths
await Clipboard.clear();
```

### `Clipboard.has(format): Promise<boolean>`

Tests whether the clipboard currently contains a given format.
`format` is `"text" | "html" | "image" | "files"`. Useful for guarding
reads that might return empty/null.

### `Clipboard.readImage()` notes

- Returns PNG bytes as a `Uint8Array`, or `null` when no image.
- Apple-deposited TIFF (Preview's "Copy", many screen-capture tools)
  is transparently re-encoded to PNG on the native side, so consumers
  always get PNG.
- Bridge crosses as base64 — the runtime decodes back to a
  `Uint8Array` on the JS side.

### `Clipboard.readFiles()` notes

- Returns absolute file paths from clipboard file references — most
  commonly populated by Cmd-C in Finder.
- Empty array when the clipboard has no `NSPasteboardTypeFileURL`
  entries.

### Platform support

macOS (NSPasteboard) + iOS (UIPasteboard) — text / HTML / image on both.
`readFiles()` on iOS is best-effort: it returns `file://` URLs found on the
pasteboard, but most iOS share flows hand files through extension contexts
rather than the pasteboard, so it's commonly empty. Windows is a no-op until
WebView2 / Win32 clipboard integration lands (planned in `WINDOWS_PORTING.md`).

---

## `Shortcuts` — global hotkeys

System-wide hotkeys that fire whether or not the app is focused.
Backed by Carbon's `RegisterEventHotKey` on macOS — no accessibility
permission required, no entitlement, works from menu-bar-only apps.

```ts
import { Shortcuts, Window } from "@zappdev/runtime";

const ok = await Shortcuts.register("CmdOrCtrl+Shift+Space", () => {
  Window.current().show();
});
if (!ok) console.warn("hotkey unavailable — already taken?");

await Shortcuts.unregister("CmdOrCtrl+Shift+Space");
await Shortcuts.unregisterAll();
```

### Accelerator syntax

Same notation as menu accelerators:
`<modifier>+<modifier>+...+<key>`. Modifiers and keys are
case-insensitive.

**Modifiers:** `Cmd` / `Command` / `CmdOrCtrl` / `Meta`, `Ctrl` /
`Control`, `Alt` / `Option`, `Shift`.

**Keys:** `A`–`Z`, `0`–`9`, `Space`, `Tab`, `Return` / `Enter`,
`Escape` / `Esc`, `Delete` / `Backspace`, `ForwardDelete`, `Left`,
`Right`, `Up`, `Down`, `Home`, `End`, `PageUp`, `PageDown`,
`F1`–`F12`.

### `Shortcuts.register(accelerator, handler): Promise<boolean>`

Resolves to `true` on success, `false` on:
- accelerator already registered by this app (call `unregister`
  first to replace).
- the OS reports the hotkey is held by another app.
- the accelerator string couldn't be parsed.

The `handler` runs every time the hotkey is pressed system-wide
until you unregister or the app exits. Errors thrown inside the
handler are caught and logged.

### `Shortcuts.unregister(accelerator): Promise<boolean>`

Resolves to `true` if the accelerator was registered and is now
released, `false` if it wasn't registered. Idempotent.

### `Shortcuts.isRegistered(accelerator): Promise<boolean>`

Whether *this app* currently holds the accelerator. Says nothing
about whether other apps hold it.

### `Shortcuts.unregisterAll(): Promise<void>`

Releases every accelerator the app has registered. Useful for
"Reset shortcuts" UI or test teardown.

### Platform support

macOS only today. Windows is a no-op until Win32 `RegisterHotKey`
wires up.

---

## `Protocols` — custom in-webview URL schemes

Intercept requests inside Zapp's own WebViews on a custom scheme
(`asset://`, `media://`, etc.) and answer them from JavaScript. Useful
for serving generated content (thumbnails, decoded media, IndexedDB
blobs) without spinning up a local HTTP server.

**Different from `deepLinkSchemes`.** Deep links are *system-wide* — the
OS routes `myapp://...` URLs to your app even when it's not running, and
they fire `App.on(AppEvent.OPEN_URL)`. Protocols are *webview-internal*
— they intercept requests inside Zapp's WebViews only.

### Setup

Declare schemes in `zapp.config.ts` (config-time only; WKWebView's scheme
registration runs at webview creation):

```ts
// zapp.config.ts
export default defineConfig({
  name: "My App",
  protocols: ["asset"],
});
```

Register a handler at runtime:

```ts
import { Protocols } from "@zappdev/runtime";

Protocols.register("asset", async (req) => {
  const id = new URL(req.url).pathname.slice(1);   // /thumb-123 → thumb-123
  const bytes = await loadAssetBytes(id);
  return { body: bytes, contentType: "image/jpeg" };
});

// Then anywhere in your HTML / CSS:
//   <img src="asset://thumb-123" />
```

### `Protocols.register(scheme, handler): () => void`

Returns an unsubscribe function. Calling it removes the handler; the
scheme stays registered with WKWebView, so a later `Protocols.register`
for the same scheme reattaches without re-rendering the webview.

Re-registering the same scheme replaces the previous handler — listeners
don't accumulate.

### `ProtocolRequest`

```ts
{
  url: string      // full URL, e.g. "asset://thumb-123"
  method: string   // HTTP method, usually "GET"
}
```

### `ProtocolResponse`

```ts
{
  body: Uint8Array | string    // binary or UTF-8 string
  contentType?: string         // default: "application/octet-stream"
  status?: number              // default: 200
}
```

Throwing inside the handler replies with status 500 so WebKit cancels
the request cleanly (no hangs).

### Platform support

macOS + iOS today (shipped in alpha.54). Windows route through WebView2's
`AddWebResourceRequestedFilter` — planned as part of the Windows-parity
push.

---

## `Permissions` — capability manifest

Declare which built-in native capabilities your app may use via the
`permissions` field in `zapp.config.ts`. Absent means allow-all (legacy
behavior); present is an exhaustive allowlist enforced natively in the
webview and all workers.

```ts
// zapp.config.ts
export default defineConfig({
  name: "My App",
  permissions: ["clipboard:read", "fs", "dialog", "notifications", "window:create"],
});
```

A bare module name grants all its verbs (`"clipboard"` ⊇ `clipboard:read` +
`clipboard:write`). Unknown ids are a build error — the typed
`ZappPermission` union gives editor autocomplete.

### Catalog

| Permission | Verbs | Covers |
|---|---|---|
| `clipboard` | `:read`, `:write` | Clipboard reads / writes+clear |
| `fs` | `:read`, `:write` | FS API (additionally path-allowlisted) |
| `dialog` | — | file open/save + message dialogs |
| `notifications` | — | show/schedule/categories |
| `shortcuts` | — | global hotkeys |
| `tray` | — | status items |
| `dock` | — | badge/bounce/icon |
| `menu` | — | app menu + context menus |
| `screen` | — | display enumeration / cursor |
| `embed` | — | `<zapp-webview>` panels |
| `window:create` | — | creating new windows (ops on existing windows are never gated) |
| `shell` | `:open`, `:reveal`, `:trash` | openExternal/openPath · showItemInFolder · trashItem |

Not gated in v1: window ops on existing windows, app lifecycle, `Events`,
`Sync`, user `Services`, `protocols`/`deepLinkSchemes` (config declaration
is the grant).

### Denied-call behavior

- **Invoke-style APIs** (Clipboard, Dialog, Notification, Shortcuts, Screen,
  `Window.create`) — **reject** with an error where
  `error.code === "PERMISSION_DENIED"` and `error.permission` names the id.
- **Fire-and-forget APIs** (Tray, Dock, Menu, ContextMenu, shell helpers,
  `Webview.create`) — **throw `PermissionDeniedError` synchronously** in the
  webview; in workers the native layer logs `[zapp] permission denied: <id> (<method>)`
  (once per id) and drops the call.

### `Permissions.query(id): Promise<"granted" | "denied" | "unsupported">`

```ts
import { Permissions } from "@zappdev/runtime";
const status = await Permissions.query("tray");
// "granted"     — in the allowlist (or no manifest → allow-all)
// "denied"      — manifest present and id not listed
// "unsupported" — platform doesn't support this capability (e.g. tray on iOS)
```

`"unsupported"` is answered before the manifest is consulted — unsupported
APIs still silently no-op when called (v1 keeps legacy behavior);
`query()` is how you detect them.

### `Permissions.list(): Promise<string[]>`

Returns the active allowlist — the `permissions` array from your config
as resolved at startup. Returns `[]` when no manifest is present (allow-all
mode); use `Permissions.query()` per-id to check individual capabilities.

For the full trust model — navigation allowlist, FS path allowlist,
sandboxed embeds, and v2 roadmap — see [`docs/security.md`](security.md).

---

## `Sync` — cross-context wait/notify

Low-level coordination. Like `pthread_cond_*` but keyed by string and
available from JS.

### `Sync.wait(key, timeoutOrOptions?): Promise<"notified" | "timed-out">`

```ts
const result = await Sync.wait("ready", 5000);
if (result === "notified") {
  // someone called Sync.notify("ready")
} else {
  // 5s passed with no notify
}

// Indefinite wait
await Sync.wait("ready", null);
```

### `Sync.notify(key, count = 1): void`

Wake up to `count` waiters. Defaults to **1** (same semantics as
`pthread_cond_signal`).

### `Sync.notifyAll(key): void`

Wake every current waiter.

### Use cases

- **Lock / mutex**: single-slot queue + notify on release
- **Barrier**: wait until N producers notify, then notifyAll to release consumers
- **Rate limiter**: cap concurrent access, queue waiters
- **Producer / consumer signaling**: wait for "data-ready" events without polling

Sync keys live in native memory and are thread-safe (pthread mutex inside
`darwin_sync_handle`). Both wait and notify work from any context (webview
or worker), same keyspace.

---

## Logging

### Zen-C app logging

Three functions write to the app's log output. All three prefix the message
with `[zapp]` so log lines are easy to grep:

```c
log("app started");                // default — always visible
logv("connecting to sync");        // verbose — shown with --verbose / ZAPP_LOG=verbose
logd("detailed trace point");      // debug — shown with --debug / ZAPP_LOG=debug
```

The three levels map to the CLI flags and the `ZAPP_LOG` env var:

| Zen-C function | CLI flag | `ZAPP_LOG` value | Always visible? |
|---|---|---|---|
| `log(msg)` | — | — | yes |
| `logv(msg)` | `--verbose` / `-v` | `verbose` | no |
| `logd(msg)` | `--debug` | `debug` | no |

Each has the signature `fn log(msg: string) -> void` — a single string
argument, no `printf`-style varargs. A `%s` in the message prints
literally; build any interpolated text with string concatenation before
the call. Output goes to the app's stderr, visible in the terminal where
`zapp dev` is running or when the app is launched manually.

### Worker `console.log`

`console.log(...)` in a worker prints as `[zapp/<name>]` where `<name>` is
the worker's configured display name (the `name` key in `zapp.config.ts →
headless`, or the second argument to `new Worker(url, { name })`). Falls
back to the runtime ID (`h-ticker`, `w-3`, etc.) when no name is set.

```
[zapp/sync-engine] connected to server
[zapp/h-ticker]    tick 42
```

Worker log lines respect the same verbosity levels — `console.log` is
always shown. The framework's own **routine** worker lifecycle messages
(script loaded, created, exited) are gated on `--verbose` / `--debug`, so
they stay out of a default `zapp dev` run. Errors (a worker throwing, a
spawn failing) and supervisor restart / gave-up notices remain at the
default level — those signal a crash you want to see.

### Controlling log level

Pass flags to `zapp dev` or `zapp build`:

```bash
zapp dev --verbose   # framework lifecycle + build-step detail
zapp dev --debug     # full compiler invocation + complete build output
```

Or set `ZAPP_LOG` — this also works on **packaged apps** without a rebuild:

```bash
ZAPP_LOG=verbose zapp dev
ZAPP_LOG=debug   ./MyApp.app/Contents/MacOS/MyApp   # field debug a shipped build
```

---

## Bridge detection

The runtime uses `Symbol.for("zapp.bridge")` to find the bridge. In
workers, the symbol points at `__zappBridge` directly (the raw host
object with all the C-backed methods). In webviews, it points at an
async IPC bridge defined in `bootstrap/webview.ts`.

Userland code shouldn't need to poke at `getBridge()`. Every API above
uses it internally. But if you're debugging, the bridge is accessible:

```ts
const bridge = (globalThis as any)[Symbol.for("zapp.bridge")];
console.log(Object.keys(bridge));
```

In a worker you'll see `invokeService`, `createWindow`, `notif`, `dock`,
`syncWait`, etc. In a webview you'll see `invoke`, `emit`, `on`,
`createWorker`, etc. (async methods).

---

## Further reading

- [`patterns.md`](patterns.md) — complete working examples of common patterns
- [`zen-c-services.md`](zen-c-services.md) — how to write the native handlers you invoke
- [`architecture.md`](architecture.md) — how the runtime, bridge, and native fit together
- [`../llms.txt`](../llms.txt) — single-file reference for agents
