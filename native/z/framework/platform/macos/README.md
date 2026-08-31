# macOS platform implementation

This directory is Zapp's internal macOS backend. It is not part of the public
`zapp` package surface.

- `application.zs` owns application startup, lifecycle ordering, the native
  run loop, and deterministic shutdown.
- `runtime.zs` owns shared application state, WebKit message routing, and the
  authoritative open and retired native-window registries.
- `window-backend.zs` adapts the cross-platform `WindowBackend` contract to
  macOS operations.
- `window-delegate.zs` owns the retained `NSWindowDelegate` adapter, window
  lifecycle/focus/resize policy, and the Z-owned registry close callback.
- `window-runtime.zs` defines the retained AppKit/WebKit object graph for one
  window; `runtime.zs` owns the authoritative open and retired registries.
- `scheme-handler.zs` owns the retained WebKit protocol adapter, packaged-origin
  and path policy, asset routing, MIME/encoding selection, and response delivery.
- `webview-injections.zs` owns bootstrap/window identity scripts, configured
  injection-profile validation and ordering, JSON-safe CSS wrapping, phase
  mapping, and `WKUserScript` registration.
- `navigation.zs` owns logical URL resolution, frontend-origin comparison, the
  retained `WKNavigationDelegate` adapter, completion-block decisions, and
  navigation-failure policy.
- `response-delivery.zs` owns JavaScript-safe response envelopes and delivery
  policy. `desktop.m` retains a narrow adapter over WebKit's untyped
  Objective-C completion result.
- `desktop-smoke.m` is isolated native test support for DOM verification and
  bounded smoke shutdown. It is compiled only for smoke/sanitizer builds and
  is not application policy or part of production binaries.
- `zapp_desktop.h` and `desktop.m` are the remaining native ABI seam for the
  run loop, generated asset/injection-table reads, Brotli decoding, native
  errors, run-loop wakeup, and WebKit completion adaptation that have not yet
  gained a checked direct Z representation. They do not own application or
  window registry state.

The migration rule is that policy moves toward these Z modules while
Objective-C shrinks toward generated adapters or small ABI glue. New public
framework behavior belongs in the cross-platform framework layer, not in this
directory.
