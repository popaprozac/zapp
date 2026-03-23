# Architecture

## Overview

A Zapp app has three layers:

```
┌─────────────────────────────────────────────┐
│                  Frontend                    │
│         (HTML/CSS/JS — any framework)        │
│        Runs in system WebView (WKWebView     │
│        on macOS, WebView2 on Windows)        │
├─────────────────────────────────────────────┤
│               Bridge Layer                   │
│     postMessage ↔ native message handler     │
│        0.085 ms round-trip (macOS)           │
│        0.307 ms round-trip (Windows)         │
├─────────────────────────────────────────────┤
│              Native Layer                    │
│    Zen-C → C → platform APIs (Cocoa/Win32)   │
│    Services, Workers, Window Management      │
│          ~170 KB compiled binary             │
└─────────────────────────────────────────────┘
```

## Bridge Protocol

Communication between JS and native uses a simple wire format over `postMessage`:

```
type\nkey\npayload
```

Where:
- `type` — message category: `invoke`, `invoke_rpc`, `emit`, `worker`, `sync`, `window`, `app`, `dialog`
- `key` — action or method name
- `payload` — JSON string

The native side parses this in `app_handle_frontend_message()` and routes to the appropriate handler.

## WebView Bootstrap

Each webview gets bootstrap scripts injected before the page loads:

1. **App config** — name, bundle settings, CSP policy
2. **Service bindings manifest** — available RPC methods
3. **Owner/Window IDs** — for worker ownership and event routing
4. **Bootstrap runtime** — bridge setup, event system, worker management, sync primitives

The bootstrap establishes `Symbol.for('zapp.bridge')` on `globalThis` which the runtime package (`@zapp/runtime`) uses.

## Custom Scheme

Assets are served via `zapp://` (macOS) or `https://app.localhost/` (Windows):

- Embedded assets are Brotli-decompressed on demand
- MIME types are detected from file extension
- SPA fallback: unknown routes serve `index.html`
- COOP/COEP/CORP headers on all responses
- Path traversal (`..`) blocked with 403

## Event System

Events flow between contexts via the bridge:

```
Webview A  ←→  Native  ←→  Webview B
                 ↕
            Backend (JS)
                 ↕
              Workers
```

- `Events.emit("name", data)` from any context reaches all others
- Window events (RESIZE, FOCUS, etc.) fire from native → JS
- Service invocations flow JS → native → JS (round-trip)
- Sync primitives (wait/notify) are managed in native memory

## File Structure

```
src/
  app/
    app.zc              — App struct, lifecycle, message routing
  event/
    event.zc            — EventManager
    events.zc           — Event ID definitions
  service/
    service.zc          — Service registry, Result<T>
  platform/
    platform.zc         — Platform trait, dispatch
    window.zc           — Window API, event callbacks (shared)
    worker.zc            — WorkerBackend trait
    shared/
      log.zc            — Logging
      worker_registry.zc — Worker ID tracking
      worker/qjs/       — Shared QJS bindings
    darwin/
      platform.zc       — CocoaPlatform, menus, event loop
      window.zc         — NSWindow management, events, dialogs
      webview.zc        — WKWebView, scheme handler, sync
      backend.zc        — JSC/QJS backend context
      worker/           — JSC and QJS worker implementations
    windows/
      platform.zc       — WindowsPlatform, WndProc, menus
      window.zc         — HWND management, events, dialogs
      webview.zc        — WebView2, resource handler, sync
      backend.zc        — QJS backend context
      worker/           — QJS worker implementation
```

## Build Pipeline

```
zapp build --brotli
  1. Frontend build (Vite)
  2. Asset manifest + Brotli compression
  3. Build config generation (mode, URLs, CSP)
  4. Asset embedding into Zen-C source
  5. Native compilation (zc → C → platform binary)
  6. Optional: QuickJS library linking
```

Output: single binary with embedded assets (~170 KB without QJS, ~960 KB with QJS on Windows).
