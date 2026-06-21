# Native UI strategy: AppKit / UIKit / SwiftUI

> **Living document.** Captures how Zapp uses Apple's native UI frameworks for its
> *chrome* (the native UI around the web content), what's shipped, and the roadmap.
> Last updated 2026-06-20. Apple-only concerns; Windows/Linux native UI is a separate story.

## Orientation

Zapp's *actual app UI is web* — your HTML/TS running in a `WKWebView`. The native
frameworks below are the **chrome around** that web content: windows, sidebars,
inspectors, toolbars, popovers, tray/menus, and (new) embedded native surfaces.

Three frameworks are in play:

| | **AppKit** | **UIKit** | **SwiftUI** |
|---|---|---|---|
| Platform | macOS only | iOS / iPadOS only | **All Apple** (macOS, iOS, iPadOS, …) |
| Style | Imperative — you create + mutate view objects | Imperative | **Declarative** — you describe UI from state; it re-renders |
| Role | Legacy baseline (deep, complete) | Legacy baseline | **Modern** — where Apple ships new APIs |
| Size-class adaptivity | Manual | Some (e.g. `UISplitViewController` auto-collapses) | **Automatic** — `.inspector`, `NavigationSplitView` adapt column↔sheet for free |
| Zapp's stance | Baseline / cross-platform path | Baseline | **Selective "enhanced tier"** — adopt where it wins |

"AppKit/UIKit" is the imperative pair (macOS = AppKit, iOS = UIKit). SwiftUI spans both.

## Strategic posture

**SwiftUI is a selective *enhanced tier*, not the primary native path.** Zapp's chrome
is fundamentally about hosting web content (`WKWebView` + split views + drag regions +
toolbar + menus + tray) — Cocoa/AppKit/UIKit territory tightly coupled to webview interop,
which SwiftUI does not replace. We reach for SwiftUI **specifically** where it gives
something the imperative frameworks can't (or can't cheaply) — most notably modern
size-class adaptivity. The AppKit/UIKit path stays the proven baseline and the
cross-platform story.

Crucially, Zapp's native-surface API is **tech-agnostic**: callers ask for a native
surface, never naming SwiftUI or AppKit. A resolver picks the backing per platform + OS
version. That keeps the policy — "AppKit-default, SwiftUI-for-specific-features" →
eventually "SwiftUI-default, AppKit-fallback" — **reversible without API churn**. We start
selective and can ratchet toward SwiftUI as confidence grows.

Min macOS target is 12.0, but the genuinely better SwiftUI APIs floor at macOS 13/14+ /
iOS 16/17+. So anything SwiftUI-backed needs an AppKit/UIKit fallback regardless — "you
maintain both anyway," which the resolver handles cleanly (enhanced where available,
baseline otherwise).

## What backs each chrome surface — today vs. future

| Surface | **macOS today** | **iOS/iPadOS today** | **Future (SwiftUI where it wins)** |
|---|---|---|---|
| Window shell | `NSWindow` (AppKit) | `UIWindow`/view controllers (UIKit) | Optional SwiftUI shell (big lift; only if needed) |
| Sidebar | `NSSplitViewItem` (AppKit) | `UISplitViewController` (UIKit — **already adapts**) | `NavigationSplitView` (optional; UIKit already adapts here) |
| **Inspector** | `NSSplitViewItem` trailing (AppKit) | **hand-rolled** (iPad held-pane / iPhone `UISheetPresentationController` sheet) | **`.inspector` (SwiftUI) ← biggest win**: auto column↔bottom-sheet |
| Toolbar | `NSToolbar` (AppKit) | limited | SwiftUI `.toolbar` possible |
| Popover | `NSPopover` (AppKit) | — | SwiftUI `.popover`/`.sheet` possible |
| Tray / menu bar / dock | AppKit | n/a (desktop-only) | stays AppKit |
| **Native-surface pane** *(shipped)* | AppKit split pane → **SwiftUI content** (enhanced) / **`NSView`** (baseline) | stub (no-op) | iOS via `UIHostingController` |
| Web content (your app) | `WKWebView` | `WKWebView` | unchanged (can be wrapped in SwiftUI via a representable for adaptivity) |

The **inspector** is the standout: UIKit has *no* first-party inspector, so today's iOS
inspector is hand-rolled — `.inspector` is the first native adaptive one. Sidebars already
adapt via `UISplitViewController`, so SwiftUI adds less there.

## What we shipped — the native-surface resolver

The generic native-surface pane (macOS) picks its backing automatically:

| Condition | Backing chosen |
|---|---|
| macOS + `swiftc` present + not opted out | **SwiftUI** (`NSHostingView`) — enhanced |
| macOS + `native: { swiftui: false }` or no `swiftc` | **AppKit** (`NSView`) — baseline |
| iOS (current) | stub / no-op |

Delivered: the `swiftc` build step + Swift link wiring (gated by `resolveSwiftUIBuild`),
`WindowOptions.nativeSurface`, `win.nativeSurfaceBacking()`, and a native→Nim→web round-trip
event. The Swift + SwiftUI runtimes are **OS-provided** (resolve via SDK `.tbd` stubs +
`/usr/lib/swift`), so the binary-size cost is negligible and nothing is bundled. See
`docs/api-reference.md` → "Native surface (macOS)" for the developer-facing API.

## The adaptivity trick (why the webview goes *inside* SwiftUI)

To get SwiftUI's automatic column↔sheet adaptivity (e.g. `.inspector` on iPhone becoming a
bottom sheet), the SwiftUI container must **own the shell** and host the `WKWebView` as its
primary content via a representable (`NSViewRepresentable` / `UIViewRepresentable`):

