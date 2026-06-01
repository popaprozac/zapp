# Common Patterns

Reusable shapes for real Zapp apps. Each pattern shows the full working
code — copy, adapt.

## Close guard with unsaved-changes dialog

Block window close until the user decides what to do.

```ts
// src/main.ts
import { Window, WindowEvent, Dialog } from "@zappdev/runtime";

const win = Window.current();
let isDirty = false;

// Set dirty whenever the user edits
document.getElementById("editor")!.addEventListener("input", () => {
  isDirty = true;
});

win.setCloseGuard(true);
win.on(WindowEvent.CLOSE, async () => {
  if (!isDirty) {
    win.close();
    return;
  }

  const result = await Dialog.message({
    title: "Save changes?",
    message: "You have unsaved changes. Save before closing?",
    buttons: ["Save", "Don't save", "Cancel"],
    kind: "warning",
  });

  if (result.button === 0) {
    await save();
    win.close();
  } else if (result.button === 1) {
    win.close();
  }
  // button 2 (Cancel) → stay open, guard remains active
});

async function save() { /* your save logic */ }
```

## Headless worker broadcasting state to all windows

Perfect for real-time updates (chat, stock prices, sync status).

```ts
// zapp.config.ts
import { defineConfig } from "@zappdev/cli/config";

export default defineConfig({
  name: "My App",
  headless: {
    live: "src/workers/live.ts",
  },
});
```

```ts
// src/workers/live.ts — starts at app boot, broadcasts every 2 seconds
import { Events, Services } from "@zappdev/runtime";

async function tick() {
  try {
    const latest = await Services.invoke<{ items: unknown[] }>("fetchLatest");
    Events.emit("live:update", latest);  // broadcast to every open window
  } catch (e) {
    console.error("fetch failed:", e);
  }
}

setInterval(tick, 2000);
tick();  // fire once immediately at boot
```

```ts
// src/main.ts — any window listens
import { Events } from "@zappdev/runtime";

Events.on("live:update", (data) => {
  renderItems((data as any).items);
});
```

Open a second window and it gets the same broadcasts automatically.
No per-window subscription setup needed.

## Headless worker auto-restart

Configure a restart policy in `zapp.config.ts` so the supervisor recreates
the worker's JS context after an uncaught throw. After `maxRetries`
failures inside `withinMs`, the supervisor gives up.

```ts
// zapp.config.ts
headless: {
  sync: {
    script: "src/workers/sync.ts",
    engine: "zjs",
    restart: { maxRetries: 3, withinMs: 60_000 },
  },
}
```

```ts
// src/main.ts — observe the worker's lifecycle
import { Events } from "@zappdev/runtime";

Events.on("worker:crashed", ({ id, message, incarnation }) => {
  console.warn(`[${id}] crashed (incarnation ${incarnation}): ${message}`);
});

Events.on("worker:restarted", ({ id, incarnation }) => {
  console.log(`[${id}] restarted as incarnation ${incarnation}`);
});

Events.on("worker:gave-up", ({ id, retriesAttempted }) => {
  // Supervisor capped out — show a user-facing "background sync paused" toast.
  alert(`${id} stopped after ${retriesAttempted} restart attempts.`);
});
```

**Clean-slate semantics.** Each incarnation starts with a fresh JS
context: timers, channel handlers, in-flight inbox messages from the
prior incarnation are all gone. If a webview tries `Workers.send(id,
"channel", data)` during the restart gap, the message is dropped with
a stderr log. The simplest pattern: gate sends on the next
`worker:restarted` after a `worker:crashed`.

**Top-level vs async throws.** Both count as crashes against the cap. A
worker whose script throws at module top will burn through `maxRetries`
in a few milliseconds and surface `worker:gave-up` — no infinite restart
loop possible.

**Window decay.** The supervisor's `withinMs` is a sliding window: after
the window elapses with no failures, the counter resets. A worker that
crashes once a day stays alive indefinitely with `maxRetries: 2` and
`withinMs: 60_000`.

**Engine support.** Restart works identically on `zjs` (default), `bare-jsc`,
`bare-v8`, `bare-quickjs`, `bare-mqjs`, and `bare-hermes`. Same TypeScript
worker source produces the same event sequence on every engine.

## Headless worker for background sync that survives window close

Headless workers keep running while the app is alive, even when every
window is closed. Useful for uploads, background downloads, or keeping
a websocket open.

```ts
// src/workers/sync.ts
import { Events, App, AppEvent } from "@zappdev/runtime";

const queue: Array<{ id: string; payload: unknown }> = [];

// Accept new uploads from any window
Events.on("sync:enqueue", (item: any) => {
  queue.push(item);
  drain();
});

App.on(AppEvent.SHUTDOWN, () => {
  console.log("app shutting down, flushing queue", queue.length);
  // Write pending items to disk so next launch can resume
});

async function drain() {
  while (queue.length > 0) {
    const item = queue.shift()!;
    try {
      await fetch("https://api.example.com/upload", {
        method: "POST",
        body: JSON.stringify(item.payload),
      });
    } catch (e) {
      console.error("upload failed, requeuing", e);
      queue.unshift(item);
      await sleep(5000);
    }
  }
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
```

```ts
// any UI window
import { Events } from "@zappdev/runtime";

uploadButton.addEventListener("click", () => {
  Events.emit("sync:enqueue", { id: "item-1", payload: {...} });
});
```

Note: `fetch` and `WebSocket` in workers require a `workerModules:
["fetch"]` capability declaration in `zapp.config.ts` (for bare-* engines)
or native engine support (zjs ships fetch as its runtime layer matures).
Move network calls to a webview (which has full DOM APIs) if the target
engine doesn't provide them.

## Service that calls ObjC (Keychain, AVFoundation, NSWorkspace)

