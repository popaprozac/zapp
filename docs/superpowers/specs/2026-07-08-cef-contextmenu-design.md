# CEF breakage fix #2 — context menu on CEF windows (macOS) — design

**Date:** 2026-07-08
**Branch:** `feat/cef-contextmenu` (off `feat/nim-native @ e8fae88`; NO merge to `nim-native` without ask)
**Type:** Bug fix — make `ContextMenu.show()` (a native `NSMenu`) appear on a `webEngine:"chromium"` window. Gated. macOS-only.
**Status:** design approved (popover-anchor mirror; cef-hello fixture); pending spec review → writing-plans → SDD

## Goal

`ContextMenu.show(items, { event })` pops a native `NSMenu` at the cursor on a CEF window — same as WKWebView. Second of the three kitchen-sink-on-CEF breakages.

## Root cause (diagnosed)

`darwin_menu_show_context` (`native/platform/darwin/menu.m:358`) resolves the view to position the menu relative to via `darwin_window_get_webview(window_id)` (menu.m:369) → **nil on CEF** (CEF browsers aren't WKWebViews) → `if (!wv_ptr) return;` (menu.m:370) → the native `NSMenu` never shows. The JS→router edge already works — the `showContextMenu` router message arrives (confirmed in the kitchen-sink-on-CEF catalog log); the gap is purely native presentation.

This is the same WK-specific-view-lookup gap the popover anchor had (breakage #1), in the `NSMenu` surface — but simpler: a context menu is a native menu, so there is NO web content to mount, only the anchor view to resolve.

## Design — reuse the popover anchor (gated, WK unchanged)

### Primary fix — CEF anchor-view fallback (`darwin_menu_show_context`)

A `#ifdef ZAPP_HAS_CEF` fallback: when `darwin_window_get_webview(window_id)` returns nil, resolve the CEF pane's NSView via `zapp_cef_view_for_slot(window_id)` (the helper built for popover #1, now merged) and use it as `view`. Everything else in `darwin_menu_show_context` is engine-agnostic and unchanged:
- `build_menu_from_json(items)` — the `NSMenu`.
- the `isFlipped`-guarded point flip (menu.m:379-381) — already handles a non-flipped view; popover confirmed the CEF browser NSView's coordinate behavior, and this `isFlipped` guard is robust either way.
- `[menu popUpMenuPositioningItem:nil atLocation:point inView:view]` (menu.m:382).

Concretely, the nil-guard becomes a gated fallback rather than an early return:
```objc
    void* wv_ptr = darwin_window_get_webview(window_id);
#ifdef ZAPP_HAS_CEF
    if (!wv_ptr) wv_ptr = zapp_cef_view_for_slot(window_id);   // CEF pane NSView
#endif
    if (!wv_ptr) return;
```
`window_id` here is the numeric window id (= slot), the same value `zapp_cef_view_for_slot` takes. `#ifdef ZAPP_HAS_CEF`-gated; `unifdef -UZAPP_HAS_CEF menu.m` reproduces the original → `system` build byte-identical.

### Gate-contingent — suppress Chromium's own context menu (only if observed)

Chromium has its own native context menu (Reload / Inspect / …). Our app's JS `preventDefault()`s the `contextmenu` event and sends `showContextMenu`; on WKWebView that suppresses the browser menu. On CEF, `preventDefault` *should* likewise stop Chromium's, but CEF's default menu is driven natively (`CefContextMenuHandler::on_before_context_menu`), which can fire independent of the JS event. **If the R0 gate shows Chromium's context menu ALSO appearing** (competing with our `NSMenu`), the follow-up is a small `CefContextMenuHandler` on the client that clears the model in `on_before_context_menu` (so only our menu shows). This is designed but NOT built unless the gate shows it's needed — the primary fix alone may suffice (the catalog reported the native menu missing, not a stray Chromium menu).

## Fixture

`examples/cef-hello/` gains a right-click trigger in the host pane (mirror kitchen-sink `src/sections/contextmenu.ts`): a `contextmenu` listener that `e.preventDefault()` + `ContextMenu.show([...items...], { event: e })` with a couple of items (one with an action that logs / updates a status line, to prove item clicks route back).

## Testing (human R0 gates)

- **Appears at cursor:** right-clicking the CEF window pops our native `NSMenu` at the pointer (not at 0,0, not offscreen).
- **Items work:** clicking an item fires its action (routes back to JS — status line / log updates).
- **No stray Chromium menu:** Chromium's own context menu does NOT also appear. (If it does → add the `CefContextMenuHandler` follow-up.)
- **Byte-identical:** a `webEngine:"system"` build is unaffected (`unifdef -UZAPP_HAS_CEF menu.m` == original; the WK view-lookup path unchanged).

## Error handling

- `zapp_cef_view_for_slot` NULL-guards internally (browser/host/handle); nil → the existing `if (!wv_ptr) return;` still guards (no crash, menu just doesn't show — same as WK with no webview).
- No slot / no CEF browser → nil view → graceful no-op.

## Non-goals

- WK context menu — unchanged.
- Chromium's default menu content/customization beyond suppression (if needed).
- The popover / embedded-webview breakages — their own cycles (embedded-webview is #3).

## Scope

`menu.m` (the gated fallback — a few lines), `cef-hello` fixture, FINDINGS/SMOKE. Likely **~1 task** (fix + fixture + gate) plus a docs task; **+1 task only if** the R0 gate shows Chromium's menu needs the `CefContextMenuHandler` suppression. A small reuse of the popover anchor helper.
