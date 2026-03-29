# Zapp — Claude Skills Reference

Reference for Claude sessions working on the Zapp desktop framework.

## 1. Mission

Zapp creates the **smallest, fastest desktop application framework**. Key metrics (v2 baseline, no optimizations):

| Metric | Zapp v2 | Tauri v2 | Wails v3 | Electron |
|---|---|---|---|---|
| Binary | **259 KB** (86 KB optimized) | 8.2 MB | 7.5 MB | 263 MB |
| Memory | **24 MB** | 27 MB | 30 MB | 528 MB |
| Bridge | **0.085 ms** (WebView), **0.0005 ms** (Worker host object) | ~0.1 ms | ~0.2 ms | ~0.3 ms |

- Written in **Zen-C** (compiles to C) with system WebViews (WKWebView macOS, WebView2 Windows)
- No bundled browser, no runtime overhead
- Frontend: any Vite-compatible framework (React, Svelte, Vue, vanilla)
- Platforms: macOS first. Windows next. Linux future.

## 2. Architecture

### v2 Directory Structure

```
zapp/
├── native/                     # Zen-C framework
│   ├── app/                    # App lifecycle, message routing
│   │   ├── app.zc              # App struct, config, bootstrap JS
│   │   └── router.zc           # Bridge message dispatch
│   ├── window/                 # Cross-platform window API
│   │   ├── window.zc           # Structs, enums, accessors, trampolines
│   │   ├── events.zc           # Event IDs (struct+def), EventResult enum
│   │   └── callbacks.zc        # Unified event dispatcher (raw C)
│   ├── dialog/
│   │   └── dialog.zc           # Native Zen-C dialog wrappers
│   ├── notification/
│   │   └── notification.zc     # Native Zen-C notification wrappers
│   ├── service/
│   │   └── service.zc          # Service registry, RPC invoke
│   ├── bridge/
│   │   ├── protocol.zc         # JSON protocol, cancellation bitmap
│   │   └── dispatch.zc         # Response/event dispatch to WebViews
│   ├── worker/                 # Worker engine abstraction
│   │   ├── worker.zc           # Worker trait
│   │   └── engines/            # JSC, txiki.js (replacing QJS)
│   ├── platform/
│   │   ├── platform.zc         # @cfg dispatch to platform impls
│   │   └── darwin/
│   │       ├── platform.h/.m   # NSApp, delegate, menus
│   │       ├── window.h/.m     # NSWindow, delegates, events
│   │       ├── webview.h/.m    # WKWebView, scheme handler, bridge
│   │       ├── dialog.h/.m     # Dialogs (bridge JSON + native typed)
│   │       ├── notification.h/.m # Notifications (async + fire-and-forget)
│   │       └── menu.h/.m       # Menus (recursive builder, accelerators)
│   └── shared/
│       └── log.zc
├── runtime/                    # TypeScript user API (@zappdev/runtime)
│   ├── app.ts, window.ts, events.ts, services.ts
│   ├── dialog.ts, menu.ts, context-menu.ts, notification.ts
│   └── bridge.ts               # Internal bridge accessor
├── cli/                        # Build tooling (Bun)
│   └── src/                    # init, dev, build, generate commands
├── bootstrap/                  # JS injected into WebView/Workers (future)
└── hello-world/                # Reference example app
```

### Layered Architecture

| Layer | Purpose | Language |
|---|---|---|
| **User native code** | Services, window config | Zen-C (pure, no raw blocks) |
| **Framework abstraction** | Window, events, bridge, services | Zen-C (minimal raw for C arrays) |
| **Platform impl** | NSWindow, WKWebView, Win32 | ObjC .m / C .c files |
| **Bootstrap** | JS bridge in WebView | JS (inlined, future: TS codegen) |
| **Runtime** | User-facing TS API | TypeScript |
| **CLI** | Build pipeline | TypeScript (Bun) |

### The .zc → .h → .m Pattern

ObjC lives in proper .m files. Zen-C owns the types and calls through C headers:

```
Zen-C (.zc)  →  defines structs, enums, accessor functions
C Header (.h) →  declares opaque types + C API
ObjC (.m)    →  implements using accessor functions (no struct layout duplication)
```

Example: `WindowOptions` defined in Zen-C, `darwin_window_create(WindowOptions* opts)` in .m calls `wopts_width(opts)`, `wopts_title(opts)` etc.

