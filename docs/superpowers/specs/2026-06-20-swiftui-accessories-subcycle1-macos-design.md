# SwiftUI-backed accessories — Sub-cycle 1 (macOS pane layout) — Design

**Date:** 2026-06-20 · **Branch:** `feat/nim-native` (do not merge to main) · **Track:** Apple-only

## Where this sits

The "SwiftUI-backed accessories" feature gives Zapp's sidebar/inspector accessories real
SwiftUI containers (`NavigationSplitView` / `.inspector`) on capable OS so iPad/iPhone get
true size-class adaptivity (the auto column↔bottom-sheet inspector UIKit can't do), with the
existing AppKit/UIKit impls as graceful fallbacks. The risk spike came back **GO**
(`spikes/swiftui-webview-inspector/FINDINGS.md`): a `WKWebView` keeps its bridge inside a
SwiftUI representable, and `.inspector` adapts.

The feature is decomposed into sub-cycles, each its own spec→plan→build:

- **Sub-cycle 1 (THIS spec) — macOS pane layout.** The SwiftUI pane layout hosting the real
  webviews on macOS, selected automatically for accessory'd windows, AppKit fallback. The
  risk-bearing foundation: prove the real, fully-integrated webviews survive the SwiftUI host
  in-app. (macOS gains little user-visibly — AppKit already does columns — but it de-risks
  the re-plumb in the easiest environment.)
- **Sub-cycle 2 — iOS.** The same pane layout via `UIHostingController`, where `.inspector`
  delivers the adaptive payoff (iPhone sheet / iPad column). First checkpoint: confirm
  `.inspector`'s iPhone-sheet adaptivity works when hosted via `UIHostingController` (the
  spike proved it via a full SwiftUI `App`).
- **Sub-cycle 3 — polish/parity.** Toolbar `trackingSeparator` alignment with the SwiftUI
  split; chrome-metrics (KVO inset) re-plumb; sidebar/inspector runtime collapse/resize API
  parity in the SwiftUI path; the default-on decision.

## Goal (Sub-cycle 1)

On macOS 14+, an **accessory'd window** (one that declares a sidebar and/or inspector) builds
its sidebar/content/inspector arrangement via a **SwiftUI pane layout** (`NavigationSplitView`
+ `.inspector`) hosting Zapp's **real** webviews, instead of today's `NSSplitViewController`.
Prove the real webviews (assets via the `zapp://` scheme handler, the `"zapp"` bridge,
devtools) survive the SwiftUI host, at AppKit parity (sidebar + resizable inspector column).

## Selection — automatic, no new knob

A window resolves to the SwiftUI pane layout when **all** hold:
- it is **accessory'd** — `hasSidebar || hasInspector` (a plain window has nothing to adapt →
  stays AppKit, untouched), AND
- the OS supports it — `@available(macOS 14, *)` (Sub-cycle 1 floor), AND
- the app hasn't opted out — `native.swiftui != false`.

Otherwise it uses today's AppKit `NSSplitViewController` path (the automatic fallback).

There is **no per-window option and no dev/env flag.** The only knob is the existing
app-level **`native.swiftui: false`** (shipped in the native-surface cycle), which *also*
serves as the compile gate: when false, `swiftc` is skipped and `ZAPP_HAS_SWIFTUI` /
`-d:zappSwiftUI` aren't defined, so the SwiftUI-panes code isn't compiled in and the
construction `#ifdef`s out to AppKit. This keeps the opt-in forward-compatible — "default to
SwiftUI when capable" is already the behavior; later sub-cycles only raise capability (iOS)
and add polish, never an API migration.

## Scope boundary (the rabbit hole is shallow)

SwiftUI owns **only the window's content subtree** — the sidebar/content/inspector pane
layout. Everything else stays AppKit and is unchanged:

| Stays AppKit (unchanged) | Becomes SwiftUI |
|---|---|
| `NSApplication` / app lifecycle / run loop (Nim-driven) | — |
| `NSWindow` (still created by window.m); title bar; traffic lights; styleMask | — |
| `NSToolbar` (attaches to the NSWindow, above the content) | — |
| Tray / menu bar / dock / `NSPopover` / context menus | — |
| — | The sidebar + content + inspector **pane layout** (`NavigationSplitView` / `.inspector`) hosting the real webviews via `NSViewRepresentable` |

We do **not** convert the app or the window to SwiftUI; we host a SwiftUI *view tree* in the
window's `contentView` via `NSHostingView`.

## Components

### `native/platform/darwin/swift/panes.swift` (new, auto-compiled by the existing `swiftc` step)

