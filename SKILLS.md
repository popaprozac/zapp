# Zapp — contributor / agent primer

Short orientation doc for Claude sessions (or other agents) working **on
Zapp itself**, not apps built with Zapp.

**For the public API**, read [`llms.txt`](llms.txt). That's the
single-file reference — concepts, config, full runtime API, patterns.
Don't duplicate that here.

**This file covers what agents need to navigate the framework source
code**: directory layout, conventions, invariants, file roles.

## Mission

Build the smallest, fastest desktop framework. macOS first, Windows next.

Current headline numbers (M4 Max, one-window kitchen-sink):

| Metric | Zapp (zjs) |
|---|---|
| Binary | 445 KB |
| Memory | 26 MB |
| IPC round-trip (webview) | 135 µs |
| IPC round-trip (worker) | 0.45 µs |

Full comparison vs Tauri / Wails / Electron / Electrobun: `benchmarks/RESULTS.md`.

## Architecture

Three layers, read bottom to top:

1. **Native core** (`native/`) — Zen-C source. Owns App, Window, Service,
   Menu, Notification, Dialog, Dock, Sync, Worker engines. Calls into
   platform code via `darwin_*` / `windows_*` externs declared in `.h`
   files and implemented in `.m` / `.c` files.
2. **Bridge** (`bootstrap/`) — TypeScript that gets bundled, minified, and
   compiled into the native binary as a C string constant. Injected into
   each WebView and each Worker JS context at startup. Defines the
   `__zappBridge` global the runtime uses.
3. **Runtime** (`runtime/`) — published as `@zappdev/runtime`. Thin TS
   wrappers over `__zappBridge`. Same imports work in webview + workers;
   per-call fast-path detection is inline.

Alongside:
- **CLI** (`cli/`) — `@zappdev/cli`. Project scaffold + build pipeline.
- **Vite plugin** (`vite/`) — `@zappdev/vite`. Worker bundling + Vite
  integration.
- **Bootstrap** (`bootstrap/`) — TS → C string codegen.

## Directory map

```
zapp/
├── native/                         # Zen-C framework
│   ├── app/                        # App, router, events
│   │   ├── app.zc                  # AppConfig, ZappInspectable, App::new/run
│   │   ├── router.zc               # Bridge message dispatch
│   │   └── app_events.zc           # AppEvent broadcast to workers
│   ├── window/                     # Cross-platform window API
│   │   ├── window.zc               # WindowOptions, Window, accessors
│   │   ├── events.zc               # WindowEvent IDs
│   │   └── callbacks.zc            # Event dispatcher, per-window bitmask
│   ├── bridge/                     # IPC protocol
│   │   ├── protocol.zc             # JSON protocol types
│   │   └── dispatch.zc             # Response/event dispatch
│   ├── service/service.zc          # Service registry, invoke
│   ├── worker/
│   │   ├── worker.zc               # Engine abstraction
│   │   ├── registry.zc             # Worker slots, owner tracking
│   │   └── engines/
│   │       ├── zjs.{h,c}            # First-party engine (cross-platform, default)
│   │       └── bare-*.{h,c}        # bare-jsc / bare-v8 / bare-quickjs / bare-mqjs / bare-hermes
│   ├── dialog/dialog.zc            # Native dialog wrappers
│   ├── notification/notification.zc # Native notification wrappers
│   ├── dock/dock.zc                # Native dock wrappers (macOS)
│   ├── menu/menu.zc                # Native menu wrappers
│   ├── sync/sync.zc                # Cross-context wait/notify
│   └── platform/
│       ├── darwin/*.{h,m}          # NSWindow, WKWebView, etc.
│       └── windows/*.{h,c}         # WebView2 (in progress)
│
├── bootstrap/                      # Injected JS (codegen'd into binary)
│   ├── webview.ts                  # WKWebView / WebView2 bridge
│   ├── worker.ts                   # Unified worker bootstrap (all engines)
│   └── codegen.ts                  # TS → minified → escaped → Zen-C string
│
├── runtime/                        # @zappdev/runtime (TS API)
│   ├── index.ts                    # Re-exports
│   ├── bridge.ts                   # getBridge() via Symbol.for('zapp.bridge')
│   ├── app.ts, window.ts, events.ts, services.ts
│   ├── worker.ts, sync.ts
│   ├── dialog.ts, menu.ts, context-menu.ts
│   ├── notification.ts, dock.ts
│   └── worker-globals.ts
│
├── cli/                            # @zappdev/cli
│   ├── src/
│   │   ├── zapp-cli.ts             # Command dispatch (init/dev/build/package/generate)
│   │   ├── init.ts                 # Scaffold
│   │   ├── config.ts               # ZappConfig + defineConfig (subpath-exported)
│   │   ├── build-config.ts         # Generate .zapp/*.zc
│   │   ├── native.ts               # Resolve + compile with zc
│   │   ├── paths.ts                # Resolve native/, bootstrap/, vendor/
│   │   ├── generate.ts, workers.ts, bundle.ts, package.ts, icon.ts
│   │   └── assets.ts               # Brotli-embed dist/ as C struct array
│   └── patches/                    # Applied to vendored engine sources
│
├── vite/                           # @zappdev/vite
│   └── src/index.ts                # zappWorkers() plugin
│
├── benchmarks/                     # Zapp vs Tauri/Wails/Electron/Electrobun
├── kitchen-sink/                   # Showcase + smoke app (native chrome, workers, etc.)
├── llms.txt                        # Public API reference (single file)
├── docs/                           # Long-form guides
└── SKILLS.md                       # This file
```

