# SwiftUI → Nim interop spike — Design

**Date:** 2026-06-20
**Branch:** `feat/nim-native`
**Status:** Design (awaiting user review)

## Summary

A **risk-reduction spike** (not a feature) to get a **go/no-go verdict** on calling
SwiftUI from Zapp's Nim native layer. Prove (or disprove) that a Swift `@_cdecl`
C-ABI entry point — including one that builds a real SwiftUI view — can be
`swiftc`-compiled into a static lib, linked into the existing `nim c --cc:clang`
build, and called from Nim via `{.importc, cdecl.}`. macOS only; standalone
throwaway harness; nothing wired into the real Zapp build.

The point is to settle the unknowns **before** committing to re-implementing
modern Apple UI (e.g. SwiftUI `.inspector` adaptivity) in Swift, where the
current UIKit/AppKit implementations become graceful fallbacks. See memory
`project_swiftui_cxx_interop_spike`.

## Why this shape (decided in brainstorming)

- **No link-free path exists.** A generated header (C from `@_cdecl`, or C++ from
  cxx-interop) carries only *declarations*; the Swift function bodies + runtime
  must always be linked. For Nim, `{.importc, cdecl.}` already supplies the
  declaration on our side, so plain C ABI (`@_cdecl`) is the simplest bridge — no
  generated header needed, same FFI shape as our existing `.m` interop. (The C++
  cxx-interop / `{.importcpp.}` path is richer but untrodden + fragile for Nim,
  and links identically — out of scope.)
- **Binary-size worry is small.** SwiftUI is a system framework (`-framework
  SwiftUI`, OS-shipped, zero bundled bytes, like Cocoa). The Swift runtime is
  ABI-stable + OS-provided (since Swift 5 / macOS 10.14.4+) — linked against, not
  bundled. So new bytes ≈ only our own compiled Swift glue. The spike measures
  this empirically rather than asserting it.
- **The real risk is the link** — does the Swift/SwiftUI runtime link into a
  nim/clang-driven binary, and what's the exact incantation. That's what the
  spike de-risks; the header approach does not dodge it.
- **Staged** (bridge → view) so the runtime-linking rough edges surface on the
  cheapest possible probe before any SwiftUI effort.
- **Standalone harness** (`spikes/swiftui-nim/`, matching the language-eval spike
  precedent) — isolated, throwaway, proves the mechanics without mutating the real
  build pipeline. Real-build `--passL` coexistence is a feature-cycle step if go.

## Toolchain (verified)

- Swift 6.3 (`swiftc`), Nim 2.2.10, `nim c --cc:clang` backend. No existing Swift
  in the repo. The Nim build already links native libs via `--passL` (the libzjs
  pattern) — Swift slots in the same way.

## Architecture

```
spikes/swiftui-nim/
  probe.swift   # @_cdecl C-ABI entry points (bridge fns + SwiftUI window)
  probe.nim     # {.importc, cdecl.} + a tiny main that calls them
  build.sh      # swiftc → libzappswift.a ; nim c --cc:clang --passL <swift link flags>
  FINDINGS.md   # the deliverable: verdict + sizes + the working incantation
```

Bridge direction: **Nim → (importc cdecl) → Swift `@_cdecl` → Swift stdlib /
SwiftUI**. The harness's Swift side owns the `NSApplication`/window/run-loop
(simplest for a probe); hosting a SwiftUI view into Zapp's *existing* AppKit
window is deliberately feature-cycle work, not spike work.

## Sub-gate 1 — the bridge (run first; the rough-edge zone)

`probe.swift`:
```swift
import Foundation

@_cdecl("zapp_swift_probe")
public func zapp_swift_probe() -> UnsafePointer<CChar> {
  // strdup so the pointer outlives the call (Nim reads it, then we leak it —
  // fine for a probe). Proves a Swift-built string crosses the C ABI.
  return UnsafePointer(strdup("hello from Swift 6.3"))
}

@_cdecl("zapp_swift_add")
public func zapp_swift_add(_ a: Int32, _ b: Int32) -> Int32 { a + b }  // arg passing
```

