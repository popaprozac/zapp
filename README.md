<div align="center">
  <h1>Zapp</h1>
  <h3>Desktop and mobile apps. 445 KB on macOS.</h3>
  <p>
    <img src="https://img.shields.io/badge/macOS-supported-brightgreen" alt="macOS">
    <img src="https://img.shields.io/badge/iOS-supported-brightgreen" alt="iOS">
    <img src="https://img.shields.io/badge/Windows-in_progress-yellow" alt="Windows">
    <img src="https://img.shields.io/badge/Linux-planned-lightgrey" alt="Linux">
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="License">
  </p>
</div>

---

Zapp is an application framework that produces **extraordinarily small binaries** by compiling to native code via [Zen-C](https://github.com/zenc-lang/zenc) and rendering UI in the system WebView. No bundled browser. No runtime overhead. Your frontend is your choice — React, Svelte, Vue, or vanilla.

The same Zapp codebase ships to **macOS and iOS** today (Windows next). Desktop apps get the full multi-window / menu-bar / tray surface; iOS apps get UIKit-native modal sheets, file pickers, notifications, and clipboard — without any "this looks like a web app on a phone" feel.

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
| **Build** | **3.5s** | 3.2s | 53.8s | 1.9s | 3.6s | 12.8s |

### Bridge latency — by context (µs, median)

Two numbers matter, not one: calls from the webview, and calls from a
worker. Worker calls are where real app hot paths live (sync engine,
DB access, local filesystem).

| | Zapp (JSC) | Zapp (txiki) | Tauri | Wails | Electron | Electrobun |
|---|---:|---:|---:|---:|---:|---:|
| **Webview → native** | 145 | 130 | 265 | 325 | **51** | 360 |
| **Worker → native** | **2.1** | **0.3** | N/A<sup>\*</sup> | N/A<sup>\*</sup> | 73 | N/A<sup>†</sup> |

<sub>\* Tauri and Wails don't ship a JS worker with native-call access — their equivalent is "drop to Rust/Go and wire it yourself." No apples-to-apples JS number exists.</sub>
<br>
<sub><sup>†</sup> Electrobun uses an encrypted WebSocket for webview IPC; no separate worker→native fast path.</sub>

Electron wins row 1 because Chromium's IPC uses optimized named pipes / mach ports. Electron's worker row (73 µs) is the realistic pattern: a Web Worker can't call `ipcRenderer` directly (contextBridge only exposes APIs to the main window), so calls route worker → renderer postMessage → `ipcRenderer.invoke` → main, then the reply flows back the same way — 2 postMessage hops plus the IPC round-trip.

Zapp workers bypass that entirely — `Services.invokeSync` is a direct C call via the worker engine's host object. **JSC is 35× faster than Electron** on this path; **txiki is 243× faster** because QuickJS's `JS_NewCFunction` is a thinner C-call convention than JSC's JSValue-block dispatch. For apps where hot work lives in workers (sync engines, DB access, background pipelines), row 2 is the number that matters — and Tauri/Wails can't compete on row 2 at all, because they force a language boundary instead.

### Which engine?

Zapp ships two worker engines on macOS. Both win on different axes:

- **JSC** *(default)* — 445 KB binary. macOS system framework, zero extra cost. Best raw JS perf (JIT). Worker → native: 2.1 µs.
- **txiki** *(opt-in)* — 6.5 MB binary. Cross-platform (macOS + future Windows/Linux). Full web APIs in workers: `fetch`, `WebSocket`, `TextEncoder`, `crypto`, embedded SQLite, FFI. Fastest worker → native path: 0.3 µs (QuickJS's `JS_NewCFunction` is a thinner C-call convention than JSC's JSValue dispatch).

Pick **JSC** when: macOS-only, no web APIs needed inside workers, smallest binary matters. Pick **txiki** when: you need `fetch` or `WebSocket` inside a worker (sync engines, DB drivers), you're targeting cross-platform, or you have a hot worker↔native loop where the 7× call-rate difference pays back the binary cost.

Per-worker engine mix lands in a later alpha — until then, pick one per project via `zapp/build.zc`.

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

iOS dev mode (requires Xcode + booted Simulator):
```bash
xcrun simctl boot "iPhone 17 Pro"   # or any device from `simctl list devices available`
bun run dev --platform ios
```
Vite + your app on the sim, with stdout/stderr streamed to the dev terminal — same loop as desktop dev, just routed through `simctl launch --console-pty`. Edit a `.ts` file → Vite HMR refreshes the webview; edit a `.zc` / `.m` file → re-run `bun run dev --platform ios` to recompile + reinstall.

iOS prod build:
```bash
bun run build --platform ios
xcrun simctl install booted bin/ios/<name>.app
xcrun simctl launch --console-pty booted com.your.bundle
```
First iOS build takes a minute (cross-compiles txiki.js for the iOS Simulator SDK if your config opts into it). Subsequent builds reuse the cached static libs in `vendor/txiki.js/build-ios-sim`.

### Custom icons and Info.plist

Drop your app icon into `build/macos/`:

```
build/macos/icon.icon       # Icon Composer (best for macOS 26+ liquid glass)
build/macos/icon.icns       # traditional .icns
build/macos/icon.iconset    # source set, CLI converts via iconutil
build/macos/icon.png        # 1024×1024, CLI compiles via actool
```

Customize `Info.plist` via typed config (autocomplete-friendly):

```ts
// zapp.config.ts
macos: {
  copyright: "Copyright © 2026 You",
  usageDescriptions: { camera: "We need camera for ...", microphone: "..." },
  plistExtras: { LSUIElement: false, MyKey: "MyValue" },
}
```

For nested dicts/arrays, drop a partial XML file into `build/macos/Info.plist.extra`. Full pattern in [`docs/patterns.md`](docs/patterns.md#custom-icon-and-infoplist).

## Features

- **Window Management** — Create, resize, fullscreen, always-on-top. 11 typed events with payloads.
- **Application Menus** — Default OS menus + custom menu API with roles, accelerators, and inline actions.
- **Context Menus** — Filtered default (no Reload/Back) + `ContextMenu.show()` for custom native menus.
- **Dialogs** — Native file open/save and message dialogs.
- **Draggable Regions** — `data-zapp-drag-region` for custom titlebar apps. Buttons, inputs, links, and other interactive elements inside a drag region stay clickable by default; override with `style="--zapp-drag: drag"` or `--zapp-drag: no-drag` to force either behavior. Native window metrics (`--zapp-titlebar-height`, `--zapp-content-inset-left`) are injected as CSS variables so custom titlebars size correctly without hard-coded magic numbers.
- **Close Prevention** — Cancellable close events from native or JS. "Unsaved changes?" dialogs.
- **Services** — Define native RPC in Zen-C, call from JS. Auto-generated TypeScript bindings. Drop `.m` (macOS) or `.c` (Windows) files anywhere under `zapp/` for ObjC/C-backed services (Keychain, AVFoundation, libsqlite3, etc.) — auto-compiled and linked.
- **Workers (unified)** — Webview-spawned (`new Worker("./foo.ts")`) or headless (declared in `zapp.config.ts`). Both share the full runtime API — `Window.create`, `Events`, `Services`, `Notification`, `Dock`, `Sync` — via a zero-overhead direct host bridge (no IPC).
- **Sync** — `wait`/`notify` across contexts without SharedArrayBuffer.
- **Events** — Typed cross-context events with autocomplete.
- **Security** — CSP, navigation restrictions, path traversal prevention, dev tools disabled in production.
- **Packaging** — `.app` bundles with icon generation (including macOS Tahoe liquid glass).
- **iOS** — Same source compiles to iOS Simulator / device via `--platform ios`. UIKit-native presentation: `Window.create({ asSheetOf, presentation: "page" | "form" | "fullscreen" | "bottomSheet", detents, grabber })` for sheets and drawers, `UIDocumentPickerViewController` for file pickers, `UNUserNotificationCenter` for notifications + actions + reply field, `UIPasteboard` for full clipboard (text / HTML / image / files), `UIDropInteraction` for file drag-drop, custom `WKURLSchemeHandler` protocols, navigation allowlist with Safari handoff for external links.

## Platform support

| Feature | macOS | iOS | Windows |
|---|:-:|:-:|:-:|
| Window create / resize / events | ✅ | ✅ (single window on iPhone, sheets for "new content") | ⚠️ in progress |
| Application menus | ✅ | n/a (no menu bar) | ⚠️ |
| Tray / status item | ✅ | n/a | ⏳ |
| Modal sheets (`asSheetOf`) | ✅ NSWindow.beginSheet | ✅ presentViewController + UISheetPresentationController | ⏳ |
| Native dialogs | ✅ | ✅ UIDocumentPicker / UIAlertController | ⚠️ |
| Notifications + actions | ✅ | ✅ UNUserNotificationCenter | ⏳ |
| Clipboard (text / HTML / image / files) | ✅ | ✅ UIPasteboard | ⚠️ text only |
| File drag-drop into webview | ✅ | ✅ UIDropInteraction | ⏳ |
| Custom protocols (`asset://`, ...) | ✅ | ✅ | ⏳ |
| Navigation allowlist | ✅ | ✅ | ⏳ |
| Workers — JSC | ✅ (JIT) | ✅ (no JIT, Apple policy) | n/a |
| Workers — txiki / fetch / WebSocket / SQLite | ✅ | ✅ (FFI disabled per App Store policy) | ⏳ |
| App Store / TestFlight packaging | n/a | ⏳ Phase 3 | n/a |

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

setInterval(() => {
  // Sync in a worker — direct host-object C call, no await, no microtask.
  // (In a webview context you'd use Services.invoke with await.)
  const latest = Services.invokeSync("fetchLatest");
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
