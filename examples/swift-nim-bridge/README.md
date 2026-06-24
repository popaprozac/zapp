# Swift ↔ Nim bridge (example)

Demonstrates compiling a SwiftUI view to a static lib and calling it from a
Zapp app via an `@_cdecl` entry point. This is a **recipe**, not a CI-built
target.

## Why this is an example, not a framework feature
Zapp's macOS chrome (sidebar/inspector/toolbar) is AppKit
(`NSSplitViewController`/`NSToolbar`). Layout-owning SwiftUI containers
(`NavigationSplitView`, `.inspector`) re-derive their geometry when hosted in
an imperative `NSWindow` and fight runtime control — see
`docs/superpowers/specs/2026-06-23-remove-swiftui-pane-path-design.md`. This
bridge is for **self-contained** SwiftUI views (a chart, a map, a custom
control) that own their own subtree, not framework chrome.

## Files
- `native_surface.swift` — a SwiftUI view exposed to C via `@_cdecl`
  (`zapp_swift_native_surface_create`), returning an `NSView` (`NSHostingView`).
- `nativesurface.m` — the ObjC host that calls the `@_cdecl` entry and returns
  an `NSView` you can add to a window. (Moved verbatim from the framework; the
  `darwin_native_surface_*` / `zapp_native_surface_emit` hooks were framework
  internals — adapt them to your own app's wiring.)

## Recipe
1. Compile the Swift to a static lib:
   `swiftc -emit-library -static -O -module-name zappbridge -o libzappbridge.a native_surface.swift`
2. In your app's `zapp.config.ts`, link it + compile the ObjC host:
   ```ts
   native: {
     sources:   { macos: ["examples/swift-nim-bridge/nativesurface.m"] },
     linkFlags: { macos: ["-L<dir-with-libzappbridge.a>", "-lzappbridge",
                          "-lswiftCore", "-lswiftFoundation",
                          "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift",
                          "-framework", "SwiftUI"] },
   }
   ```
3. Call the `@_cdecl` entry (`zapp_swift_native_surface_create`) from your
   native/Nim code and add the returned `NSView` to a window.
