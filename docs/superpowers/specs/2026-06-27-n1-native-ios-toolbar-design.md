# N1 — Native iOS Toolbar — Design

**Date:** 2026-06-27
**Branch:** `feat/ios-native-nav` (commit directly; UNMERGED)
**Program:** iOS Native Navigation, cycle N1 (`docs/superpowers/specs/2026-06-27-ios-native-navigation-program-design.md`). Builds on the toolbar placement model (#643) + N0 Platform API.
**Status:** Approved (design) → writing-plans → SDD.

## Goal

Render the cross-platform `placement` toolbar items in the **content column's `UINavigationItem`** on iOS — a real native navigation bar (leading / title / trailing) — replacing the kitchen-sink HTML top-bar stand-in. **No native routing** (that is N2/N3). The macOS `NSToolbar` is the parity reference and must not regress.

## Current state (from exploration)

- **Router path already complete:** `toolbar:setItems`/`updateItem`/`remove` (`native/nim/router.nim`) resolve `darwin_window_get_by_numeric_id` → `void* window_ptr` (a `UIWindow*` on iOS) and call the `darwin_toolbar_*` externs — which on iOS hit **6 no-op stubs** (`native/platform/ios/toolbar.m`). Only the `.m` impl is missing.
- **Content nav controller reachable:** `ZappIOSSidebarController.contentNav` (a `strong` `UINavigationController` wrapping `contentVC`, `navigationBarHidden = YES`), looked up via `zapp_ios_sidebar_for_slot(window_id)` (sidebar.m). The target for items is `contentVC.navigationItem`.
- **Content webview reachable:** `zapp_ios_content_webview_for_slot(slot)` (window.m, from the #737 work).
- **Webview-intrusion is mild:** the content webview's top is pinned to `contentVC.view.topAnchor` (sidebar.m ~589, inspector.m ~225) — which in a `UINavigationController` *already excludes* a shown bar, so flipping `navigationBarHidden = NO` auto-insets the webview. The real gap: `--zapp-toolbar-height` stays `0` (iOS `zapp_toolbar_inject_metrics` is a stub), so web content reserving toolbar space won't.
- **macOS reference to mirror** (`darwin/toolbar.m`): the placement-JSON parse (per-item dict: id/type/label/icon/placement/menu/…), the click emit (`window:toolbar-clicked`, payload `{"windowId":"win-N","id":"…"}`), the group-select emit (`window:toolbar-group-selected`), and `inject_metrics` (eval + `WKUserScript` setting `--zapp-toolbar-height`).
- **Icon resolver is AppKit-only** (`darwin/menu.m` `zapp_resolve_icon` → `NSImage`); iOS needs a parallel `UIImage` resolver (sf:/data:/path).
- **No-sidebar windows have no nav controller** (`ZappIOSRootViewController` is a plain `UIViewController`) — no bar to host items.
- **Kitchen-sink** already calls `Window.current().toolbar.setItems(shellToolbar())` unconditionally; the `ks-ios-topbar` HTML header (`main-pane.ts`, `☰`/title/`⊟`) is the fallback to remove.

## Design

**Reaching the bar:** `darwin_toolbar_set_items(window_ptr, json, slot)` → `zapp_ios_sidebar_for_slot(slot).contentNav` → set `contentVC.navigationItem.{leftBarButtonItems, titleView/title, rightBarButtonItems}` from the placement buckets → `contentNav.navigationBar` shown (un-hide). A small per-window toolbar registry (mirroring `zapp_ios_sidebars`) tracks built items for `update_item`/`remove`.

**Item-type mapping:**

| Type | iOS mapping |
|---|---|
| `button` | `UIBarButtonItem` (title or SF/data/path image) + target/action → click emit |
| `space` / `flexibleSpace` | `UIBarButtonItem(barButtonSystemItem: .fixedSpace/.flexibleSpace)` |
| `label` | placement `center` → `navigationItem.titleView` (UILabel) or `.title`; elsewhere → `customView` UILabel |
| `toggleSidebar` | `UIBarButtonItem` (SF `sidebar.leading`) → `darwin_sidebar_toggle` |
| `toggleInspector` | `UIBarButtonItem` (SF `sidebar.trailing`) → `darwin_inspector_toggle` |
| `segmented` | `UISegmentedControl` as `customView`; selection → `window:toolbar-group-selected` |
| `group` | flatten to individual `UIBarButtonItem`s |
| `button.menu` | `UIBarButtonItem` with a rebuilt `UIMenu` |
| `trackingSeparator` | **dropped** (no iOS equivalent) |
| `badge` / `style:prominent` / `controlRepresentation` | gracefully ignored on a nav bar |

**Placement → slots:** `leading` → `leftBarButtonItems` (in order), `center` → `titleView`/`title`, `trailing` → `rightBarButtonItems`. (`space`/`flexibleSpace` are mostly redundant on a nav bar but accepted as system items.)

**Webview-intrusion fix:** implement iOS `zapp_toolbar_inject_metrics` to compute `contentNav.navigationBar.frame.size.height` (when shown) and inject `--zapp-toolbar-height` into the pane webviews via `evaluateJavaScript` + a `WKUserScript` (mirroring macOS, so it survives in-webview navigations). The layout itself auto-adjusts via the existing top constraint.

**Click events:** mirror macOS — emit `window:toolbar-clicked` `{"windowId":"win-N","id":"…"}` and `window:toolbar-group-selected` via the iOS eval-all path (`zapp_ios_eval_js_all_webviews`, window.m) so all panes + (where linked) workers receive it.

**iOS icon resolver:** a new `zapp_ios_resolve_icon(spec, size)` → `UIImage` (`sf:`→`systemImageNamed:`, `data:`→base64+`imageWithData:`, else file path), parallel to the macOS `NSImage` resolver.

## Decisions (confirmed)

1. **`toggleSidebar`/`toggleInspector`** → manual `UIBarButtonItem` calling `darwin_sidebar_toggle`/`darwin_inspector_toggle` (SF `sidebar.leading`/`sidebar.trailing`), **not** the system `displayModeButtonItem` — cleaner + works in collapsed iPhone mode. (Deviation from the program doc's `displayModeButtonItem` mention; intentional.)
2. **No-sidebar windows** → **deferred** (no nav controller to host a bar; wrapping the root VC is a follow-up). N1 targets sidebar windows.
3. **Opt-in** → none; the native toolbar renders whenever `win.toolbar.setItems(...)` is called on iOS (no config flag).
4. **Replace** the kitchen-sink HTML top-bar (T3).
5. **One cycle**, risk-gate-first.

## Decomposition (each = SDD task)

- **T1 — RISK GATE (core).** iOS `ios/toolbar.m`: placement-JSON parse + `UIBarButtonItem`s for `button` / `space` / `flexibleSpace` / `label` / `toggleSidebar` / `toggleInspector`; assign to `contentVC.navigationItem`; show the bar; per-window toolbar registry; `window:toolbar-clicked` emit; the iOS `UIImage` icon resolver; iOS `zapp_toolbar_inject_metrics` (`--zapp-toolbar-height`). → **human smoke** (iPhone+iPad): core items render in the content nav bar, no webview overlap, clicks fire, toggleSidebar/Inspector work.
- **T2 — Breadth.** `segmented` (UISegmentedControl customView + `window:toolbar-group-selected`), `group` (flatten), `button.menu` (UIMenu); `darwin_toolbar_update_item` + `darwin_toolbar_remove`; `trackingSeparator` dropped + badge/prominent/controlRepresentation ignored without error.
- **T3 — Kitchen-sink + docs.** Replace the `ks-ios-topbar` HTML header with the native toolbar (the `☰`/title/`⊟` become native bar items via the existing `shellToolbar()`); document the iOS toolbar (placement→nav-bar mapping, dropped types, no-sidebar/create-time caveats) in `docs/api-reference.md`; full gates + final smoke.

## Out of scope / deferred

- **No-sidebar-window toolbar** (needs wrapping the root VC in a nav controller) — follow-up.
- **Create-time `WindowOptions.toolbar` on iOS** — iOS `window.m` doesn't call `darwin_toolbar_attach` at materialize; only the `setItems` late-attach path is wired (the kitchen-sink uses `setItems`). Note as a minor follow-up.
- `trackingSeparator` on iOS; `badge`/`style:prominent`/`controlRepresentation` (degrade silently).
- Native routing (N2/N3); the iPhone bottom `UIToolbar` (`placement:"bottom"`, later).

## Risks

1. **Webview overlap** if `--zapp-toolbar-height` isn't injected — mitigated by the iOS `inject_metrics` impl (T1) + the auto-adjusting top constraint. **The T1 risk-gate smoke confirms it.**
2. **Collapsed-iPhone nav stack:** when UIKit merges sidebar+content into one collapsed nav controller, items set on `contentVC.navigationItem` show when `contentVC` is the top VC — correct for content-visible state; verified in the T1 smoke.
3. **`group`/`menu` mapping** (UIMenu rebuild, group flatten) — isolated to T2; the macOS JSON shape is documented to mirror.

## Testing & gates

- Native (ObjC) — no unit-test harness; correctness via build gates + human smoke. (TS/Nim unchanged — the wire contract already exists.)
- Gates each task: `bun run check`; `bun test cli/src`; `bun run test:native`; iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`); macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`, parity reference unchanged).
- **Human smoke (iPhone + iPad):** T1 core items in the content nav bar + no overlap + clicks + sidebar/inspector toggles; T3 full kitchen-sink toolbar native (segmented/group/menu) + HTML top-bar gone.

## Constraints

Branch `feat/ios-native-nav` (commit on it directly), UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun; native-first parity (the TS/Nim/router wire already exists — this cycle is the iOS `.m` consumer + docs); NO iOS simulator interaction in-session (build-only gates + human smoke); iOS arm64 / min 15.0; macOS is the parity reference (don't regress `NSToolbar`); `ios/toolbar.m` is the main new code; docs updated in the same PR.
