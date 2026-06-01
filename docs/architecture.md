# Architecture

Zapp is three layers: **native core** (Zen-C → C → binary), **bridge**
(JS injected into every webview and worker), and **runtime** (the TS API
users import).

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│   NATIVE CORE (Zen-C → C → single static binary)                     │
│                                                                      │
│    ┌──────────────────────────────────────────────────────────────┐  │
│    │  App / Windows / Services / Menus / Dialogs / Notifications │  │
│    │  / Dock / Sync / Worker engines (zjs + bare-*)              │  │
│    └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
└──────┬────────────────────────────────────┬──────────────────────────┘
       │                                    │
       │  WKWebView postMessage IPC         │  Direct host-object C call
       │  (~135 µs round-trip)              │  (~5 µs)
       ▼                                    ▼
  ┌─────────────────────────┐      ┌─────────────────────────────────┐
  │  WEBVIEW JS             │      │  WORKER JS                      │
  │                         │      │                                 │
  │  bootstrap/webview.ts   │      │  bootstrap/worker.ts            │
  │       + @zappdev/runtime│      │       + @zappdev/runtime        │
  │                         │      │                                 │
  │  Your UI code           │      │  Your worker code               │
  │  (Svelte/React/etc)     │      │  (TS, unified API)              │
  └─────────────────────────┘      └─────────────────────────────────┘
          one per window                  one per `new Worker()`
                                          or per headless: {} entry
