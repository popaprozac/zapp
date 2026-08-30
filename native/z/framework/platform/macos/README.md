# macOS platform implementation

This directory is Zapp's internal macOS backend. It is not part of the public
`zapp` package surface.

- `application.zs` owns application startup, lifecycle ordering, the native
  run loop, and deterministic shutdown.
- `runtime.zs` owns the shared application/window state, WebKit message
  routing, and the native AppKit/WebKit object graph.
- `window-backend.zs` adapts the cross-platform `WindowBackend` contract to
  macOS operations.
- `window-events.zs` contains the C ABI callbacks that bring native window
  events back into Z and schedule them on `thread.main`.
- `scheme-handler.zs` owns the retained WebKit protocol adapter, packaged-origin
  and path policy, asset routing, MIME/encoding selection, and response delivery.
- `webview-injections.zs` owns bootstrap/window identity scripts, configured
  injection-profile validation and ordering, JSON-safe CSS wrapping, phase
  mapping, and `WKUserScript` registration.
- `navigation.zs` owns logical URL resolution, frontend-origin comparison, the
  retained `WKNavigationDelegate` adapter, completion-block decisions, and
  navigation-failure policy.
- `zapp_desktop.h` and `desktop.m` are the remaining native ABI seam for the
  run loop, generated asset/injection-table reads, Brotli decoding, native
  errors, and callbacks that have not yet gained a checked direct Z
  representation.

The migration rule is that policy moves toward these Z modules while
Objective-C shrinks toward generated adapters or small ABI glue. New public
framework behavior belongs in the cross-platform framework layer, not in this
directory.
