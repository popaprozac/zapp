<div align="center">
  <h1>Zapp</h1>
  <h3>Desktop apps. 445 KB.</h3>
  <p>
    <img src="https://img.shields.io/badge/macOS-supported-brightgreen" alt="macOS">
    <img src="https://img.shields.io/badge/Windows-in_progress-yellow" alt="Windows">
    <img src="https://img.shields.io/badge/Linux-planned-lightgrey" alt="Linux">
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="License">
  </p>
</div>

---

Zapp is a desktop application framework that produces **extraordinarily small binaries** by compiling to native code via [Zen-C](https://github.com/zenc-lang/zenc) and rendering UI in the system WebView. No bundled browser. No runtime overhead. Your frontend is your choice — React, Svelte, Vue, or vanilla.

Building with an AI agent? Point it at [`llms.txt`](llms.txt) for a
comprehensive single-file reference covering concepts, config shapes, the
full runtime API, and common patterns. See [`docs/`](docs/) for longer-form
guides.

## Benchmarks

Real numbers. Same hello-world app (1 window, 1 service call) on each framework. macOS ARM64, M4 Max.

| | Zapp (JSC) | Zapp (txiki) | Tauri v2 | Wails v3 | Electron | Electrobun |
|---|---|---|---|---|---|---|
| **Binary** | **445 KB** | 6.5 MB | 8.0 MB | 7.5 MB | 170.6 MB | 17.0 MB |
| **Bundle** | **2.8 MB** | 8.9 MB | 8.1 MB | 9.0 MB | 263.3 MB | 17.1 MB |
| **Memory** | **26 MB** | 25 MB | 26 MB | 32 MB | 90 MB | 101 MB |
| **IPC** | **0.14 ms** | 0.13 ms | 0.28 ms | 0.33 ms | 0.05 ms | 0.38 ms |
| **Build** | **3.5s** | 3.2s | 53.8s | 1.9s | 3.6s | 12.8s |

Zapp ships two worker engines: **JSC** (macOS-only, tiny, no web APIs in workers) and **txiki** (cross-platform, full web APIs). Both share the same native bridge — IPC is within noise of each other.

<sub>See <a href="benchmarks/RESULTS.md">full results</a> with methodology, cold/hot build times, and raw JSON.</sub>

## Quick Start

```bash
# Prerequisites: Zen-C compiler (zc) + Bun
bunx @zappdev/cli init my-app
cd my-app
bun install
bun run dev
```

Production build:
```bash
bun run build
bun run package   # .app bundle with icon (macOS)
```

No global install needed — `bunx` fetches the CLI on the fly for init, and `bun run` uses the local copy in your project's `node_modules`.

## Features

- **Window Management** — Create, resize, fullscreen, always-on-top. 11 typed events with payloads.
- **Application Menus** — Default OS menus + custom menu API with roles, accelerators, and inline actions.
- **Context Menus** — Filtered default (no Reload/Back) + `ContextMenu.show()` for custom native menus.
- **Dialogs** — Native file open/save and message dialogs.
- **Draggable Regions** — `data-zapp-drag-region` for custom titlebar apps.
- **Close Prevention** — Cancellable close events from native or JS. "Unsaved changes?" dialogs.
- **Services** — Define native RPC in Zen-C, call from JS. Auto-generated TypeScript bindings.
- **Workers (unified)** — Webview-spawned (`new Worker("./foo.ts")`) or headless (declared in `zapp.config.ts`). Both share the full runtime API — `Window.create`, `Events`, `Services`, `Notification`, `Dock`, `Sync` — via a zero-overhead direct host bridge (no IPC).
- **Sync** — `wait`/`notify` across contexts without SharedArrayBuffer.
- **Events** — Typed cross-context events with autocomplete.
- **Security** — CSP, navigation restrictions, path traversal prevention, dev tools disabled in production.
- **Packaging** — `.app` bundles with icon generation (including macOS Tahoe liquid glass).

## Example

**Native** (`zapp/app.zc`):
```zc
import "app/app.zc";

fn greet(_app: App*, _args: JsonValue*) -> string {
    return "Hello from Zapp!";
}

fn on_ready(_id: int, _handle: void*) -> void {
    Window{id: _id, handle: _handle}.show();
}

fn run_app() -> int {
    let config = AppConfig{
        name: "My App",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: Zapp::inspectable_auto(),
        maxWorkers: 0,
        qjsStackSize: 0,
    };
    let app = App::new(config);
    app.service.add("greet", greet);

    let opts = WindowOptions::create("My App");
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

## Headless workers

Add a long-running TypeScript worker that starts at app boot — useful for
database connections, background sync, or any app-level state that needs
to outlive individual windows.

```ts
// zapp.config.ts
import { defineConfig } from "@zappdev/cli/config";

export default defineConfig({
  name: "My App",
  headless: {
    sync: "src/workers/sync.ts",   // worker ID → source path
  },
});
```

```ts
// src/workers/sync.ts
import { Events, Services, Notification } from "@zappdev/runtime";

setInterval(async () => {
  const latest = await Services.invoke("fetchLatest");
  Events.emit("data:updated", latest);   // broadcast to every open window
}, 5000);
```

```ts
// src/main.ts — any window can listen
import { Events } from "@zappdev/runtime";
Events.on("data:updated", (data) => render(data));
```

All workers (webview-spawned via `new Worker()` or headless via config)
have identical runtime API access: `Window.create`, `Events`, `Services`,
`Notification`, `Dock`, `Sync`. The only difference is lifecycle.

## Packages

| Package | NPM | Docs |
|---|---|---|
| `@zappdev/cli` | [npm](https://www.npmjs.com/package/@zappdev/cli) | [README](cli/README.md) |
| `@zappdev/runtime` | [npm](https://www.npmjs.com/package/@zappdev/runtime) | [README](runtime/README.md) |
| `@zappdev/vite` | [npm](https://www.npmjs.com/package/@zappdev/vite) | [README](vite/README.md) |

## Documentation

| | |
|---|---|
| [`llms.txt`](llms.txt) | Single-file reference — concepts, config, full runtime API, patterns, anti-patterns. Good for agents. |
| [`docs/api-reference.md`](docs/api-reference.md) | Long-form API reference with edge cases |
| [`docs/zen-c-services.md`](docs/zen-c-services.md) | Writing native services: JsonValue args, lifecycle, thread-safety |
| [`docs/patterns.md`](docs/patterns.md) | Cookbook of common app patterns |
| [`docs/architecture.md`](docs/architecture.md) | How the pieces fit under the hood |
| [`benchmarks/README.md`](benchmarks/README.md) | Methodology for the benchmarks above |
| [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) | Full measurements with raw JSON |

## License

MIT
