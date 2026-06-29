# iPhone Native Routing Model — Owned-Nav, Sidebar-First — Design

**Date:** 2026-06-29
**Branch:** `feat/ios-native-nav` (commit directly; UNMERGED)
**Program:** iOS Native Navigation, cycle **N3** (iOS native routing — the differentiator). Supersedes the N3a per-route-VC approach for the iPhone-with-sidebar case. Program doc: `docs/superpowers/specs/2026-06-27-ios-native-navigation-program-design.md`.
**Status:** Approved (architecture + R1) → writing-plans → SDD. **This spec covers the ARCHITECTURE + the FIRST sub-cycle (R1 risk gate).** R2/R3 get their own specs.

## Background — the wall (why we re-brainstormed)

The N3a risk gate **proved the per-route-webview mechanism** on the iOS sim: per-route `WKWebView`, native push, back-button + edge-swipe pop, bidirectional `routerstate`↔native sync, brk-1 teardown, `zapp.route` per-route identity, `--zapp-*` inset injection, lateral sidebar nav. But the human smoke found an **architecture wall**: per-route native VC routing **collides with `UISplitViewController`'s collapsed master-detail on iPhone**. On compact width UIKit **combines** the two column nav controllers into one `collapsedNav` (selecting a sidebar item is the master-detail content presentation); the master-detail depth lives in `collapsedNav` and `contentNav` is orphaned. Pushing route VCs onto `contentNav` reflects/nests it into `collapsedNav` (sticky route + duplicate webview + toolbar drop); pushing onto `collapsedNav` conflates our `routerDepth` with the master-detail depth (spurious no-ops). Exploration confirmed `sidebarPresentation:overlay` does **not** escape this — all presentation modes use a `.doubleColumn` split and only affect iPad regular-width layout. The wall is intrinsic to `UISplitViewController`'s compact collapse.

**Decision:** own the nav. On iPhone, host the content in an **app-owned `UINavigationController`** instead of letting `UISplitViewController` collapse-combine — preserving today's UX exactly while eliminating the collision at the source.

## §1 — Architecture: idiom-branched iOS chrome

The chrome branches by **device idiom**, scoping the rework to iPhone only:

- **iPhone (idiom = phone): NEW chrome — owned-nav, SIDEBAR-FIRST.** The window's `rootViewController` is an **app-owned `UINavigationController`** whose **root VC is the sidebar** (the section list — you start here, exactly like today). Selecting a section **pushes** the content VC; `router.push` **pushes** a route VC; `‹ back` / edge-swipe pop each level. The stack is a fixed, stable structure — `[sidebar, content, …routes]` — that *we* own, so there is no collapse-combine, no nesting, no orphaning.

  ```
  window.root = OUR UINavigationController
    [0] sidebarVC   ← start here (section list) — preserves today's sidebar-first UX
    [1] contentVC   ← pushed on section select
    [2] routeVC…    ← pushed by router.push("/detail")
  ```