- A `WKWebView` → SwiftUI **representable** (`NSViewRepresentable` wrapping a *passed-in*
  webview — we host the existing webview so its config-level bridge survives, per the spike).
- The **pane-layout view**: `NavigationSplitView { sidebarPane } detail: { contentPane
  .inspector(isPresented:) { inspectorPane } }`, building only the panes that exist (content
  always; sidebar/inspector when present).
- An **`@_cdecl`** entry, e.g. `zapp_swift_panes_create(content:, sidebar:, inspector:,
  showInspector:) -> NSView*` (passed-in `WKWebView`s as `NSView*`; nil for absent panes),
  returning an `NSHostingView` for the window's `contentView`.

Lives in `native/platform/darwin/swift/` alongside `native_surface.swift` — one file per
SwiftUI surface (the directory is the "all the SwiftUI" answer; files are named by surface,
no `swiftui_` prefix). A shared `webview_representable.swift` is factored out only when a
second surface needs it (YAGNI until the DOM-embed cycle).

### `native/platform/darwin/window.m` (modify — the construction fork)

At window construction, where it builds the `NSSplitViewController` for accessory'd windows:
- Compute `useSwiftUIPanes = (useSidebar || useInspector)` AND `@available(macOS 14, *)` AND
  `#ifdef ZAPP_HAS_SWIFTUI` (compiled in ⇔ not opted out).
- When `useSwiftUIPanes`: create the pane webviews exactly as today (so each pane's
  config-level `"zapp"` bridge + `zapp_register_pane_webview` routing/slot bookkeeping is
  intact), then assemble them via `zapp_swift_panes_create(...)` and set the result as the
  window's `contentView` — *instead of* the `NSSplitViewController`.
- Else: today's `NSSplitViewController` path, unchanged.
- A `getenv("ZAPP_LOG")` debug line reports which layout was chosen.

### Nim (minimal)

No public `WindowOptions` field. A small internal resolver/getter if needed by window.m is
ObjC-local (the `@available` + `#ifdef` checks live in window.m). The existing
`native.swiftui` config + `ZAPP_HAS_SWIFTUI` define are reused as-is.

### kitchen-sink

Its existing sidebar+inspector main window automatically becomes the smoke target on
macOS 14 (no app change needed). It must render identically (sidebar + content + inspector)
via the SwiftUI layout, and visibly unchanged when run with `native: { swiftui: false }`.

## Data flow

1. window.m builds an accessory'd window; the gate resolves `useSwiftUIPanes`.
2. It creates the content/sidebar/inspector `WKWebView`s as today (bridge + registration
   intact).
3. SwiftUI path: hand the webviews to `zapp_swift_panes_create` → `NSHostingView` →
   `window.contentView`. AppKit path: today's `NSSplitViewController`.
4. The webviews load the app (scheme handler), the bridge round-trips, events route — all
   independent of which host wraps them.

## Error handling / fallback

- Opted out (`native.swiftui:false`) → `swiftc` skipped, `ZAPP_HAS_SWIFTUI` undefined → the
  SwiftUI branch `#ifdef`s out → AppKit. (Compile-gated; no runtime swift symbols.)
- macOS < 14 → `@available` false → AppKit. (Runtime-gated.)
- Plain window (no accessories) → AppKit (unchanged).
- The window always renders: AppKit is the guaranteed floor.

## Testing

- **Build gates:** macOS (default) links the `panes.swift` symbol + builds clean; the opted-out
  build (`native.swiftui:false`) builds clean with no swift; iOS-sim still builds (macOS-only
  change). `bun test cli/src` green.
- **Human visual smoke (macOS 14):** the kitchen-sink window renders sidebar + content +
  inspector via SwiftUI; assets load; a **real Zapp service call round-trips**; devtools open;
  inspector is a resizable column; title bar / traffic lights / toolbar intact. With
  `native: { swiftui: false }` (then reverted) the window is identical to today (AppKit).
- No unit tests for the native UI itself — build + visual smoke is the established gate.

## Non-goals (later sub-cycles)

- iOS (Sub-cycle 2 — the adaptive payoff + the `UIHostingController` sheet checkpoint).
- Auto-default policy beyond "accessory'd + capable + not opted out" (already the behavior).
- Toolbar `trackingSeparator` alignment with the SwiftUI split (Sub-cycle 3 polish).
- Chrome-metrics (KVO inset) re-plumb (Sub-cycle 3).
- Sidebar/inspector runtime collapse/resize/width APIs in the SwiftUI path — basic render
  only this sub-cycle; runtime-control parity is a noted Sub-cycle 3 follow-up.
- Windows/Linux.
