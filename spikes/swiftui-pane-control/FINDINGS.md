# SwiftUI pane-control spike — FINDINGS (2c risk gate)

**Question:** can the SwiftUI `NavigationSplitView` path (macOS) support the
runtime sidebar controls that AppKit already has — `setWidth(px)`,
`setResizable(bool)`, and `presentation: tile|overlay` — given SwiftUI exposes
column *bounds* (`min/ideal/max`), not imperative setters?

**Principle (user direction 2026-06-21):** where SwiftUI/macOS can't match the
AppKit behavior exactly, we ship the achievable part and **document the
deviation** (same approach as the 2b toolbar seam).

**Design target — Messages.app (user reference 2026-06-21):** the macOS Messages
sidebar is **forced-tiled** — as the window narrows it **shrinks to a minimum
width (breakpoint), it does not overlay or fully collapse**. So "tile" for Zapp =
a persistent column clamped to `[min, max]` that never overlays/collapses; the
mechanism is a **window minimum size** (≥ sidebar.min + content.min) so the
column can't be squeezed past `min`. "overlay" = the current SwiftUI default
(floats over content at narrow widths). The probe sets a window min-size to test
this directly.

Build: `./build.sh` → `./build/macos/spike`. Drive every control from the
detail-pane panel; watch the teal sidebar column.

## Verdict — PARTIAL GO (human visual run 2026-06-22)

