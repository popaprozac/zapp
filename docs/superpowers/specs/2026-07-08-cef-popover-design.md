# CEF breakage fix #1 — popover on CEF windows (macOS) — design

**Date:** 2026-07-08
**Branch:** `feat/cef-popover` (off `feat/nim-native @ 6a00907`; NO merge to `nim-native` without ask)
**Type:** Bug fix — make `NSPopover` (web content in a popover) work on a `webEngine:"chromium"` window. Opt-in path is CEF; gated. macOS-only.
**Status:** design approved (C-series mirror; cef-hello fixture); pending spec review → writing-plans → SDD

## Goal

`Window.current().createPopover(opts)` + `PopoverHandle.show(anchor)` (an `NSPopover` hosting web content) works on a CEF window — the popover opens, shows its content on Chromium, anchors to the pane, and tears down cleanly on close. Parity with WKWebView. First of the three kitchen-sink-on-CEF breakages.

## Root cause (diagnosed)

The popover no-ops on CEF for **two** WK-specific reasons, both in `native/platform/darwin/popover.m`:

1. **Content** (`darwin_popover_create`, popover.m:78-87): the popover's content webview is mounted into its container via `darwin_webview_create_ext(window_ptr, …, popover_slot, …, container, host_slot, /*pane_role=*/2, …)` — which creates a **WKWebView**. On a CEF window, no browser is mounted into the popover's content view (the content is empty).
2. **Anchor** (`darwin_popover_show`, popover.m:141-145): the view to anchor to is `zapp_webview_for_slot(sender_slot)`, falling back to `zapp_webview_for_slot(c.hostSlot)` — both **nil on CEF** (CEF browsers live in `zapp_cef_browsers[]`, not `zapp_webviews[]`) → `if (!anchorView) return;` → the whole show no-ops.

This is the same class of WK-specific-host gap the C-series fixed for the panes, in a new surface. It is NOT shared with the contextmenu breakage (that's an `NSMenu` with no content webview — a separate fix).

## Design — mirror the C-series (gated, WK unchanged)

### 1. Content — mount a CEF browser in the popover container (`darwin_popover_create`)

A `#ifdef ZAPP_HAS_CEF` branch: instead of `darwin_webview_create_ext`, mount a CEF browser into `container` via sub-cycle B's `zapp_cef_create_browser_in_view(container, url, popover_slot, hostWindowId, ownerId, /*pane_role=*/2, host_has_sidebar=false, host_has_inspector=false)`. `pane_role=2` already maps to the `zapp.isPopover` carrier in the shared bootstrap builder, so `Window.current()` + identity work inside the popover for free. Write `zapp_window_ids[popover_slot] = hostWindowId` (mirrors the pane path; lets `Workers.create()` etc. from the popover resolve). The `NSPopover`/`contentViewController`/registry wiring below is engine-agnostic and unchanged (the popover hosts `container` either way).

### 2. Anchor — resolve the CEF pane's NSView (`darwin_popover_show`)

A `#ifdef ZAPP_HAS_CEF` fallback: when `zapp_webview_for_slot(sender_slot)`/`(hostSlot)` is nil, resolve the CEF browser's NSView for the anchor. Add a small helper `void* zapp_cef_view_for_slot(int32_t slot)` in `zapp_cef_host.m` (borrowed browser → `get_host` [owned, release once] → `get_window_handle` → the SetAsChild NSView), analogous to `zapp_cef_window_for_slot`. Use its result as `anchorView`, then the existing `showRelativeToRect:ofView:` + rect/toolbar-item logic (engine-agnostic) runs unchanged. (The anchor rect x/y is still measured by the popover-opening JS; only the host NSView differs.)

### 3. Teardown — tear down the popover's CEF browser on close

The `ZappPopoverController` is the `NSPopoverDelegate`. When the popover closes (`popoverDidClose:` / the existing `POPOVER_CLOSED` path), tear down its CEF browser via `zapp_cef_teardown_browser_for_slot(popover_slot)` (sub-cycle B's Electrobun teardown), mirroring the per-pane `windowWillClose:` teardown — so a closed popover doesn't leak its browser. Gated.

### Gating / byte-identical

All three changes are inside `#ifdef ZAPP_HAS_CEF`; the WK path (`darwin_webview_create_ext` content, `zapp_webview_for_slot` anchor, delegate) is unchanged → `system` build byte-identical.

## Fixture

`examples/cef-hello/` gains a minimal popover trigger in the host pane: a **"Show popover"** button that lazily `Window.current().createPopover({ url: "#popover-pane", width, height })` then `.show({ x, y })` anchored to the button (mirroring kitchen-sink's popover section, minimal). `src/main.ts` grows a `#popover-pane` branch (a simple distinct page, like the sidebar/inspector panes) so the popover content is identifiable.

## Testing (human R0 gates)

- **Opens + renders:** clicking **Show popover** on the CEF window opens an `NSPopover` showing its web content (the `#popover-pane` page) rendered on Chromium.
- **Anchored:** the popover is anchored to the button/pane (not floating at 0,0).
- **Teardown:** dismissing the popover (click-away for transient) closes it and tears down its CEF browser — reopening works; no leak (`browser closed (slot <popover>)` in the log).
- **Byte-identical:** a `webEngine:"system"` build is unaffected (all CEF changes `#ifdef`-gated; the WK popover path unchanged).

## Error handling

- Popover slot bounds-checked; the CEF create/teardown follow B's proven lifecycle.
- `zapp_cef_view_for_slot` NULL-guards (browser/host/handle), like `zapp_cef_window_for_slot`.
- No CEF browser for the slot → the anchor fallback yields nil → the existing `if (!anchorView) return;` still guards (no crash).

## Non-goals

- WK popover — unchanged.
- Vibrancy/material behind the popover — CEF opaque (same as the panes).
- The `menu:`-toolbar-item popover path beyond what `createPopover`/`show` exercises — if the diagnosis during impl shows a separate toolbar-item-anchored gap, note it; the core is `createPopover` + `show`.
- contextmenu / embedded-webview — their own cycles.

## Scope

`popover.m` (content branch + anchor fallback + teardown), `zapp_cef_host.m` + `zapp_cef.h` (`zapp_cef_view_for_slot`), `cef-hello` fixture, FINDINGS/SMOKE. Likely **~2 tasks**: (1) the three native changes + the `zapp_cef_view_for_slot` helper + the fixture + the open/anchor/teardown gate; (2) docs. A focused C-series-style mirror.
