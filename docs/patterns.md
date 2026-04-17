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

## Further reading

- [`api-reference.md`](api-reference.md) — full runtime API
- [`zen-c-services.md`](zen-c-services.md) — writing native services
- [`architecture.md`](architecture.md) — how everything fits together
- [`../llms.txt`](../llms.txt) — single-file reference for agents