The 2c core is achievable on the SwiftUI path: **exact-width set works**,
**forced-tile (Messages-style) works via a window min-size**, and
**collapsible must be a distinct control** (it's independent of width/lock). Two
SwiftUI limitations get **documented deviations** (lock can't capture a live
user-dragged width; `NavigationSplitViewStyle` is not the tile/overlay lever on
macOS), plus a few quirks to mitigate. Build 2c.

## #665 follow-up — divider-drag collapse gating (human visual run 2026-06-22)

**Question:** can `collapsible:false` stop the SIDEBAR divider-drag collapse on the
SwiftUI path? The hybrid (`NSHostingController`) glitches (visual collapse → snap
back). Hypothesis: a REAL SwiftUI Scene would gate it cleanly → would validate #644.

**Experiment:** added section (4) to the probe — a `columnVisibility` binding clamp
that refuses `.detailOnly` when collapsible is OFF (the SAME mechanism Zapp ships in
the hybrid), but here inside a real `WindowGroup`/`App` Scene. Toggle collapsible
OFF, drag the divider past min.

**Result — (b) GLITCH.** The clamp behaves IDENTICALLY in a real Scene: the column
visually collapses mid-drag, then snaps back (the `blocked` counter climbs, proving
the drag reaches the threshold and the clamp fires). **The host is not the variable.**

**Verdict (clamp):** #644 (real SwiftUI Scene) does NOT fix sidebar divider-drag
gating via the clamp. The clamp is a post-hoc catch — NavigationSplitView collapses
visually before any binding setter can intervene, regardless of hosting. Dead.

## #665 RESOLVED — AppKit lock on the backing NSSplitView (human visual run 2026-06-22)

**The win.** Reach NavigationSplitView's REAL backing `NSSplitView` and lock the
sidebar split ITEM with the full combination:

```swift
sidebarItem.canCollapse = false
if #available(macOS 14.0, *) { sidebarItem.canCollapseFromWindowResize = false }
sidebarItem.minimumThickness = minW          // hard floor — divider can't reach collapse
```

**Result — CLEAN. No collapse, no glitch.** The divider bottoms out at `minW` and
will not collapse. Toggling collapsible back ON restores normal drag/collapse. This
is the lever every SwiftUI-level approach missed: `minimumThickness` is a HARD floor
the divider physically can't cross, so the collapse threshold is never reached —
categorically different from `canCollapse` alone (flaky on macOS 26.x) and from the
SwiftUI `.navigationSplitViewColumnWidth` modifier (ignored for the drag).

**Why prior attempts failed:** they set `canCollapse` alone (no `minimumThickness`
floor) and/or were one-shot (NavigationSplitView re-derives the item after layout).
The probe applies the lock from inside the SwiftUI view tree via an
`NSViewRepresentable` (`SplitViewLocker`) whose `updateNSView` re-fires on every
@Published change + delayed re-apply, so the lock survives re-derivation.

**Dependency-free.** `swiftui-introspect` is only a view-finder; the probe uses a
manual superview-walk / contentView-descend (and Zapp already ships
`zapp_find_split_view` for the width reach-through). No new dep required.

**Known side effect:** `canCollapse=false` makes macOS HIDE the SwiftUI sidebar
toggle button entirely (not grey it). Arguably correct (non-collapsible ⇒ no toggle),
but if a visible-but-disabled toggle is wanted, that's a separate follow-up spike
(app-render the sidebar toggle like the inspector toggle, via `.toolbar(removing:
.sidebarToggle)` + custom button).

**Production path:** port `SplitViewLocker` into `panes.swift`, mount on the sidebar
PaneHost, bound to `state.sidebarCollapsible` + `state.sidebarMinW`, gated on
ZAPP_HAS_SWIFTUI. The @Published-driven SwiftUI update cycle handles re-derivation.

## Probe results (original 2c)

| Probe | Mechanism | Result |
|---|---|---|
| (1) setWidth(px) — pin to exact width | bind `min == ideal == max == px` | ✅ column jumps to the exact width and holds. Side effects: still collapsible (width ≠ collapse — expected); not draggable while pinned (min==max — that's the lock). |
| (2) setResizable(false) — lock | pin `min == max == ideal` | ⚠️ stops the drag, BUT **snaps to the @State `ideal` (~260)**, not the user's live-dragged width — SwiftUI doesn't report the live column width back, so "lock at the *dragged* width" is impossible. Locking at an **app-set** width works. |
| (2) setResizable(true) — unlock | restore `min 180 / max 480` | ✅ divider drags again after unlock. |
| (3) presentation — tile vs overlay | `.navigationSplitViewStyle(...)` toggle | ❌ style (`automatic`/`balanced`/`prominentDetail`) made **no visible difference** — it is NOT the tile/overlay lever on macOS. |
| (3b) forced tile (Messages-style) | window min-size (`minW + 360`) | ✅ narrowing the window **bottoms out at a min width and does NOT auto-collapse/overlay** — the window min-size is the real forced-tile mechanism. |

## Notes / gotchas (→ design implications)

- **`setCollapsible(true|false)` is a required, distinct control.** Locked OR
  unlocked, at any width, the sidebar can still be collapsed (toggle + buttons).
  Width/resize do not gate collapse. Implement collapsible by clamping the
  `columnVisibility` binding (refuse `.detailOnly` when non-collapsible) **and**
  removing the titlebar sidebar toggle (`.toolbar(removing: .sidebarToggle)`).
- **Tile vs overlay = window min-size, not style.** "tile" (Messages) = set a
  window minimum ≥ sidebar width + content min so it can't be squeezed to
  overlay/collapse. "overlay" = the default (no/low min). The
  `NavigationSplitViewStyle` knob is a no-op for this and won't be exposed.
- **DEVIATION — lock preserves the *app-set* width, not a live drag.** SwiftUI
  doesn't surface the user's dragged column width, so `setResizable(false)` locks
  at the last programmatic width (e.g. a `setWidth` value or the configured
  width), not wherever the user last dragged. Document it.
- **Quirk — drag-to-max then narrow → sidebar overflows left** (Image 1): if the
  user drags to `max` (480) and then narrows the window, the column overflows
  past the window's left edge. Pinning the width (setWidth 440) then narrowing is
  clean (Image 2). Mitigation: the forced-tile window min-size must track the
  *effective* (or max) sidebar width, not just `min`, so the window can't narrow
  below `effectiveSidebarWidth + contentMin`.
- **Quirk — re-expand after collapse grows the window** when the width is pinned
  (`min==max==440`): expanding from collapsed forces the window wider to fit the
  pinned column. Mitigation: same min-size accounting / relax the pin on collapse.
- **Animation gap — collapse/show + the titlebar toggle do NOT animate** in the
  spike (the `withAnimation { columnVisibility = … }` button didn't animate).
  2a's runtime toggles DO animate via `zapp_swift_panes_toggle_*` (withAnimation
  at the @_cdecl) — so verify/ensure the real 2c path animates; if the
  binding-driven change won't animate, route collapse through the proven 2a
  toggle path.