Some system APIs are cleaner to use from ObjC than from Zen-C — Keychain
via Security.framework is the canonical example. Drop a `.m` file
anywhere under `zapp/` and the CLI auto-compiles and links it.

```
zapp/services/
├── keychain.h       # C header
├── keychain.m       # ObjC implementation
└── keychain.zc      # Zen-C bridge (typed wrapper)
```

```objc
// zapp/services/keychain.m
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "keychain.h"

const char* keychain_read(const char* service, const char* account) {
    NSDictionary* query = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: [NSString stringWithUTF8String:service],
        (id)kSecAttrAccount: [NSString stringWithUTF8String:account],
        (id)kSecReturnData: @YES,
    };
    CFDataRef data = NULL;
    if (SecItemCopyMatching((CFDictionaryRef)query, (CFTypeRef*)&data) != errSecSuccess || !data) return NULL;
    static _Thread_local char buf[1024];
    NSData* nsData = (__bridge_transfer NSData*)data;
    strncpy(buf, [[[NSString alloc] initWithData:nsData encoding:NSUTF8StringEncoding] UTF8String], sizeof(buf) - 1);
    return buf;
}
```

```zc
// zapp/services/keychain.zc
import "services/keychain.h" as c;

fn keychain_read_zc(service: string, account: string) -> string {
    let v = c::keychain_read(service, account);
    if v == NULL { return ""; }
    raw { return v; }
    return "";
}
```

```zc
// zapp/app.zc
import "services/keychain.zc";

fn get_token(_app: App*, args: JsonValue*) -> string {
    let svc = args.get_string("service").unwrap();
    let acct = args.get_string("account").unwrap();
    let token = keychain_read_zc(svc, acct);
    raw {
        static _Thread_local char buf[1280];
        snprintf(buf, sizeof(buf), "{\"token\":\"%s\"}", (const char*)token);
        return buf;
    }
    return "";
}
```

And link Security.framework from `zapp/build.zc`:

```zc
//> macos: framework: Security
```