```

## Layer 1: native core

Everything that's Zen-C, C, or ObjC/Windows-C ships inside the single
binary. The framework's own source lives in `native/`.

```
native/
├── app/
│   ├── app.zc           # App struct, AppConfig, App::new, App::run
│   ├── router.zc        # Dispatches incoming JS messages by type
│   └── app_events.zc    # Broadcasts app:* events to workers + webviews
├── window/              # WindowOptions, WindowManager, per-window events
├── service/             # Service registry, invoke, lifecycle
├── bridge/
│   ├── protocol.zc      # JSON schema for JS ↔ Native messages
│   └── dispatch.zc      # Sends responses back to windows / workers
├── worker/
│   ├── worker.zc        # Engine abstraction (worker_create, terminate, etc.)
│   ├── registry.zc      # Slot table tracking all active workers
│   └── engines/
│       ├── zjs.c/.h     # First-party engine (cross-platform, default)
│       └── bare-*.c/.h  # bare-jsc / bare-v8 / bare-quickjs / bare-mqjs / bare-hermes
├── dialog/              # Typed Zen-C wrappers for file/message dialogs
├── notification/
├── menu/
├── dock/
├── sync/                # Cross-context wait/notify (condvar + FIFO)
└── platform/
    ├── darwin/*.m       # macOS impls (NSWindow, WKWebView, etc.)
    └── windows/*.c      # Windows impls (partial — see WINDOWS_PORTING.md)
```

### Two-tier API inside native

Every framework feature (dialogs, notifications, menus, dock) has two
callable surfaces:

1. **JSON bridge**: invoked from JS via `__notif:show`, `__dialog:open`,
   etc. The router parses JSON and calls into the same handler.
2. **Typed Zen-C**: called directly from user Zen-C code without JSON.
   Defined in `native/<module>/<module>.zc` as a thin wrapper over the
   platform function.

```
    JS:      Services.invoke("...")  → JSON → C(JSON) → ObjC → JSON → JS
  Zen-C:    native::notification_show_typed(...)  → ObjC → return
```

User-defined services use the JSON path (that's how you register
handlers). Framework-internal calls within Zen-C prefer the typed path —
no serialization cost.

### User-authored ObjC / C sources

The CLI scans `<project>/zapp/**/*.{m,c}` on every build and appends them
to the platform `cflags` alongside the framework's own platform sources.
This lets an app ship a service implementation in a `.m` file (macOS) or
`.c` file (Windows) without modifying the framework. See
[`zen-c-services.md`](zen-c-services.md) → "Services in ObjC or C" for
the bridging pattern.

### Zen-C <-> ObjC boundary

Zen-C owns the types (`WindowOptions`, `AppConfig`, etc.). Zen-C emits
them as opaque structs in generated C; the `.m` file can't read struct
fields directly. So every cross-file read goes through an **accessor
function**:

```zc
// native/window/window.zc
struct WindowOptions { width: int; height: int; /* ... */ }
fn wopts_width(opts: WindowOptions*) -> int { return opts.width; }
```

```objc
// native/platform/darwin/window.m
void darwin_window_create(WindowOptions* opts) {
    int w = wopts_width(opts);  // NOT opts->width
    // ...
}
```

This keeps the .m file decoupled from Zen-C struct layout (which can
change between compiler versions).

## Layer 2: bridge (bootstrap)

`bootstrap/webview.ts` and `bootstrap/worker.ts` are **TypeScript source
files that get compiled into the binary as C string constants**.

At build time, `bootstrap/codegen.ts`:
1. Bundles each file with Bun (minified, inlined, single module).
2. Escapes for C string literal syntax.
3. Writes `.zapp/zapp_bootstrap.zc` with two functions:
   - `zapp_webview_bootstrap_script() -> string`
   - `zapp_worker_bootstrap_script() -> string`
4. `zc build` compiles that file into the final binary.

At runtime, the platform code injects the right script at context
creation:
- **Webview**: WKWebView `userContentController` with a document-start
  `WKUserScript` calls `evaluateJavaScript`.
- **Worker**: the engine's `setup_bridge` function calls
  `ctx.evaluateScript(zapp_worker_bootstrap_script())` after setting up
  host objects.

The bootstrap sets up `globalThis[Symbol.for('zapp.bridge')]` as the
canonical bridge. That symbol is what the runtime's `getBridge()` looks
up — see [api-reference.md → Bridge detection](api-reference.md).

### Webview bridge

`bootstrap/webview.ts` implements:
- Async invoke with request ID / cancel / timeout (type 1 / 2 / 7)
- Emit (type 3)
- Window action (type 4) — fire-and-forget
- Worker lifecycle (type 5) — `createWorker`, `postToWorker`, `terminate`
- Sync wait/notify (type 6)
- Event dispatch back from native via `evaluateJavaScript`

One WKWebView per window → one bootstrap context per window. Everything
is async because WKWebView IPC is async.

### Worker bridge

`bootstrap/worker.ts` is **the same bootstrap for every worker type** —
webview-spawned or headless. It:
- Aliases host-object methods onto `bridge`: `bridge.emit =
  bridge.dispatchEventToAll`, `bridge.invoke = bridge.invokeService`, etc.
- Sets up the event listener registry + `_dispatchAppEvent` callback so
  `App.on(AppEvent.OPEN_URL, ...)` works
- Wires the channel API (`self.send` / `self.receive`)
- Glues `dispatchSyncResult` so `Sync.wait(...)` resolves its promise
  when the native sync system broadcasts a result

Host objects (`__zappBridge.invokeService`, `.createWindow`, `.notif`,
`.dock`, etc.) are set up in native before the bootstrap runs. The
bootstrap mutates `__zappBridge` in place to add pure-JS behaviors (event
registry, channels) and **exposes the same object** under
`Symbol.for('zapp.bridge')` — no wrapper, no overhead.

## Layer 3: runtime (`@zappdev/runtime`)

Thin TS API. Every function dispatches to the bridge. In worker context,
runtime functions fast-path to host objects; in webview context they
fall back to async IPC. Example from `runtime/services.ts`:

```ts
export const Services = {
  invoke<T>(method: string, args?: object, opts?: InvokeOptions): CancellablePromise<T> {
    const hostBridge = (globalThis as any).__zappBridge;
    if (hostBridge?.invokeService) {
      // Worker: direct C call, wrapped in resolved Promise
      const result = hostBridge.invokeService(method, args) as T;
      const p = Promise.resolve(result) as CancellablePromise<T>;
      p.cancel = () => {};
      return p;
    }
    // Webview: async IPC
    return getBridge().invoke(method, args, opts) as CancellablePromise<T>;
  },
};
```

Same check pattern in `runtime/window.ts` (for `Window.create`),
`runtime/notification.ts` (via `__zappBridge.notif`), `runtime/dock.ts`
(via `__zappBridge.dock`). Users don't write detection code; the runtime
does it.

## Worker lifecycle

A new `new Worker("./foo.ts")` from a webview goes through these steps:

1. Webview JS: `new Worker(scriptUrl)` in `runtime/worker.ts`.
2. `bridge.createWorker(scriptUrl)` → JSON over WKWebView as type 5
   (worker lifecycle message with action=`create`).
3. Native router in `app/router.zc` receives the message, routes to
   `worker_create(app, scriptUrl, owner_id, worker_id)`.
4. Engine-specific code allocates a fresh JS context (on a serial dispatch
   queue or background thread depending on the engine), sets up host
   objects, runs the bootstrap, then fetches and evaluates the user's
   worker script.

Headless workers follow the same path but:
- Spawn happens at `app.run()` via the CLI-generated
  `.zapp/zapp_headless_workers.zc` calling
  `zapp_start_headless_worker(id, url)`.
- Owner ID is empty (no parent window).
- Worker ID is prefixed `h-<user-key>` so termination APIs can
  distinguish.

Termination:
- Window close → `worker_terminate_owner(window_id)` — terminates every
  webview-spawned worker that window owned. Headless workers (empty owner)
  are unaffected.
- Explicit: `worker_terminate(worker_id)` — looks up by ID in the slot
  table and shuts down the engine context.

## IPC round-trip anatomy

### Webview → native invoke (WKWebView IPC)

```
JS: Services.invoke("ping", {x:1})
  → bridge.invoke("ping", {x:1})                        [runtime]
    → post JSON {"t":1,"id":42,"m":"ping","a":{"x":1}}  [bootstrap/webview.ts]
      → WKWebView userContentController message          [WKWebView IPC]
        → native router.zc dispatches type=1              [native]
          → service.invoke(app, "ping", args_json_value)
            → user handler returns string
          → dispatch_invoke_response(window_id, 42, true, result)
            → evaluateJavaScript back into WebView        [WKWebView IPC]
              → bridge._onInvokeResult(42, result)         [bootstrap/webview.ts]
                → pending[42].resolve(result)
                → Promise resolves                        [runtime]