- **iPad (idiom = pad): `UISplitViewController`, UNCHANGED.** Side-by-side tile on regular width; expanded `contentNav` is already a clean nav, so per-route push works there today. (iPad-multitasking *compact* width still hits the split collapse → **deferred**, adjacent to #718.)

- **macOS / Windows / desktop: UNAFFECTED.** No native-VC concept in a single webview; `router.push` is in-window content-swap + browser history (N2b), flag or no flag.

**Opaque to the developer.** The dev attaches "a sidebar"; we host it idiomatically — macOS `NSSplitView` pane, iPad `UISplitViewController` column, iPhone owned-nav root VC. Same philosophy as the iPhone **inspector = sheet** (ISP B2): we choose the native presentation; the dev gets idiomatic behavior and neither knows nor cares about the mechanism.

### What owning the collapse changes (vs `UISplitViewController` auto-collapse)
- **Free** (normal `UINavigationController` behavior now): the back button to the sidebar, **edge-swipe-from-content-back-to-sidebar**, and no collapse/expand transition to replicate (iPhone is always a stack).
- **Given up (minor, deferred):** `UISplitViewController` auto-adapts to **regular width**, so a **Plus/Max iPhone in landscape** would show sidebar+content side-by-side; our owned stack stays sidebar-first there. Recoverable later by branching on **size class** (compact→owned-nav, regular→split) instead of idiom. Deferred.
- **Gained:** clean route stack (no combine) + no toolbar orphaning — the whole point.

## §2 — Routing API direction (flag-free target)

`router.push`/`pop` should **"just work"** per platform: native VC push on iPhone, content-swap+history on desktop. **The end state has no public flag.** Client-side SPA routing (an app using the History API *inside* the content webview, never calling Zapp's `router.push`) is transparent — the owned nav just hosts the content webview at depth 1 and never pushes.

The N3a `nativeRouting` window flag is **demoted to a transitional dev gate**: it selects the owned-nav chrome on iPhone during R1/R2 so the kitchen-sink can exercise the new chrome without making it everyone's default mid-build (which would regress shipped iPhone sidebar apps before parity). **R3 flips owned-nav to the iPhone default and drops the public flag**, keeping a small **opt-*out*** for apps that specifically want the old master-detail split (a `sidebarPresentation`-style mode, future). `routerstate` mapping: the sidebar is an implicit **depth-0 chrome level**; `routerDepth` counts content + routes; **native nav depth = 1 (sidebar) + routerDepth** — a rock-stable baseline.

## §3 — R1: RISK GATE (the first sub-cycle, designed here)

**Goal:** prove the make-or-break on the iOS sim — an **app-owned `UINavigationController` (sidebar-first) hosts the sidebar + content + a pushed route VC cleanly**, with native push/back/swipe and the **toolbar surviving**, on iPhone, gated so the shipped split is untouched.

**Gate:** `idiom == phone` **AND** the window's `nativeRouting` flag (`zapp_window_native_routing`, already threaded). On → owned-nav chrome; off (or iPad) → existing `UISplitViewController`, untouched.

**Components (minimal to prove viability):**
1. **Chrome construction** — `window.m`'s iPhone path, when gated on, builds the owned-nav chrome instead of the split: create the sidebar pane VC (sidebar webview, via the existing `create_ext` container path) as the **root** of an app-owned `UINavigationController`; set `window.rootViewController` = that nav. A new focused source (e.g. `native/platform/ios/iphonenav.m`) owns this construction. The iPad/no-sidebar/non-gated paths are unchanged.
2. **Section select → push content** — selecting a section in the sidebar webview pushes the content pane VC (content webview) onto the owned nav (depth 1). (Exact section-switch semantics — e.g. pop-to-sidebar then push, vs replace — are an R1 implementation detail; the gate only needs select→content→drill→back to work coherently.)
3. **Route push on the owned nav** — `routing.m`'s `zapp_routing_nav` returns the **owned nav** for this chrome; the existing N3a reconcile pushes a `ZappRouteVC` (route webview) with `want_native = 1 + routerDepth` (stable baseline), reusing the compose-delegate, brk-1 teardown, `zapp.route` identity, and `--zapp-*` inset injection unchanged.
4. **Toolbar on the owned nav** — N1's toolbar attaches to the content/route VC's `navigationItem` on a nav with a **reliable `topViewController`** (no collapsed/`contentVC` workaround). R1 proves items **persist across a push+back**.

**The human iOS-sim SMOKE (R1's gate; you run it):** on iPhone —
- (a) App starts on the **sidebar** (section list).
- (b) Select a section → content **pushes** in (native slide), `‹ back` returns to the sidebar; edge-swipe-back works.
- (c) `router.push("/detail")` → a route VC **pushes** onto the owned nav (native slide), back-button + edge-swipe pop it; route stays coherent.
- (d) **Toolbar items persist** across the push+back (the N3a toolbar-drop is gone).
- (e) No sticky route / no duplicate inspectable webview / route webviews tear down on pop.

**Reuses from the N3a WIP (carry forward, retargeted to the owned nav):** `webview.m` `zapp.route` injection; `toolbar.m` `zapp_ios_toolbar_inject_webview_safe_area`; `routing.m` reconcile + `ZappRoutingNavDelegate` (compose + self-heal) + unified `didShow` teardown + `pushedVCs`; kitchen-sink lateral sidebar nav (`popToRoot`+`replace` on iOS) + per-route identity render (`!canGoBack`). **Throwaway from N3a WIP:** the `collapsedNav`-vs-`contentNav` targeting (`zapp_routing_nav` collapse logic) and all the diagnostic `NSLog`s.

**Deferred from R1 (→ R2/R3):** full sidebar parity (gestures/insets/presentation-mode semantics on the owned nav), inspector sheet wiring, per-route chrome (title/toolbar per route), the flag-drop + default flip, large-iPhone-landscape side-by-side, iPad-multitasking-compact routing.

## §4 — Decomposition (sub-cycles)

- **R1 — RISK GATE (this spec):** owned-nav sidebar-first skeleton + section→content push + route push + toolbar-persist, gated on `phone && nativeRouting`. Ends in the human iOS-sim smoke above. If it holds, the architecture is sound.
- **R2 — iPhone chrome parity:** port the full sidebar behavior onto the owned-nav model — edge-swipe/gesture parity, safe-area insets, inspector sheet, toolbar reapply, pane-event fan-out (#627/#713) — to reach parity with today's shipped iPhone sidebar. Keep the iPad split intact.
- **R3 — wire routing + retire the flag:** full N3 routing on the owned nav (params, per-route chrome) + flip owned-nav to the iPhone default + drop the public `nativeRouting` flag (keep the master-detail opt-out) + the kitchen-sink demo.

## §5 — Out of scope / deferred (tracked)
- Large-iPhone-landscape (regular-width) side-by-side on iPhone (size-class branch) — future.
- iPad-multitasking-compact-width routing (split collapses there too) — #718-adjacent, deferred.
- Per-route webview cache + state restore — N3b (#770).
- Content-first + hamburger-drawer presentation as an optional `sidebarPresentation` mode — future.

## §6 — Risks
1. **Regressing shipped iPhone sidebar behavior** — mitigated by gating the new chrome (`phone && nativeRouting`) so the split stays the default through R1/R2; parity reached in R2 before R3 flips the default.
2. **Section-switch semantics on a pure nav stack** (vs master-detail) — R1 keeps it minimal; R2 nails the full UX (incl. switching sections without losing drill state where desired).
3. **Toolbar reapply on the owned nav** — should be *simpler* than the collapsed workaround (reliable `topViewController`); the R1 smoke confirms persist.
4. **`routerstate` depth-0 sidebar mapping** — the sidebar is a chrome level below `routerDepth`; `native = 1 + routerDepth` must hold across section-select/drill/back; covered by R1.

## Constraints
Branch `feat/ios-native-nav` (commit directly), UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun; native-first parity (TS runtime ↔ Nim router/stack ↔ iOS native; Nim faithful to the wire; `reference_ios_symbol_parity_gate` for new symbols); **macOS MUST NOT regress** (iOS-only, `when defined(zappIos)`/`TARGET_OS`-gated; the iPad split path also unchanged); iOS arm64 / min 15.0, sim functional / device compile-only; NO iOS simulator interaction in-session (build gates + human sim smoke run by the user); default iOS engine zjs; NO git worktree, NO `git commit --amend`, NO merge. Gates: `bun run check`, `bun test cli/src`, `bun run test:native`, macOS build, iOS compile (+ the human iOS-sim smoke at R1).
