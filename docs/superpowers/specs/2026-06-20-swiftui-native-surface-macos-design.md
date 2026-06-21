# SwiftUI native-surface primitive (macOS) — Design

**Date:** 2026-06-20 · **Branch:** `feat/nim-native` (do not merge to main) · **Track:** Apple-only

## Goal

Turn the GO-verdict Swift→Nim bridge spike (`spikes/swiftui-nim/`, FINDINGS.md) into a
real, reusable framework capability: a **generic native surface** mounted into an existing
Zapp window, whose backing is **SwiftUI when available** (the *enhanced* tier) and
**AppKit otherwise** (the *baseline*). This is "foundation part 2" — it makes SwiftUI a
usable building block and proves the real-build integration end-to-end, without
re-implementing any specific chrome feature yet.

## Strategic posture (decided during brainstorming)

- **SwiftUI is an enhanced tier, not the primary native path.** Zapp's chrome is
  fundamentally web-content hosting (`WKWebView` + split views + drag regions + toolbar +
  menus + tray) — Cocoa/AppKit territory tightly coupled to webview interop, which SwiftUI
  does not replace. SwiftUI is adopted *selectively* where it genuinely wins (e.g. future
  `.inspector` size-class adaptivity). The AppKit/UIKit path stays the proven baseline and
  the cross-platform story.
- **The generic-surface abstraction makes the policy reversible.** Because the public API
  is tech-agnostic, the policy ("AppKit-default, SwiftUI-for-specific-features" →
  eventually "SwiftUI-default, AppKit-fallback") can ratchet over time **without API
  churn**. We start selective and can shift the default toward SwiftUI as confidence grows.
- **Min macOS target is 12.0**, but the genuinely better SwiftUI APIs floor at macOS 13/14+.
  So anything SwiftUI-backed needs an AppKit fallback regardless — reinforcing "you
  maintain both anyway," which the generic surface handles cleanly.

## Scope

**In scope (this cycle):**
- The generic native-surface primitive on **macOS**, mounted as a window pane.
- Two real backings (SwiftUI `NSHostingView` enhanced / AppKit `NSView` baseline) + a
  compile-time-and-runtime resolver.
- The `swiftc` build step + Swift link-flag coexistence in the real `buildNativeNim`.
- Opt-out gating (`native.swiftui: false`) + clear build/runtime messaging + graceful
  always-functional fallback.