```

Measured: ~135 µs median round-trip on M4 Max.

### Worker → native invoke (direct host call)

```
JS: Services.invoke("ping", {x:1})
  → __zappBridge.invokeService("ping", {x:1})           [runtime, detect-worker fast path]
    → zapp_bridge_invoke_service host object             [engine host object]
      → service.invoke(app, "ping", args_json_value)      [direct C call]
        → user handler returns string
      → parse JSON, return JSValue to JS
    ← synchronous return
  ← Promise.resolve(result)                              [runtime wraps in Promise]
```

Measured: ~5 µs median round-trip on M4 Max. Same engine, same service
handler, but no IPC, no serialization, no thread hop.

This is why heavy IPC loops belong in workers, not webviews. WKWebView's
async userContentController dispatch is a kernel-level round-trip that
can't be sped up.

## Why "headless" and not "backend"?

`backend: true` in the AppConfig used to spawn a single privileged JS
context for app-level work. That design had two problems:

1. **Naming**: "backend" overloads with "web backend" and "main process"
   mental models.
2. **Singleton**: only one backend worker allowed, with hardcoded
   `/_workers/backend.mjs` URL.

0.6.0-alpha collapsed the backend worker into the regular worker slot
system. Now:
- You can have as many headless workers as you want, declared in
  `zapp.config.ts → headless: { id: path }`.
- Every worker (headless or webview-spawned) uses the same bootstrap and
  gets the same host objects.
- The name "backend" reads as "web server backend" — we renamed to
  "headless" (no owning window) which matches the actual mechanic.

## Further reading

- [`api-reference.md`](api-reference.md) — full runtime API
- [`zen-c-services.md`](zen-c-services.md) — writing native services
- [`patterns.md`](patterns.md) — common patterns
- [`../SKILLS.md`](../SKILLS.md) — contributor primer, file-by-file
