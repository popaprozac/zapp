# SwiftUI + WKWebView + .inspector adaptivity spike — FINDINGS

**Date:** 2026-06-20 · **Toolchain:** Swift 6.3 (swiftc) · macOS 26.x host · floors macOS 14 / iOS 17

## Verdict: ✅ GO

A `WKWebView` mounted inside a SwiftUI representable keeps its `WKScriptMessageHandler`
JS↔native round-trip, and SwiftUI `.inspector` adapts correctly — a trailing column on
macOS and iPad, an automatic bottom sheet on iPhone. Both load-bearing unknowns for the
"SwiftUI-backed accessories" cycle are cleared. Proceed.

## Scorecard
| Question | Result |
|---|---|
| WKWebView in a SwiftUI representable keeps its WKScriptMessageHandler round-trip | **PASS** ("pong from native ✓" on macOS, iPhone, iPad) |
| `.inspector` renders a COLUMN on macOS | **PASS** |
| `.inspector` renders a COLUMN on iPad | **PASS** (iPad Pro 11-inch M5 sim) |
| `.inspector` becomes a bottom SHEET on iPhone | **PASS** (iPhone 17 Pro sim) — the size-class adaptivity payoff |
| Builds on macOS (`arm64-apple-macos14.0`) | **PASS** (120 KB binary) |
| Builds + runs on iOS-sim (`arm64-apple-ios17.0-simulator`) | **PASS** (`.app` via simctl install/launch) |

## The working incantation (reproduces from clean)
```bash
cd spikes/swiftui-webview-inspector
# macOS (Gate 1): column + bridge
./build.sh macos && ./build/macos/probe

# iOS-sim (Gate 2): iPhone = bottom sheet, iPad = column
./build.sh ios-sim
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; open -a Simulator
xcrun simctl install booted build/ios/Probe.app
xcrun simctl launch  booted dev.zapp.spike.swiftuiwebview
# repeat install/launch against a booted iPad UDID for the column idiom
```
`swiftc` lines: macOS `-O -target arm64-apple-macos14.0`; iOS-sim `-O -sdk
$(xcrun --sdk iphonesimulator --show-sdk-path) -target arm64-apple-ios17.0-simulator`,
then a hand-assembled `Probe.app` (Info.plist + binary).

## Notes / gotchas (carry into the feature cycle)
- **Bridge is config-level, not mount-level.** The `WKScriptMessageHandler` is installed on
  the `WKWebViewConfiguration`/`WKUserContentController`, so it survives being hosted by a
  SwiftUI representable unchanged. This is the key reason the real `ZappWebView` re-plumb is
  expected to work — its bridge lives on the same config object.
- **macOS filesystem is case-insensitive.** `build/probe` (macOS) and `build/Probe` (iOS)
  collide and silently clobber each other — keep per-platform build subdirs.
- **A bare `swiftc` SwiftUI binary launches as an accessory process** (no Dock icon, window
  not fronted). An `NSApplicationDelegate` with `setActivationPolicy(.regular)` +
  `activate(...)` fixes it. (A real `.app` bundle would too.)
- **Single-file SwiftUI app:** use the script-style entry `ProbeApp.main()` (not `@main`) so
  it's clean in both `swiftc` "main" mode and SourceKit; `@main` on a lone file is rejected
  in main mode.
- **iOS `.app`** needs `UILaunchScreen` / `UIDeviceFamily` / `MinimumOSVersion` in Info.plist
  for `simctl` to install + launch.

## What the feature cycle must solve (now de-risked)
1. **Re-plumb the REAL `ZappWebView`** (custom `zapp://` scheme handler, the `"zapp"` script
   handler, drag regions, traffic-light insets, KVO chrome metrics, embeddable panels)
   through the representable's `Coordinator` — confirm none break when SwiftUI-hosted. The
   bridge-is-config-level finding above is the reason to expect this to hold.
2. **`@available` gating** (macOS 14 / iOS 17 floors) + graceful fallback to the current
   AppKit `NSSplitViewItem` / UIKit hand-rolled inspector for older OS or opt-out
   (`native: { swiftui: false }`), reusing the resolver pattern from the native-surface cycle.
3. **Nim-side wiring** — select + drive the SwiftUI shell from the Nim window layer.
4. **Coexistence** with the rest of Zapp's window chrome (toolbar, tray, window controls).

## Reproduce / cleanup
Standalone + throwaway. Keep as the reference artifact, or delete
`spikes/swiftui-webview-inspector/` — the verdict + incantation live here.
