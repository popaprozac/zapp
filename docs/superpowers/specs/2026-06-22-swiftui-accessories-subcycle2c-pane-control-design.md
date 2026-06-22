# SwiftUI Accessories Sub-cycle 2c — pane presentation + resize/collapse parity (macOS)

**Date:** 2026-06-22
**Branch:** `feat/nim-native` (unmerged)
**Status:** Approved-in-principle (probe done); spec under review

## Goal

Bring the SwiftUI pane path (macOS `NavigationSplitView`/`.inspector`) to **parity
with the AppKit path** for sidebar/inspector **width**, **resize lock**,
**collapsible**, and **presentation (tile/overlay)** — so the **end-user API is
identical whether `native.swiftui` is on or off**, and the *result* matches too.
Where SwiftUI genuinely can't match AppKit, ship the achievable part and
**document the deviation** (user steer 2026-06-22).

**Framing:** SwiftUI is the **enhanced, multiplatform** tier (its real payoff is
iOS/iPad adaptivity); AppKit is the functional baseline. The sidebar/main/
inspector(+toolbar) shell is the one place we hard-match both API and result
across the two. (Separate open question: flip `native.swiftui` default → false —
see `memory project_swiftui_default_reconsider`. Not part of 2c.)

## Background

- **AppKit path already does all of this** (`darwin_sidebar_*`/`darwin_inspector_*`
  in `sidebar.m`/`inspector.m`: `setPosition` for width, min/max thickness for
  resize, `NSSplitViewItem.canCollapse`, create-time geometry). Those ops are
  **no-op-with-log on the SwiftUI path** (the 2a deferral) — that's the gap.
- **Probe (`spikes/swiftui-pane-control/`, FINDINGS = PARTIAL GO):** the
  pure-SwiftUI approach (drive `min/ideal/max` + `columnVisibility` + a window
  min-size from `@State`) is **limited** — `setWidth` must *pin* (`min==max`,
  which disables drag), lock can't capture a live user-dragged width, and the
  window-min-size forced-tile has overflow/grow quirks.
- **Research (donnywals / swiftui-introspect / Apple forums):**
  `.toolbar(removing:.sidebarToggle)` only **hides the button**; true
  non-collapsible + Messages-style forced-tile live on the underlying
  **`NSSplitViewItem`**: `canCollapse = false` + `canCollapseFromWindowResize =
  false`. On macOS a SwiftUI `NavigationSplitView` is **backed by a real
  `NSSplitViewController`**.
- **Zapp's advantage:** the SwiftUI panes are hosted in an `NSHostingController`
  (the 2a/2b seam), so Zapp can **reach that underlying `NSSplitViewController`
  natively — no third-party introspect lib** — and **reuse the existing AppKit
  `darwin_*` control primitives**. This is the path to *true* parity with minimal
  new code.

## Approach — reach-through (primary), SwiftUI-native (fallback)

**Primary (reach-through):** resolve the embedded `NSSplitViewController` from the
SwiftUI pane window's `NSHostingController`, cache it on the window delegate (like
`swiftPaneState`), and **un-no-op the `darwin_sidebar_*`/`darwin_inspector_*` ops
on the SwiftUI path to operate on that real split view** — reusing the AppKit
logic. Each control maps to a documented `NSSplitViewItem`/`NSSplitView` API:

| Control | Reach-through mechanism (reuse AppKit) |
|---|---|
| `setWidth(px)` | `NSSplitView setPosition:ofDividerAtIndex:` (clamped to min/max) — true imperative width, still draggable |
| `setResizable(false/true)` | lock/restore `NSSplitViewItem.min/maximumThickness` |
| `setCollapsible(false/true)` | `NSSplitViewItem.canCollapse` + remove the SwiftUI toolbar toggle when non-collapsible |
| `presentation: tile` (Messages) | `NSSplitViewItem.canCollapseFromWindowResize = false` (won't collapse/overlay as the window narrows) |
| `presentation: overlay` | default (`canCollapseFromWindowResize = true`) |
| create-time width/min/max/collapsed | apply to the resolved `NSSplitViewItem` at construction |

**The risk (must gate):** SwiftUI *owns* that `NSSplitViewController` and may
**re-assert/clobber** our settings on re-layout — the exact failure mode that
killed 2b Strategy A (SwiftUI re-asserted `window.toolbar`). So 2c **leads with a
reach-through risk gate**.

**Fallback (SwiftUI-native):** if the gate shows SwiftUI clobbers the AppKit
settings, fall back to the probe's `@State`-driven approach (`min/ideal/max` +
`columnVisibility` + window min-size) and **document the deviations** (setWidth
pins/disables drag; lock is app-set-width only; style is not the lever; overflow/
grow quirks mitigated by effective-width-aware min-size).

