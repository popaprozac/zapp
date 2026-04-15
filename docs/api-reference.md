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
  Worker, SharedWorker, SharedWorkerPort, type WorkerMessageEvent,

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
  visible?: boolean               // default: true
  resizable?: boolean             // default: true
  closable?: boolean              // default: true
  minimizable?: boolean           // default: true
  maximizable?: boolean           // default: true
  fullscreen?: boolean            // default: false
  borderless?: boolean            // default: false
  transparent?: boolean           // default: false
  alwaysOnTop?: boolean           // default: false
  titleBarStyle?: "default" | "hidden" | "hiddenInset"
}
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
```

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