Full treatment with error handling, `.c` equivalent for Windows, and
framework guidance: [`zen-c-services.md → Services in ObjC or C`](zen-c-services.md#services-in-objc-or-c).

## Service with lifecycle — persistent DB connection

Open a DB connection at app boot, close it on shutdown.

```zc
// zapp/app.zc
import "app/app.zc";
import "./db.zc";  // your wrapper around sqlite / whatever

struct DbService {
    conn: void*;
}

let db_state = DbService{conn: NULL};

fn db_startup(ptr: void*) -> void {
    let self = (DbService*)ptr;
    self.conn = db::open("/Users/me/.my-app/data.db");
    println "db opened";
}

fn db_shutdown(ptr: void*) -> void {
    let self = (DbService*)ptr;
    if self.conn != NULL {
        db::close(self.conn);
    }
    println "db closed";
}

fn db_query(_app: App*, args: JsonValue*) -> string {
    if args == NULL { return "{\"error\":\"no args\"}"; }
    let sql_opt = args.get_string("sql");
    if sql_opt.is_none() { return "{\"error\":\"missing sql\"}"; }

    let sql = sql_opt.unwrap();
    let rows_json = db::query(db_state.conn, sql);  // returns JSON string
    return rows_json;
}

fn run_app() -> int {
    let config = AppConfig{
        name: "mydata",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: Zapp::inspectable_auto(),
        maxWorkers: 0,
        qjsStackSize: 0,
    };
    let app = App::new(config);

    app.service.register("db:query", (void*)&db_state, &ServiceImpl{
        handler: db_query,
        startup: db_startup,
        shutdown: db_shutdown,
    });

    let opts = WindowOptions::create("mydata");
    opts.visible = false;
    let win = app.window.create(&opts);
    win.on_ready(fn (_id: int, _handle: void*) -> void {
        Window{id: _id, handle: _handle}.show();
    });

    return app.run();
}
```

```ts
// src/main.ts — use it
import { Services } from "@zappdev/runtime";

const users = await Services.invoke("db:query", {
  sql: "SELECT id, name FROM users",
});
```

## Notification with action buttons

Categorized notifications with reply field (macOS Action Center /
Notification Center).

```ts
import { Notification } from "@zappdev/runtime";

// One-time setup at app start — typically in src/main.ts or in a startup hook
await Notification.requestPermission();

await Notification.registerCategory({
  id: "message",
  actions: [
    { id: "reply", title: "Reply" },
    { id: "delete", title: "Delete", destructive: true },
  ],
  hasReplyField: true,
  replyPlaceholder: "Type your reply…",
  replyButtonTitle: "Send",
});

// Global handler — fires for every notification interaction
Notification.on("response", async (r: any) => {
  console.log("notif", r.id, "action:", r.actionId, "text:", r.userText);
  if (r.actionId === "reply") {
    await sendReply(r.id, r.userText);
  } else if (r.actionId === "delete") {
    await deleteMessage(r.id);
  }
});

// Show one
await Notification.show({
  id: "msg-123",  // explicit ID so we can update / remove later
  title: "New message from Alice",
  body: "Hey, are you free later?",
  categoryId: "message",
  data: { conversationId: "alice-123" },
});
```

## Custom menu with app shortcuts

Standard menu bar with your own entries + roles for built-in behavior.

```ts
import { Menu, App } from "@zappdev/runtime";

Menu.build([
  { role: "appMenu" },   // About / Quit / Services / Hide (auto-populated)
  {
    label: "File",
    submenu: [
      { label: "New Window", accelerator: "CmdOrCtrl+N", action: openNewWindow },
      { label: "Open…",       accelerator: "CmdOrCtrl+O", action: openFile },
      { type: "separator" },
      { label: "Close Window", accelerator: "CmdOrCtrl+W", role: "quit" /* or a custom close */ },
    ],
  },
  {
    label: "Edit",
    role: "editMenu",   // Cut/Copy/Paste/Select All (auto-populated)
  },
  {
    label: "View",
    submenu: [
      { label: "Toggle Sidebar", accelerator: "CmdOrCtrl+B", action: () => toggleSidebar() },
    ],
  },
  { label: "Window", role: "windowMenu" },
]);

async function openNewWindow() {
  const { Window } = await import("@zappdev/runtime");
  await Window.create({ title: "Untitled", width: 800, height: 600 });
}
async function openFile() {
  const { Dialog } = await import("@zappdev/runtime");
  const r = await Dialog.openFile();
  if (!r.cancelled) console.log("open:", r.paths);
}
function toggleSidebar() { /* ... */ }
```

## Multi-window app with shared state via Events

Two windows that share state, synced via a headless worker.

```ts
// zapp.config.ts
headless: { state: "src/workers/state.ts" }
```

```ts
// src/workers/state.ts — source of truth for shared state
import { Events } from "@zappdev/runtime";

let state = { todos: [] as string[] };

// Any window can read current state
Events.on("state:request", () => {
  Events.emit("state:snapshot", state);
});

// Any window can mutate
Events.on("state:add-todo", (item: any) => {
  state.todos.push(item.text);
  Events.emit("state:snapshot", state);  // broadcast new state
});

Events.on("state:clear", () => {
  state.todos = [];
  Events.emit("state:snapshot", state);
});
```

```ts
// src/main.ts — any window
import { Events, Window } from "@zappdev/runtime";

let localState: any = { todos: [] };

Events.on("state:snapshot", (s) => {
  localState = s;
  render();
});

// Ask for the current state at startup
Events.emit("state:request");

document.getElementById("add")!.addEventListener("click", () => {
  const text = (document.getElementById("input") as HTMLInputElement).value;
  Events.emit("state:add-todo", { text });
});

document.getElementById("open")!.addEventListener("click", async () => {
  await Window.create({ title: "Another view", width: 400, height: 600 });
});
```

Each window gets the same broadcasts, so they stay in sync without
window-to-window plumbing.

## Context menu on right-click

```ts
import { ContextMenu } from "@zappdev/runtime";

document.getElementById("list")!.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  ContextMenu.show([
    { label: "Copy", role: "copy" },
    { label: "Paste", role: "paste" },
    { type: "separator" },
    { label: "Delete", action: () => deleteItem() },
    { label: "Rename…", action: () => promptRename() },
  ]);
});
```

Position auto-derives from the last `contextmenu` event. To force a
specific position:
```ts
ContextMenu.show(items, { x: 100, y: 200 });
```

## Custom titlebar with draggable region

Mark any element with `data-zapp-drag-region` and the system treats it
as a draggable region — click-and-hold moves the window. Interactive
elements *inside* the region (buttons, inputs, links, selects,
textareas, `role="button"` widgets, `contenteditable` elements) stay
clickable by default — the bootstrap walks the hovered element's
ancestors and auto-excludes them from drag.

```html
<!-- Drag anywhere in the titlebar except the controls -->
<div class="titlebar" data-zapp-drag-region>
  <button onclick="goBack()">←</button>
  <input type="search" placeholder="Search..." />
  <div class="title">My App</div>
  <button onclick="settings()">⚙</button>
</div>
```

Works without any CSS on the buttons or input.

### Overriding the default

Two CSS variables force either behavior on a specific element:

```css
/* Force this button to drag the window instead of receiving clicks */
.grab-handle { --zapp-drag: drag; }

/* Force this custom div to be clickable inside a drag region */
.my-custom-button { --zapp-drag: no-drag; }
```

Walk order: explicit `--zapp-drag` on the element > native interactive
tag > `data-zapp-drag-region`. The first decisive rule wins, walking
from the hovered element upward.

### When to use `--zapp-drag: no-drag`

You mostly don't need it — native interactive elements are
auto-excluded. Reach for it only when you build a "button-shaped
thing" out of a `<div>` with your own click handler, or when you
have a complex widget (color picker, slider) that isn't a standard
form control.

### Window metrics — stop eyeballing 28px

Zapp injects real values from the native window into the webview at
document start, so you don't have to guess titlebar height or traffic-
light width:

```css
.titlebar {
  height: var(--zapp-titlebar-height, 38px);
  padding-left: var(--zapp-content-inset-left, 78px);
}
```

- `--zapp-titlebar-height`: the vertical inset the native titlebar
  occupies. `0` on fully borderless windows.
- `--zapp-content-inset-left`: the horizontal offset of the right edge
  of the traffic-light buttons (+ 8pt breathing room). Pad your content
  by this amount to avoid overlap.
- `data-zapp-titlebar-style` on `<html>`: `"default"`, `"hidden"`, or
  `"hiddenInset"`. Use as a CSS attribute selector for style-conditional
  layout.

The values reflect the actual `NSWindow.frame` / `contentLayoutRect` /
`standardWindowButton(NSWindowZoomButton).frame` math on the host
system, so they match exactly whether the OS is using the classic
22pt titlebar, the modern 28pt titlebar, a toolbar-compact variant, or
a future macOS change. Always fall back to a reasonable literal (the
28 / 78 defaults above) so the CSS still works when previewed outside
a Zapp window.

## Custom in-webview protocols

Apps can register their own URL schemes inside the WebView and serve
arbitrary bytes from a JS handler — useful for app-managed assets
(user uploads from a DB, decrypted vault content, on-the-fly resized
images) that you don't want to write to disk just to make WebKit
fetch them.

```ts
// zapp.config.ts
export default defineConfig({
  // Schemes must be declared at build time — WKWebView's scheme
  // registration is config-time only. You can declare any number;
  // each one stays dormant until JS calls Protocols.register.
  protocols: ["asset", "media"],
});
```

```ts
import { Protocols } from "@zappdev/runtime";

Protocols.register("asset", async (req) => {
  // req.url = "asset://thumb-123" (or whatever the consumer fetched)
  const id = new URL(req.url).pathname.slice(1);
  const bytes = await myDb.loadAsset(id);    // your storage
  return { body: bytes, contentType: "image/jpeg" };
});

// Anywhere in HTML / CSS / fetch:
//   <img src="asset://thumb-123" />
//   const r = await fetch("asset://config.json");
```

Returns: `{ body, contentType?, status? }`. Body can be `Uint8Array`
(binary) or `string` (UTF-8 encoded). Status defaults to 200 and
contentType to `application/octet-stream`.

### Use cases

- **Auth-gated images.** `asset://avatar/{user_id}` → fetch from S3
  with the user's session token, return JPEG bytes. The webview can
  use it as a normal `<img src>` — no `fetch`+`URL.createObjectURL`
  dance.
- **Encrypted vault content.** `vault://note/{id}` → decrypt on the
  fly, return Markdown bytes.
- **On-the-fly transcoding.** `media://video/{id}.webm` → run a
  worker that produces a stream-friendly format from the source.
- **Local file proxy with FS allowlist.** `local://file.png` →
  read from disk via the FS service so the rest of the app sees a
  uniform URL space without scattered `file://` paths.

### Different from `deepLinkSchemes`

- `deepLinkSchemes` registers a scheme **system-wide** with macOS so
  `myapp://open/document/123` clicked from another app launches your
  app and fires `App.on(AppEvent.OPEN_URL)`. Routing happens in the
  OS.
- `protocols` registers a scheme **inside the WebView** — Zapp
  intercepts navigation/fetch requests for that scheme and routes
  them to your handler. The OS doesn't see them at all.

You can declare both for the same app — they don't conflict (different
mechanisms, different scheme namespaces).

