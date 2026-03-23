# @zapp/runtime

Frontend runtime API for Zapp desktop apps. Provides type-safe access to native window management, events, dialogs, menus, services, and more from your web frontend.

## Install

```sh
bun add @zapp/runtime
```

```sh
npm install @zapp/runtime
```

## Usage

```ts
import { App, Window, Events, Dialog, Menu } from "@zapp/runtime";

// Listen for window events
Events.on("window:resize", (payload) => {
  console.log("Window resized:", payload.width, payload.height);
});

// Open a file dialog
const result = await Dialog.openFile({
  title: "Select a file",
  filters: [{ name: "Images", extensions: ["png", "jpg"] }],
});

// Create a new window
await Window.open({ title: "My Window", width: 800, height: 600 });
```

## Features

- **Window management** -- create, resize, move, and close native windows
- **Event system** -- subscribe to window and app lifecycle events
- **Dialogs** -- native open/save file dialogs and message boxes
- **Menus** -- build native application and context menus
- **Services** -- communicate with backend services
- **Workers** -- spawn Web Workers and Shared Workers with native integration
- **Sync primitives** -- cross-thread synchronization utilities

## Docs

See the full documentation in [`../../docs/`](../../docs/).

## License

MIT
