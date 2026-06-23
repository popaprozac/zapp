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
| SwiftUI accessories **Sub-cycle 2b** — per-world toolbar | the toolbar renders in whichever world owns the content: SwiftUI `.toolbar` on the SwiftUI pane path (`toolbar.swift` `ZappToolbarContent`), `NSToolbar` on AppKit — behind one app-facing toolbar spec. Dynamic (`setItems`/`updateItem`/`remove`), no nav collapse, toggles drive `PaneState`. + an AppKit↔SwiftUI parity pass (launch-width, `titleBarStyle`, `toolbarStyle`, non-`sf:` icons, menu checkmarks). | ✅ Done (macOS) — deviations below |
| SwiftUI accessories **Sub-cycle 2c** — presentation + resize | sidebar/inspector **tile** parity (drop `.ignoresSafeArea`), style-conditional titlebar bleed, create-time pane geometry, and runtime width/resize/collapsible on the SwiftUI path (#660 — **hybrid**: declarative `@Published` resize-lock/collapsible + imperative reach-through width). Collapsible **divider-drag** gating shipped via an AppKit lock on the backing `NSSplitView` (#665); the sidebar toggle is app-rendered (remove-native + grey-when-locked, #668). | ✅ Done (macOS) — see *Pane control* below |
| SwiftUI accessories **Sub-cycle 3** — iOS | the same pane layout via `UIHostingController` — the adaptive payoff (iPhone sheet / iPad column); first checkpoint: `.inspector` sheet via `UIHostingController` | 🔜 |
| DOM-overlay native view | native view *inline anywhere* in web content (reuses `panel.m` geometry tracking) — "native, no ceremony" | 🔜 Spike |
| iOS native surface | `UIHostingController` + `swiftc` cross-compile so the native-surface pane works on iOS | 🔜 |
| App-authored native code | let app devs write their own Swift/native, Nim-style DX | 🌅 Later vision |

### Toolbar coexistence — the decision (Sub-cycle 2b, shipped)

A window can't half-share its title-bar toolbar between SwiftUI and a manual `NSToolbar`: when SwiftUI content uses `NavigationSplitView`/`.inspector`, **SwiftUI owns `window.toolbar` and re-asserts it on re-layout**, clobbering a foreign `NSToolbar` (an attempt to keep `NSToolbar` on the SwiftUI path *collapsed on navigation*; the `swiftui:false` AppKit build held, proving the cause). **Decision: the toolbar is rendered by whichever world owns the content** — SwiftUI `.toolbar` on the SwiftUI pane path, `NSToolbar` on the AppKit path — behind **one** app-facing toolbar spec (`ToolbarItemDef`; the same one-API/per-renderer pattern as the panes). The app describes its toolbar once; the framework renders it via the active path's toolbar system, routing actions back to the same handlers (`window:toolbar-clicked` → `TOOLBAR_CLICKED`). This is also the iOS toolbar path (SwiftUI `.toolbar` is the only coherent `NavigationSplitView` placement).

**SwiftUI renderer (`toolbar.swift`).** Items render as `ToolbarItemGroup` + `ForEach` over a stable-`id` array — the dynamic-update shape proven by `spikes/swiftui-dynamic-toolbar/`. Split at the first `flexibleSpace`: before → leading (`.navigation`), after → trailing (`.primaryAction`) — SwiftUI's placement is the native equivalent of AppKit's `flexibleSpace`+`trackingSeparator`. `updateItem` **merges** a partial patch (not whole-replace); `menu` items render the `checked` state; icons resolve `sf:`/path/`data:`. The host needs `NSWindowStyleMaskFullSizeContentView` (else the toolbar shifts on sidebar collapse).

**Parity matrix (AppKit established ↔ SwiftUI now).** Width (configured content size on both); `titleBarStyle` (title-hide + content-under honored on the SwiftUI path too); `toolbarStyle` (`unified`); non-`sf:` icons; menu checkmarks — all aligned.

**Documented deviations (inherent to the AppKit↔SwiftUI hosting seam):**
- **Hidden-title windows → flat (leading) toolbar on SwiftUI.** SwiftUI's `.navigation`/`.primaryAction` split needs the window title as a layout anchor; `titleBarStyle: hidden`/`hiddenInset`/Unset-sidebar hide it, so the split collapses (items pack leading). No reliable macOS-14 workaround (single-`ToolbarItem`+`HStack`+`Spacer` can't expand). AppKit's `flexibleSpace` is title-independent, so it still splits. **Decision: honor `titleBarStyle` (hide the title); accept the flat toolbar.** Revisited via the SwiftUI-window path (#644).
- **`trackingSeparator`** has no SwiftUI `.toolbar` item — dropped on the SwiftUI path; `NavigationSplitView` auto-aligns the column boundary (#638).
- **Sidebar `presentation` (overlay vs tile):** SwiftUI honors `overlay`; macOS AppKit tiles (#646).
- **Toolbar display style beyond `unified`** (`unifiedCompact`/`expanded` from `setItems`) defaults to `unified` on the SwiftUI path.
- **`toggleSidebar` position is SwiftUI-native (leading), not app-ordered, on the SwiftUI path.** AppKit renders the app's `toggleSidebar` item wherever it's declared; SwiftUI satisfies it with `NavigationSplitView`'s native auto sidebar toggle (always leading) and filters the app's explicit item out — `.toolbar(removing: .sidebarToggle)` leaked a duplicate across the `NSHostingController` seam, so we embrace the native toggle. Same "one spec, consistent outcomes" intent; only the toggle's *position* is the deviation.

The unifying principle (the **split-world anchor**): one app-facing spec, each platform-renderer uses its *native* mechanism; aim for consistent OUTCOMES, not identical internals — and document where the seam forces a divergence.

### Pane control — hybrid: declarative state + imperative width (Sub-cycle 2c / #660, shipped)

Runtime sidebar/inspector **resize-lock** and **collapsible** are **declarative and durable**; **width** is **imperative** (reach-through). This split is forced by a hard SwiftUI constraint discovered the hard way (#660):

> **`.navigationSplitViewColumnWidth` / `.inspectorColumnWidth` are initial-only at runtime.** SwiftUI honors the column-width modifier on first layout but **ignores changes to its `min`/`ideal`/`max` on an already-laid-out column** — so a declarative `setWidth` (mutating an `@Published` width the modifier reads) has *no visible effect*. Width can only be moved imperatively, via `NSSplitView setPosition` on the column's divider.

So the durable design is a hybrid in `native/platform/darwin/swift/panes.swift` + `sidebar.m` / `inspector.m`:
- **Resize-lock + collapsible — declarative `@Published`.** `sidebarResizable`/`collapsible` (+ inspector twins) drive the column modifier's range (`min==max==width` locks; `[min,max]` allows drag) and the `columnVisibility` / `.inspector(isPresented:)` binding-clamps. SwiftUI *does* re-apply these on relayout, so they survive collapse→expand (the headline durability win — the old imperative thickness-lock was transient).
- **Width — imperative reach-through.** `darwin_*_set_width` resolves the SwiftUI-backed `NSSplitView` (via `zapp_*_bind_swiftui`) and calls `setPosition` on the column's divider — within the resizable range. (Inspector uses `setPosition` on its *own* split, not a thickness re-pin: the re-pin wrote the same item-thickness property the declarative modifier re-asserts over, so it had no effect.) A `GeometryReader` (`WidthReader`) then captures the rendered width back into the `@Published` width so the value persists across relayout and feeds `setResizable(false)`'s lock-at-current.
- **Reverse parity:** `WidthReader` emits `window:sidebar-resized` / `window:inspector-resized` — the same events the AppKit `splitViewDidResize` path emits, on both user drag and programmatic change.

The AppKit branch (`swiftui:false`) keeps its own imperative reach-through throughout. The runtime TS API (`SidebarHandle`/`InspectorHandle`, `SidebarOptions`/`InspectorOptions`) is unchanged — it's the parity point. `setWidth` is a no-op while a pane is non-resizable (width moves only within the resizable range) — same on both paths.

**Pane collapsible semantics.** `collapsible: false` gates **user/system** collapse affordances only — the divider snap and SwiftUI's native sidebar toggle. Programmatic `collapse()`/`expand()`/`toggle()` and an app's own toolbar toggle button still work, on **both** the SwiftUI and AppKit paths (AppKit's `[item animator] setCollapsed:` ignores `canCollapse`). If you need a toggle button to also honor `collapsible: false`, gate it in app code.

**Divider-drag collapse gating (#665, shipped).** `collapsible: false` now blocks the **sidebar divider-drag collapse** cleanly on the SwiftUI path — but *not* via SwiftUI (`NavigationSplitView` ignores the column-width modifier, and the `columnVisibility` binding-clamp catches the drag only *after* a visual collapse → glitch). The working lever is at the AppKit layer: `SplitViewLocker` (an `NSViewRepresentable` in the sidebar subtree, driven by `state.sidebarCollapsible`) reaches `NavigationSplitView`'s real backing `NSSplitView` and locks the sidebar split item with `canCollapse = false` + `canCollapseFromWindowResize = false` + a hard `minimumThickness` floor (the divider physically can't cross it, so the collapse threshold is never reached). Dependency-free — proven in `spikes/swiftui-pane-control` (FINDINGS.md). The inspector divider is gated the same way via `canCollapse` on its split item.

**Sidebar toggle is app-rendered (#668, shipped).** The native auto sidebar toggle is removed via `.toolbar(removing: .sidebarToggle)` placed on the sidebar **content** (not the body — on the body it leaked a duplicate across the hosting seam) and the app's `toggleSidebar` item is rendered by `ZappToolbarContent` (toolbar.swift) like the inspector toggle: it drives `state.sidebarVisible` and is `.disabled` (greyed) when `sidebarCollapsible == false`. This closes three edges the native toggle caused: the escape-hatch (clicking the native toggle re-derived the split item and un-locked the #665 drag), the inability to grey it, and the toolbar `»` overflow on collapse. Polish follow-up: native standalone placement of the toggle (#643).

**Pane geometry is owned by one durable AppKit reach-through (#671/#672, shipped).** `SplitViewLocker` was generalized into `PaneGeometryLocker` — the single owner of the sidebar's backing `NSSplitViewItem` geometry, driven by `@Published PaneState` and **re-asserted on every relayout** (an `NSSplitView.didResizeSubviews` observer) so neither `NavigationSplitView` nor the column-width modifier can wipe it: `maximumThickness = resizable ? maxW : width` (hard clip — `maxWidth` now constrains content), `minimumThickness = resizable ? minW : width` (resize-lock + `minWidth` floor), `canCollapse = collapsible` (independent of the floor). The column-width modifier drops to a permissive creation-time hint. Initial width is set deterministically post-mount from `window.m` (`darwin_sidebar_set_width` snaps once the split lays out — the modifier's `ideal` is initial-only and NavigationSplitView estimates narrow while the webview mounts).

**SwiftUI chrome metrics (#670, shipped).** The pane path now re-injects `--zapp-titlebar-height` / `--zapp-toolbar-height` *after* the SwiftUI `.toolbar` renders (`window.m`, `else if (swiftUIToolbar)`), so `frame − contentLayoutRect` captures the full unified band — content no longer underlaps the toolbar, and the metrics match the AppKit path.

**Documented limit — collapse-gating decays after a content-only relayout (#673).** A route change that swaps a pane's DOM without resizing the split's subviews makes `NavigationSplitView` re-derive `canCollapse` back to `true`, and the resize observer can't see it — so `collapsible: false` can lapse until the next `@Published` re-enforce. This is **inherent to NavigationSplitView re-derivation** (the #644 real-scene spike was NO-GO: architecturally incompatible *and* wouldn't fix it). For guaranteed pane collapse/resize behavior, `native: { swiftui: false }` (real `NSSplitViewController`) is the rock-solid path; the SwiftUI path trades this for `.toolbar` titlebar integration.

### Sub-cycle 1 known limitations (→ Sub-cycle 2)

- **Toolbar glitch:** in the SwiftUI pane path, SwiftUI's auto toggles + ownership of `window.toolbar` clobbered the app's `NSToolbar`. **Resolved in 2b** by the per-world toolbar above (SwiftUI `.toolbar` owns the SwiftUI path).
- **Sidebar presents as overlay:** `.navigationSplitViewStyle(.balanced)` did not force tiling — needs `columnVisibility`/explicit column width (folds into the presentation-styles work; the overlay-vs-tile AppKit↔SwiftUI gap is #646).
- **Runtime pane control not wired** — *resolved:* visibility in Sub-cycle 2a; width/resize/`setCollapsible`/`setResizable` parity in Sub-cycle 2c via the declarative `@Published` `PaneState` rewrite (#660, see *Pane control* above) — the old `ZAPP_LOG` no-op reach-through is gone. Tiling shipped in 2c (drop `.ignoresSafeArea`).
- **Per-platform sidebar defaults to document:** macOS tiles; iOS sidebar overlays — to be exposed as cross-platform `presentation` styles.

## Anchors

1. **Tiering.** AppKit/UIKit = always-present baseline; SwiftUI = selective enhanced tier
   for enhanced or net-new modern Apple views.
2. **Reversibility.** The tech-agnostic surface API lets the SwiftUI-vs-AppKit policy shift
   over time without breaking callers.
3. **Compile-time gating + graceful fallback.** A feature compiles into the SwiftUI path
   only where its OS floor is met; otherwise it falls back to the imperative path
   automatically, and apps can opt out entirely (`native: { swiftui: false }`).
