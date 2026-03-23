# AppConfig (Native)

The `AppConfig` struct configures your Zapp application at the native level.

## Definition

```zc
struct AppConfig {
    name: string;
    applicationShouldTerminateAfterLastWindowClosed: bool;
    webContentInspectable: int;  // -1 = inherit, 0 = off, 1 = on
    maxWorkers: int;
    qjsStackSize: int;          // 0 = default 4MB
}
```

## Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | `"Zapp App"` | Application name. Used in menus, window titles, bundle metadata. |
| `applicationShouldTerminateAfterLastWindowClosed` | `bool` | `false` | Quit the app when all windows are closed. |
| `webContentInspectable` | `int` | `-1` | Dev tools. `-1` = inherit from build mode, `0` = off, `1` = on. |
| `maxWorkers` | `int` | `0` | Maximum concurrent Zapp Workers. `0` = unlimited. |
| `qjsStackSize` | `int` | `0` | QuickJS stack size in bytes. `0` = default (4 MB). |

## Example

```zc
fn run_app() -> int {
    let config = AppConfig{
        name: "My App",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: -1,  // dev=on, prod=off
        maxWorkers: 10,
        qjsStackSize: 0,
    };
    let app = App::new(config);

    // Register services
    app.service.add("greet", greet_handler);

    // Create window
    let opts = window_options_default("My App");
    opts.visible = false;
    let win = app.window.create(&opts);
    win.on_ready(on_ready);

    return app.run();
}
```

## App Lifecycle

```zc
impl App {
    fn new(config: AppConfig) -> Self;    // Create app
    fn config(self) -> AppConfig;          // Read config
    fn run(self) -> int;                   // Start event loop (blocking)
}
```

`App::run()` initializes logging, starts services, binds the runtime, and enters the platform event loop. Returns `0` on success.

## Build Directives

Platform-specific build configuration goes in `zapp/build.zc`:

```zc
// --- Platform Tags ---
//> macos: define: apple
//> windows: define: windows

// --- macOS ---
//> macos: framework: Cocoa
//> macos: framework: WebKit
//> macos: framework: CoreFoundation
//> macos: framework: JavaScriptCore
//> macos: framework: Security
//> macos: link: -lcompression
//> macos: cflags: -fobjc-arc -x objective-c

// --- Windows ---
//> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS
//> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 -lcomdlg32 -lshlwapi
//> windows: link: -lwinhttp -lbcrypt -ladvapi32 -lrpcrt4 -lcrypt32 -lversion

// Optional: QuickJS workers
//> windows: define: ZAPP_WORKER_ENGINE_QJS
// Uncomment for QJS on macOS:
// //> macos: define: ZAPP_WORKER_ENGINE_QJS

import "app.zc";

fn main() -> int {
    return run_app();
}
```