`probe.nim`:
```nim
proc zappSwiftProbe(): cstring {.importc: "zapp_swift_probe", cdecl.}
proc zappSwiftAdd(a, b: int32): int32 {.importc: "zapp_swift_add", cdecl.}

echo "swift says: ", $zappSwiftProbe()
echo "2 + 3 = ", zappSwiftAdd(2, 3)
```

`build.sh` (sub-gate 1): `swiftc` the Swift into a static lib, then `nim c
--cc:clang --passL:"<lib + Swift runtime link flags>"`. The exact runtime link
flags are the unknown the spike resolves (candidate paths: linking the final
binary via swiftc as the driver; or `-L $(xcrun --show-sdk-path)/usr/lib/swift -L
/usr/lib/swift` + `-Xlinker -rpath` + the autolinked runtime libs Swift static
libs embed). Whatever works gets recorded verbatim in FINDINGS.md.

**PASS:** `./probe` prints `swift says: hello from Swift 6.3` and `2 + 3 = 5`.
Record: the working link incantation + binary size (nim-only baseline vs
nim+swift-bridge).

**If gate 1 fails:** stop. Record the failure mode + what was tried in FINDINGS.md
→ that *is* a useful no-go verdict (the bridge has unacceptable rough edges).

## Sub-gate 2 — SwiftUI renders (only if gate 1 passes)

Extend `probe.swift`:
```swift
import SwiftUI
import AppKit

struct ProbeView: View {
  var body: some View {
    VStack(spacing: 12) {
      Text("Hello from SwiftUI").font(.largeTitle)
      Text("driven from Nim via @_cdecl").foregroundStyle(.secondary)
    }.padding(40).frame(width: 360, height: 200)
  }
}

@_cdecl("zapp_swift_show_window")
public func zapp_swift_show_window() {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 200),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
  win.contentView = NSHostingView(rootView: ProbeView())
  win.center(); win.makeKeyAndOrderFront(nil)
  app.activate(ignoringOtherApps: true)
  app.run()
}
```
`probe.nim` calls `zappSwiftShowWindow()`. `build.sh` adds `-framework SwiftUI
-framework AppKit`.

**PASS (human visual):** a window appears rendering the SwiftUI `Text`. Record:
binary-size delta of adding SwiftUI (expected small — system framework).

## Deliverable — `spikes/swiftui-nim/FINDINGS.md`

The verdict artifact (scorecard form, like the language-eval spike):
- Does the bridge link + run? Does SwiftUI render?
- Three binary sizes: nim-only / +swift-bridge / +swiftui.
- The exact `swiftc` + `nim c` incantation that worked (copy-pasteable).
- Build-complexity assessment (extra toolchain steps, gotchas).
- **Go/no-go recommendation** + if go, what the feature cycle must then solve:
  real-build `--passL` coexistence (Cocoa/Carbon/libzjs/frameworks), iOS
  cross-compile (`swiftc` for `arm64-apple-ios*` + sim), and the compile-time
  OS-version-gating + clear-messaging + graceful-fallback DX.

## Testing

The two gates ARE the test: build + run (gate 1) + build + visual (gate 2). No
unit tests — it's a throwaway mechanics probe. All commands + their outputs are
captured in FINDINGS.md so the result is reproducible/auditable.

## Scope / non-goals

- **macOS only.** iOS cross-compile is a documented follow-up (we have the
  zjs/bare-hermes iOS cross-compile lessons to draw on later).
- **Standalone + throwaway.** No wiring into `buildNativeNim` / the real Zapp
  build — that's the first feature-cycle step if the verdict is go.
- **Swift owns the window** in the harness; hosting SwiftUI into Zapp's existing
  AppKit window is feature-cycle work.
- **No feature implementation** (no `.inspector`, no real chrome) — this only
  answers "is the bridge viable + what does it cost."
- Lives in `spikes/`, wired to nothing, fully deletable. Branch `feat/nim-native`,
  not merged.

## Files touched

- `spikes/swiftui-nim/probe.swift` — created.
- `spikes/swiftui-nim/probe.nim` — created.
- `spikes/swiftui-nim/build.sh` — created.
- `spikes/swiftui-nim/FINDINGS.md` — created (the deliverable).
- (Nothing else — no changes to `cli/`, `native/`, or any app.)
