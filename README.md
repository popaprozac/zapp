<div align="center">
  <h1>Zapp</h1>
  <h3>Desktop apps. 189 KB.</h3>
  <p>
    <img src="https://img.shields.io/badge/macOS-supported-brightgreen" alt="macOS">
    <img src="https://img.shields.io/badge/Windows-supported-brightgreen" alt="Windows">
    <img src="https://img.shields.io/badge/Linux-planned-lightgrey" alt="Linux">
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="License">
  </p>
</div>

---

Zapp is a desktop application framework that produces **extraordinarily small binaries** by compiling to native code via [Zen-C](https://github.com/zenc-lang/zenc) and rendering UI in the system WebView. No bundled browser. No runtime overhead. Your frontend is your choice — React, Svelte, Vue, or vanilla.

## Benchmarks

Real numbers. Same hello-world app (1 window, 1 service call) on each framework.

| | Zapp | Tauri v2 | Wails v3 | Electron |
|---|---|---|---|---|
| **Binary** | **189 KB** | 8.2 MB | 7.5 MB | 263 MB |
| **Memory** | **24 MB** | 27 MB | 31 MB | 528 MB |
| **Bridge** | **0.085 ms** | ~0.1 ms | ~0.2 ms | ~0.3 ms |

<sub>macOS ARM64, M4 Max. See <a href="benchmarks/RESULTS.md">full results</a> including Windows.</sub>

## Quick Start

```bash
# Prerequisites: Zen-C compiler (zc) + Bun
bun add -g @zappdev/cli
zapp init my-app
cd my-app
bun install
zapp dev
```

Production build:
```bash
zapp build --brotli
zapp package --brotli   # .app bundle with icon (macOS)
```

## Features

- **Window Management** — Create, resize, fullscreen, always-on-top. 11 typed events with payloads.
- **Application Menus** — Default OS menus + custom menu API with roles, accelerators, and inline actions.
- **Context Menus** — Filtered default (no Reload/Back) + `ContextMenu.show()` for custom native menus.
- **Dialogs** — Native file open/save and message dialogs.
- **Draggable Regions** — `data-zapp-drag-region` for custom titlebar apps.
- **Close Prevention** — Cancellable close events from native or JS. "Unsaved changes?" dialogs.
- **Services** — Define native RPC in Zen-C, call from JS. Auto-generated TypeScript bindings.
- **Workers** — Optional native JS workers (QuickJS/JSC) with direct backend access.
- **Sync** — `wait`/`notify` across contexts without SharedArrayBuffer.
- **Events** — Typed cross-context events with autocomplete.
- **Security** — CSP, navigation restrictions, path traversal prevention, dev tools disabled in production.
- **Packaging** — `.app` bundles with icon generation (including macOS Tahoe liquid glass).

## Example

**Native** (`zapp/app.zc`):
```zc
import "app/app.zc";

fn greet(app: App*, args: string) -> string {
    return args;
}

fn on_ready(id: int, handle: void*) -> void {
    Window{id: id, handle: handle}.show();
}

fn run_app() -> int {
    let config = AppConfig{
        name: "My App",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: -1,
        maxWorkers: 0,
        qjsStackSize: 0,
    };
    let app = App::new(config);
    app.service.add("greet", greet);

    let opts = window_options_default("My App");
    opts.visible = false;
    let win = app.window.create(&opts);
    win.on_ready(on_ready);

    return app.run();
}
```

**Frontend** (`src/main.ts`):
```ts
import { Window, WindowEvent, Services, Menu, App } from "@zappdev/runtime";

Window.current().on(WindowEvent.READY, () => {
    Window.current().show();
});

Menu.build([
    { role: "appMenu" },
    { label: "File", submenu: [
        { label: "Quit", accelerator: "CmdOrCtrl+Q", action: () => App.quit() },
    ]},
    { label: "Edit", role: "editMenu" },
]);

const result = await Services.invoke("greet", { name: "World" });
```

## Packages

| Package | NPM | JSR |
|---|---|---|
| `@zappdev/cli` | [npm](https://www.npmjs.com/package/@zappdev/cli) | — |
| `@zappdev/runtime` | [npm](https://www.npmjs.com/package/@zappdev/runtime) | [jsr](https://jsr.io/@zapp/runtime) |
| `@zappdev/vite` | [npm](https://www.npmjs.com/package/@zappdev/vite) | [jsr](https://jsr.io/@zapp/vite) |

## Documentation

| | |
|---|---|
| [Getting Started](docs/getting-started.md) | Install, create, dev, build, package |
| [API Reference](docs/api/) | App, Window, Events, Dialog, Menu, Worker, Sync, Services |
| [Native Reference](docs/native/) | AppConfig, Window, Services in Zen-C |
| [Guides](docs/guides/) | Draggable regions, close prevention, menus, security |
| [CLI](docs/cli.md) | Command reference |
| [Config](docs/config.md) | `zapp.config.ts` reference |
| [FAQ](docs/faq.md) | Why Workers? Why Sync? Why Zen-C? |
| [Benchmarks](docs/benchmarks.md) | Full performance comparison |

## License

MIT
