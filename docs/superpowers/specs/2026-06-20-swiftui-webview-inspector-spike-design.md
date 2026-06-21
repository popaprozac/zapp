# SwiftUI + WKWebView + `.inspector` adaptivity spike — Design

**Date:** 2026-06-20 · **Branch:** `feat/nim-native` (do not merge to main) · **Track:** Apple-only

## Goal

A risk-reduction spike that gives a GO/NO-GO verdict on the next big SwiftUI cycle
("SwiftUI-backed accessories") **before** committing to it. The next cycle requires flipping
Zapp's window nesting — a SwiftUI shell that *owns* the window and hosts the `WKWebView` as
primary content, then applies `.inspector` / `NavigationSplitView` to get true size-class
adaptivity (the auto column↔bottom-sheet inspector that UIKit cannot do). That flip is
expensive (re-plumbing the real webview integration), so this spike isolates and falsifies
the two load-bearing unknowns first.

## The two unknowns under test

1. **Bridge survival:** does a `WKWebView` mounted *inside* a SwiftUI representable
   (`NSViewRepresentable` / `UIViewRepresentable`) keep its `WKScriptMessageHandler`
   JS↔native round-trip?
2. **`.inspector` adaptivity:** with the webview as the primary content, does SwiftUI
   `.inspector(isPresented:)` render a trailing column on macOS/iPad and **automatically
   become a bottom sheet on iPhone**?

Everything else (the Nim↔Swift bridge, the `swiftc` build wiring, the resolver/opt-out/
fallback pattern) is already proven by the prior cycle and is NOT re-tested here.

## Shape

A **standalone, throwaway, pure-Swift harness** in `spikes/swiftui-webview-inspector/`,
built directly with `swiftc` — no Nim, no Zapp build, wired to nothing. This mirrors the
`spikes/swiftui-nim/` pattern. Pure Swift because the unknowns are WebKit-in-SwiftUI
concerns; a plain configured `WKWebView` + script handler exercises the bridge-survival
question without needing Zapp's real bridge, and `.inspector` adaptivity is a pure SwiftUI
concern.

## Components

### `spikes/swiftui-webview-inspector/Probe.swift`

A SwiftUI `@main App` whose root is approximately:

```
NavigationSplitView {
    SidebarList                         // proves the sidebar accessory (NavigationSplitView)
} detail: {
    WebView(html: trivialHTML)          // WKWebView via representable — PRIMARY content
        .inspector(isPresented: $showInspector) { InspectorContent }   // accessory under test
}
.toolbar { ToggleInspectorButton }      // flips showInspector
```

- **`WebView`** — `NSViewRepresentable` (macOS) / `UIViewRepresentable` (iOS) wrapping a
  `WKWebView`. The `WKWebViewConfiguration` installs a `WKUserContentController` with a
  `"probe"` script-message handler (a `Coordinator` conforming to
  `WKScriptMessageHandler`). It loads a trivial inline HTML string.
- **Trivial HTML** — a button that calls
  `window.webkit.messageHandlers.probe.postMessage("ping")`. The coordinator, on receiving
  `"ping"`, calls `webView.evaluateJavaScript(...)` to make a **visible** change
  (e.g. set a status line to "pong from native"). That visible change is the bridge-survival
  proof.
- **`InspectorContent`** — trivial SwiftUI view (a label + the bridge round-trip count) so
  the inspector has something to show.
- **`SidebarList`** — a couple of static rows; just to instantiate `NavigationSplitView`.

Conditional-compile the representable (`#if os(macOS)` `NSViewRepresentable` /
`NSViewRepresentableContext`; `#else` `UIViewRepresentable`) so one file builds for both
targets.

### `spikes/swiftui-webview-inspector/build.sh`

Direct `swiftc`, two stages (`macos` | `ios-sim`):

- **macOS:** `swiftc -O -target arm64-apple-macos14 Probe.swift -o probe` → a runnable
  binary/`.app`. (`.inspector` floors at macOS 14.)
- **iOS-sim:** cross-compile with
  `-sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios17-simulator`,
  hand-assemble a minimal `.app` (a generated `Info.plist` + the binary), then
  `xcrun simctl install booted <app>` + `xcrun simctl launch booted <bundle-id>`.
  (`.inspector` floors at iOS 17.)

### `spikes/swiftui-webview-inspector/FINDINGS.md`

The deliverable scorecard — see "Deliverable" below.

## Gates (the spike *is* the test)

No unit tests. Verification is build + run + human visual confirm, exactly like
`spikes/swiftui-nim/`.

- **Gate 1 — macOS:** the window shows the `NavigationSplitView` sidebar + the webview as
  detail + an **inspector column**; clicking the HTML button produces the visible "pong"
  change (bridge round-trips through the representable); the toolbar toggle shows/hides the
  inspector.
- **Gate 2 — iOS-sim:** on an **iPhone** simulator the inspector presents as a **bottom
  sheet**; on an **iPad** simulator it's a trailing **column**; the bridge round-trip still
  works. This adaptivity is the entire payoff — human visual confirm on both idioms.

If Gate 1 fails (bridge broken in a representable, or `.inspector` unusable with a webview
primary), that's a NO-GO and the spike stops there with the finding.

## Deliverable

`spikes/swiftui-webview-inspector/FINDINGS.md`:

- **Scorecard:** bridge survives the representable? (Y/N) · `.inspector` adapts — macOS
  column / iPad column / iPhone sheet? (per-idiom Y/N) · builds on macOS? · builds + runs on
  iOS-sim?
- **The working incantation** (the `swiftc` lines + the iOS-sim `.app`/simctl steps that
  reproduce from clean).
- **GO/NO-GO verdict.**
- **If GO — what the feature cycle must solve:**
  1. Re-plumb the *real* `ZappWebView` (custom scheme handler, the `"zapp"` script handler,
     drag regions, traffic-light insets, KVO chrome metrics, embeddable panels) through the
     representable's `Coordinator` — confirm none of that breaks when the webview is
     SwiftUI-hosted.
  2. `@available` gating (macOS 14 / iOS 17 floors) + graceful fallback to the current
     AppKit `NSSplitViewItem` / UIKit hand-rolled inspector for older OS or opt-out.
  3. The Nim-side wiring (how the SwiftUI shell is selected + driven from the Nim window
     layer, reusing the resolver pattern).
  4. Coexistence of the SwiftUI shell with the rest of Zapp's window chrome (toolbar, tray,
     window controls).

## Non-goals

- Nim integration / the real Zapp bridge / real accessory re-implementation — all the
  feature cycle.
- Older-OS fallback paths — the feature cycle (the spike only proves the enhanced path on
  macOS 14+ / iOS 17+).
- Windows/Linux.

## Notes

- swiftc available (Swift 6.3); the prior spike (`spikes/swiftui-nim/`) proved
  `swiftc`-built SwiftUI windows render and `xcrun simctl` flows work.
- Keep the harness deletable: the verdict + incantation live in `FINDINGS.md`; the
  `spikes/swiftui-webview-inspector/` dir can be removed after, like the prior spike.
