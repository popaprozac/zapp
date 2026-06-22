# SwiftUI pane-control spike — FINDINGS (2c risk gate)

**Question:** can the SwiftUI `NavigationSplitView` path (macOS) support the
runtime sidebar controls that AppKit already has — `setWidth(px)`,
`setResizable(bool)`, and `presentation: tile|overlay` — given SwiftUI exposes
column *bounds* (`min/ideal/max`), not imperative setters?

**Principle (user direction 2026-06-21):** where SwiftUI/macOS can't match the
AppKit behavior exactly, we ship the achievable part and **document the
deviation** (same approach as the 2b toolbar seam).

Build: `./build.sh` → `./build/macos/spike`. Drive every control from the
detail-pane panel; watch the teal sidebar column.

## Verdict

_(fill after human visual run)_ — GO (full) / PARTIAL (achievable parts +
documented deviations) / NO-GO.

## Probe results

| Probe | Mechanism | Result |
|---|---|---|
| (1) setWidth(px) — pin to exact width | bind `min == ideal == max == px` to @State | _TBD_ — does the column jump there cleanly + survive re-layout? |
| (2) setResizable(false) — lock drag | pin `min == max == current` | _TBD_ — does the divider stop dragging? unlock restores? |
| (2) setResizable(true) — unlock | restore `min 180 / max 480` | _TBD_ |
| (3) presentation — tile vs overlay | `.navigationSplitViewStyle(.automatic/.balanced/.prominentDetail)` × `columnVisibility` × window width | _TBD_ — which combo tiles (pushes content) vs overlays (floats)? Is it controllable, or window-width-driven only? |

## Notes / gotchas

_(fill in: animation behavior on pin, whether min==max truly disables the drag
handle, what actually controls overlay vs tile on macOS, and any
NavigationSplitView quirks that force a documented deviation.)_