### Notes

- **Schemes must be declared at build time** in `zapp.config.ts`.
  Calling `Protocols.register("foo", ...)` for a scheme not in the
  config has no effect — WKWebView won't intercept `foo://` requests.
- **Reserved schemes** (http / https / ws / wss / file / about /
  zapp / etc.) are filtered or rejected at WKWebView level. Pick a
  custom name like `asset`, `vault`, `app-asset`.
- **Async handlers** are first-class — return a Promise. WebKit
  doesn't time out on its side; cancellations from JS-side abort
  (e.g. user navigating away mid-load) call `stopURLSchemeTask:`
  and the runtime's pending entry is dropped, so a late respond
  becomes a no-op rather than an error.
- **Body transit**: bytes are base64-encoded for the JS→native trip.
  For very large bodies (>10 MB) consider chunking via streams or
  routing through a Zen-C service (lower overhead).
- **iOS**: Same `WKURLSchemeHandler` API; shipped in alpha.54. Apps
  declare `protocols: [...]` in `zapp.config.ts` and the iOS build
  registers each scheme on the `WKWebViewConfiguration`. The runtime
  side is identical — `Protocols.register(...)` works on both
  platforms with the same handler signature.

## Vibrancy / blur material (macOS)

macOS apps with translucent sidebars, HUDs, and titlebars use
`NSVisualEffectView` to get the system blur. Zapp surfaces this as
a one-line option on `Window.create`:

```ts
import { Window } from "@zappdev/runtime";

const win = await Window.create({
  title: "Stats",
  width: 480, height: 360,
  vibrancy: "sidebar",
  titleBarStyle: "hiddenInset",  // common pairing — full-bleed blur
});
```

```css
/* Web content needs a transparent / translucent background for the
   blur to show through. The window's WebView has its own surface;
   set body to transparent and put per-region color via translucent
   panels. */
html, body { background: transparent; }
.panel    { background: rgba(255, 255, 255, 0.45); }
@media (prefers-color-scheme: dark) {
  .panel  { background: rgba(40, 40, 60, 0.45); }
}
```

### Materials

Maps directly to macOS `NSVisualEffectMaterial` constants:

| Value | Use for |
|---|---|
| `"sidebar"` | Mail / Finder sidebar — most common |
| `"headerView"` | Section header / toolbar background |
| `"titlebar"` | Title-bar matching, full-bleed when paired with `titleBarStyle: "hiddenInset"` |
| `"menu"` | Menu / dropdown background |
| `"popover"` | Popover content (Tray.attachWindow uses regular NSWindow, not NSPopover — set this if you want popover-style blur on a tray-attached window) |
| `"hudWindow"` | HUD overlay (control palettes) |
| `"fullScreenUI"` | Full-screen overlay chrome |
| `"sheet"` | Modal sheet content |
| `"contentBackground"` | Generic content-area background |
| `"underWindowBackground"` | Behind-window blending |
| `"underPageBackground"` | Page-level blending |
| `"windowBackground"` | Default fallback |

### Notes

- **Web content owns its background.** If `body` has `background:
  white`, vibrancy is invisible (the white covers it). Apps using
  vibrancy design CSS for transparency from the start.
- **Window-level only** — there's no per-element vibrancy in DOM
  (CSS `backdrop-filter: blur()` is the closest web equivalent and
  works inside the WebView regardless of native vibrancy).
- **Active vs inactive** — the framework uses
  `NSVisualEffectStateFollowsWindowActiveState` so the blur dims
  when the window loses key focus. Standard macOS UX.
- **No-op on iOS / Windows** — the option is silently ignored.

## Native file drop into webview

The web `drop` event gives you `File` objects, never the original
filesystem path — that's by design in browsers. For desktop apps the
path is exactly what you want, so Zapp intercepts file drops at the
AppKit layer and surfaces four events scoped to the receiving window:

