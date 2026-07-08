# CEF sub-cycle C3 — toolbar (NSToolbar) on CEF windows (macOS) — design

**Date:** 2026-07-07
**Branch:** `feat/cef-toolbar` (off `feat/nim-native @ 93c6e53`; NO merge to `nim-native` without ask — Windows handoff target)
**Type:** Feature/fix — make a native `NSToolbar` render and behave correctly on a `webEngine:"chromium"` (CEF) window. Opt-in + gated. macOS-only.
**Status:** design approved (spike-first; A/B/C scope confirmed); pending spec review → writing-plans → SDD

## Goal

A chromium (`webEngine:"chromium"`) app's window **with a toolbar** renders the toolbar correctly and behaves like a WKWebView toolbar window: panes fill cleanly under the toolbar, `trackingSeparator` tracks the sidebar divider, toolbar clicks + `toggleSidebar`/`toggleInspector` work, and chrome-metrics reach the panes. Unlike C1 (sidebar) and C2 (inspector), the toolbar is **native chrome, not a CEF browser pane** — most of it is already engine-agnostic; C3 fixes the CEF-specific defects a spike surfaced. `webEngine:"system"` (WKWebView) windows stay byte-identical.

## North star

The CEF native-chrome series (C1 sidebar → C2 inspector → **C3 toolbar** → …) exists to run the full **`kitchen-sink`** app — every native surface — with `webEngine:"chromium"`. C3 removes the toolbar blocker. Its `cef-hello` toolbar fixture is the focused gate; kitchen-sink-on-CEF is the eventual whole-app gate.

## Context — what the spike established (commit `1c83c9c`)

A spike added a toolbar (`toggleSidebar`, a `button` item, `trackingSeparator`, `toggleInspector`) to `cef-hello` window 1 (already a 3-pane sidebar+host+inspector CEF window) and observed on-device.

