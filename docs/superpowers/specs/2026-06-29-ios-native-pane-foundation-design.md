# iOS Native Pane Foundation — Design

**Date:** 2026-06-29
**Branch:** `feat/ios-native-nav` (UNMERGED)
**Status:** Approved design → ready for writing-plans
**Supersedes:** the R1′/R2′/R3′ patch sequence on the existing iOS routing machinery
**Reference implementation:** `spikes/ios-splitview-reference/` (clean-room, ObjC, now a `tripleColumn` reference — every behavior below is human-smoked on iPhone + iPad sims)

---

## 1. Problem

Zapp's iOS pane/navigation layer is **not idiomatic**, and that non-idiomatic machinery has manufactured a recurring, un-patchable bug family (nav-bar desync / sticky route / duplicate webview), confirmed over multiple failed patch rounds.

Concretely, the current native code:

- builds `UISplitViewControllerStyleDoubleColumn` (`native/platform/ios/window.m:385`) — Primary=sidebar, Secondary=content — and **never uses `tripleColumn` at all**;
- crams the **inspector as a custom trailing pane inside the content VC** (`window.m:91`), not as the split's third column (a sheet on iPhone);
- toggles sidebar↔content with `showColumn(compact)` on a **separate content nav rooted at a persistent content VC**, and manages `navigationBarHidden` by hand;
- coordinates section rendering through a **router-event broadcast + a JS render gate across multiple webviews**.

Pushing `/detail` mutates that shared content nav — minting a second per-route webview, flipping the bar on via `willShow` (never flipped back, because the sidebar is a *different* nav), and corrupting the broadcast/gate section coordination. The result is the bug family. The clean-room spike — which drives `UISplitViewController` idiomatically and never touches `navigationBarHidden` outside per-route declarations — has **none** of it.

**Decision:** stop patching; rebuild the iOS pane host on the idiomatic, spike-proven model. The kitchen-sink is too large to debug in, so the model was proven clean-room-first and is ported here.

---

## 2. Proven facts (the spike, human-smoked iPhone + iPad)

These are not assumptions — each was verified on the simulator with `[zapp-nav]` log traces.

1. **iPhone collapses a `tripleColumn` split into ONE navigation stack.** UIKit's *default* proposed top column on collapse is the **Secondary** (inspector). `showColumn:` is **left-inclusive** — it reveals the named column *and everything to its left*.
2. **Land-on-content recipe:** section-select calls `showColumn:Supplementary` → lands on **content**, leaving the inspector out of the compact stack; `topColumnForCollapsingToProposedTopColumn → Primary` → cold-launch on the sidebar.
3. **Per-route navbar-hidden is independent of swipe-back.** A full-bleed route with `navigationBarHidden = YES` still swipes back, via: re-arm `interactivePopGestureRecognizer.delegate` + `gestureRecognizerShouldBegin → viewControllers.count > 1`; `requireGestureRecognizerToFail:` between the webview scroll-pan and the edge-pop; `allowsBackForwardNavigationGestures = NO` (Zapp routes are SPAs — no web history; the edge-swipe pops the **native VC**). iOS 26 `interactiveContentPopGestureRecognizer` also enabled where available.
4. **Per-route webview teardown is mandatory.** A route VC that registers a `WKScriptMessageHandler` and never removes it leaks (userContentController→self retain cycle). Teardown on `viewDidDisappear` when `isMovingFromParentViewController` (`removeScriptMessageHandlerForName` + `stopLoading` + nil delegates) → the VC deallocs.
5. **Per-pane toolbars work and are the native look.** Each column is its own `UINavigationController` owning its own `navigationItem`, so the sidebar (compose ✎), content (its toolbar), and inspector (info ⓘ) render as three independent native bars side-by-side on iPad.
6. **Insets are free from `env(safe-area-inset-*)`** with the standard edge-pinned WKWebView mount (already fixed via `document.head→documentElement`; 62/86/116px confirmed). No native inset injection.

---

## 3. Design

### 3.1 Pane host — idiomatic `UISplitViewController`, style by declared panes

A window declares optional `sidebar` + optional `inspector`. The native iOS host picks the structure:

| Declared panes | Split style | Columns |
|---|---|---|
| sidebar + content + inspector | `tripleColumn` | Primary=sidebar, Supplementary=content, Secondary=inspector |
| sidebar + content | `doubleColumn` | Primary=sidebar, Secondary=content |
| content only | none | plain nav-wrapped content |

Each column is a `UINavigationController` wrapping a VC that owns **one** edge-pinned `WKWebView`. iPad/Mac tile columns side-by-side; iPhone collapses. **macOS (AppKit `NSSplitView`) is a separate code path (`native/platform/darwin/*`) and is untouched.**

### 3.2 iPhone collapse behavior (the proven recipe)

- Cold-launch on the sidebar (`topColumnForCollapsing → Primary`).
- Section-select calls `showColumn:Supplementary` → lands on **content** (inspector stays out of the compact stack).
- Drill-down routes (e.g. `/detail`) `pushViewController:` a route VC onto the content nav.
- The **inspector is reached via a navbar button** on the content bar that branches on `splitViewController.isCollapsed`.

