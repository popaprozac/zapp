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

  // Services (IPC to native Zen-C)
  Services, type InvokeOptions, type CancellablePromise,

  // Workers
  Worker, SharedWorker, SharedWorkerPort, Workers, type WorkerMessageEvent,

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

### `App.quit(): void`

Terminates the application. On macOS, this fires the normal
`applicationShouldTerminate` delegate chain — if a window has a close
guard active, the quit will block until the guard is resolved.

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
```

STARTED and SHUTDOWN fire before/after webview existence — listen for
them in a headless worker.

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

---

## `Services`

Call native Zen-C handlers registered via `app.service.add(name, fn)` or
`app.service.register(name, state, &ServiceImpl{...})`.

### `Services.invoke<T>(method, args?, opts?): CancellablePromise<T>`

```ts
const result = await Services.invoke<{ pong: number }>("ping");

// With args
const user = await Services.invoke<User>("user:get", { id: 123 });

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

**Worker-only** synchronous invoke. Throws in webview context. Returns
the raw result, not a Promise.

```ts
// in a worker
const r = Services.invokeSync<{ count: number }>("counter:get");
console.log(r.count);
```

Useful when you need tight loops against native services from a worker
without Promise overhead.

### `InvokeOptions`

```ts
{
  timeout?: number   // ms, default 15000
}
```

---

## `Worker` / `SharedWorker`

Spawn JavaScript workers from a webview. (From inside another worker,
use `new Worker()` the same way.)

### `new Worker(scriptUrl: string)`

```ts
const w = new Worker("./my-worker.ts");
w.postMessage({ task: "compute", data: [1, 2, 3] });
w.onmessage = (e) => console.log("result:", e.data);
w.onerror = (err) => console.error(err);
w.terminate();
```

### Named channels (optional; typed routing layer)

```ts
w.send("compute", { data: [1, 2, 3] });
const off = w.receive("result", (data) => console.log(data));
off();
```

The channel API is sugar over `postMessage` / `onmessage` — no perf cost,
just avoids a switch statement in your handler.

### `new SharedWorker(scriptUrl: string)`

```ts
const sw = new SharedWorker("./shared.ts");
sw.port.postMessage({ hello: "world" });
sw.port.onmessage = (e) => console.log(e.data);
```

Shared workers are URL-keyed and refcounted — if two webviews call
`new SharedWorker("./same-script.ts")`, they both talk to the same
underlying worker instance. The last webview releasing it lets the
worker tear down.

Each webview gets its own `SharedWorkerPort` — messages posted from the
worker via `worker.clients` broadcast to every connected port.

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
- `"sw-N"` — **rejected at the native layer.** Shared workers are
  refcounted — drop your last `SharedWorker` reference (or call
  `port.disconnect()`) and the last release auto-terminates. Calling
  `Workers.terminate("sw-…")` is a silent no-op rather than an error
  so callers don't have to branch on worker type.

Unknown IDs are also a silent no-op (native logs but doesn't throw).

```ts
import { Workers } from "@zappdev/runtime";

// Stop the headless sync worker — e.g. user toggled "Pause sync".
Workers.terminate("h-sync");
```

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
    "sync-engine": {
      script: "src/workers/sync.ts",
      engine: "bare-jsc",
      restart: { maxRetries: 2, withinMs: 30_000 },
    },
  },
};

export default config;
```

The keys (`ticker`, `sync-engine`) become the worker IDs at runtime, each
prefixed with `h-` — so `Workers.terminate("h-ticker")` stops the ticker.

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
  accelerator?: string                         // e.g. "CmdOrCtrl+N"
  role?:
    | "editMenu" | "windowMenu" | "appMenu"
    | "copy" | "cut" | "paste" | "selectAll"
    | "undo" | "redo" | "quit"
  action?: () => void
  submenu?: MenuItemDef[]
}
```

Roles auto-populate with the right system items:
- `"appMenu"` → About / Hide / Services / Quit (on macOS: full app menu)
- `"editMenu"` → Cut / Copy / Paste / Select All / Undo / Redo
- `"windowMenu"` → Minimize / Zoom / Bring All to Front / window list

When you only need one system item: `{ role: "copy" }`.

`action` fires on click. No need to wire up listeners separately —
`Menu.build` tracks them internally via the Events bus.

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
  icon: "build/menubar-icon.png",   // 18×18 template PNG, system-tinted
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
  icon: string                // path to PNG (template style recommended)
  title?: string              // text next to the icon
  tooltip?: string            // hover tooltip
  menu?: MenuItemDef[]        // popup menu on click (omit for click events)
  template?: boolean          // default: true — system tints for dark/light
}
```

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

macOS only today. Windows is a no-op until WebView2 / Win32 clipboard
integration lands (planned in `WINDOWS_PORTING.md`).

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