## Decomposition

- **T1 (RISK GATE, human visual):** in the SwiftUI pane window, resolve the
  embedded `NSSplitViewController` from the `NSHostingController` (walk child VCs);
  apply `canCollapse=false`, `canCollapseFromWindowResize=false`, a `setPosition`
  width, and locked min/max thickness; **verify they STICK** across nav changes,
  sidebar toggle, and window resize (narrow↔wide). GO → reach-through; NO-GO →
  SwiftUI-native fallback. *(This is the go/no-go for the whole approach.)*
- **T2:** resolve + cache the `NSSplitViewController`/`NSSplitViewItem`s on the
  window delegate at SwiftUI-pane construction; un-no-op
  `darwin_sidebar_set_width/collapsible/resizable` + inspector on the SwiftUI path
  to operate on it (reuse the AppKit bodies). Re-apply on clobber if needed.
- **T3:** create-time geometry (width/min/max/collapsed) on the resolved split;
  `presentation` tile/overlay via `canCollapseFromWindowResize`; `setCollapsible`
  via `canCollapse` + toolbar-toggle removal; route collapse through the proven
  2a animated toggle.
- **T4:** docs (parity matrix + any deviations in `native-ui-strategy.md` +
  api-reference) + kitchen-sink wiring (Messages-style forced-tile +
  non-collapsible showcase) + build matrix (macOS-on, swiftui:false, iOS-sim,
  `bun test`) + human visual smoke.

## Scope

**In scope:** macOS SwiftUI pane path — `native/platform/darwin/window.m`
(resolve/cache the split), `sidebar.m`/`inspector.m` (un-no-op the SwiftUI
branches), `panes.swift` (create-time bounds + toolbar-toggle removal when
non-collapsible), docs, kitchen-sink.

**Out of scope / untouched:** the AppKit path (already correct); iOS (its
sidebar/inspector presentation is already handled via `UISplitViewController`);
the runtime `SidebarHandle`/`InspectorHandle` TS API (unchanged — that's the
parity point); `WindowOptions` shape (unchanged).

## Deviations (documented per user steer)

To be finalized after T1, but anticipated:
- If reach-through holds: **near-full parity** (the win). Any residual (e.g. a
  control SwiftUI re-clamps) is documented.
- If fallback: the probe's documented set — `setWidth` pins (not draggable until
  `setResizable(true)`); lock is app-set-width only; `NavigationSplitViewStyle`
  not exposed; forced-tile via window min-size with effective-width mitigation.

## Testing

- **T1 human visual gate** (settings stick across nav + toggle + window resize).
- Build matrix: Nim macOS (`[zapp] build complete:` last line), swiftui:false
  (AppKit unchanged), iOS-sim, `bun test cli/src`.
- **Human smoke:** kitchen-sink — non-collapsible sidebar (no toggle, won't
  collapse on narrow), forced-tile shrink-to-min (Messages), `setWidth` to exact
  px, lock/unlock resize, inspector parity. Compare swiftui:true vs swiftui:false
  → same end result.

## Risks

- **SwiftUI clobber** (primary risk) — gated by T1; fallback ready.
- **Undocumented reach-through** — reaching SwiftUI's internal
  `NSSplitViewController` is introspection; could shift across macOS versions.
  Mitigation: resolve defensively (nil-guard the walk; fall back to SwiftUI-native
  if not found), and this fragility is itself an input to the swiftui-default
  reconsideration.