| Event | Payload | When |
|---|---|---|
| `file-drop-enter` | `{ paths: string[], x, y }` | A file drag entered the window. Show a soft "drag in flight" cue across the whole window. |
| `file-drop-over` | `{ x, y }` | Cursor moved during the drag (≤60 Hz). Hit-test the coords against your drop zone's bounding rect to toggle a "ready to drop" highlight only when the cursor is actually over the target. |
| `file-drop-leave` | `{ x, y }` | The drag left the window without dropping (or was cancelled). Reset all states. |
| `file-drop` | `{ paths: string[], x, y }` | Files were dropped. Process them. |

```ts
import { Events } from "@zappdev/runtime";

const dropZone = document.getElementById("drop-zone")!;

let dragInFlight = false;   // drag entered the window at all
let overTarget = false;     // cursor is currently over our drop zone

function paint() {
  dropZone.classList.toggle("is-dragging", dragInFlight);
  dropZone.classList.toggle("is-over-target", overTarget);
}

function isOverTarget(x: number, y: number): boolean {
  const r = dropZone.getBoundingClientRect();
  return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
}

Events.on("file-drop-enter", (d: any) => {
  dragInFlight = true;
  overTarget = isOverTarget(d.x, d.y);
  paint();
});

Events.on("file-drop-over", (d: any) => {
  const was = overTarget;
  overTarget = isOverTarget(d.x, d.y);
  if (was !== overTarget) paint();
});

Events.on("file-drop-leave", () => {
  dragInFlight = false;
  overTarget = false;
  paint();
});

Events.on("file-drop", (d: any) => {
  dragInFlight = false;
  overTarget = false;
  paint();
  for (const path of d.paths as string[]) {
    console.log("dropped:", path);
    // Read via native FS service, copy elsewhere, etc.
  }
});
```

```css
#drop-zone {
  border: 2px dashed currentColor;
  transition: background-color 0.15s, border-style 0.15s;
}
#drop-zone.is-dragging   { background: rgba(0, 122, 255, 0.10); }
#drop-zone.is-over-target {
  background: rgba(0, 122, 255, 0.30);
  border-style: solid;
}
```

### Notes

- **Window-scoped.** Events only fire in the window that received the
  drop — not broadcast. Open multiple windows and drop on one; the
  other window's listener won't fire.
- **Coordinates** are in CSS-pixel-ish view-local space (top-left
  origin), so they line up with `event.clientX/Y`. `getBoundingClientRect()`
  on a DOM element gives you the rect to hit-test against directly.
- **`file-drop-over` is rate-limited to ~60 Hz** at the native layer
  so it doesn't flood JS during a long drag. Skip the event if you
  don't need element-level highlighting; the other three are enough
  for window-level UX.
- **Path access** — `paths` are absolute file paths (`/Users/...`).
  JS can't `readFile` them on its own; route through a Zapp service
  with FS allowlist coverage, or use `Dialog.openFile`'s grant flow
  to extend the allowlist for the dropped paths.
- **Non-file drags** (text into an input, drag-out from an `<a>`
  tag) fall through to WebKit's normal handling.
- **iOS:** shipped in alpha.61 via `UIDropInteraction`. Drops from
  Photos / Files / other apps deliver `file-drop` events with
  paths. iOS hands us security-scoped temp copies of the dragged
  files (NSTemporaryDirectory copies of the originals); the
  framework auto-grants those paths through the FS allowlist so
  apps can `FS.readFile` them immediately. Most useful on iPad
  split-view; works on iPhone via long-press in Files.

## Sync primitive — rate-limiting a resource

```ts
import { Sync } from "@zappdev/runtime";

// Limit to 1 concurrent operation
async function rateLimited<T>(key: string, fn: () => Promise<T>): Promise<T> {
  await Sync.wait(`lock:${key}`, 30000);  // wait up to 30s for our turn
  try {
    return await fn();
  } finally {
    Sync.notify(`lock:${key}`);  // release, wakes next waiter
  }
}

// Prime the lock once at startup
Sync.notify("lock:api");
```

### Why not `SharedArrayBuffer` + `Atomics.wait`?

Zapp's `Sync` looks like the Web Platform's standard wait/notify
primitive, so a fair question is: why not just ship `SharedArrayBuffer`
+ `Atomics.wait`? Three reasons:

1. **Zapp uses multiple JS runtimes.** The webview (WKWebView) and each
   worker (zjs, bare-jsc, etc.) run in isolated runtimes — they cannot
   share a `SharedArrayBuffer` regardless of COOP/COEP headers. `Sync`
   works across every context pair Zapp supports: webview ↔ worker,
   webview ↔ webview, worker ↔ worker, across engine boundaries. SAB
   works only within a single engine instance.

2. **Robustness against Spectre mitigations.** SAB has a long history
   of being silently disabled at runtime when browsers tighten
   mitigations or the platform gets quirky. `Sync` goes through
   native primitives (`dispatch_semaphore_t` on Darwin, event objects
   on Windows) — no web-platform kill-switch can disable it.

3. **SAB is the single-engine perf path, not a replacement.** Inside
   a single engine (JSC webview ↔ JSC worker), SAB + `Atomics.wait`
   *would* be faster for hot wait/notify loops. Enabling it is
   additive — `Sync` stays as the portable correctness primitive,
   SAB becomes an opt-in perf path when COOP/COEP headers land on
   the `zapp://` scheme handler. `Sync` works everywhere today; SAB
   is a future micro-optimization for apps that need it.

Framing: **portable coordination primitive across engines, SAB as an
optional single-engine perf path when we add it.**

## Deep links

```ts
// zapp.config.ts
export default defineConfig({
  name: "My App",
  identifier: "com.example.myapp",
  deepLinkSchemes: ["myapp"],  // registers myapp:// scheme
});
```

