# Design Decisions FAQ

## Why Zapp Workers instead of Web Workers?

Web Workers provided by the webview cannot talk directly to the native backend. They run inside the webview's JavaScript context and are sandboxed from the host application.

Zapp Workers run in dedicated JS contexts -- QuickJS on Windows, JavaScriptCore (JSC) or QuickJS on macOS -- that have direct native bridge access. Each worker is owned by a window, and a SharedWorker primitive is available for sharing a worker across contexts. This enables patterns like background computation combined with native service calls, without round-tripping through the webview.

Standard Web Workers and SharedWorkers from the webview still work. They just cannot call native services directly.

## Why a Sync API instead of SharedArrayBuffer?

SharedArrayBuffer requires strict cross-origin isolation (COOP + COEP headers). With Zapp's custom `zapp://` protocol scheme, the browser requirements for cross-origin isolation cannot be fully satisfied without serving assets over an internal HTTP server -- which introduces greater security risks.

Zapp's Sync primitives (`Sync.wait` / `Sync.notify`) live in native memory, shared across all contexts in your app. They provide an Atomics-like API that is arguably better, more efficient, and faster for desktop app use cases. There is no header negotiation, no protocol workaround, and no HTTP server to secure.

## Why does Windows require QuickJS for Zapp Workers?

macOS provides JavaScriptCore (JSC) as a system framework -- available for interop without a webview, at zero binary size cost. Windows has no equivalent system-provided JS engine.

QuickJS was chosen as a balance between execution speed and binary size, adding approximately 760 KB to the binary. We are actively investigating other options for future releases.

## Why offer QuickJS on macOS too?

For maximum guaranteed compatibility of worker code between platforms. JSC and QuickJS have subtle behavioral differences in areas like date parsing, regex edge cases, and certain ES module semantics.

If your app needs identical worker behavior on macOS and Windows, enable QuickJS on macOS via `ZAPP_WORKER_ENGINE_QJS` in your `build.zc`. Most developers will prefer JSC for its smaller binary footprint.

## Are Zapp Workers required?

No. Workers are entirely optional. Both platforms support standard Web Workers and SharedWorkers provided by the WebView. The Sync API works in webview contexts and is not dependent on Zapp Workers.

On Windows, removing `ZAPP_WORKER_ENGINE_QJS` from `build.zc` drops the binary from approximately 960 KB to approximately 202 KB.

## What about Linux?

Linux support is in our backlog. The architecture supports it -- Zen-C compiles for Linux, and WebKitGTK provides the webview -- but we are prioritizing macOS and Windows feature completeness first.

Adding a third platform before the codebase is fully consolidated would triple every change. We want to get the API surface stable on two platforms before taking on that maintenance burden.

## Why Zen-C instead of Rust/Go/C++?

Zen-C compiles to human-readable C with zero runtime overhead. It provides modern ergonomics -- traits, generics, Result types, pattern matching -- while maintaining 100% C ABI compatibility.

This means direct interop with system frameworks (Cocoa, Win32) without FFI bridges, contributing to the tiny binary size. There is no runtime to embed, no garbage collector, and no bridge layer between your application logic and the OS.
