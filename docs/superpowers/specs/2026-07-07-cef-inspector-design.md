# CEF sub-cycle C2 — inspector on CEF windows (macOS) — design

**Date:** 2026-07-07
**Branch:** `feat/cef-inspector` (off `feat/nim-native @ 68c55ee`; NO merge to `nim-native` without ask — Windows handoff target)
**Type:** Feature — host a CEF browser in an `NSSplitViewController` inspector pane, a direct mirror of C1's sidebar arm. Opt-in + gated. macOS-only.
**Status:** design approved; pending spec review → writing-plans → SDD

## Goal

A chromium (`webEngine:"chromium"`) app's window **with an inspector** renders the inspector pane on CEF, with collapse/expand/resize events and imperative control reaching it, **coexisting with a sidebar**, and clean per-pane teardown. This is a direct mirror of C1's sidebar arm — nearly everything is inherited from C1; the only new code is the inspector arm in the CEF pane-mount branch. `webEngine:"system"` (WKWebView) windows stay byte-identical.

## North star

The CEF native-chrome series (C1 sidebar → **C2 inspector** → C3 toolbar → …) exists to reach one integration target: running the full **`kitchen-sink`** app — every native surface — with `webEngine:"chromium"`. Each cycle removes one blocker. C2 removes the inspector blocker. C2's `cef-hello` inspector fixture is the *focused* gate for this cycle; kitchen-sink-on-CEF is the eventual whole-app gate.

## Context — what C1 already built (inherited by C2, no new work)

C1 shipped the CEF pane-mount branch (`window.m`, `#ifdef ZAPP_HAS_CEF`) hosting CEF browsers in the **host + sidebar** pane containers via sub-cycle B's `zapp_cef_create_browser_in_view`, plus two foundational fixes C2 inherits:

- **Engine-agnostic window resolver** — `darwin_window_get_by_numeric_id` gained a CEF fallback (`zapp_cef_window_for_slot`), so imperative ops (sidebar / **inspector** / panel / screen) that route through `zapp_*_for_slot` work on CEF. Inspector toggle/collapse/expand/setWidth already resolve.
- **Shared bootstrap-carrier builder** — `zapp_build_bootstrap_carriers` (`webview.m`) injects the `zapp.*` pane-shape Symbols by `pane_role`/composition flags for BOTH engines: `zapp.hasInspector` (from the `host_has_inspector` flag, into every pane) and `zapp.isInspector` (`pane_role == 3`). So `Window.current().inspector` resolves in a CEF pane.

Also already engine-agnostic / already wired:
- **Per-pane teardown** — `windowWillClose:` already tears down `inspectorNumericId` (C1 Task 3, bounds-checked, no-ops when absent).
- **Split builder** — already constructs `inspectorContainer` (`inspVC.view`, or a vibrancy wrapper on WK) when `useInspector` (`window.m:1057-1073`).
- **Inspector event registry** — `zapp_set_inspector_slot` + `zapp_inspector_register` sit outside the `#ifdef` (`window.m:~1239+`), so they run for CEF; inspector.m's collapse/resize events reach the CEF inspector pane via `darwin_window_eval_js`'s `ZAPP_HAS_CEF` branch, exactly as the sidebar's do.

**The only missing piece:** the CEF pane-mount branch mounts host + sidebar but NOT the inspector — C1 deferred it (comment at `window.m:1131`: "Inspector-on-CEF is sub-cycle C2").

## Design

### 1. Inspector arm in the CEF pane-mount branch

In `window.m`'s `#ifdef ZAPP_HAS_CEF` pane-mount branch, after the sidebar arm (~`window.m:1169`), add an inspector arm mirroring the sidebar arm:

```objc
if (useInspector) {
    NSURL* insNsUrl = zapp_resolve_url(inspectorUrl);
    const char* insCefUrl = insNsUrl ? [[insNsUrl absoluteString] UTF8String] : "zapp://index.html";
    if (!insCefUrl || insCefUrl[0] == '\0') insCefUrl = "zapp://index.html";
    // Inspector pane: pane_role=3 (zapp.isInspector) + the window's composition
    // flags, so this pane's Window.current() resolves .inspector and imperative
    // toggle/collapse works on CEF (inherits C1's resolver + carrier fixes).
    zapp_cef_create_browser_in_view((__bridge void*)inspectorContainer, insCefUrl, inspector_slot,
                                    [hostWindowId UTF8String], [paneOwnerId UTF8String],
                                    3, useSidebar, useInspector);
    // Mirrors the WK path's zapp_register_webview(inspector_slot, …, hostWindowId)
    // so Workers.create() from JS in the CEF inspector pane resolves its owner.
    if (inspector_slot >= 0 && inspector_slot < ZAPP_MAX_WINDOW_CALLBACKS)
        zapp_window_ids[inspector_slot] = hostWindowId;
}
```

The host arm already passes `useInspector` as `host_has_inspector`, so the host pane gets the `zapp.hasInspector` carrier for free (C1's shared builder) — `Window.current().inspector.toggle()` works from the host pane.

### 2. Inherited, unchanged

Resolver, carriers, per-pane teardown, split builder (`inspectorContainer`), the inspector registry + inspector.m events. No changes to any of these.

### 3. Fixture

`examples/cef-hello/` — window 1 (already has a sidebar) gains an **inspector** → a 3-pane CEF window (sidebar + host + inspector). Window 2 stays plain (fullbleed regression). `zapp/app.nim` window 1 `WindowOptions` gains inspector opts; `src/main.ts` grows an inspector-pane branch (its own simple page/route) + a host-pane "toggle inspector" button.

## Testing (human R0 gates)

- **Inspector renders on CEF + ticks:** window 1 shows a third pane (inspector) on Chromium; a worker tick reaches all 3 panes (broadcast fan-out).
- **Collapse/expand:** collapsing/expanding the inspector (divider drag) delivers `inspector-collapsed`/`expanded` to the CEF inspector pane.
- **Imperative control:** `Window.current().inspector.toggle()` from the host pane collapses/expands the inspector on CEF (inherited resolver + carriers).
- **Coexistence:** all 3 panes live simultaneously; sidebar AND inspector each independently collapsible; both accessories' events land in their own panes.
- **Per-pane teardown:** closing window 1 tears down all 3 pane browsers — `browser closed` for host + sidebar + inspector slots, no leak; window 2 stays alive; last close quits clean.
- **Byte-identical:** a `webEngine:"system"` build is unaffected (all CEF changes `#ifdef`-gated; the WK inspector path unchanged).

## Error handling

- Inspector pane slot bounds-checked (`inspector_slot >= 0 && < ZAPP_MAX_WINDOW_CALLBACKS`).
- `inspectorUrl` absent → no inspector pane; the CEF branch is unchanged for sidebar-only and plain windows.
- Refcount: the inspector CEF browser follows B's proven create/teardown lifecycle independently, same as the host + sidebar panes.

## Non-goals (deferred)

- **Host-level window events on CEF** (`resize`/`focus`/`blur`/`move`/`maximize` via `zapp_dispatch_event_to_js`) — this dispatcher is WK-only (`zapp_webviews[window_id]`), so it returns early for ALL CEF windows. This is a pre-existing, foundational gap since sub-cycle B, **not inspector-specific** — it affects the host pane and every accessory. Deferred to a dedicated foundational follow-up **after C2** (user-agreed 2026-07-07). Note: the inspector's OWN collapse/resize events (inspector.m) DO reach the CEF inspector pane; only the host→pane window-event fan-out is gapped.
- **Toolbar + `toggleInspector` toolbar button on CEF** — sub-cycle **C3**.
- **Vibrancy / material behind a CEF inspector pane** — a CEF (non-OSR Alloy) browser is opaque and renders its own background, so the WK inspector's material won't show through. CEF inspector panes are opaque this cycle (same as C1's sidebar; vibrancy-on-CEF = OSR territory).
- The sub-cycle B **terminal-close** limitation (a closed CEF window reshows blank) applies per-pane — already documented.

## Scope

`window.m` inspector arm + `cef-hello` inspector fixture + FINDINGS/SMOKE docs. Likely **~2 tasks**: (1) the inspector arm in the CEF pane-mount branch + the fixture + the render / coexistence / teardown gates; (2) docs. This is the lowest-risk C cycle yet — everything but the ~12-line pane-mount arm is inherited from C1, and the WK `#else` inspector path is untouched.