```ts
// src/main.ts or src/workers/whatever.ts
import { App, AppEvent } from "@zappdev/runtime";

App.on(AppEvent.OPEN_URL, (data: any) => {
  console.log("deep link:", data.url);
  // data.url is the full URL: "myapp://open/document/123"
  const url = new URL(data.url);
  if (url.hostname === "open" && url.pathname.startsWith("/document/")) {
    const id = url.pathname.split("/")[2];
    openDocument(id);
  }
});
```

On macOS, the OS routes `myapp://...` URLs to your app via
`application:openURLs:`. On Windows, URL scheme registration goes
through the registry + `WM_COPYDATA` for single-instance handling.

## Single-instance enforcement

```ts
// zapp.config.ts
export default defineConfig({
  name: "My App",
  singleInstance: true,
});
```

Maps to `LSMultipleInstancesProhibited = YES` in Info.plist on macOS.
Launch Services refuses second-launch attempts (`open -n` / running a
duplicated bundle); the existing instance receives any `myapp://` URL
or dock-icon reopen via `App.on(AppEvent.OPEN_URL)` /
`AppEvent.REOPEN`.

Default is `false` to match macOS-native behavior. Most desktop apps
want `true`; menu-bar / sync-engine apps almost always want `true` to
keep local state coherent (two copies of a sync worker would corrupt
the local DB).

No-op on iOS — apps are always single-instance there by platform
contract.

## Menu-bar app (tray-attached window)

The classic macOS menu-bar app pattern: an icon in the top-right of
the menu bar, click it, a small panel slides in. Bartender, Hand
Mirror, Stats, Linear's status icon, Granola's mini panel.

```ts
import { Tray, Window } from "@zappdev/runtime";

// 1. Create the popover window. Make it borderless + invisible until
//    the tray icon toggles it on. The framework forces floating level
//    + auto-hides on blur, so you don't have to.
const popover = await Window.create({
  title: "Stats",
  width: 320,
  height: 480,
  borderless: true,
  visible: false,
  resizable: false,
});

// 2. Create the tray icon and attach the window. Left-click toggles
//    visibility. Position is auto-computed from the icon's screen
//    coordinates.
const tray = Tray.create({ icon: "build/menubar-icon.png", tooltip: "Stats" });
tray.attachWindow(popover, { position: "centerBelow" });
```

### Combined mode — left = window, right = menu

`attachWindow` is purely additive to `setMenu`. With both configured,
left-click drives the window and right-click opens the menu (the
[`menubar`](https://github.com/max-mapper/menubar) package's
convention):

```ts
const tray = Tray.create({
  icon: "build/menubar-icon.png",
  menu: [                                 // right-click menu
    { label: "Open Settings…", action: openSettings },
    { type: "separator" },
    { label: "Quit", role: "quit" },
  ],
});
tray.attachWindow(popover);                // left-click toggle
```

### Options

`attachWindow(window, opts?)` accepts:

| Option | Default | Notes |
|---|---|---|
| `position` | `"centerBelow"` | `"centerBelow"`, `"centerAbove"`, or `"rightCenter"` |
| `dismissOnBlur` | `true` | Hide on focus loss (cmd-tab to another app, key window changes) |
| `dismissOnOutsideClick` | `true` | Hide on any click outside the popover (other windows, dock, menu bar) |
| `toggleOnClick` | `true` | Second click hides; set false for click-to-show only |
| `offset` | `{ x: 0, y: 4 }` | Pixel adjustment from the computed anchor point |

The two dismiss flags are independent. Set both `false` for a "sticky" panel that you close explicitly from inside (e.g. an X button). Set only `dismissOnOutsideClick: false` for a panel that survives stray clicks but still auto-hides when you cmd-tab away.

### Detaching

```ts
tray.detachWindow();  // restores menu-only or click-event mode
```

If a menu was previously set, it returns to system-driven left-click
behavior. Otherwise the tray reverts to firing `click` /
`right-click` events.

### Caveats

- The window is forced to `NSFloatingWindowLevel` while attached.
  This restores to normal level on detach.
- Multi-monitor: the window appears on the screen the menu bar lives
  on (drag the menu bar between displays to test).
- Make the window **`borderless: true`** at creation. Re-styling
  after creation is unreliable — the macOS titlebar reappears in
  weird states.
- iOS / Windows: `attachWindow` is a no-op (no menu bar / different
  metaphor). Code is portable.

## Modal sheets — same code, native presentation per platform

`Window.create({ asSheetOf: parent })` opens a child window attached
to a parent — slides down as an `NSWindow` sheet on macOS, presents
as a `UIViewController` modal on iOS. Same JSON, two native idioms.

```ts
import { Window } from "@zappdev/runtime";

const settings = await Window.create({
  title: "Settings",
  width: 480,
  height: 600,
  asSheetOf: Window.current(),
});
// macOS: slides down from the parent's titlebar.
// iOS: presents as PageSheet by default.
```

iOS adds presentation styles (no-op on macOS) that desktop-cross-
platform frameworks can't expose, because they don't have a native
iOS story:

```ts
// Drawer-style bottom sheet with snap points + grabber.
await Window.create({
  asSheetOf: Window.current(),
  presentation: "bottomSheet",
  detents: ["small", "medium", "large"],
  grabber: true,
});

// Compact form sheet (centered card on iPad, ~half-screen on iPhone).
await Window.create({
  asSheetOf: Window.current(),
  presentation: "form",
});

// Take-over modal — no swipe-to-dismiss, modal must close itself.
await Window.create({
  asSheetOf: Window.current(),
  presentation: "fullscreen",
});
```

### Detents (iOS 15+ `UISheetPresentationController`)

| Value | Approx. height | Availability |
|---|---|---|
| `"small"` | ~25% | iOS 16+ (custom detent; silently dropped on iOS 15) |
| `"medium"` | ~50% | iOS 15+ |
| `"large"` | full sheet | iOS 15+ |

Mix freely (`["small", "medium", "large"]`) to give users multiple
snap points. When omitted on `bottomSheet`, defaults to
`["medium", "large"]`. Page / form sheets ignore detents on iPhone
in older iOS versions but respect them on iOS 15+ where the
underlying controller is the same.

### Grabber

`grabber: true` shows the small drag-handle at the top of the
sheet — makes swipe-to-dismiss obviously discoverable on full-
width iPhone sheets. iOS 15+; no-op on macOS.

### Nested sheets

You can present a sheet from inside a sheet. The framework keeps a
modal stack and presents on the topmost currently-displayed VC:

```ts
// Inside the first modal's webview:
await Window.create({
  asSheetOf: Window.current(),
  presentation: "page",
});
// Stacks on top of the bottom sheet that opened this one.
```

Dismissing the topmost reveals the one beneath, and the
`WINDOW_MODAL_DISMISSED` event fires with the right `(parent, modal)`
pair so app code can react per-level.

### Dismissal event

```ts
parent.on(WindowEvent.MODAL_DISMISSED, ({ modalId }) => {
  console.log("user closed modal:", modalId);
});
```

Fires when the user swipes a sheet down (iOS), clicks the close
button (macOS), or app code calls `parent.detachModal(modal)`.
Fullscreen presentations don't fire on swipe (they don't allow it)
— only on programmatic dismiss.