### 3.3 Inspector presentation (compact)

On compact (iPhone) the inspector button is configurable via `inspector.presentation`:

- **`"push"`** — push the inspector as a page/route onto the content nav (default; spike-proven).
- **`"sheet"`** — present it modally via `UISheetPresentationController` (Zapp's legacy iPhone inspector behavior).

On iPad/regular width the inspector is always the **third column**, and the button **toggles** it (`isVisible ? hideColumn:Secondary : showColumn:Secondary`). This mirrors the existing `sidebarPresentation` option.

### 3.4 Per-pane + per-route chrome

Each **pane** (sidebar / content / inspector) **and** each **route** declares its own:

- **toolbar items** → rendered into that pane's/route's `navigationItem` (independent native bars);
- **title**;
- **`navbar.hidden: boolean`** — default shown, hideable per route, **independent of swipe-back** (§2.3).

This is the per-pane/per-route chrome model and folds the former R2′ per-view-chrome opt-out into the foundation. It aligns with the iOS-per-column vs macOS-spanning toolbar placement already specified (commit `25a2f1c`): iOS renders per-pane `UINavigationItem` bars; macOS renders one spanning `NSToolbar`.

### 3.5 Per-route webview lifecycle

A drill-down route mints its own webview on push; on pop the VC **tears down** (`removeScriptMessageHandlerForName` + `stopLoading` + nil delegates) so it deallocs. (Zapp already has `zapp_route_vc_teardown` for this — `reference_wkwebview_teardown`.)

### 3.6 Insets

Keep the `env(safe-area-inset-*)` model (the `document.head→documentElement` fix in `ios/webview.m`). Remove any native inset-injection machinery the old path relied on.

---

## 4. Scope, sequencing, and what we delete

**This is one iOS foundation cycle (iPhone + iPad), risk-gated into four phases.** iPhone is smoked at each gate; iPad at the end. macOS (`darwin/*`) is a **regression guard**, not a build target.

- **Phase 1 (RISK GATE) — pane-host seam:** idiomatic split-by-pane-count + the iPhone collapse recipe (`showColumn:Supplementary`, `topColumnForCollapsing → Primary`, inspector-as-button) + per-pane `UINavigationController`s. *Smoke: land-on-content, columns tile on iPad.*
- **Phase 2 — per-route + per-pane chrome + lifecycle:** per-route `navbar.hidden` + swipe re-arm + per-route webview teardown + per-pane/per-route toolbar items. *Smoke: no-navbar detail swipes back + deallocs; three independent bars.*
- **Phase 3 — inspector presentation:** `inspector.presentation: "push" | "sheet"` (compact) + iPad inspector real-toggle. *Smoke: both modes on iPhone; toggle on iPad.*
- **Phase 4 — kitchen-sink rebuild + iPad polish + docs:** rebuild the kitchen-sink shell on the new seam (reverting the debugging probes added during diagnosis: the `main-pane.ts` overlay, `index.html` red banner, `sidebar-pane.ts` logs); exercise all `width`/`minWidth`/`maxWidth`/`resizable`/`collapsible`/`presentation` sidebar+inspector options; address the iPad detail-route inset; final 2-device smoke; update docs.

**Delete from the current iOS code:** the `doubleColumn` build + inspector-crammed-in-content-VC; the `showColumn`-reveal sidebar↔content toggle + manual `navigationBarHidden` management; the broadcast + JS-render-gate section coordination.

**Keep:** the `env()` inset fix; the per-route webview identity model (with the teardown now mandatory); the existing TS/Nim window/sidebar/inspector option surface (extended with `inspector.presentation`).

---

## 5. Constraints (binding)

- Branch `feat/ios-native-nav`; **no** worktree, **no** `commit --amend`, **no** merge.
- **macOS must not regress** — `native/platform/darwin/*` untouched; verify the macOS 3-panel + NSToolbar still build and run at each gate.
- **No iOS-simulator interaction in-session** — every smoke is run by the human; build-only on our side, and a build is "complete" only on `[zapp] build complete:` + a fresh binary mtime (not Vite `✓ built`).
- **Per-file `git add` only** (never `-A`/`.`); pre-existing unrelated WIP stays unstaged.
- Commit trailer exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
  ```
- Always Bun, never Node.
- Native-first: every feature lands C/ObjC primitive → Nim → router → TS runtime → docs in the same phase.

---

## 6. Testing

- **Unit (TDD where applicable):** option parsing (`inspector.presentation`, per-route chrome) in Nim + TS, via `bun test` / `zc-run`; the iOS symbol-parity gate (`reference_ios_symbol_parity_gate`).
- **Build gate:** iOS-sim cross-compile must pass at every phase; macOS build must pass.
- **Human smoke (per phase, both devices at the end):** the spike's run sheet is the template — install via `simctl`, `log stream` the `[zapp-nav]` channel, exercise the documented sequence.

---

## 7. Open questions

None blocking. Deferred polish tracked for Phase 4 / follow-ups: iPad detail-route inset value; live sidebar-resize emit during drag (#720); animate tile→overlay sidebar transition (#721).
