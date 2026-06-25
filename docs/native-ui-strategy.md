# Native UI strategy: AppKit / UIKit

> **Living document.** Captures how Zapp uses Apple's native UI frameworks for its
> *chrome* (the native UI around the web content), what's shipped, and the roadmap.
> Last updated 2026-06-23. Apple-only concerns; Windows/Linux native UI is a separate story.

## Orientation

Zapp's *actual app UI is web* — your HTML/TS running in a `WKWebView`. The native
frameworks below are the **chrome around** that web content: windows, sidebars,
inspectors, toolbars, popovers, tray/menus, and embedded webview panels.

Two frameworks provide the framework chrome:

| | **AppKit** | **UIKit** |
|---|---|---|
| Platform | macOS only | iOS / iPadOS only |
| Style | Imperative — you create + mutate view objects | Imperative |
| Role | macOS chrome baseline (deep, complete) | iOS chrome baseline |
| Zapp's stance | **macOS chrome** | **iOS chrome** |

## Strategic posture

**macOS chrome = AppKit. iOS chrome = UIKit. SwiftUI is not used for framework chrome.**

Zapp's chrome is fundamentally about hosting web content (`WKWebView` + split views +
drag regions + toolbar + menus + tray) — Cocoa/AppKit/UIKit territory tightly coupled to
webview interop. The macOS SwiftUI pane path (`NavigationSplitView` + `.inspector` hosted
in an imperative `NSWindow`) was tried and removed on 2026-06-23 (see
[`docs/superpowers/specs/2026-06-23-remove-swiftui-pane-path-design.md`](superpowers/specs/2026-06-23-remove-swiftui-pane-path-design.md)).
The root cause was irreconcilable: `NavigationSplitView` re-derives its column geometry on
every relayout (route changes, window resizes) and re-asserts its own defaults over any
imperative control, because it was never designed to be hosted inside an imperative
`NSWindow`. The AppKit `NSSplitViewController` path has no such re-derivation and is the
rock-solid baseline the SwiftUI effort was only ever trying to reach parity with.

**Apps can still use SwiftUI**, but as self-contained embedded views — not as
layout-owning containers around Zapp's webviews. The Swift<->Nim bridge is documented as
a standalone recipe at [`examples/swift-nim-bridge/`](../examples/swift-nim-bridge/).
Note that layout-owning SwiftUI containers (`NavigationSplitView`, `.inspector`) re-derive
geometry when hosted in an imperative `NSWindow` and fight runtime control; use them only
for self-contained leaf views where you don't need programmatic geometry control.

Recovering specific SwiftUI affordances (e.g. `.inspector` auto column<->bottom-sheet on
iOS) natively on AppKit/UIKit is a queued future cycle.

## What backs each chrome surface

| Surface | **macOS** | **iOS / iPadOS** |
|---|---|---|
| Window shell | `NSWindow` (AppKit) | `UIWindow` / view controllers (UIKit) |
| Sidebar | `NSSplitViewItem` (AppKit) | `UISplitViewController` (UIKit — auto-collapses) |
| Inspector | `NSSplitViewItem` trailing (AppKit) | hand-rolled (iPad held-pane / iPhone `UISheetPresentationController` sheet) |
| Toolbar | `NSToolbar` (AppKit) | limited |
| Popover | `NSPopover` (AppKit) | — |
| Tray / menu bar / dock | AppKit | n/a (desktop-only) |
| Embedded webview panels | `panel.m` geometry tracking (AppKit) | `panel.m` geometry tracking (UIKit) |
| Web content (your app) | `WKWebView` | `WKWebView` |

## Roadmap

