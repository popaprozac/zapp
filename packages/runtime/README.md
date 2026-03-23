# @zappdev/runtime

Frontend runtime API for Zapp desktop apps. Provides type-safe access to native window management, events, dialogs, menus, services, and more from your web frontend.

## Install

```sh
bun add @zappdev/runtime
```

```sh
npm install @zappdev/runtime
```

## Usage

```ts
import { App, Window, WindowEvent, Events, Dialog, Menu } from "@zappdev/runtime";

// Show window when ready
Window.current().on(WindowEvent.READY, () => {
    Window.current().show();
});

// Listen for window resize with typed payload
Window.current().on(WindowEvent.RESIZE, (payload) => {
    console.log("Resized:", payload.size.width, payload.size.height);
});

// Open a file dialog
const result = await Dialog.openFile({
    title: "Select a file",
    filters: [{ name: "Images", extensions: ["png", "jpg"] }],
});

// Create a new window
const win = await Window.create({ title: "My Window", width: 800, height: 600 });
```

## Features

- **Window management** — create, resize, move, fullscreen, always-on-top, close prevention
- **Event system** — 11 typed window events with autocomplete and size/position payloads
- **Dialogs** — native open/save file dialogs and message boxes
- **Menus** — build native application menus with roles, accelerators, and inline actions
- **Services** — call native Zen-C services with auto-generated TypeScript bindings
- **Workers** — optional native JS workers (QuickJS/JSC) with direct backend access
- **Sync primitives** — Atomics-like `wait`/`notify` across contexts without SharedArrayBuffer

## Docs

See the full documentation at [docs/](../../docs/).

## License

MIT