### Notes

- **iPhone** is single-window. `Window.create` without `asSheetOf`
  on iPhone returns the existing window; sheets are how you "open
  new content" on iPhone.
- **Custom detent heights** (e.g. exactly 200pt or 35%) aren't
  in the API yet — see `project_ios_custom_detents` for the future
  shape.
- **macOS** `beginSheet` is single-style; the `presentation` /
  `detents` / `grabber` options silently no-op there. macOS apps
  that want a "popover bottom sheet" effect would need a different
  primitive.

## Dock badge + bounce

```ts
import { Dock } from "@zappdev/runtime";

// Show unread count
Dock.setBadge("5");

// Grab user attention when app is in background
Dock.bounce("informational");   // one bounce
Dock.bounce("critical");        // keeps bouncing until activated

// Clear when opened
window.addEventListener("focus", () => {
  Dock.removeBadge();
});
```

## Custom icon and Info.plist

### Just an icon

Drop your icon into `build/macos/`. CLI picks it up automatically at
`bun run package` — no config needed.

```
build/macos/icon.icon         # Icon Composer (best for macOS 26+)
# or
build/macos/icon.icns
build/macos/icon.iconset
build/macos/icon.png          # 1024×1024 single PNG
```

For a custom path elsewhere, set `macos.icon` in `zapp.config.ts`:

```ts
export default defineConfig({
  name: "My App",
  macos: {
    icon: "design/app-icon.png",
  },
});
```

### Privacy usage descriptions

If your app uses camera, microphone, location, etc., macOS requires a
human-readable explanation. Without one, the app crashes the moment it
tries to use the capability.

```ts
// zapp.config.ts
export default defineConfig({
  name: "My App",
  macos: {
    usageDescriptions: {
      camera: "Capture photos for your profile",
      microphone: "Record audio messages",
      photos: "Pick images from your library",
    },
  },
});
```

These map to `NSCameraUsageDescription`,
`NSMicrophoneUsageDescription`, and `NSPhotoLibraryUsageDescription`
in the generated `Info.plist`.

### Background-only / agent app

A "menu bar app" or background daemon — no dock icon, no menu in the
menu bar.

```ts
// zapp.config.ts
export default defineConfig({
  name: "My App",
  macos: {
    plistExtras: {
      LSUIElement: true,    // → <true/>
    },
  },
});
```

### Custom URL scheme + permissions + signing

Real-app config combining several options:

```ts
import { defineConfig } from "@zappdev/cli/config";

export default defineConfig({
  name: "Conversa",
  identifier: "com.acme.conversa",
  version: "1.4.2",
  deepLinkSchemes: ["conversa"],
  macos: {
    copyright: "Copyright © 2026 Acme Corp",
    category: "public.app-category.social-networking",
    minimumSystemVersion: "13.0",
    signingIdentity: "Developer ID Application: Acme Corp (TEAM12345)",
    usageDescriptions: {
      camera: "Take photos for your conversations",
      microphone: "Record voice messages",
      photos: "Attach images from your library",
      bluetooth: "Discover nearby contacts",
    },
  },
});
```

### Complex Info.plist via raw file

When you need nested dicts/arrays of mixed types — not expressible via
`plistExtras`'s flat map — use `build/macos/Info.plist.extra`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>example.com</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
<key>UTExportedTypeDeclarations</key>
<array>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>com.acme.mydoc</string>
        <key>UTTypeDescription</key>
        <string>My App Document</string>
    </dict>
</array>
```

Don't wrap in `<plist>` or `<dict>` — only the inner key/value pairs.
The CLI injects them into the generated plist's top-level `<dict>`.

If a key here matches a CLI-derived key, CLI logs a warning at package
time and your value wins.

## Code-signing entitlements

Entitlements are **separate from the Info.plist**. They live in a
standalone `Entitlements.plist` and are passed to `codesign
--entitlements` during both `zapp dev` and `zapp package`.

### Typed map in `zapp.config.ts`

Common entitlements that fit a flat map:

```ts
import { defineConfig } from "@zappdev/cli/config";

export default defineConfig({
  name: "my-app",
  macos: {
    entitlements: {
      // Network access for a web client
      "com.apple.security.network.client": true,

      // File system scopes
      "com.apple.security.files.user-selected.read-write": true,

      // Hardened runtime relaxations
      "com.apple.security.cs.allow-jit": true,

      // App Sandbox opt-in (usually paired with narrow scopes above)
      "com.apple.security.app-sandbox": false,
    },
  },
});
```

Value rules match `plistExtras`:
- `boolean` → `<true/>`/`<false/>`
- `string` → `<string>…</string>`
- `number` → `<integer>` (or `<real>` if fractional)
- `string[]` → `<array>` of strings

### File at `build/macos/app.entitlements`

For complex entitlements — App Groups with arrays, nested dicts — drop
a full `.entitlements` file. Wrap in the standard `<plist><dict>…</dict>
</plist>` header (the CLI strips and re-emits the wrappers):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.acme.myapp.shared</string>
    </array>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.acme.myapp</string>
    </array>
</dict>
</plist>
```