**Already works on CEF (inherited, engine-agnostic — confirmed):**
- **Attach** — `darwin_toolbar_attach` (window.m:1388) runs at the top level of window creation; the NSToolbar attaches to any NSWindow. Builds, links, no crash, clean teardown.
- **Clicks → JS** — `zapp_toolbar_emit_click` (toolbar.m:95) fans `window:toolbar-clicked` via the CEF-aware `darwin_webview_eval_all`, not the WK-only `zapp_dispatch_event_to_js`. Confirmed: clicking the item delivered `{"windowId":"win-0","id":"ping"}` to the CEF host pane. (Accessory panes just didn't subscribe — a fixture detail, not a gap. So C3 does NOT depend on the deferred host-event fan-out fix.)
- **Toggles** — `toggleSidebar` (native split-VC action) and `toggleInspector` (`darwin_inspector_toggle` resolver, CEF-aware from C1) both collapse/expand their panes.
- Window 2 stays toolbar-free.

**Three CEF-specific defects the spike surfaced (C3's scope):**
- **A — Panes don't fill under the toolbar ("dark band").** The toolbar icons render in the titlebar, but a dark band of window background shows between the toolbar and the panes: the CEF browser NSViews don't re-fill the content area after the toolbar shrinks it.
- **B — `trackingSeparator` misaligned.** The sidebar-toggle should sit at the sidebar↔content divider; instead it starts at the leading edge and slides the wrong way when the sidebar collapses — the separator isn't tracking the CEF split's divider position.
- **C — chrome-metrics absent.** `--zapp-toolbar-height` is empty on CEF (confirmed) — `zapp_toolbar_inject_metrics` is WK-only (`zapp_webview_for_slot` → `WKWebView` → `evaluateJavaScript`/`WKUserScript`).

## Design

### Fix 1 — CEF pane layout under the toolbar (addresses A, likely B)

**Hypothesis (to confirm via systematic-debugging):** the CEF browser view is created SetAsChild sized to `parent.bounds` **at create time** (`zapp_cef_host.m:207-220`), but the toolbar attaches **one runloop tick later** (`window.m:1403`), shrinking the window's `contentLayoutRect`. The pane containers autoresize, but the CEF browser NSView inside each container keeps its pre-toolbar frame → the dark band (A). Because the CEF panes are then mis-sized relative to the `NSSplitView`, the split's divider sits where the separator doesn't expect → the `trackingSeparator` mis-tracks (B).

**Direction:** ensure each CEF browser NSView tracks its container's bounds (e.g. set `NSViewWidthSizable | NSViewHeightSizable` on the CEF browser view after create, and/or re-layout the CEF panes after the toolbar attaches). The exact fix is determined by diagnosis; the gate is "no dark band AND the trackingSeparator tracks the divider." A and B may resolve with one fix (shared cause) or need a small follow-on for B — the plan treats them as one investigation with two gates.

### Fix 2 — chrome-metrics injection for CEF (addresses C)

`zapp_toolbar_inject_metrics` (toolbar.m) resolves `zapp_webview_for_slot(slot)` → `WKWebView` and injects the `--zapp-*` CSS vars via `evaluateJavaScript` (dynamic, re-run on layout via `contentLayoutRect` KVO) + a `WKUserScript` (reload-persistence). For CEF panes (no `WKWebView`), route the per-slot injection through the CEF-aware **`darwin_window_eval_js(slot, js)`** (has the `ZAPP_HAS_CEF` branch). Reload-persistence: CEF has no `WKUserScript`, so re-inject on the CEF pane's load (the metrics are recomputed from live layout anyway). Keep the WK path byte-identical — the CEF path is an added branch.

### Fixture

The spike fixture (`cef-hello` window 1 gains a toolbar + a toolbar-click display + a `--zapp-toolbar-height` readout, commit `1c83c9c`) becomes the C3 fixture, refined as needed. Window 2 stays plain.

## Testing (human R0 gates)

- **A — panes fill:** window 1's toolbar sits flush above the panes — NO dark band; the sidebar/host/inspector panes render up to the toolbar's bottom edge. Resize the window — panes keep filling.
- **B — trackingSeparator tracks:** the sidebar-toggle sits at the sidebar↔host divider; dragging/collapsing the sidebar keeps the separator aligned to the divider (moves toward leading as the sidebar shrinks), not sliding the wrong way.
- **C — metrics present:** `--zapp-toolbar-height` shows a non-empty pixel value on the CEF panes; switching the toolbar's Icon/Text display mode updates it.
- **Regression (inherited, must still pass):** toolbar click delivers `{id}` to the host pane; `toggleSidebar`/`toggleInspector` collapse/expand; window 2 stays toolbar-free; per-pane teardown of all panes on close, no leak.
- **Byte-identical:** a `webEngine:"system"` build is unaffected (all CEF changes `#ifdef ZAPP_HAS_CEF`-gated; the WK toolbar path unchanged).

## Error handling

- CEF pane-layout fix guarded to CEF windows (`#ifdef ZAPP_HAS_CEF`); WK path untouched.
- Metrics: the CEF branch is additive; `darwin_window_eval_js` no-ops on an absent slot.
- No toolbar (`toolbarJson` empty) → no attach, no change (fullbleed/plain CEF windows unaffected).

## Non-goals (deferred)

- **Host-level window-event fan-out** (`zapp_dispatch_event_to_js`, WK-only) — still deferred; C3 does not need it (toolbar clicks use the CEF-aware broadcast). Foundational follow-up after C3.
- **Vibrancy / material behind the toolbar** — CEF panes are opaque (same as C1/C2); a toolbar over a CEF window shows the panes' own backgrounds, not vibrancy.
- **Toolbar pull-down menus / NSMenuToolbarItem popovers on CEF beyond click delivery** — if the spike/impl surfaces a distinct popover gap, split it out; not in scope unless found.
- **Devtools** — sub-cycle D.

## Scope

`zapp_cef_host.m` / `window.m` (CEF pane layout under toolbar), `toolbar.m` (CEF metrics branch), the `cef-hello` toolbar fixture, FINDINGS/SMOKE. Likely **~3 tasks**: (1) diagnose + fix the CEF pane layout under the toolbar (gates A + B); (2) chrome-metrics injection for CEF (gate C); (3) docs. Higher-risk than C1/C2 — A/B require diagnosis (systematic-debugging), not a known mirror — which is why C3 was spiked first.
