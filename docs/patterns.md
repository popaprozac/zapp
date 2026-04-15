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

Note: `fetch` and `WebSocket` only work in workers when using the
**txiki** engine (see `zapp/build.zc`). JSC workers don't have them —
move network calls to a webview (which has full DOM APIs) or switch
engines.

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

## Native file drop into webview

Zapp handles drag-drop natively — add `data-file-drop-target` to an
element and listen for the event:

```html
<div data-file-drop-target id="drop-zone">Drop files here</div>
```

```ts
import { Events } from "@zappdev/runtime";

Events.on("files-dropped", (payload: any) => {
  console.log("dropped files:", payload.paths);
  // payload.paths is string[]
});
```

Files are passed as file:// paths that you can read via a service
(native has FS access; JS doesn't on its own).

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

## Further reading

- [`api-reference.md`](api-reference.md) — full runtime API
- [`zen-c-services.md`](zen-c-services.md) — writing native services
- [`architecture.md`](architecture.md) — how everything fits together
- [`../llms.txt`](../llms.txt) — single-file reference for agents