| Cycle | Delivers | Status |
|---|---|---|
| Sidebar (macOS) | `NSSplitViewItem` sidebar, `SidebarHandle`, sidebar events | Done |
| Inspector (macOS) | `NSSplitViewItem` trailing inspector, `InspectorHandle` | Done |
| Toolbar (macOS) | `NSToolbar`, `ToolbarItemDef`, `setItems`/`updateItem`/`remove` | Done |
| Embedded webview panels | `<zapp-webview>`, `panel.m` — macOS + iOS | Done |
| iOS sidebar / inspector | `UISplitViewController`-backed sidebar + sheet inspector | Done |
| SwiftUI pane path (macOS) | `NavigationSplitView`/`.inspector` via `NSHostingController` | Removed 2026-06-23 (geometry re-derivation; see spec) |
| Inspector auto-adaptive (iOS) | `.inspector` sheet / iPad column via `UIHostingController` | Future |
| DOM-overlay native view | native view inline in web content (reuses `panel.m`) | Spike |
| App-authored native code | Swift<->Nim bridge recipe — see `examples/swift-nim-bridge/` | Recipe available |

## Content background extension (macOS 26+)

`WindowOptions.backgroundExtension` controls how the content pane's background
relates to the floating Liquid Glass sidebar on macOS 26 and later. This is a
**sidebar-edge-only** concept — the inspector pane sits edge-to-edge glass
*alongside* content (not floating over it), so there is nothing to extend under
or mirror; `backgroundExtension` does not apply to the inspector edge.

Three modes:

- **`"none"` (default)** — content sits beside the sidebar. Today's behavior
  on all macOS versions. No overlap.
- **`"extend"`** — content flows *under* the floating sidebar. The sidebar glass
  floats over the content's left edge. Apps keep foreground content clear by
  padding with `--zapp-safe-area-left` (injected by Zapp). The divider tracks
  live in real time.
- **`"mirror"`** — `NSBackgroundExtensionView`: content is inset to the
  unobscured area and its left edge is mirrored and blurred *behind* the sidebar
  glass — the "poster" effect (validated against Messages.app on macOS 26 and
  27 beta). Real content still bleeds under the titlebar/toolbar; only the
  sidebar edge is mirrored.

`"extend"` and `"mirror"` require macOS 26; on earlier releases both fall back
silently to `"none"`. The Liquid Glass itself is delivered by AppKit
(`NSSplitViewController` sidebar) — Zapp rides the OS treatment.

**Mirror reflow:** `NSBackgroundExtensionView` re-snapshots the out-of-process
`WKWebView` per layout pass. The snapshot cost scales with content weight: light
content resizes live; heavy content settles the mirror on mouseup. `"extend"` and
`"none"` always resize live. Choose `"extend"` for live divider tracking, `"mirror"`
for the poster look.

See [`docs/api-reference.md` → Content background extension](#content-background-extension-macos-26)
and the design spec at
[`docs/superpowers/specs/2026-06-24-appkit-w3-content-background-extension-design.md`](superpowers/specs/2026-06-24-appkit-w3-content-background-extension-design.md).

## Material / native glass

The `material` option on `sidebar` (and `inspector`) controls which background
treatment AppKit applies to that pane:

- **Unspecified or `Material.Sidebar`** — the OS-native glass treatment. On
  macOS 26+ this is the floating Liquid Glass sidebar (no forced
  `NSVisualEffectView`; AppKit owns the rendering). On earlier macOS it is
  classic vibrancy. This is the default and the path to the modern look.
- **Any other explicit `material`** — a forced `NSVisualEffectView` with the
  specified material is applied. This works on all macOS versions but opts out
  of the 26+ Liquid Glass treatment.

**Rule of thumb:** leave `material` unset (or set `Material.Sidebar`) to get
the native OS glass automatically. Only set an explicit material if you need a
specific vibrancy effect and are willing to opt out of the Liquid Glass on 26+.

Validated on macOS 26 and macOS 27 beta against Messages.app for the
`backgroundExtension` behavior.

## Anchors

1. **macOS chrome = AppKit; iOS chrome = UIKit.** These are the sole framework-chrome paths.
   SwiftUI is not used for framework chrome.
2. **AppKit/UIKit are the proven baselines** for hosting `WKWebView` with webview-interop
   (bridge, script handlers, drag regions, traffic-light insets, KVO chrome metrics). They
   do not re-derive geometry behind the framework's back.
3. **Apps can embed SwiftUI** as self-contained leaf views via the Swift<->Nim bridge example
   (`examples/swift-nim-bridge/`). Layout-owning SwiftUI containers fight imperative
   `NSWindow` geometry control and are not recommended for that use.