## Key invariants

### The `.zc / .h / .m` pattern

- Zen-C owns the types (structs, enums) and declares accessor functions.
- `.h` declares the C API the .m file implements (`darwin_window_create`,
  etc.) and any `extern` Zen-C helpers the .m calls back into.
- `.m` uses the accessor functions — no struct-layout duplication.

```
Zen-C struct WindowOptions { width: int; ... }
   │
   ├── wopts_width(WindowOptions* opts) -> int  // accessor in window.zc
   │
   └── darwin_window_create(WindowOptions* opts)  // in window.m
           // reads via wopts_width(opts), not opts->width
```

This is because Zen-C struct layout is opaque to hand-written C/.m code
(generated C is ordered late in the unit).

### Two-tier native API

Every framework feature exposes two paths:

```
JS:       JS → JSON → C(JSON) → ObjC → JSON → JS
Zen-C:    Zen-C → typed C call → ObjC → typed return → Zen-C
```

The Zen-C path skips JSON serialization entirely. Wrappers in
`native/dialog/dialog.zc`, `native/notification/notification.zc`,
`native/menu/menu.zc`, `native/dock/dock.zc` provide the typed path.

### Unified worker model

All workers (webview-spawned and headless-from-config) use the **same
bootstrap** (`bootstrap/worker.ts`) and get the **same host objects**
(`invokeService`, `syncWait`, `syncNotify`, `dispatchEventToAll`,
`postToWebview`, `createWindow`, `quit`, `showNotification`,
`subscribeWindowEvent`, `notif`, `dock`).

There is **no separate "backend worker" code path** anymore — that was
folded into the worker engine in 0.6.0-alpha.0. When reading old code or
old comments that reference `jsc_backend_create` / `txiki_backend_create`,
that's been removed; everything is just `_worker_create`.

Headless workers differ from webview-spawned ones in three ways only:
1. **Spawn timing** — headless start at `app.run()`; webview-spawned on
   `new Worker(...)`.
2. **Owner ID** — webview-spawned have `owner_id = <windowId>`; headless
   have empty owner. Window-close cleanup respects this.
3. **Worker ID prefix** — headless IDs are prefixed `h-` in the registry
   so termination APIs can distinguish.

### Worker → native is fast-path, webview → native is IPC

`runtime/services.ts`, `runtime/window.ts`, `runtime/notification.ts`,
`runtime/dock.ts` all branch on `globalThis.__zappBridge` presence. If
present → call host object directly (~5 µs). If not → async IPC through
WKWebView (~135 µs). This branch is intentional and has to stay fast —
don't wrap host objects in JS middleware.

### Bridge message types

Single byte `t` field routes in `native/app/router.zc`:

| t | Name | Direction | Responds? |
|---|---|---|---|
| 1 | invoke | JS → Native | yes (type 2 back) |
| 2 | invoke_response | Native → JS | — |
| 3 | emit | JS → Native | no, broadcast |
| 4 | window_action | JS → Native | no (show/hide/setTitle/etc.) |
| 5 | worker | JS → Native | — |
| 6 | sync | JS → Native | async result via dispatchSyncResult |
| 7 | cancel | JS → Native | no (cancel in-flight invoke by ID) |

Special method names prefixed `__` (e.g. `__window:create`, `__notif:show`,
`__dialog:open`) are internal — user services can't start with `__`.

### Event dispatch is tiered

`native/window/callbacks.zc` is the single place window events get
dispatched. For each event, it:
1. **Layer 1** — invokes native Zen-C callback (can return CANCEL).
2. **Layer 2** — broadcasts to every active worker via each engine's
   `broadcast_eval_js` function.