Override the path via `macos.entitlementsFile` if you keep it
elsewhere.

### Map + file precedence

If both are configured, map entries override the same keys in the file.
CLI logs a warning when a key appears in both.

### Ad-hoc signing caveat

Privileged entitlements — anything starting with `com.apple.developer.*`
or `com.apple.security.app-sandbox` — require a **real signing
identity**. Ad-hoc signing embeds the entitlements but macOS ignores
them. The CLI warns when it detects this mismatch.

Two common examples:

- `kSecUseDataProtectionKeychain` needs
  `com.apple.developer.default-data-protection`, which requires a
  Developer ID signing identity + a provisioning profile.
- iCloud containers need a team-id-scoped container entitlement, also
  Developer ID only.

For local dev against those APIs, set `macos.signingIdentity` to a
self-signed or Developer ID identity so the entitlements take effect.
`zapp dev` re-signs with the same identity and entitlements, so the
dev run matches the `zapp package` result.

## Notarization

Distributing a `.app` outside the App Store on macOS 10.15+ requires
**notarization** — Apple scans the bundle, returns a verdict, and you
"staple" the approval ticket onto the bundle so Gatekeeper opens it
without warnings on first launch.

`zapp package --notarize` automates this end-to-end. Three things
need to be in place:

1. A real Developer ID code-signing identity (not ad-hoc).
2. Notarization credentials (one of three auth paths below).
3. The signed `.app` (handled by `zapp package` itself).

### Set up credentials

**Option 1 — Keychain profile (easiest local).**

Run once on your machine:

```bash
xcrun notarytool store-credentials zapp-notarize \
  --apple-id "you@example.com" \
  --team-id "TEAMID1234" \
  --password "app-specific-password-from-appleid.apple.com"
```

Then in `zapp.config.ts`:

```ts
macos: {
  signingIdentity: "Developer ID Application: Your Name (TEAMID1234)",
  notarize: { keychainProfile: "zapp-notarize" },
}
```

**Option 2 — API key (recommended for CI).**

Generate an App Store Connect API key (`.p8`). Set:

```ts
macos: {
  signingIdentity: "Developer ID Application: ...",
  notarize: {
    apiKeyPath: "/secure/path/AuthKey_AB12CD34EF.p8",
    apiKeyId: "AB12CD34EF",
    apiIssuerId: "1234abcd-...-...-...-1234abcd5678",
  },
}
```

For CI, override via env vars instead of committing the values:

```bash
ZAPP_NOTARIZE_API_KEY_PATH=/secrets/key.p8
ZAPP_NOTARIZE_API_KEY_ID=AB12CD34EF
ZAPP_NOTARIZE_API_ISSUER_ID=1234abcd-...
```

**Option 3 — Apple ID + app-specific password (legacy).**

```ts
macos: {
  signingIdentity: "Developer ID Application: ...",
  notarize: {
    appleId: "you@example.com",
    teamId: "TEAMID1234",
    // password ALWAYS via env, never config:
    //   ZAPP_NOTARIZE_APPLE_PASSWORD=xxxx-xxxx-xxxx-xxxx
  },
}
```

### Run it

```bash
bunx @zappdev/cli package --notarize
```

Output looks like:

```
[zapp] signing (Developer ID Application: Your Name) with entitlements...
[zapp] notarizing via keychain profile "zapp-notarize"…
[zapp] (Apple typically takes 1–5 min — be patient)
[zapp] notarization accepted, stapling…
[zapp] notarization complete: release/MyApp.app
```

### Common failures

- **Hardened runtime not enabled** — required for notarization. Add
  `entitlements: { "com.apple.security.cs.allow-unsigned-executable-memory": false }`
  and ensure no entitlement disables the hardened runtime. The CLI
  passes `--options runtime` to codesign automatically when
  `signingIdentity` is non-ad-hoc.
- **Bundle not fully signed** — `--deep` fixes most cases; if you
  vendor pre-built binaries (e.g. bare-* engine libs) they must
  also be signed.
- **"Invalid" status with no obvious reason** — the CLI fetches the
  submission log via `xcrun notarytool log` and prints it. Look for
  `code: 90000` and the `message` field for the actual rejection
  reason.

### Env-var overrides

Every `notarize.*` config field has a matching env var, so secrets
stay out of `zapp.config.ts`:

| Config | Env var |
|---|---|
| `keychainProfile` | `ZAPP_NOTARIZE_KEYCHAIN_PROFILE` |
| `apiKeyPath` | `ZAPP_NOTARIZE_API_KEY_PATH` |
| `apiKeyId` | `ZAPP_NOTARIZE_API_KEY_ID` |
| `apiIssuerId` | `ZAPP_NOTARIZE_API_ISSUER_ID` |
| `appleId` | `ZAPP_NOTARIZE_APPLE_ID` |
| `teamId` | `ZAPP_NOTARIZE_TEAM_ID` |
| (password — env only) | `ZAPP_NOTARIZE_APPLE_PASSWORD` |

Env wins over config so you can set safe placeholders in source and
override per-environment.

## Further reading

- [`api-reference.md`](api-reference.md) — full runtime API
- [`zen-c-services.md`](zen-c-services.md) — writing native services
- [`architecture.md`](architecture.md) — how everything fits together
- [`../llms.txt`](../llms.txt) — single-file reference for agents
