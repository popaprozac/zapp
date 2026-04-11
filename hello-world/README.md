# Zapp v2 Hello World

Reference example app for the Zapp v2 framework.

## Quick Start

```bash
bun install
bun run build     # production build
./bin/hello-world
```

Dev mode (Vite HMR):
```bash
bun run dev
```

## Project Structure

```
hello-world/
├── zapp/                    # Native Zen-C code
│   ├── app.zc               # Services, windows, lifecycle
│   └── build.zc             # Build directives, entry point
├── src/                     # Frontend (Vite)
│   ├── main.ts              # App entry — uses @zappdev/runtime
│   └── style.css            # Styles
├── .zapp/                   # CLI-generated build artifacts
│   ├── zapp_build_config.zc # Build-time constants
│   ├── zapp_bootstrap.zc    # Generated bridge JS
│   └── zapp_platform.zc     # Platform .m file compilation
├── index.html
├── vite.config.ts
├── zapp.config.ts
└── package.json
```

## Runtime API

```ts
import {
  App, Window, WindowEvent, Events, Services,
  Worker, SharedWorker, Dialog, Menu, ContextMenu,
  Notification, Sync
} from "@zappdev/runtime";

// Window events + close guard
const win = Window.current();
win.on(WindowEvent.RESIZE, (p) => console.log(p.size));
win.setCloseGuard(true);
win.on(WindowEvent.CLOSE, async () => {
  const r = await Dialog.message({ message: "Close?", buttons: ["Yes", "No"] });
  if (r.button === 0) win.close();
});

// Dialogs
const { paths } = await Dialog.openFile({ title: "Pick a file" });
const { button } = await Dialog.message({ message: "Sure?", buttons: ["Yes", "No"] });

// Menus
Menu.build([
  { label: "File", submenu: [{ label: "Open", accelerator: "CmdOrCtrl+O" }, { role: "quit" }] },
  { role: "editMenu" }
]);

// Context menu
ContextMenu.show([
  { label: "Copy", action: () => {} },
  { label: "Delete", action: () => {} },
], { x: e.clientX, y: e.clientY });

// Notifications
await Notification.requestPermission();
await Notification.show({ title: "Done!", body: "File saved" });

// Sync (cross-context wait/notify)
const result = await Sync.wait("data-ready", 5000); // "notified" | "timed-out"
Sync.notify("data-ready");      // wake one waiter (default count = 1)
Sync.notifyAll("data-ready");   // wake every waiter — broadcast

// Workers
const w = new Worker("./worker.ts");
w.send("compute", { n: 42 });
w.receive("result", (data) => console.log(data));

// Backend → all webviews state push (src/backend.ts is the convention)
// In src/backend.ts:
//   let count = 0;
//   setInterval(() => Events.emit("counter:tick", { value: ++count }), 2000);
// In any webview:
//   Events.on("counter:tick", ({ value }) => updateUI(value));
// Every open window receives the broadcast simultaneously.

// Open URL in system browser
App.openExternal("https://example.com");
```

## Draggable Regions

```css
.titlebar { --zapp-drag: drag; }
.titlebar button { --zapp-drag: no-drag; }
```
