# Zapp

**Tiny binaries. System WebView. Native speed.**

Zapp is a desktop application framework that produces extraordinarily small binaries by leveraging the system WebView (WKWebView on macOS, WebView2 on Windows) and compiling to native code via [Zen-C](https://github.com/zenc-lang/zenc).

## Why Zapp?

| | Zapp | Tauri v2 | Wails v3 | Electron |
|---|---|---|---|---|
| **Binary size** | **173 KB** | 8.2 MB | 7.5 MB | 263 MB |
| **Memory** | **25 MB** | 27 MB | 31 MB | 528 MB |
| **Bridge latency** | **0.085 ms** | ~0.1 ms | ~0.2 ms | ~0.3 ms |
| **Language** | Zen-C | Rust | Go | Node.js |
| **WebView** | System | System | System | Bundled Chromium |

Your app's native layer compiles to a ~170 KB binary. The frontend is your choice — React, Svelte, Vue, vanilla — served from embedded Brotli-compressed assets via a custom `zapp://` protocol.

## Features

- **Window Management** — Create, position, resize, fullscreen, always-on-top. 11 typed window events with size/position payloads.
- **Application Menus** — Default OS menus out of the box. Custom menu API with roles, accelerators, and inline action handlers.
- **Dialogs** — Native file open/save dialogs and message boxes on both platforms.
- **Draggable Regions** — CSS-driven custom titlebar dragging via `data-zapp-drag-region`.
- **Close Prevention** — Cancellable close events from both native callbacks and JS handlers.
- **Services (RPC)** — Define native services in Zen-C, call them from JS with auto-generated TypeScript bindings.
- **Workers** — Optional native JS workers (QuickJS/JSC) with direct backend access. Also supports standard Web Workers.
- **Sync Primitives** — Atomics-like `wait`/`notify` across workers, webviews, and backend — without SharedArrayBuffer.
- **Events** — Typed event system with autocomplete. Emit and listen across webviews, workers, and backend.
- **Security** — Content Security Policy, path traversal prevention, dev tools disabled in production builds.
- **Packaging** — `.app` bundles with icon generation (including macOS Tahoe liquid glass support).

## Platforms

| Platform | Status |
|---|---|
| macOS (ARM64, x86_64) | Supported |
| Windows (x86_64) | Supported |
| Linux | Planned |

## Quick Start

```bash
# Install prerequisites
# - Zen-C compiler: https://github.com/zenc-lang/zenc
# - Bun: https://bun.sh

# Create a new project
zapp init my-app
cd my-app

# Development
zapp dev

# Production build
zapp build --brotli

# Package as .app bundle (macOS)
zapp package --brotli
```

See [Getting Started](getting-started.md) for the full guide.

## Architecture

Zapp apps have three layers:

1. **Native layer** (Zen-C) — App lifecycle, window management, services, workers. Compiles to ~170 KB.
2. **WebView** — System WKWebView (macOS) or WebView2 (Windows). Renders your frontend.
3. **Bridge** — `postMessage`-based communication between JS and native. 0.085ms round-trip latency.

See [Architecture](architecture.md) for details.
