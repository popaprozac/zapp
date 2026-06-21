# SwiftUI dynamic-toolbar spike — FINDINGS

**Context:** 2b (per-world toolbar, macOS). The earlier Strategy-A attempt kept
`NSToolbar` on the SwiftUI pane path and it **collapsed on navigation** — root cause:
on the SwiftUI pane path SwiftUI *owns* `window.toolbar` and re-asserts it on every
re-layout, clobbering a foreign `NSToolbar` (confirmed: the AppKit `swiftui:false`
build holds the full toolbar across navigation; only the SwiftUI path collapses).

So on the SwiftUI pane path the toolbar **must** be SwiftUI-owned (`.toolbar`).
This spike de-risks the thing that sank the first Strategy-B attempt: **dynamic items.**

## Verdict: GO ✅

A SwiftUI `.toolbar` driven by an external `@Published` item array (proxy for Zapp's
router pushing `setItems`/`updateItem`/`remove`) **survives both** navigation re-layout
and dynamic mutation without dropping items — confirmed by human visual gate
(2026-06-21).

## What works

- **No collapse on navigation.** Because SwiftUI owns the toolbar and redraws it every
  layout, there is nothing for a re-layout to clobber. This is the decisive win over
  Strategy A.
- **Dynamic mutation is clean:** setItems (2↔4), updateItem (label/icon + enabled),
  remove-all → re-add — all reflect exactly, no dropped items, no leftovers, no flicker.
- **`.toolbar(removing: .sidebarToggle)` sticks** across navigation + mutation (it did
  NOT stick on the Strategy-A NSToolbar path).

## Key build-time constraint

You **cannot** `ForEach { ToolbarItem }` — `ForEach`'s content is a `@ViewBuilder`, so it
must yield Views, not `ToolbarContent`. The only dynamic shapes are a `ForEach` of
*Views* inside:
- **`ToolbarItemGroup`** ← preferred (idiomatic; proper per-item spacing/overflow), or
- a single **`ToolbarItem` holding an `HStack`** (works with `.fixedSize()`, but crams
  buttons into one item — fallback only).

Both passed the gate. **Use `ToolbarItemGroup` + `ForEach` over a stable-`id` Identifiable
array** as the renderer shape.

## Implications for the full implementation (beyond the spike)

The spike covered homogeneous buttons. The real Zapp toolbar is heterogeneous — the
renderer must map each `ToolbarItemDef` type to SwiftUI:

| Zapp item            | SwiftUI mapping |
|----------------------|-----------------|
| `button`             | `Button { } label: { Label(label, systemImage:) }` (+ `.disabled`) |
| `menu` (pull-down)   | `Menu { … }` (checkmarks via item state) |
| `toggleSidebar`      | `Button` → toggles `PaneState.sidebarVisible` |
| `toggleInspector`    | `Button` → toggles `PaneState.inspectorPresented` |
| `flexibleSpace`      | **placement split**: items before → `.navigation` (leading) group; items after → `.primaryAction` (trailing) group. SwiftUI toolbars position by placement, not explicit spacers. |
| `space` (fixed)      | no clean SwiftUI equivalent — likely drop or approximate |
| `trackingSeparator`  | **drop** on the SwiftUI path (no `NSSplitView` to bind; ties to #638) |

`flexibleSpace → placement split` is the main design decision for the real renderer.
