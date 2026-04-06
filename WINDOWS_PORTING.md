# Windows Porting Guide

Summary of the macOS implementation to port to Windows. Written for a fresh Claude Code session on a Windows machine.

## Repo Structure

```
zapp/
├── native/                 # Zen-C framework
│   ├── app/                # App lifecycle, router, events
│   ├── window/             # Window, events, callbacks
│   ├── service/            # Service registry + lifecycle
│   ├── bridge/             # Protocol, dispatch
│   ├── worker/             # Worker engines (JSC macOS, txiki cross-platform)
│   ├── dialog/             # Native dialog wrappers
│   ├── notification/       # Native notification wrappers
│   ├── menu/               # Native menu wrappers
│   ├── sync/               # Sync wait/notify wrappers
│   ├── platform/
│   │   ├── platform.zc     # @cfg dispatch to platform impls
│   │   ├── darwin/         # macOS: .h/.m files (COMPLETE)
│   │   └── windows/        # Windows: stub files (TO PORT)
│   └── shared/
├── runtime/                # @zappdev/runtime TypeScript package
├── cli/                    # Build tooling (Bun)
├── bootstrap/              # WebView/Worker/Backend bootstraps (TS → codegen)
├── hello-world/            # Reference example app
├── vendor/
│   ├── txiki.js/           # Cross-platform JS engine (submodule)
│   └── webview2/           # Windows WebView2 headers + static lib
└── old/                    # v1 code (reference only)
```

## What's Complete (macOS)

All features working on macOS:
- Windows (create, show, hide, close, resize, fullscreen, titlebar styles, close guard, load_url)
- WebView (zapp:// scheme handler, brotli decompression, navigation allowlist, drag regions)
- Bridge (JSON protocol, 7 message types, cancellation, timeout)
- Services (register + lifecycle startup/shutdown, invoke from JS/workers)
- Events (11 window events + 8 app events, unified dispatcher, per-window bitmask)
- Workers (JSC macOS-only + txiki.js cross-platform, SharedWorkers, channels)
- Backend worker (privileged JS context, app lifecycle events, JSC or txiki)
- Dialogs (open file, save file, message — JSON bridge + typed Zen-C)
- Menus (app menu, context menu — JSON bridge + typed Zen-C, roles, accelerators)
- Notifications (show, schedule, categories with action buttons, reply field, click/action response)
- Sync (wait/notify — FIFO queues, blocking wait for background threads)
- Deep links (custom URL protocols, CFBundleURLTypes)
- Packaging (zapp package with brotli-embedded assets, liquid glass icons, code signing)
- Bootstrap codegen (webview.ts + worker.ts + backend.ts → minified → .zc)
- App events (STARTED, SHUTDOWN, REOPEN, NOTIFICATION_CLICK, OPEN_URL, ACTIVE/INACTIVE)

Binary: 405 KB (JSC) | 6.5 MB (txiki) | App bundle: ~750 KB

## Windows Stubs (Files to Implement)

These exist as stubs with TODO comments:

```
native/platform/windows/
├── window.zc      # TODO: Port from v1 src/platform/windows/window.zc
├── webview.zc     # TODO: Port from v1 src/platform/windows/webview.zc
├── platform.zc    # TODO: Port from v1 src/platform/windows/platform.zc
├── dialog.zc      # TODO: Port dialog code from v1
└── (need: menu.c, notification.c, sync.c)
```

## V1 Windows Reference (in old/)

The v1 Windows implementation is in `old/src/platform/windows/`:
- `window.zc` — Win32 window creation, WndProc, WebView2 embedding
- `webview.zc` — WebView2 setup, scheme handler, message handler, navigation
- `platform.zc` — Win32 message loop, COM init
- `worker/qjs.zc` — QuickJS worker (v2 uses txiki.js instead)

V1 vendor WebView2 headers: `vendor/webview2/include/WebView2.h`
V1 vendor WebView2 static lib: `vendor/webview2/lib/x64/WebView2LoaderStatic.lib`

## Key Architecture Patterns

### The .zc → .h → .c/.m Pattern
- Zen-C (.zc) defines structs, enums, accessor functions
- C headers (.h) declare opaque types + C API
- Platform impl (.m for macOS, .c for Windows) implements using accessor functions
- No struct layout duplication — .m/.c accesses fields via accessor functions

### @cfg Platform Dispatch
```zc
@cfg(apple)
fn platform_init(name: string) -> void { darwin::darwin_platform_init(name); }

@cfg(windows)
fn platform_init(name: string) -> void { windows::windows_platform_init(name); }
```

### Two-Tier API
- JSON bridge path: JS → JSON → C(JSON) → result JSON → JS
- Native typed path: Zen-C → C(typed) → typed return (zero serialization)

### Bridge Protocol
JSON with numeric type routing: `{"t":1,"id":42,"m":"greet","a":{...}}`
Types: 1=invoke, 2=response, 3=emit, 4=window_action, 5=worker, 6=sync, 7=cancel

### Event Dispatcher
- Layer 1: Native Zen-C callback (can cancel)
- Layer 2: JS bridge dispatch (targeted to WebView)
- Per-window bitmask skips dispatch for unlistened events

## Windows-Specific Notes

### WebView2
- Use `WebView2LoaderStatic.lib` for self-contained loader (no DLL needed at runtime)
- `ICoreWebView2` for WebView, `ICoreWebView2Controller` for embedding
- Custom scheme via `ICoreWebView2_22.AddWebResourceRequestedFilterWithRequestSourceKinds`
- JS bridge via `ICoreWebView2.PostWebMessageAsString` / `add_WebMessageReceived`

### Workers on Windows
- No JSC (macOS-only framework)
- txiki.js is the cross-platform worker engine
- Or QuickJS standalone (lighter, no web APIs)

### Build System
- Zen-C compiler (zc) works on Windows
- Build directives in build.zc: `//> windows: define: windows`, `//> windows: link: -lole32 ...`
- CLI already has Windows paths in build-config.ts and native.ts (stubs)

## Design Principles

1. **Native-first**: Zen-C is privileged. JS/WebView is presentation extended after.
2. **Services are native**: Written in Zen-C, invoked from JS. Not the reverse.
3. **App events fire natively**: STARTED, SHUTDOWN, REOPEN — before/without WebView.
4. **Backend worker is optional**: For JS devs who don't write Zen-C.
5. **Two-tier API**: JSON for bridge, typed for native. Both call shared internals.

## Zen-C Docs

https://docs.zenc-lang.org/
