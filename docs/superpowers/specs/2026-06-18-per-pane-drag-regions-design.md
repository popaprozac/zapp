# Per-Pane Window Drag Regions (sidebar / inspector) — Design

**Status:** DESIGNED — 2026-06-18. Make `data-zapp-drag-region` work in sidebar
and inspector panes (not just the main pane) so the full-bleed sidebar-chrome
window can be dragged from its whole top edge, like a native macOS sidebar app.
Router-only fix (nim + zc) + a kitchen-sink demo.

## Background: why native drag doesn't work on the main window

The kitchen-sink main window uses the sidebar-app chrome — `FullSizeContentView`
+ hidden title + transparent titlebar. The WKWebView panes extend edge-to-edge,
**covering the title-bar zone**, so the web content intercepts mouse events there
and AppKit's built-in title-bar drag never receives them — the window can't be
moved. (Secondary windows launched at runtime use a normal/unified title bar with
a real native title-bar strip, which AppKit drags for you — so they don't have
this problem.) Zapp's substitute is the `data-zapp-drag-region` feature: an
element marked with it sets the webview's `inDragRegion`, and on mousedown the
view's `mouseDownCanMoveWindow` / `performWindowDragWithEvent:` drags the window.

## Problem

`data-zapp-drag-region` works in the **main** pane but NOT in the sidebar or
inspector panes — so the top of those panes (a large part of the window's top
edge) can't drag the window. Root cause (`native/nim/router.nim` /
`native/app/router.zc`):

- A pane's bootstrap posts `{t:4, m:"setDragRegion", a:{drag}}` (panes DO run the
  same webview bootstrap, incl. drag-tracking — `darwin_webview_create_ext`
  injects `zapp_webview_bootstrap_script()` into every pane).
- But `routeWindowAction` handles `setDragRegion` **after**
  `let windowId = resolveAccessoryHost(rawWindowId)`, which remaps a pane's
  transport slot → the **host** window id. So `darwin_webview_set_drag_region(
  windowId)` → `darwin_window_get_webview(hostId)` → the **main** webview, and
  the sidebar/inspector webview's own `inDragRegion` is never set.

Each pane is its own `ZappWebView` NSView with its own `mouseDownCanMoveWindow`,
so the drag flag must be set on the *pane's* view, not the host's main view.

## Decision: route `setDragRegion` by the sender's own slot

Handle `setDragRegion` with the sender's **own** slot (`rawWindowId`), **before**
the `resolveAccessoryHost` remap — exactly as `subscribe`/`unsubscribe`/`ready`
already do (they intentionally keep the sender's slot). Then
`darwin_webview_set_drag_region(rawWindowId, drag)` →
`darwin_window_get_webview(senderSlot)` → the pane's own webview (verified:
`darwin_window_get_webview` indexes `zapp_webviews[numeric_id]`, and panes
register their webviews under their own slot ids), whose `mouseDownCanMoveWindow`
then drags the window.

**Correctness for the main pane:** the main pane's `rawWindowId` IS the host
window id (its webview is registered at the window's id), so using `rawWindowId`
resolves to the main webview — identical to today. So the move fixes sidebar +
inspector without changing main-pane behavior.

### What changes

- **`native/nim/router.nim`:** move the `setDragRegion` arm above
  `let windowId = resolveAccessoryHost(rawWindowId)` and call
  `darwin_webview_set_drag_region(rawWindowId.int32, …)` (sender slot). It joins
  the small set of sender-slot-preserving actions (subscribe/unsubscribe/ready).
- **`native/app/router.zc`:** the identical move for the zc build (parity — same
  symmetric one-arm relocation). Both builds compile `webview.m` + share the
  window-action router shape.
- **No native change** — `darwin_webview_set_drag_region` already resolves the
  slot via `darwin_window_get_webview`; it just needs the right (sender) slot.
- **No bootstrap change** — panes already post `setDragRegion` from the shared
  drag-tracking bootstrap; the toggle simply lands on the right view now.

### Kitchen-sink demo

Add a `data-zapp-drag-region` title-bar-height strip to the **sidebar** and
**inspector** pane HTML, matching the main-pane strip already shipped
(`d79e653`). Net effect: the entire top edge of the kitchen-sink window
(sidebar + main + inspector) drags the window — full native sidebar-app feel.
Keep the traffic-light inset consideration where a pane reaches the window's
top-left (the sidebar pane does); the inspector (trailing) does not.

## Components

- `native/nim/router.nim` — relocate the `setDragRegion` arm (sender slot).
- `native/app/router.zc` — same relocation (parity).
- `kitchen-sink/src/shell/...` (sidebar + inspector pane render) + `style.css` —
  add the drag strip to those panes (reuse the `.drag-strip` style from the
  main-pane work; READ where each pane's HTML is rendered).

## Testing

- Build both: nim kitchen-sink + zc kitchen-sink → `[zapp] build complete:`.
- `bun run check` (tsc) for the kitchen-sink web edits.
- Manual smoke (human gate): in the nim kitchen-sink, drag the window by the
  **sidebar** top strip AND the **inspector** top strip (and the main strip) —
  the window moves in all three. Interactive controls in those panes still click
  (auto no-drag).

## Parity note

Both `router.nim` (nim) and `router.zc` (zc) get the identical fix — no
divergence; this is a shared-behavior correctness fix (per-pane drag) applied to
both builds. `webview.m`'s `set_drag_region` is unchanged.

## Out of scope

- iOS (no window dragging; `darwin_webview_set_drag_region` is already a no-op on
  iOS — `ios/webview.m:963`).
- Changing the main window's chrome to a native title bar (the full-bleed sidebar
  chrome is intentional; the drag-region is its correct complement).
- Windows (`windows_webview_set_drag_region` exists; the same router relocation
  benefits it, but the kitchen-sink smoke + this cycle target macOS/nim).