```
UIHostingController / NSHostingController
  └─ SwiftUI root
       ├─ WebView(WKWebView)            ← your web content, via a representable
       └─ .inspector(isPresented) { … } ← accessory, auto-adaptive by size class
```

This is the **inverse** of the native-surface pane we shipped (AppKit pane → `NSHostingView`
→ SwiftUI *content*). Flipping ownership so SwiftUI wraps the webview is what unlocks the
adaptivity — and its cost is re-plumbing Zapp's existing webview integration (bridge, script
handlers, drag regions, traffic-light insets, KVO chrome metrics, embeddable panels) through
the representable's coordinator. That flip is its own cycle (see roadmap).

## Roadmap

| Cycle | Delivers | Status |
|---|---|---|
| Foundation + native-surface pane | Swift↔Nim bridge, `swiftc` build wiring, opt-out gating, resolver pattern, the pane primitive (macOS) | ✅ Done |
| SwiftUI accessories **Sub-cycle 1** — macOS pane *render* | accessory'd macOS windows (macOS 14+, not opted out) build sidebar/content/inspector via a SwiftUI `NavigationSplitView`/`.inspector` pane layout (`native/platform/darwin/swift/panes.swift`) hosting the real webviews; AppKit `NSSplitViewController` fallback. Selection automatic; no new knob. | ✅ Done (render proven) |
| SwiftUI accessories **Sub-cycle 2a** — runtime pane *visibility* control | the app's sidebar/inspector toggle items + runtime visibility APIs drive the SwiftUI panes (the inspector renders + toggles), animated via `withAnimation`; the same reverse `window:sidebar-collapsed/expanded` + `window:inspector-collapsed/expanded` events the AppKit path emits | ✅ Done |
| SwiftUI accessories **Sub-cycle 2b** — per-world toolbar | the toolbar is rendered in whichever world owns the content (SwiftUI `.toolbar` on the SwiftUI pane path, `NSToolbar` on AppKit) behind one app-facing toolbar spec (see below) | ⏭ Next |
| SwiftUI accessories **Sub-cycle 2c** — presentation + resize | cross-platform sidebar **presentation** styles (tile/overlay) · width/resize control · `setCollapsible`/`setResizable` parity on the SwiftUI path · per-platform default docs | ⏭ Next |
| SwiftUI accessories **Sub-cycle 3** — iOS | the same pane layout via `UIHostingController` — the adaptive payoff (iPhone sheet / iPad column); first checkpoint: `.inspector` sheet via `UIHostingController` | 🔜 |
| DOM-overlay native view | native view *inline anywhere* in web content (reuses `panel.m` geometry tracking) — "native, no ceremony" | 🔜 Spike |
| iOS native surface | `UIHostingController` + `swiftc` cross-compile so the native-surface pane works on iOS | 🔜 |
| App-authored native code | let app devs write their own Swift/native, Nim-style DX | 🌅 Later vision |

### Toolbar coexistence — the decision (for Sub-cycle 2)

A window can't half-share its title-bar toolbar between SwiftUI and a manual `NSToolbar`: when SwiftUI content uses `NavigationSplitView`/`.inspector`, SwiftUI auto-injects its own toggles and reflows the toolbar, and the app's `NSToolbar` items intermittently vanish. **Decision: the toolbar is rendered in whichever world owns the content** — SwiftUI `.toolbar` on the SwiftUI pane path, `NSToolbar` on the AppKit path — behind **one** app-facing toolbar spec (the same enhanced/baseline-behind-one-API pattern as the panes; not ad-hoc duplication). This is also what makes the iOS toolbar viable (with `NavigationSplitView`, SwiftUI `.toolbar` is the only coherent placement). The app describes its toolbar once; the framework renders it via the active path's toolbar system, routing actions back to the same handlers.

### Sub-cycle 1 known limitations (→ Sub-cycle 2)

- **Toolbar glitch:** in the SwiftUI pane path, SwiftUI's auto sidebar/inspector toggles collide with the app's `NSToolbar` (items flicker/disappear). Fixed properly by the per-world toolbar above.
- **Sidebar presents as overlay:** `.navigationSplitViewStyle(.balanced)` did not force tiling — needs `columnVisibility`/explicit column width (folds into the presentation-styles work).
- **Runtime pane control not wired** — *resolved in Sub-cycle 2a (visibility only):* the app's sidebar/inspector toggle items + runtime visibility APIs now drive the SwiftUI panes (the inspector renders + toggles, animated via `withAnimation`) and the reverse collapse/expand events fire on the SwiftUI path. Still deferred to **2c**: width/resize control + `setCollapsible`/`setResizable` parity + tiling/presentation styles — the SwiftUI path currently no-ops those with a `ZAPP_LOG` line.
- **Per-platform sidebar defaults to document:** macOS tiles; iOS sidebar overlays — to be exposed as cross-platform `presentation` styles.

## Anchors

1. **Tiering.** AppKit/UIKit = always-present baseline; SwiftUI = selective enhanced tier
   for enhanced or net-new modern Apple views.
2. **Reversibility.** The tech-agnostic surface API lets the SwiftUI-vs-AppKit policy shift
   over time without breaking callers.
3. **Compile-time gating + graceful fallback.** A feature compiles into the SwiftUI path
   only where its OS floor is met; otherwise it falls back to the imperative path
   automatically, and apps can opt out entirely (`native: { swiftui: false }`).