3. **Layer 3** — posts to the owning window's WebView JS.

Per-window listener bitmask in `callbacks.zc` skips Layer 3 when no
webview handler has subscribed.

### User-authored native sources scan

`cli/src/native.ts → getUserProjectSources(root)` recursively walks
`<project>/zapp/**` and collects `.m` files on macOS, `.c` files on
Windows. They're appended to the generated `.zapp/zapp_platform.zc`'s
platform `cflags` alongside the framework's own platform sources, so a
user app can ship service implementations in ObjC/C without modifying
the framework. Scope is bounded to `zapp/**` — files under `src/` are
JS/TS, not compiled.

Without this scan, a bridging `.zc` that `import`s a user's `.h` would
generate C that *declares* the externs but leaves them undefined at link
time. If you ever change the scan's scope, update
[`docs/zen-c-services.md`](docs/zen-c-services.md) and
[`llms.txt`](llms.txt) — both document the `zapp/**` boundary.

### Bootstrap is a C string constant

`bootstrap/codegen.ts` runs at every CLI build. It bundles and minifies
`bootstrap/webview.ts` and `bootstrap/worker.ts`, then escapes them into
C string literals compiled into the binary via
`.zapp/zapp_bootstrap.zc`. Two exported functions:
- `zapp_webview_bootstrap_script()` — injected into WKWebView via
  `WKUserScript` at document-start
- `zapp_worker_bootstrap_script()` — eval'd into each worker context
  during the engine's `setup_bridge` step

There is **no separate backend-bootstrap** anymore.

## Zen-C conventions

- **Enums construct with `()`**: `TitleBarStyle::Hidden()`, not
  `TitleBarStyle::Hidden`
- **Accessor fns for struct fields** used across file boundaries
- **`.m` files** hold ObjC — never raw ObjC inside a `.zc` raw block
- **`darwin_*`** prefix for platform-specific C API; **`zapp_*`** for
  internal C helpers in .m files; plain names for Zen-C trampolines
- **`@cfg(apple)` / `@cfg(windows)`** on top-level imports and functions
- **`#ifdef __APPLE__`** inside .c files for conditional platform host
  objects (used until a cross-platform `zapp_*` extern layer lands)
- **`_Thread_local` static buffer** for service return values (avoids
  malloc in the hot path)

## Things that look weird but aren't

- `app.zc:Zapp` struct with `impl Zapp` containing only functions — it's
  a namespace for `Zapp::inspectable_auto()` etc. Zen-C's struct literal
  limitation prevents using `ZappInspectable::Auto()` as a bare value in
  some contexts, so we provide these wrappers.
- `zjs.c` and bare-* engine files may have `#ifdef __APPLE__` around
  notif/dock dispatcher bodies. Those are placeholders for the day
  `darwin_*` externs get replaced with a cross-platform `zapp_*` layer.
  When that lands, drop the guards.
- `cli/package.json` has `prepack` / `postpack` scripts that copy
  `native/`, `bootstrap/`, `assets/`, `vendor/webview2/` into `cli/`
  before npm pack, then delete them after. This ships the framework
  source inside the CLI tarball.

## Development conventions

- **Bun everywhere**, never Node.
- **Inclusive language**: allowlist/blocklist, not white/black.
- **`kitchen-sink/`** is the showcase + smoke app — test changes here end-to-end.
- **`benchmarks/`** is the performance regression harness.
- Before publishing: `bun run build` in `kitchen-sink/` must pass with the
  `zjs` engine (default). Test bare-* engines by changing the `engine:`
  field in `kitchen-sink/zapp.config.ts` for cross-engine verification.

## Public docs

For anyone building **with** Zapp (not on it), point them at:

| Path | Audience |
|---|---|
| `README.md` | Landing page |
| `llms.txt` | Agent reference — full API surface, single file |
| `docs/api-reference.md` | Long-form API reference |
| `docs/patterns.md` | Common patterns cookbook |
| `docs/zen-c-services.md` | Writing native services |
| `docs/architecture.md` | Under-the-hood walkthrough |

Don't add public-API content to `SKILLS.md`. This file is for people
hacking on the framework itself.

## Resources

| Resource | URL |
|---|---|
| Zen-C docs | https://docs.zenc-lang.org/ |
| Zen-C repo | https://github.com/zenc-lang/zenc |
| Bare runtime | https://github.com/nicolo-ribaudo/bare |
| WebView2 host objects | https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/hostobject |
| Apple WKWebView | https://developer.apple.com/documentation/webkit/wkwebview |
