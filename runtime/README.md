# @zappdev/runtime

TypeScript frontend API for [Zapp](https://github.com/zappdev/zapp)
desktop apps. Use the same imports in webview code, webview-spawned
workers, and headless workers — internal fast paths are automatic.

## Install

The CLI's `zapp init` scaffolds this package as a dependency. If you're
adding it manually:

```bash
bun add @zappdev/runtime
```

## Exports

```ts
import {
  // App lifecycle
  App,
  Events, AppEvent, type EventName,

  // Windows
  Window, WindowEvent, type WindowHandle, type WindowOptions,
  type WindowPayload, type WindowSizePayload,

  // Screens / displays
  Screen, type Display, type DisplayRect, type CursorPoint,

  // Embedded webviews (<zapp-webview>)
  Webview, ZappWebviewElement, type PanelEvent, type WebviewCreateOptions,

  // IPC to native services
  Services, type InvokeOptions, type CancellablePromise,

  // Workers
  Worker, Workers, type WorkerMessageEvent,

  // UI surfaces
  Dialog, type OpenFileOptions, type SaveFileOptions, type MessageOptions,
  Menu, type MenuItemDef, type MenuHandle,
  ContextMenu, type ContextMenuOptions,
  Notification, type NotificationOptions, type ScheduleOptions, type PermissionStatus,
  Dock,
  Tray, type TrayOptions, type TrayHandle, type AttachWindowOptions,

  // System integration
  Clipboard, type ClipboardFormat,
  Shortcuts,
  Protocols, type ProtocolRequest, type ProtocolResponse, type ProtocolHandler,

  // Cross-context coordination
  Sync, type SyncWaitOptions,

  // Helpers
  eventName,
} from "@zappdev/runtime";
```

Focused entrypoints keep environment-specific code out of bundles that do not
need it. Generated service bindings use the same service surface in WebViews
and application workers:

```ts
import {
  Services,
  PermissionDeniedError,
  ZappError,
  ZappInvocationError,
  type CancellablePromise,
  type InvokeOptions,
} from "@zappdev/runtime/service";
```

`@zappdev/runtime/window` and `@zappdev/runtime/worker` provide the equivalent
focused window and application-worker surfaces. `@zappdev/runtime/shell`
exports the focused `ShellError` contract used by
`Application.current().shell`. The root entrypoint remains a convenient broad
import for WebView application code.

## Context story

The runtime works in three contexts, same API everywhere, different fast
paths under the hood:

| Context | Services.invoke | Window.create | Notification / Dock |
|---|---|---|---|
| Webview | async IPC through WKWebView (~135 µs) | async IPC | async IPC |
| Webview-spawned worker (`new Worker()`) | direct host-object C call (~5 µs) | direct C call | direct C call (via `__zappBridge.notif` / `.dock`) |
| Headless worker (from `zapp.config.ts`) | direct host-object C call | direct C call | direct C call |

You don't write any detection code. The same `Services.invoke("foo", args)`
works everywhere; the runtime picks the right path.

**One API difference**: `Window.current()` throws in worker context (a
worker doesn't have a "current" window — it's not inside one). Use
`Window.create()` to spawn a window from a worker, or pass a `windowId`
through a service call if you need to act on a specific existing window.

## Quick reference

```ts
// App lifecycle
App.quit();
App.openExternal("https://...");
App.on(AppEvent.OPEN_URL, (data) => { ... });

// Focused replacement application surface
await Application.current().shell.openExternal("https://docs.z-language.com");

// Windows
const w = Window.current();                          // webview only
const w2 = await Window.create({ title: "Second" }); // any context
w.subscribe(WindowEvent.CLOSE, () => { ... });
w.setCloseGuard(true);  // block close; handle in CLOSE event

// Services (Zen-C handlers)
const r = await Services.invoke<{ pong: number }>("ping");

// Events (cross-context bus)
Events.on("data:updated", (d) => { ... });
Events.emit("data:updated", { value: 42 });  // from a worker: broadcasts to all windows

// Cross-context wait/notify
await Sync.wait("ready", 5000);   // → "notified" | "timed-out"
Sync.notify("ready");             // wake one
Sync.notifyAll("ready");          // wake all

// Native UI
await Dialog.openFile({ multiple: true });
Menu.build([{ role: "appMenu" }, ...]);
await Notification.show({ title: "Hello", body: "World" });
Dock.setBadge("3");
const tray = Tray.create({ icon: "build/menubar.png", menu: [...] });

// System integration
await Clipboard.writeText("hello");
await Shortcuts.register("CmdOrCtrl+Shift+K", () => { ... });  // macOS
Protocols.register("asset", async (req) => ({ body: ..., mime: "image/svg+xml" }));

// Screens
const displays = await Screen.getAll();   // bounds / workArea / scaleFactor

// Embedded webview (loads X-Frame-Options-blocked sites; sandboxed)
document.body.appendChild(Webview.create({ src: "https://github.com" }));
```

## Reference

Full API with edge cases, anti-patterns, and worker vs webview semantics:
see [`llms.txt`](../llms.txt) at the repo root. Longer-form guides in
[`docs/api-reference.md`](../docs/api-reference.md).
