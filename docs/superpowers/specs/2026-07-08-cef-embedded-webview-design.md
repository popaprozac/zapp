# CEF breakage fix #3 (last) — embedded webview (`<zapp-webview>`) positioning on CEF windows (macOS) — design

**Date:** 2026-07-08
**Branch:** `feat/cef-embedded-webview` (off `feat/nim-native @ 6bc9229`; NO merge to `nim-native` without ask)
**Type:** Bug fix — make the embedded `<zapp-webview>` (a "panel" — a child WKWebView tracking a DOM box) position correctly on a `webEngine:"chromium"` window. Gated. macOS-only.
**Status:** design approved (reuse `zapp_cef_view_for_slot`; cef-hello fixture); pending spec review → writing-plans → SDD. The LAST of the three kitchen-sink-on-CEF breakages.

## Goal

`Webview.create({ src })` (the `<zapp-webview>` custom element) tracks its host DOM box on a CEF window — the embedded native webview sits ON the element's rectangle (and follows it on resize/scroll), same as WKWebView. The embedded webview already renders + loads on CEF; only its POSITIONING is wrong.

## Root cause (diagnosed)

The embedded webview is a "panel" (`native/platform/darwin/panel.m`): a child WKWebView added as a subview of the window's `contentView` (panel.m:120, 154), positioned each frame from the DOM `getBoundingClientRect` the element reports.

`darwin_panel_create` (panel.m:135-137) captures a **host coordinate-reference webview** via `darwin_window_get_webview(window_id)` → **nil on CEF** → `panel.hostWebview` stays nil. Then `darwin_panel_set_bounds` (panel.m:178-195):
- **With a host** (WK): converts the DOM rect from the host content webview's coordinate space into the panel-parent (`contentView`) space via `[host convertRect:inHost toView:parent]` (panel.m:180-186), `isFlipped`-guarded. This accounts for the host webview being inset (e.g. by a sidebar).
- **Without a host** (CEF, host nil): takes the `else` **fallback** (panel.m:187-194) that assumes the panel-parent (`contentView`) *is* the host viewport — a parent-relative flip only.

The comment at panel.m:168-172 documents the exact failure mode: "when the host webview is inset (e.g. by a sidebar), the two spaces differ... so sidebars/inspectors don't cause the panel to bleed over adjacent panes." On a **paned** CEF window (kitchen-sink: sidebar + inspector), the host CEF pane IS inset — but the convert path is skipped, so the DOM rect (host-pane-viewport coords) maps straight into `contentView` coords → **offset by the pane's origin → the panel mis-positions** (bleeds over the wrong area). On a fullbleed CEF window the host viewport ≈ `contentView`, so the fallback is roughly right; the paned case is what breaks.

This is the same WK-specific-view-lookup gap as popover/contextmenu — here the missing view is the coordinate REFERENCE for `convertRect`.

## Design — reuse `zapp_cef_view_for_slot` (gated, WK unchanged)

**One gated insert** in `darwin_panel_create`: when `darwin_window_get_webview(window_id)` is nil, set `panel.hostWebview` to the CEF pane's NSView via `zapp_cef_view_for_slot(window_id)` (the helper from popover #1, merged):
```objc
        extern void* darwin_window_get_webview(int32_t window_id);
        void* hostWV = darwin_window_get_webview(window_id);
        if (hostWV) panel.hostWebview = (__bridge WKWebView*)hostWV;
#ifdef ZAPP_HAS_CEF
        // CEF host: no WKWebView. Use the CEF pane's NSView as the coordinate
        // reference so set_bounds' convertRect maps the DOM rect (host viewport)
        // into the contentView correctly — a paned window would otherwise offset
        // the panel by the pane's origin. Cast to WKWebView*: set_bounds uses
        // only NSView API on it (isFlipped / bounds / convertRect:toView:).
        extern void* zapp_cef_view_for_slot(int32_t slot);
        if (!hostWV) panel.hostWebview = (__bridge WKWebView*)zapp_cef_view_for_slot(window_id);
#endif
```
`darwin_panel_set_bounds` is **UNCHANGED**: with `panel.hostWebview` now non-nil on CEF, its existing `convertRect` path (panel.m:180-186) runs and maps the DOM rect from the CEF host view's coords into the `contentView`, `isFlipped`-guarded (popover confirmed the CEF browser NSView's flip behavior). The `(WKWebView*)` cast is used only via NSView API in `set_bounds` (same deliberate pattern as popover's anchor cast).

### Gating / byte-identical

The insert is a pure `#ifdef ZAPP_HAS_CEF … #endif`; `unifdef -UZAPP_HAS_CEF panel.m` reproduces the original bytes (panel.m has no prior `#ifdef ZAPP_HAS_CEF` — this is the first). The WK path and `set_bounds` are untouched → `system` build byte-identical.

## Fixture

`examples/cef-hello/` gains a `<zapp-webview>` in the host pane (mirror kitchen-sink `src/sections/embedded-webview.ts`): a `frame` div (fixed height, border) with `Webview.create({ src })` appended, so the panel tracks the frame's box. A visible border on the frame makes "does the native webview sit inside the box" obvious. Because window 1 is a PANED CEF window (sidebar + inspector), this exercises the exact inset case that was broken.

## Testing (human R0 gates)

- **Sits on its box:** the embedded webview renders inside the `frame` div's rectangle (aligned to the visible border), NOT offset into the sidebar / elsewhere.
- **Tracks on resize:** resizing window 1 keeps the embedded webview aligned to its box (the panel re-tracks).
- **Renders + loads:** the embedded page still loads (unchanged — this already worked).
- **Byte-identical:** a `webEngine:"system"` build is unaffected (`unifdef -UZAPP_HAS_CEF panel.m` == original; the WK path + `set_bounds` unchanged).

## Error handling

- `zapp_cef_view_for_slot` NULL-guards internally; nil → `panel.hostWebview` stays nil → `set_bounds` takes the existing `else` fallback (no crash; same as a fullbleed embed).
- The cast host reference is `weak` (like the WK host webview) — nils if the CEF view deallocs; `set_bounds` guards `if (host && parent)`.

## Non-goals

- WK embedded webview — unchanged.
- The embedded webview's content engine — it is a WKWebView even on a CEF host (v1 design); this fix is positioning only.
- Non-host-pane embeds (embedding inside the sidebar/inspector pane itself) — the fixture + gate use the host pane; `window_id` resolves the appropriate pane view, but the R0 exercises the host-pane case.
- popover / contextmenu — done (#1, #2).

## Scope

`panel.m` (one gated insert in `darwin_panel_create`), `cef-hello` fixture, FINDINGS/SMOKE. Likely **~1 task** (fix + fixture + gate) plus a docs task. The simplest of the three breakages — `set_bounds`'s convert+flip logic is already correct and engine-agnostic; it only lacked a non-nil host reference on CEF.