- A trivial-but-real demonstrative view (a native control that round-trips a value into
  Nim via the spike's `@_cdecl` callback), wired into kitchen-sink for visual smoke.

**Out of scope (future work, recorded below):**
- iOS (`UIHostingController` + `swiftc` cross-compile for device + simulator slices).
- App-authored native code with Nim-style DX (letting users write their own Swift/native
  and integrate it) — a deliberate future direction.
- Re-implementing a specific chrome feature (e.g. `.inspector` adaptivity) in SwiftUI —
  a follow-on cycle that builds on this primitive.
- Windows/Linux native surface.

## Authoring model

**Framework-authored Swift.** The Swift/SwiftUI lives in Zapp's `native/` layer; Zapp owns
it. Devs consume the surface through the existing native-first chain (C/ObjC primitive →
Nim method/option → router/TS as needed → docs) and never touch Swift. This matches the
"native chrome you can't fake in CSS" pitch: the framework authors native UI, apps consume
it. App-authored Swift is explicitly future work.

## Architecture

A new generic **native surface**: framework-authored native UI mounted into an existing
Zapp `NSWindow` as a pane. A resolver picks the backing:

- **SwiftUI (`NSHostingView`)** when its `@available` floor is met and SwiftUI is compiled
  in and not opted out → the enhanced tier.
- **AppKit (`NSView`)** otherwise → the baseline tier; the surface still works, just
  without SwiftUI niceties.

The demonstrative view is trivial-but-real (a label + a button) so the cycle stays about
the *pipeline* (build → host → resolve → fall back), not the view. The button round-trips a
value into Nim through a C callback (the spike's `@_cdecl` mechanism), proving the bridge
works through the real build.

## Components

### 1. Build wiring — `cli/src/native.ts` (`buildNativeNim`) + `cli/src/build-config.ts`

- **`swiftc` step:** compile framework Swift sources → static `libzappswift.a`, mirroring
  the spike incantation
  (`swiftc -emit-library -static -O -module-name zappswift -o libzappswift.a <sources>`).
  Runs only when **all** hold: `swiftc` resolvable via `xcrun`, target is `macos`, and not
  opted out (`config.native?.swiftui !== false`).
- **Link flags** appended to the nim link, coexisting with the existing Cocoa/Carbon/libzjs
  set: `-L<dir> -lzappswift -lswiftCore -lswiftFoundation -Xlinker -rpath -Xlinker
  /usr/lib/swift -framework SwiftUI` (AppKit comes in via Cocoa). Assembled in
  `buildNativeNim` (gated, like the existing `iosArgs`) since `swiftc` availability is a
  runtime check and `renderPlatformNim` is a pure function.
- **Defines when compiled in:** `-d:zappSwiftUI` (Nim) + `-DZAPP_HAS_SWIFTUI` (passed to the
  `nativesurface.m` compile) so neither side references Swift symbols when SwiftUI is off.
- **The decision is a pure, unit-testable function** (`resolveSwiftUIBuild({target, config,
  swiftcAvailable}) → {compileSwift, defines, linkFlags}` or similar) so the predicate,
  opt-out skip, and flag assembly are tested without invoking the toolchain.
- **Messaging:** build logs one line — `[zapp] SwiftUI: enabled (enhanced tier)` /
  `disabled (opt-out)` / `skipped (swiftc not found — AppKit baseline)`.

### 2. Swift layer — `native/platform/darwin/swift/native_surface.swift`

- `@_cdecl("zapp_swift_native_surface_create")` returns an `NSView*` — an `NSHostingView`
  wrapping the demonstrative SwiftUI view. `@available(macOS 10.15, *)`-guarded.
- The SwiftUI view takes a C function pointer (callback) and invokes it on button tap to
  round-trip a value into Nim.
- Swift sources live in a `swift/` subdir so they stay out of the `.m` compile-list glob
  (`getPlatformSources`).

### 3. AppKit backing + resolver — `native/platform/darwin/nativesurface.m`

- `darwin_native_surface_create(window_id, …)`:
  - **Resolve backing:** if `ZAPP_HAS_SWIFTUI` is defined **and** `@available(macOS X, *)`
    **and** not forced-AppKit → call `zapp_swift_native_surface_create(...)` for the
    `NSHostingView`; **else** build the AppKit equivalent (`NSStackView` + `NSTextField` +
    `NSButton`) wired to the *same* C callback.
  - **Attach:** mount the returned `NSView` into the window as a pane, reusing the
    `NSSplitViewItem` attach pattern from `inspector.m` / `sidebar.m` (but for a plain
    `NSView`, not a webview slot).
  - **Report** the chosen backing (for the Nim getter + a debug log line).
- The callback path: AppKit/SwiftUI button → C callback → Nim handler → emits a Zapp event
  / logs (the bridge round-trip proof, identical for both backings).

### 4. Nim + router + TS

- **Nim:** a window option / `win`-method to add a native-surface pane (shaped like the
  existing sidebar/inspector pane APIs), plus `nativeSurfaceBacking() → "swiftui" |
  "appkit"` for introspection/DX. Calls `darwin_native_surface_create` (with an iOS stub for
  symbol parity per the `#ifdef __APPLE__`/iOS-link rule).
- **Router:** none required this cycle — creation stays native (config/Nim) to keep the
  primitive minimal. The round-tripped value reaches web content via the existing event
  system. A JS-driven create/toggle route is a follow-on.
- **TS runtime:** light — kitchen-sink web content subscribes to the round-trip event to
  show it reached JS; optional read-only `nativeSurfaceBacking` accessor for parity.

### 5. Gating / fallback DX

- **Opt-out:** `native.swiftui: false` in `zapp.config.ts` → skips `swiftc`, no defines,
  resolver uses AppKit. Default = **enabled where the toolchain is present** (opt-out, not
  opt-in).
- **Runtime resolution:** `@available` picks SwiftUI vs AppKit per surface (future
  per-feature OS floors). Since the trivial view's floor is always met at Zapp's min target,
  **the opt-out flag is how we demonstrate the AppKit fallback this cycle** — no sub-floor OS
  needed.
- **Always-functional:** the surface always renders (AppKit floor); SwiftUI is additive.
- **Messaging:** build-time line (above) + runtime debug log `native surface backing:
  swiftui|appkit`.

## Data flow

1. App config / Nim requests a native-surface pane on a window.
2. `buildNativeNim` (at build time) decided whether SwiftUI was compiled in (`swiftc` ran,
   defines + Swift link flags present) or not (opt-out / no toolchain).
3. At runtime, `darwin_native_surface_create` resolves the backing (SwiftUI vs AppKit) and
   attaches the `NSView` pane to the window.
4. User clicks the control → C callback → Nim handler → Zapp event emitted → observable from
   web content (and logged).

## Error handling

- `swiftc` not found → skip the Swift step, log `skipped … AppKit baseline`, build proceeds
  AppKit-only (no failure).
- Opt-out → no Swift compiled/linked; resolver is AppKit-only.
- Runtime `@available` false → AppKit backing (graceful).
- The surface never hard-fails to render: AppKit is the guaranteed floor.

## Testing

- **Bun unit tests:** the pure build-decision function — swiftc-runs predicate
  (enabled + macOS + toolchain), opt-out skip, link-flag assembly, define presence; macOS vs
  iOS vs opted-out matrices.
- **Build gates:**
  - macOS build, SwiftUI enabled → links clean (Swift flags coexist with
    Cocoa/Carbon/libzjs).
  - macOS build, `native.swiftui: false` → links clean (no Swift in the binary).
  - **iOS-sim build still passes** (macOS-only gating must not break the iOS path; iOS gets
    no SwiftUI this cycle).
- **Human visual smoke (kitchen-sink):** a native-surface pane renders the demonstrative
  view; clicking the control round-trips a value into Nim (observable via event/log).
  Rebuild with `native.swiftui: false` → the same pane renders via AppKit.

## Future work

- **iOS:** `UIHostingController` + `swiftc` cross-compile (arm64 device + simulator slices,
  mirroring the zjs/bare-hermes cross-compile pattern). The `@available`/fallback DX built
  here is the same shape iOS will reuse.
- **App-authored native code:** a clean, Nim-style DX for users to write their own
  Swift/native code and integrate it with the framework.
- **Specific chrome features in SwiftUI:** e.g. `.inspector` adaptivity — builds on this
  primitive; may let the inspector drop its hand-rolled iPad pane / iPhone sheet on
  sufficiently new OS while keeping them as fallbacks.
- **Policy ratchet:** as SwiftUI proves out, shift the resolver's default toward
  SwiftUI-primary without API churn.
- **Windows/Linux:** a native-surface story off the Apple track (separate design).
