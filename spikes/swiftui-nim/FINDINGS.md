# SwiftUI → Nim interop spike — FINDINGS

**Date:** 2026-06-20 · **Toolchain:** Swift 6.3 (swiftc), Nim 2.2.10, `nim c --cc:clang --mm:orc` · macOS 26.5 (arm64)

## Verdict: ✅ GO

Zapp's Nim native layer **can** drive Swift — and real SwiftUI — through a plain
C-ABI bridge (`@_cdecl` → `swiftc` static lib → `nim c --passL` → `{.importc,
cdecl.}`). Both gates passed on the first real attempt, the binary-size cost is
negligible (the Swift + SwiftUI runtimes are OS-provided, not bundled), and the
build adds just one `swiftc` step. A SwiftUI feature cycle is viable; recommend
proceeding when prioritized.

## Scorecard
| Question | Result |
|---|---|
| Gate 1 — Swift `@_cdecl` bridge links + runs from Nim | **PASS** (`swift says: hello from Swift 6.3` / `2 + 3 = 5`) |
| Gate 2 — SwiftUI view renders (NSHostingView from Nim) | **PASS** (window rendered, human-confirmed) |
| Binary size — nim-only baseline | 74,584 B (~76 K) |
| Binary size — + Swift `@_cdecl` bridge | 76,024 B (~76 K) — **Δ +1,440 B** |
| Binary size — + SwiftUI / AppKit | 87,336 B (~88 K) — **Δ +11,312 B** vs bridge, +12,752 B vs baseline |
| Swift runtime bundled or OS-provided? | **OS-provided** — `otool -L` shows `/usr/lib/swift/libswiftCore.dylib` + `libswiftFoundation.dylib` (dyld shared cache); nothing bundled |

## The working incantation (from build.sh, reproduces from clean)
```bash
# Swift side → static lib
swiftc -emit-library -static -O -module-name zappswift -o libzappswift.a probe.swift

# Link into the nim/clang build
SWIFT_LIBDIR="$(dirname "$(xcrun --find swiftc)")/../lib/swift/macosx"
nim c --cc:clang --mm:orc -d:release --opt:size --hints:off \
  --passL:"-L. -lzappswift -L${SWIFT_LIBDIR} -lswiftCore -lswiftFoundation \
           -Xlinker -rpath -Xlinker ${SWIFT_LIBDIR} -Xlinker -rpath -Xlinker /usr/lib/swift \
           -framework SwiftUI -framework AppKit" \
  -o:probe probe.nim
```
`./build.sh bridge` (no frameworks) and `./build.sh swiftui` (+SwiftUI/AppKit)
reproduce gates 1 and 2 respectively. Nim declares the entry points with
`{.importc: "zapp_swift_<name>", cdecl.}`; the Swift side marks them `@_cdecl`.

**Why it works (the load-bearing detail):** `-lswiftCore`/`-lswiftFoundation` do
NOT resolve via the Xcode toolchain dir — they resolve through the macOS SDK
`.tbd` stubs (`$SDK/usr/lib/swift/*.tbd`, auto-searched by clang) and load at
runtime from the OS dyld shared cache via `-rpath /usr/lib/swift`. So on modern
macOS the Swift + SwiftUI runtimes are OS-provided/dynamic — hence the tiny size
delta. The "header vs link" question was moot: there is no link-free path, but the
link is cheap because nothing is bundled.

## Build-complexity notes
- One extra toolchain step (`swiftc` → static lib) before the existing `nim c`.
  No code generation, no headers needed (Nim's `{.importc.}` is the declaration).
- First-try link success — no `-force_load` (the `@_cdecl` symbols weren't
  dead-stripped), no swiftc-as-driver fallback, no `-emit-object` variant needed.
- **Cosmetic dead path (note for later robustness):** the first `-rpath`
  (`SWIFT_LIBDIR`, the Xcode toolchain `swift/macosx`) holds no swift dylibs on
  this machine and `-L${SWIFT_LIBDIR}` is inert; the load-bearing pieces are the
  SDK `.tbd` resolution + `-rpath /usr/lib/swift`. Harmless today; if a future
  build must work on CLT-only (no full Xcode) machines, lean on the SDK stubs +
  `/usr/lib/swift` and drop the toolchain path.

## If GO — what the feature cycle must solve
1. **Real Zapp build `--passL` coexistence.** Add the `swiftc` step + the Swift
   link flags into `buildNativeNim` (cli/src/native.ts) and confirm they coexist
   with the existing link set (Cocoa/Carbon/libzjs/frameworks). Expected additive,
   but unverified — first task of the feature cycle.
2. **Host SwiftUI into Zapp's EXISTING AppKit window.** The harness lets Swift own
   the `NSApplication`/run-loop; the real framework already owns the app + window,
   so the entry point must instead return/attach an `NSHostingView` (or
   `NSHostingController`) into an existing `NSWindow`/split item — NOT call
   `app.run()`. (This also sidesteps the unbundled-CLI window-activation quirk
   seen here, which only matters for the standalone harness.)
3. **iOS cross-compile.** `swiftc` for `arm64-apple-ios*` + the simulator slice
   (mirror the zjs/bare-hermes iOS cross-compile pattern); `UIHostingController`
   instead of `NSHostingView`.
4. **Compile-time OS-version gating + DX.** `@available` / availability checks so
   SwiftUI features compile only where their API floor is met; clear messaging
   when the toolchain/OS is missing; graceful fallback to the existing UIKit/AppKit
   path. (See memory `project_swiftui_cxx_interop_spike` DX requirements.)

## Reproduce
```bash
cd spikes/swiftui-nim
./build.sh bridge   && ./probe   # gate 1: prints the Swift string + 2+3=5
./build.sh swiftui  && ./probe   # gate 2: opens a SwiftUI window (close to exit)
```
Harness is standalone + throwaway (wired to nothing). Keep as the reference
artifact, or delete `spikes/swiftui-nim/` — the verdict + incantation live here.
