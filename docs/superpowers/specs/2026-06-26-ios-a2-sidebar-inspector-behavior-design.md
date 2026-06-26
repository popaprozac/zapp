# iOS A2 — Sidebar/Inspector Behavior — Design

**Status:** approved (brainstorm), pending plan
**Program:** iOS/iPadOS A+B+C (see `docs/superpowers/specs/2026-06-26-ios-ipados-program-matrix.md`). Second correctness sub-cycle of Tier A (A1 SHIPPED).
**Branch:** `feat/nim-native` (UNMERGED). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Per-file `git add`. Bun.
**Scope:** iOS sidebar/inspector behavior fixes, **one cycle**, ordered so the mechanical/low-risk work (T1–T5) lands first and the uncertain sim-dependent presentation work (T6) is a risk-gated tail whose three items can each ship or defer independently. No simulator interaction in-session — build-only gates + human smoke on the user's device/sim (iOS arm64, min 15.0, sim functional / device compile-only).

## Why these, why now

A1 fixed pane-event fan-out (#713: collapse/expand reach all panes, iPad-smoked). The iPad smoke surfaced the lead gap (#714) plus a cluster of sidebar/inspector behavior issues. A2 closes the behavior gaps. The genuinely-uncertain part — iPad split presentation (tile/overlay) — is isolated as T6 so it can't stall the ready fixes.

## Items

### T1 — sidebar `sidebar-resized` (width) emit (#714) — mechanical, native
**Problem:** iOS `darwin_sidebar_set_width` (ios/sidebar.m ~392) sets `preferredPrimaryColumnWidth` + stores `configuredWidth` but **emits nothing**. `zapp_ios_sidebar_emit` (~154) is name-only (2-arg `dispatchWindowEvent`). So `SIDEBAR_RESIZED` never fires on iOS → `win.sidebar.width` (runtime/window.ts) stays at the seed forever and the kitchen-sink inspector shows no width signal. macOS fires `sidebar-resized {"width":N}` from `splitViewDidResize:` (darwin/sidebar.m ~152) on both drag and programmatic `setWidth`. The iOS **inspector** already does the right thing (`zapp_ios_inspector_emit_resize` → `{"width":N}`, ios/inspector.m ~129, fired even when compact).
**Fix (mirror the inspector):**
- Add `zapp_ios_sidebar_emit_data(c, eventName, dataJson)` (3-arg) that fans out to host + sidebar slot + inspector slot — same fan-out the A1 #713 fix + `zapp_ios_inspector_emit_data` use (extern `zapp_ios_inspector_slot_for`, dedup `slot >= 0 && slot != host && slot != other`).
- Refactor the existing name-only `zapp_ios_sidebar_emit` to call `_emit_data(c, name, nil)` (one fan-out path).
- Add `zapp_ios_sidebar_emit_resize(c, width)` emitting `{"width":N}` (bare top-level `width`, matching the inspector + the macOS payload + the bootstrap `bareWidth` branch that already promotes `sidebar-resized`→`width`).
- Call `zapp_ios_sidebar_emit_resize(c, width)` from `darwin_sidebar_set_width` (emit the **requested** width, as the inspector does).
**Layers that light up for free (verify, no change):** bootstrap/webview.ts `bareWidth` already handles `sidebar-resized`; runtime SidebarHandle already updates `width` on `SIDEBAR_RESIZED` (window.ts ~1195); kitchen-sink Sidebar section already renders `width N` on `SIDEBAR_RESIZED` (sections/sidebar.ts ~57). **Native-only change.**

### T2 — iPhone-landscape inspector sheet stays dismissable — mechanical, native
**Problem:** the iPhone inspector sheet (ios/inspector.m ~247: `pageSheet`, medium+large detents, grabber, swipe-dismiss via `presentationControllerDidDismiss` ~61) gets promoted to fullscreen by UIKit in compact-height (landscape iPhone) → grabber + swipe vanish → can't dismiss; rotating back restores it (matrix §3).
**Primary fix:** set `sheet.prefersEdgeAttachedInCompactHeight = YES` (+ `widthFollowsPreferredContentSizeWhenEdgeAttached = YES`) so the sheet stays an edge-attached card in compact height, keeping the grabber + swipe-dismiss.
**Fallback (smoke-contingent):** if the primary doesn't keep it dismissable on the device/sim, add an explicit close affordance (a "Done"/✕ the inspector chrome shows when compact). The plan carries this as a documented contingency so the smoke can trigger it without a redesign.

### T3 — sidebar-pane top safe-area CSS — mechanical, kitchen-sink
**Problem:** `.sidebar-pane` (kitchen-sink/src/style.css ~40) uses `padding-top: var(--zapp-titlebar-height, 52px)`; `--zapp-titlebar-height` is not injected on iOS → static 52px that doesn't track the status bar → iPhone header hugs the status bar / iPad overlay shows a top-gap (matrix §2 polish).
**Fix:** make the sidebar-pane top padding clear the real iOS safe area via `env(safe-area-inset-top)` (front it with the cross-platform var per the A1 idiom: `var(--zapp-safe-area-top, env(safe-area-inset-top))` where appropriate, since `--zapp-safe-area-*` is macOS-injected / iOS-env). Demo CSS only; read the exact current rule before editing and keep macOS unaffected.

### T4 — `setCollapsible` / `setResizable` documented as macOS-only on iOS — mechanical, docs
**Problem:** both are no-ops on iOS (ios/sidebar.m ~406/410, ios/inspector.m ~333/340) — by design (iOS collapse is size-class-driven; no divider-drag affordance exists). Undocumented, so the cross-platform contract looks broken.
**Fix:** document in `docs/api-reference.md` (and the iOS handle notes) that `setCollapsible`/`setResizable` are macOS-only and no-op on iOS, with the reason. `setWidth` still works programmatically on iOS (T1). Docs-only. (Real collapsible-gating on iPad is presentation-adjacent → deferred, not in A2.)

### T5 — presentation enum honesty + runtime `setPresentation` — low-risk
**Problem:** ios/window.m (~277) only branches on `"overlay"`; `Default` and `Tile` both fall through to the system (≈`.automatic`), so configuring `tile` does NOT force side-by-side — a latent bug. There's no runtime way to switch presentation (needed as the T6 diagnostic lever + a real feature).
**Fix:**
- Make the enum honest in ios/window.m: `Default`→`preferredSplitBehavior = .automatic` (explicit), `Tile`→`.tile`, `Overlay`→`.overlay` (keep). (`SidebarPresentation` enum + parse already exist: window.nim ~50/618; `wopts_sidebar_presentation` ~278.)
- Add runtime **`sidebar.setPresentation("automatic"|"tile"|"overlay")`**: TS `SidebarHandle` method (runtime/window.ts), router route (t:4 `sidebar:set-presentation`, alongside the existing sidebar control routes), native `darwin_sidebar_set_presentation(window_id, mode)` on iOS (set `preferredSplitBehavior` [+ `preferredDisplayMode` as needed] + force relayout), macOS no-op (darwin already ignores presentation — keep). TDD the parse/normalize where there's a pure function.
- Kitchen-sink Sidebar section gets a presentation toggle (automatic/tile/overlay) — the live smoke surface for T5 **and** T6.

### T6 — iPad split presentation (RISK GATE; three independently-deferrable items) — sim-debug
The genuinely-uncertain, sim-iteration-dependent work. Each item ships or defers on its own; if one is stubborn across a couple of smoke rounds, ship the rest and split it to a follow-up task — nothing ready gets blocked.
- **T6a — landscape iPad won't tile under `.automatic`.** Ground truth (user smoke 2026-06-26): with `presentation: Default` (→`.automatic`), the sidebar is an **overlay in BOTH orientations** on iPad, not tile-in-landscape. Root-cause on sim why a wide regular-width iPad doesn't resolve to `.tile` (candidates: `preferredDisplayMode` getting set to `SecondaryOnly`, a startup collapse, column-width math forcing overlay/displace, or the `.doubleColumn`+nav-controller composition). Goal: `.automatic` actually adaptive — tile wide / overlay narrow (Mail-like). T5's `setPresentation("tile")` is the diagnostic (does forcing `.tile` even produce side-by-side?).
- **T6b — overlay dim + tap-outside-dismiss (portrait).** The portrait/overlay sidebar doesn't dim the content or collapse on tap-out (Apple's native overlay does). Root-cause (likely the full-bleed WKWebview swallowing UIKit's dimming view / touches) and restore native behavior.
- **T6c — `setWidth` re-assert after the reveal gesture.** After the swipe-reveal gesture, `setWidth` stops applying (matrix §2: "fails after a manual drag"). Re-assert `preferredPrimaryColumnWidth` + force layout / clear the user-driven state. May resolve as a side effect of T6a; verify.

## Non-goals / deferred
- Real `setCollapsible` gating on iOS (disable the hide gesture) — presentation-adjacent; revisit only if wanted later.
- Safe-area **seed-and-override** uniformity (bare `var(--zapp-safe-area-*)` everywhere) — deferred (its own small cross-platform cycle); the A1 `var(x, env(y))` idiom works today.
- iPad multi-window / `UIWindowScene` (#654/#655) — Tier C.
- macOS behavior changes — darwin sidebar/inspector are the parity reference, not modified (except confirming `setPresentation` stays a documented macOS no-op).

## Verification
- `bun run check` clean; `bun test cli/src` green (incl. any new `setPresentation` route/enum-normalize surface); iOS-sim build (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`) + default macOS build stay green.
- **Human smoke (iPhone + iPad, both orientations):** (1) Sidebar section → `Width 180/320` updates the inspector pane's "width N" on iPad (#714); (2) iPhone landscape — inspector sheet can still be dismissed; (3) sidebar-pane header sits correctly under the status bar (iPhone) with no top-gap (iPad); (4) `setPresentation` flips automatic/tile/overlay live; (5) **T6:** landscape iPad tiles (side-by-side), portrait overlay dims + tap-outside-dismisses, `setWidth` holds after the reveal gesture — per-item; any unmet T6 item is split to a follow-up.

## Task shape (for the plan)
- **T1** sidebar width emit (#714) — native, atomic (the lead mechanical fix).
- **T2** iPhone inspector sheet dismissable — native (+ documented close-button fallback).
- **T3** sidebar-pane safe-area CSS — kitchen-sink.
- **T4** collapsible/resizable docs — docs.
- **T5** presentation enum honesty + runtime `setPresentation` + KS toggle — TS + router + native + KS (could split TS/route from native if large).
- **T6** RISK GATE (a/b/c) — sim-debug; one task with three deferrable items + HUMAN SMOKE; ends the cycle.

(T1–T5 verified by iOS-sim compile + `bun test`; T6 by human smoke. Group as the plan sees fit; T3/T4 are small and may merge.)
