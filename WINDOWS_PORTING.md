# Windows Porting Guide

Current state of the Windows port and what's needed to finish it.

macOS is the reference platform and has full coverage. Windows has partial
scaffolding in place — basic WebView2 + window + dialogs + menus + Toast
notifications + clipboard (text) + global hotkeys (`RegisterHotKey`) work
today. Tray, file-drop, custom protocols, MSIX packaging, and code-signing
are the remaining gaps for a "production beta" Windows release (see
[`project_doc_audit_2026-06`](https://github.com/zappdev/zapp) task #167).

For general framework orientation, read [`SKILLS.md`](SKILLS.md) first. This
file is Windows-specific.

## Repo Structure (Windows-relevant)

```
zapp/
├── native/platform/
│   ├── platform.zc             # @cfg(apple) / @cfg(windows) dispatch
│   ├── darwin/*.{h,m}          # macOS: complete
│   └── windows/                # Windows: partial stubs
├── native/worker/engines/
│   ├── zjs.{h,c}               # Default. Cross-platform first-party engine.
│   ├── bare-*.{h,c}            # bare-jsc / bare-v8 / bare-quickjs / bare-mqjs / bare-hermes
│   ├── jsc.{h,m}               # Deprecated compat (macOS-only — JSC is Apple)
│   └── txiki.{h,c}             # Deprecated compat (cross-platform; #ifdef __APPLE__ guards on host objects)
├── vendor/webview2/            # Windows WebView2 headers + static loader
└── old/src/platform/windows/   # v1 Windows impl — reference, not code-path
```

## What's Complete (macOS)

Windows stubs exist for everything in this list; fill them in:

- Windows (create, show, hide, close, resize, fullscreen, titlebar styles,
  close guard, loadUrl)
- WebView (zapp:// scheme, brotli-decompressed asset serving, navigation
  allowlist, drag regions)
- Bridge (JSON protocol, 7 message types, cancellation, timeout) — **platform-
  agnostic, shared with Windows**
- Services (register + lifecycle startup/shutdown, invoke from JS and
  workers) — **platform-agnostic**
- Events (11 window events + 8 app events, unified dispatcher, per-window
  bitmask) — **platform-agnostic; window events need Windows window procs to
  call into `zapp_window_event`**
- Workers — **txiki.js already compiles cross-platform**; JSC is macOS-only
  and stays that way
- Unified worker model (no separate "backend worker" — all workers share
  the same API via `bootstrap/worker.ts`)
- Dialogs (open file, save file, message) — Windows: IFileDialog,
  TaskDialogIndirect
- Menus (app menu, context menu) — Windows: HMENU, TrackPopupMenu
- Notifications — Windows: Toast XML via `ToastNotificationManager`
- Dock → Taskbar — Windows: `ITaskbarList3` for badges, thumbnail buttons
- Sync (wait/notify) — **platform-agnostic**; needs a Windows-safe
  condition variable primitive (std::condition_variable via a small C
  wrapper, or CONDITION_VARIABLE)
- Deep links — Windows: URL scheme registration in the registry + command
  line parsing on `WM_COPYDATA`
- Packaging — Windows: MSIX or plain `.exe` + resource icons

## Current txiki.js state on non-Apple

`native/worker/engines/txiki.c` compiles on Windows today but several
privileged host objects are guarded with `#ifdef __APPLE__`:
- `zapp_bridge_notif` — body stubbed on non-Apple (returns undefined)
- `zapp_bridge_dock` — body stubbed on non-Apple
- `zapp_bridge_create_window` — runs the window create inline instead of
  `dispatch_sync(main)` (TODO: Windows main-thread-hop equivalent needed)
- `zapp_bridge_quit` — calls `exit(0)` directly instead of going through
  GCD

**The path forward**: when each Windows backend lands (notifications,
taskbar, etc.), introduce a cross-platform `zapp_*` extern layer that
both the darwin and windows impls fulfill:

```
Before (darwin-only):
  extern void darwin_notification_show_typed(...)   // in darwin/notification.m
  used directly in txiki.c, jsc.m, and zapp routing

After (platform-agnostic):
  extern void zapp_notification_show(...)            // declared in native/notification/notification.zc
    → on darwin, lowered to darwin_notification_show_typed
    → on windows, lowered to ToastNotificationManager call
  txiki.c and jsc.m call zapp_notification_show unconditionally — no #ifdef
```

When that layer lands, drop the `#ifdef __APPLE__` guards from `txiki.c`.

## Windows-Specific Notes

### WebView2

- Use `WebView2LoaderStatic.lib` (in `vendor/webview2/lib/x64/`) for a
  self-contained loader — no DLL needed at runtime.
- `ICoreWebView2` for the WebView, `ICoreWebView2Controller` for embedding.
- Custom `zapp://` scheme via
  `ICoreWebView2_22::AddWebResourceRequestedFilterWithRequestSourceKinds`.
- JS ↔ native bridge via `ICoreWebView2::PostWebMessageAsString` /
  `add_WebMessageReceived`.

### Main-thread-hop equivalent

On macOS we use `dispatch_sync(dispatch_get_main_queue(), ^{ ... })` to
call window / dialog / menu APIs from worker threads. On Windows the
equivalents:

- **Async fire-and-forget**: `PostMessage(g_main_hwnd, WM_ZAPP_TASK, ...)`
  with a WndProc handler that executes the task and posts back.
- **Sync with return value**: `PostMessage` + `WaitForSingleObject` on an
  event set by the handler, with the return value stashed in a shared
  struct. Be careful not to deadlock when called from the main thread
  itself — mirror the `NSThread.isMainThread` check we use in `jsc.m`.

### Workers on Windows

- JSC is **not available** — it's Apple's engine. The `jsc` / `bare-jsc`
  engines fall back through the resolver chain on Windows builds.
- Default is **`zjs`** — Zapp's first-party engine, cross-platform,
  ~1 MB, no JIT entitlement gymnastics. Same source compiles on
  Windows; bytecode AOT works the same way.
- For JIT-heavy workloads, **`bare-v8`** adds ~30 MB and gives you a
  full V8 with optimizer + GC tuning. Opt in per worker via
  `engine: "bare-v8"` in `zapp.config.ts`.
- `bare-quickjs` / `bare-mqjs` / `bare-hermes` also build on Windows
  for size-constrained or niche scenarios.
- See [`docs/engines.md`](docs/engines.md) for the full per-platform
  recommendation table.

### Build System

- Zen-C compiler (`zc`) works on Windows.
- Build directives in `zapp/build.zc`:
  ```
  //> windows: define: windows
  //> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS
  //> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 -lcomdlg32 -lshlwapi
  //> windows: link: -lwinhttp -lbcrypt -ladvapi32 -lrpcrt4 -lcrypt32 -lversion
  ```
- `cli/src/build-config.ts` already generates the Windows cflags/link
  entries from `.zapp/zapp_platform.zc` — no changes needed there.
- WebView2 headers are included via `-I${webview2Dir}/include`.

## V1 Windows Reference (in `old/`)

The v1 Windows implementation is in `old/src/platform/windows/`. Useful
as a reference for Win32 patterns (WndProc, COM init, WebView2 embedding),
but don't port it line-by-line — the architecture shifted between v1 and
v2. Read it for shape, then write fresh against the current `darwin/`
patterns.

## Design Principles (Windows-relevant)

1. **Native-first**: Zen-C owns the app. WebView is a view into state,
   not a shell around JS.
2. **Services run natively**: Written in Zen-C, invoked from JS — same
   across platforms.
3. **App events fire natively**: STARTED, SHUTDOWN, OPEN_URL. On macOS
   from `NSApplicationDelegate`; on Windows from WndProc /
   `WM_COPYDATA` for single-instance URL handoff.
4. **Unified worker model**: All workers have the same API (`Window.create`,
   `Events`, `Services`, `Notification`, `Dock/Taskbar`, `Sync`). Spawn-
   location differs (`zapp.config.ts → headless` vs `new Worker()`) but
   capability does not.
5. **Two-tier native API**: JSON bridge for JS callers, typed Zen-C wrappers
   for native callers. The typed path skips serialization entirely.

## Zen-C Docs

https://docs.zenc-lang.org/
