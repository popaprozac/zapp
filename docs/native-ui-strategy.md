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
| Toolbar affordances (macOS 26) | `style`/`tintColor`/`badge`/`bordered` on `ToolbarItemDef`; prominent+flat+badge looks; live `updateItem` patches | Done |
| Toolbar grouping (macOS 10.15+) | `type:"segmented"` (`NSSegmentedControl`-in-group, selectionMode one/any/momentary) + `type:"group"` (cluster → overflow); `TOOLBAR_GROUP_SELECTED` event; `updateItem({selected})` | Done |
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

**Mirror reflow scales with content weight:** `NSBackgroundExtensionView` re-snapshots
the out-of-process `WKWebView` per layout pass (a cost `"extend"`/`"none"` avoid). The
snapshot scales with how heavy the content is to reflow: a light page mirrors live during
a sidebar drag; a heavy single-page app defers reflow to drag-settle, and very heavy
content can stall mid-drag. Verified by isolation — inspector, window `vibrancy`, and
primary-vs-secondary window were each ruled out; content complexity is the determinant.
`"extend"`/`"none"` always resize live. Choose `"extend"` for guaranteed live tracking,
`"mirror"` for the poster look on lighter content.

See [`docs/api-reference.md` → Content background extension](#content-background-extension-macos-26)
and the design spec at
[`docs/superpowers/specs/2026-06-24-appkit-w3-content-background-extension-design.md`](superpowers/specs/2026-06-24-appkit-w3-content-background-extension-design.md).

## Toolbar affordances (macOS 26)

Four new fields on `ToolbarItemDef` (and patchable via `win.toolbar.updateItem`)
recover the prominent/badge/flat looks that macOS 26 exposes natively:

- **`style: "prominent"`** — filled-capsule background (the Mail Compose button look).
  Combine with `tintColor` (hex) to set the fill color; omit `tintColor` to use the
  app accent. `style`/`tintColor` are macOS-26-gated; on earlier releases they fall
  back silently to plain.
- **`badge`** — numeric (`{count}`), text (`{text}`), or dot (`{dot:true}`) badge
  on the icon. Pass `null` to a `updateItem` patch to clear a live badge. macOS-26-gated;
  hidden on earlier releases.
- **`bordered: false`** — flat borderless button (the Messages attachment-picker look).
  Universal — no macOS-26 gate.

All four fields are parity-identical across TS and Nim authoring. The kitchen-sink
Toolbar section demonstrates live badge increment/clear via `updateItem`.

See the design spec at
[`docs/superpowers/specs/2026-06-24-appkit-w2-toolbar-affordances-design.md`](superpowers/specs/2026-06-24-appkit-w2-toolbar-affordances-design.md)
and the API reference at [`docs/api-reference.md` → Toolbar (macOS)](#toolbar-macos).

## Toolbar grouping (macOS 10.15+)

Two `NSToolbarItemGroup` flavors let you cluster controls in the toolbar:

- **`type: "segmented"`** — an `NSSegmentedControl` embedded in a group item.
  `selectionMode` controls behavior: `"one"` (radio), `"any"` (multi-select),
  `"momentary"` (no persistent highlight — fires action only). The shared
  primitive for all three modes is `action: () => void` on each segment. For
  `"one"` and `"any"`, selection changes also emit `TOOLBAR_GROUP_SELECTED`
  (`{ windowId, id, index, selected }`) so any pane or worker holding a window
  handle can react without registering individual segment callbacks. Live
  selection can be pushed from code via `win.toolbar.updateItem(id, { selected })`.
  Menu-like unification (a single callback/event for both action and selection) is
  a planned follow-up; today the two primitives — per-segment `action` and the
  group `TOOLBAR_GROUP_SELECTED` event — coexist.

- **`type: "group"`** — wraps a flat array of button items into a single
  `NSToolbarItemGroup` that clusters them visually and collapses to an overflow
  menu when the window narrows. `controlRepresentation: "automatic"` (default)
  lets AppKit decide; `"expanded"`/`"collapsed"` force the state. Nested groups
  are rejected at create time.

Both flavors share the `controlRepresentation` field and are parity-identical
across TS and Nim authoring (Nim: `segmented:` / `group:` in the toolbar block).
macOS 10.15 floor; the field is a no-op on iOS.

See [`docs/api-reference.md` → Toolbar grouping](#toolbar-grouping--segmented-controls--item-groups-macos-1015) for the full API.

## Title bar styles & toolbar tracking

`titleBarStyle` is a free, per-window cosmetic choice — the framework never
forces a particular style. Three values are supported:

- **`"default"` (or unset on a plain window)** — standard macOS title bar: title
  text shown, toolbar (if any) renders as its own separate band below it. More
  chrome, taller combined height.
- **`"hidden"`** — sets `NSWindowStyleMaskFullSizeContentView` + transparent
  titlebar, hides the title text. Content runs full-height; the toolbar merges
  into the unified titlebar row (the Mail/Notes "unified" look).
- **`"hiddenInset"`** — identical to `"hidden"` but keeps the title text
  visible in the unified bar. This is the most common choice for sidebar+toolbar
  apps and matches what Apple's own apps (Mail, Notes) use.

**Unset → resolves to `"default"` for plain windows.** Exception: a window with
a `sidebar` or `inspector` automatically adopts the hidden-title unified chrome
when `titleBarStyle` is omitted — set `titleBarStyle: "default"` explicitly to
opt back into the standard title bar on those windows.

**`trackingSeparator` and pane reflow.** A `{ type: "trackingSeparator" }` toolbar
item is an `NSTrackingSeparatorToolbarItem` that binds a toolbar divider to the
sidebar (or inspector) split-view divider. Items before the separator stay aligned
over that pane's column; items after it stay over the content. When the pane
collapses, the divider moves and the toolbar groups reflow — this is the Mail/Notes
sidebar pattern and is intentional AppKit behavior.

The visual prominence of that reflow depends on `titleBarStyle`:

- Under `"hidden"`/`"hiddenInset"` the reflow looks clean — the toolbar lives in
  the compact unified bar.
- Under `"default"` the shift appears more pronounced — the taller separate toolbar
  band + visible title make the movement read larger. Both are correct.

`trackingSeparator` is opt-in: omit it and toolbar items stay fixed regardless of
pane state. See [`docs/api-reference.md` → Toolbar (macOS)](#toolbar-macos) for
the full item API.

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