### Two-Tier Native API

The `.m` files serve two consumers — typed C functions bypass JSON entirely for native Zen-C code:

```
JS Bridge:  JS → JSON → C(JSON) → ObjC → JSON → JS
Native:     Zen-C → C(typed) → ObjC → typed return → Zen-C  (zero serialization)
```

Wrappers in `native/dialog/dialog.zc` and `native/notification/notification.zc` give pure Zen-C code (no raw blocks, no JSON).

### Bridge Protocol

JSON with numeric type routing:
```json
{"t":1,"id":42,"m":"greet","a":{"name":"World"}}
```

| Type | Code | Direction | Response? |
|---|---|---|---|
| invoke | 1 | JS→Native | Yes (targeted to calling window) |
| invoke_response | 2 | Native→JS | — |
| emit | 3 | JS→Native | No (fire-and-forget, broadcast) |
| window_action | 4 | JS→Native | No (show, hide, setTitle, subscribe, ready) |
| worker | 5 | JS→Native | — |
| sync | 6 | JS→Native | — |
| cancel | 7 | JS→Native | No (cancels pending invoke by ID) |

### Event System

Unified layered dispatcher:
1. **Layer 1**: Native Zen-C callback (can return CANCEL to stop propagation)
2. **Layer 2**: JS bridge dispatch (targeted to owning window's WebView)

Optimizations:
- Per-window JS listener bitmask — skips JS dispatch for unlistened events
- Direct WebView dispatch table — O(1) lookup by numeric window ID
- Reusable C buffer for event JS — zero allocation per event
- Cached numericId on delegate — no string lookup in hot path

### Worker Architecture

Workers are in-process JS contexts owned by a window. They have direct native access via host objects (nanosecond-level calls vs 0.085ms WebView bridge).

| Engine | Platform | Status |
|---|---|---|
| **JSC** | macOS (default) | v1 working, v2 pending port |
| **txiki.js** | All platforms | Replacing QuickJS — web APIs built-in |
| QuickJS | Legacy | Being replaced by txiki.js |

txiki.js (QuickJS-ng + libuv) provides fetch, WebSocket, timers, crypto, TextEncoder/Decoder natively — eliminates our manual polyfills.

## 3. Zen-C Quick Reference

### Trusted C header imports (KEY DX PATTERN)
```zc
import "stdio.h" as c;
import "JavaScriptCore/JavaScriptCore.h" as jsc;

fn example() -> void {
    c::printf("hello\n");
    let ctx = jsc::JSGlobalContextCreate(NULL);  // entire JSC C API works
}
```

### Enums (tagged unions)
```zc
enum TitleBarStyle { Default, Hidden, HiddenInset }
let style = TitleBarStyle::Hidden();  // () required — constructors
```
Raw block access: `value.tag == TitleBarStyle_Hidden_Tag`

### struct+def pattern (int-valued constants)
```zc
struct WindowEvents { READY: int; FOCUS: int; RESIZE: int; }
def WindowEvent = WindowEvents{ READY: 0, FOCUS: 1, RESIZE: 3 };
```
Use when raw blocks need direct int comparisons.

### Auto-dereference
```zc
fn process(data: MyStruct*) -> int { return data.width; }
```

### String interpolation
```zc
println "value: {x}, name: {name}";
```
macOS ARC issue with int32_t pointer fields — extract to local `int` var first.

### @cfg platform dispatch
```zc
@cfg(apple)
fn platform_init(name: string) -> void { darwin::darwin_platform_init(name); }
```
Only works on top-level declarations (not inside functions).

### Key limitations
- Struct bodies emitted late in generated C — raw blocks can't stack-allocate Zen-C structs
- Raw block ordering unpredictable across files — `#define` must be duplicated with `#ifndef` guards
- Enum values need `()` — `Color::Red()` not `Color::Red`
- `default` is a C reserved word — don't use as function name (use `create` instead)
- `{}` in strings triggers interpolation — use raw blocks for literal braces

## 4. Key Files (v2)

### Native framework
| File | Role |
|---|---|
| `native/app/app.zc` | App lifecycle, config, bootstrap JS, active app state |
| `native/app/router.zc` | Bridge message dispatch (invoke, emit, window actions, workers, cancel) |
| `native/window/window.zc` | WindowOptions, Window, WindowManager, accessors, @cfg trampolines |
| `native/window/events.zc` | Event IDs (struct+def), EventResult enum, #define macros |
| `native/window/callbacks.zc` | Unified event dispatcher, bitmask, callback registry |
| `native/service/service.zc` | Service registration, invoke, sync invoke for workers, manifest JSON |
| `native/bridge/protocol.zc` | Message types, JSON parsing, cancellation bitmap |
| `native/bridge/dispatch.zc` | Response/event dispatch, JS string escaping |
| `native/worker/worker.zc` | Worker trait, @cfg engine dispatch, workers_enabled() |
| `native/worker/registry.zc` | Worker-to-owner tracking for cleanup |
| `native/worker/engines/jsc.h/.m` | JSC worker engine (macOS, serial dispatch queue) |
| `native/worker/engines/jsc.zc` | JSC Zen-C trampolines |
| `native/worker/engines/txiki.h/.c` | txiki.js worker engine (cross-platform, libuv threads) |
| `native/worker/engines/txiki.zc` | txiki.js Zen-C trampolines |
| `native/platform/platform.zc` | @cfg(apple) trampolines for platform_init/run |
| `native/platform/darwin/platform.h/.m` | NSApp, delegate, menus |
| `native/platform/darwin/window.h/.m` | NSWindow, ZappWindowDelegate, event dispatch, WebView table |
| `native/platform/darwin/webview.h/.m` | WKWebView, scheme handler, message handler, navigation delegate |
| `native/platform/darwin/dialog.h/.m` | macOS dialogs — bridge JSON + native typed API |
| `native/platform/darwin/notification.h/.m` | macOS notifications — async bridge + fire-and-forget typed |
| `native/platform/darwin/menu.h/.m` | macOS menus — recursive NSMenu builder, accelerators, roles |
| `native/dialog/dialog.zc` | Native Zen-C dialog wrappers (zero JSON) |
| `native/notification/notification.zc` | Native Zen-C notification wrappers (fire-and-forget) |

### TypeScript
| File | Role |
|---|---|
| `runtime/index.ts` | Re-exports: App, Window, Events, Services, Worker, Dialog, Menu, ContextMenu, Notification |
| `runtime/bridge.ts` | Internal getBridge() via Symbol.for('zapp.bridge') |
| `runtime/services.ts` | Services.invoke() → CancellablePromise |
| `runtime/events.ts` | Events.on/emit, WindowEvent/AppEvent enums |
| `runtime/window.ts` | Window.current().on/show/hide/setTitle/etc |
| `runtime/worker.ts` | Worker class with postMessage + channels (send/receive) |
| `runtime/dialog.ts` | Dialog.openFile/saveFile/message |
| `runtime/menu.ts` | Menu.build() with action stripping, auto-IDs, event wiring |
| `runtime/context-menu.ts` | ContextMenu.show() with one-shot event cleanup |
| `runtime/notification.ts` | Notification.requestPermission/show/schedule/cancel/on |
| `runtime/app.ts` | App.quit(), App.openExternal(), App.getConfig() |
| `cli/src/zapp-cli.ts` | CLI entry: init, dev, build, generate |
| `cli/src/build-config.ts` | Generates .zapp/zapp_build_config.zc + platform config |
| `cli/src/generate.ts` | Scans services → src/zapp/ TypeScript bindings |
| `cli/src/workers.ts` | Discovers + bundles worker scripts |
| `cli/src/native.ts` | Resolves framework dir, compiles with zc |
| `cli/src/bundle.ts` | Dev .app bundle creation (Info.plist + ad-hoc signing) |
| `cli/src/init.ts` | Scaffolds via Vite + adds zapp/ native code |

## 5. Conventions

- **Always use Bun**, never Node.js
- **Inclusive language**: allowlist/blocklist
- **Test in playground/** before applying Zen-C patterns
- **ObjC in .m files**, never in raw blocks in .zc files
- **Accessor functions** bridge Zen-C structs to .m code (no layout duplication)
- **darwin_ prefix** in .h/.m, clean names in .zc trampolines
- **zapp_ prefix** for internal C globals/helpers in .m files
- **`@cfg(apple)`** on top-level imports and functions for platform dispatch
- `hello-world/` is the reference example app

## 6. Current State

### Working (v2, as of 2026-03-29)
- Window creation with all options (TitleBarStyle enum, transparency, always-on-top)
- WebView with zapp:// custom scheme handler
- Bridge: JSON protocol, numeric routing, request IDs, cancellation + timeout
- Services: register in Zen-C, invoke from JS/Workers, auto-generated TS bindings
- Events: 11 window events, unified dispatcher, per-window bitmask, targeted delivery
- Window actions: show, hide, close, setTitle, setSize, setPosition, minimize, maximize, fullscreen, alwaysOnTop
- Close guard: `Window.current().setCloseGuard(true)` prevents close from JS, handler decides
- Workers: JSC (macOS, 0 size) + txiki.js (cross-platform, +6 MB)
  - postMessage round-trip (WebView ↔ Worker)
  - Channel API (send/receive named routing)
  - Host objects (invokeService — direct native calls from worker)
  - Worker bundling (CLI scans for `new Worker()`, bundles .ts → .mjs)
  - Page refresh cleanup (pagehide terminates owned workers)
  - SharedWorkers: refcounted multi-window, dedup by URL, broadcast dispatch
  - Safari Web Inspector for JSC workers (gated on inspectable config)
- Dialogs: openFile, saveFile, message — bridge JSON API + native Zen-C typed API
- Menus: app menu + context menu — JSON from JS, recursive NSMenu builder, accelerators, roles
- Draggable regions: `--zapp-drag` CSS property, mousemove tracking in bootstrap JS
- Notifications: async bridge API (permission, show, schedule, cancel) + fire-and-forget native Zen-C API
- Native Zen-C wrappers: `dialog/dialog.zc`, `notification/notification.zc` — two-tier design, zero JSON
- Dev .app bundle: CLI creates minimal .app + Info.plist + ad-hoc signing (enables notifications, dock icon)
- Navigation restrictions: block external URLs, allowlist with glob patterns, user clicks → system browser
- App.openExternal(url) — open URL in system browser
- CLI: init (Vite scaffold), dev (HMR + .app bundle), build (prod binary), generate (TS bindings)
- Bootstrap codegen: `bootstrap/webview.ts` → minified → `.zapp/zapp_bootstrap.zc` (proper TypeScript, build-time)
- Sync: cross-context wait/notify coordination — native per-key FIFO queues with timeout, host objects in workers
- Native Zen-C menu API: MenuItem struct, menu_set, menu_show_context — two-tier (typed + JSON)
- Manager pattern: app.menu, app.dialog, app.notification, app.sync — namespaced access
- App-level event system: STARTED, SHUTDOWN, REOPEN, OPEN_URL, ACTIVE/INACTIVE — native-first
- Deep links: custom URL protocols (CFBundleURLTypes), `application:openURLs:` delegate
- Backend worker: privileged app-level JS context (JSC default, txiki.js opt-in for web APIs)
- Production packaging: `zapp package` with icons (liquid glass), signing, notarization
- Window.create() from frontend, App.on(AppEvent) from frontend, Window.loadUrl()
- Runtime: App, Window, Events, Services, Worker, SharedWorker, Dialog, Menu, ContextMenu, Notification, Sync

### Binary sizes
- 384 KB (JSC workers + backend, no optimizations)
- ~6.4 MB (txiki.js workers, no optimizations)
- ~90 KB (JSC workers, -Oz -flto strip — deferred for baseline)

### Not yet in v2
- Windows platform
- Brotli/embedded assets
- File watching in dev mode
- Build optimizations (-Oz -flto strip)
- Service lifecycle trait (startup/shutdown, Wails-style)

### Deferred design decisions
- Deep links — reference Wails v3 custom protocols
- Binary protocol header — add when JSON parsing is a measured bottleneck
- Per-window capabilities (Tauri-style security) — config-driven
- JSC web APIs (fetch, WebSocket) — keep lean, users reach for txiki.js

## 7. Resources

| Resource | URL |
|---|---|
| Zen-C docs | https://docs.zenc-lang.org/ |
| Zen-C repo | https://github.com/zenc-lang/zenc |
| txiki.js | https://github.com/saghul/txiki.js |
| WebView2 host objects | https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/hostobject |
| Wails v3 bindings | https://v3alpha.wails.io/features/bindings/methods/ |
| Tauri IPC | https://tauri.app/develop/calling-rust/ |
| Playground | `playground/` (test Zen-C patterns before applying) |
| Interop tests | `tests/zenc-interop/` (12 tests) |
| Gemini research | `GEMINI.md` (bridge architecture, host objects) |
