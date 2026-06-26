# iOS A1 — Low-Risk Correctness Batch — Design

**Status:** approved (brainstorm), pending plan
**Program:** iOS/iPadOS A+B+C (see `docs/superpowers/specs/2026-06-26-ios-ipados-program-matrix.md`). This is sub-cycle **A1** of the correctness tier (A1–A5).
**Branch:** `feat/nim-native` (UNMERGED). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Per-file `git add`. Bun.
**Scope:** the smallest, lowest-risk iOS correctness fixes with **no UI-paradigm decisions** — fully mergeable, de-risks A2–A5.

## Why A1 first

The matrix grounding (§1–§6) showed iOS is solid at the core but has a cluster of correctness gaps. A1 collects the ones that are well-understood, low-risk, and independent of the deferred design forks (iPad sidebar tile-vs-overlay → A2; inspector multitasking → A3; native-toolbar → SP-4). #713 is a near-mechanical mirror of the macOS `zapp_pane_emit` fan-out fix already shipped (commit 2c1c979). Verification is build gates + the runnable parity test + a focused human smoke.

## Items

### A1.1 — iOS pane-event fan-out (#713)
**Problem:** pane chrome events don't reach all panes on iOS (mirror of the macOS #627 bug):
- `zapp_ios_sidebar_emit` (ios/sidebar.m) → host + sidebar slot only (misses inspector).
- `zapp_ios_inspector_emit_data` (ios/inspector.m) → host + inspector slot only (misses sidebar).
- `zapp_dispatch_event_to_js` (ios/window.m) → host + sidebar only (misses inspector) for general window events.

**iOS-shaped fix (different from darwin):** iOS has no shared `zapp_pane_emit` and no slot-lookup tables. The sidebar registry (ios/sidebar.m) and inspector registry (ios/inspector.m) each key their controllers by host window id. So:
- Add a tiny lookup in each registry file: `int32_t zapp_ios_sidebar_slot_for_host(int32_t host)` (sidebar.m) and `int32_t zapp_ios_inspector_slot_for_host(int32_t host)` (inspector.m), each returning the accessory slot for that host or `-1`.
- In `zapp_ios_sidebar_emit`: eval host + own sidebar slot + `extern`'d `zapp_ios_inspector_slot_for_host(host)` (deduped, `slot >= 0 && slot != host`).
- In `zapp_ios_inspector_emit_data`: eval host + own inspector slot + `extern`'d `zapp_ios_sidebar_slot_for_host(host)`.
- In `zapp_dispatch_event_to_js` (ios/window.m): add the inspector slot to its existing fan-out (it already reaches host + sidebar).

**Result:** the Sidebar-section inspector updates on iOS when the sidebar changes (Image #9 fixed), symmetric with macOS. Same deliberate bypass of the gJsListeners bitmask as macOS — see [[reference_pane_event_fanout_627]].

### A1.2 — `inspectable` honors config
**Problem:** ios/window.m:661 hardcodes `d->inspectable = true`, so `webContentInspectable: false` is ignored (devtools always on). **Fix:** read `wopts_inspectable(opts)` into the deferred struct, as darwin/window.m does. The iOS-16.4 `webview.inspectable` gate in webview.m already consumes the flag; this just stops forcing it true.

### A1.3 — `viewport-fit=cover` in `zapp init` templates (#577)
**Problem:** generated apps' `index.html` lacks `viewport-fit=cover`, so `env(safe-area-inset-*)` resolves to 0 on iOS. **Fix:** in `cli/src/init.ts`, post-process the generated `index.html` to ensure the viewport meta includes `viewport-fit=cover` (kitchen-sink already has it). Add a focused test that the scaffolded HTML carries it.

### A1.4 — inject `--zapp-safe-area-*` on iOS (macOS parity) — DECIDED: inject
**Problem:** macOS injects `--zapp-safe-area-*` CSS vars (darwin/toolbar.m); iOS doesn't, so cross-platform apps using those vars get 0 on iOS. **Fix:** inject `--zapp-safe-area-{top,right,bottom,left}` from the webview's `safeAreaInsets` on iOS, mirroring the macOS injection, re-injected on safe-area changes (rotation, etc.). Raw `env(safe-area-inset-*)` remains available too.

**Dogfood (added per user):** migrate the kitchen-sink's raw `env(safe-area-inset-*)` usages — the iOS faux top bar (`main-pane.ts` / `style.css` `.ks-ios-topbar`, `.main-pane--ios-offset`) and any other content — to the canonical `--zapp-safe-area-*` vars where applicable. This dogfoods the API and is the **live verification surface** for A1.4: the chrome must still sit correctly under the notch / home-indicator using the vars. (The sidebar-pane *visual* top-gap/hug **spacing redesign** stays in **A2**, but A2 will use these same vars.)

### A1.5 — parity-lint covers `native/nim/**` importc (#637)
**Problem:** `cli/src/ios-platform-parity.test.ts` scans `.zc` refs + `ios/*.m` externs, but not the ~140 `{.importc.}` `darwin_*` symbols in `native/nim/*.nim`. **Fix:** add a test arm that scans `native/nim/**` for `importc`'d `darwin_*` symbols and asserts each has an iOS definition (or is Nim-provided), same violation-reporting style as the existing tests.

## Verification
- `bun run check` clean; `bun test cli/src` (parity gate, incl. the new #637 arm) green — both runnable in-session.
- iOS-sim build: `cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:` (compiles the ObjC changes); also default macOS build stays green (no regression).
- **Human smoke (device/sim, your gate):** (1) Sidebar section → inspector pane updates on sidebar collapse/expand/drag (#713 fixed); reverse still works. (2) Build kitchen-sink (or a config) with `inspectable:false` → Safari Web Inspector can NOT attach; with default → it can. (3) `zapp init` a throwaway app → its `index.html` has `viewport-fit=cover`. (4) `--zapp-safe-area-*` resolve non-zero on iOS AND the kitchen-sink faux top bar (now using the vars) still sits correctly under the notch/Dynamic Island on iPhone + iPad — this is the live A1.4 proof.

## Non-goals (explicitly parked)
- Sidebar presentation tile-vs-overlay, dim/tap-dismiss, sidebar-pane visual safe-area spacing → **A2**.
- Inspector iPad-multitasking pane↔sheet transition (RISK GATE) → **A3**.
- Dialogs-broken (async routing), file-drop regression, iOS sheet focused-`url` → **A4**.
- App-events dispatch (theme/lock/unlock) + demo surface + `<zapp-webview>` demo → **A5**.
- Native toolbar / context menu / popover / UIKeyCommand / multi-window → Tier B/C.

## Task shape (for the plan)
- **A1-T1 (meatiest):** iOS pane-event fan-out — the two registry `_slot_for_host` lookups + three emit/dispatch sites (sidebar.m, inspector.m, window.m); build-verify.
- **A1-T2:** `inspectable` honors config (ios/window.m).
- **A1-T3:** `viewport-fit=cover` in `zapp init` (init.ts + test).
- **A1-T4:** inject `--zapp-safe-area-*` on iOS (webview/window .m, mirror darwin) + migrate kitchen-sink raw `env(safe-area-*)` usages to the vars (dogfood + verification surface; excludes the A2 sidebar-pane spacing redesign).
- **A1-T5:** parity-lint #637 extension (test) + full gates + HUMAN SMOKE.

(Group as the plan sees fit; A1-T2/T3/T5 are small and could merge. Native items (T1/T2/T4) verified by iOS-sim compile; T3/T5 by `bun test`.)
