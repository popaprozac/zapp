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
- `zapp_desktop.h` and `desktop.m` are the remaining native ABI seam.

The migration rule is that policy moves toward these Z modules while
Objective-C shrinks toward generated adapters or small ABI glue. New public
framework behavior belongs in the cross-platform framework layer, not in this
directory.
