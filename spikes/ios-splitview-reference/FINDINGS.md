# FINDINGS — ios-splitview-reference Phase 1

## Observe List

### iPhone (collapsed)

> **PASS** — iPhone (collapsed): idiomatic UIKit gave sidebar-first collapse, native back button,
> edge-swipe-back, and correct per-VC toolbar (compose / filter+share / trash — no duplication,
> no stale) with ZERO custom code.

- [x] (a) App starts on the **Sidebar** (Sections list) — not the Content VC.
- [x] (b) Tap a section → Content slides in with a **back button** to the Sidebar.
- [x] (c) **Edge-swipe from the left pops back to the Sidebar** — zero custom code.
- [x] (d) "Push detail →" pushes Detail with a **back button** to Content.
- [x] (e) **Edge-swipe pops Detail** back to Content — zero custom code.
- [x] (f) Toolbar items are **correct per screen** (Sidebar: Compose; Content: Share+Filter; Detail: Trash) with no duplication and no stale items across push/pop.

### iPad (expanded)

> **PASS (with two polish nuances)** — iPad: after the `UIDeviceFamily=[1,2]` universal fix, the
> split presents both columns and adapts (tile at full width / overlay sidebar at narrower /
> Stage-Manager widths — correct UIKit adaptive behaviour). Section→content update, drill-down
> push within the content column, native back button, edge-swipe-back, and per-VC toolbar all
> worked with ZERO custom code. The #771-class bugs (disabled back/forward, toolbar drop, sticky
> route) were ABSENT.

- [x] (g) Sidebar + Content both present; layout adapts (tile vs overlay sidebar) by width — UIKit's call, not ours.
- [x] (h) Tapping a section updates the Content column in place; sidebar stays.
- [x] (i) "Push detail →" pushes within the Content column; sidebar stays; native back button + edge-swipe both work.
- [x] (j) Toolbar items correct in the Content column after push/pop (filter+share → trash), no duplication/stale.

**Nuances (POLISH, not architecture):**
- **N1 — section tap while drilled into Detail doesn't route** (stays on Detail; sidebar collapses). The spike updates the content root but doesn't pop the pushed Detail first. Idiomatic fix is one line — `popToRootViewControllerAnimated:NO` on the content nav before updating + `showColumn:` — which IS Zapp's intended "lateral nav" semantics. Trivial.
- **N2 — content bleeds under the overlay sidebar** (like kitchen-sink today). The safe-area/inset layer — exactly what Phase 2 (WKWebView VCs) exists to characterise. On a true side-by-side tile the content is beside, not under, so the bleed is a presentation/inset detail to handle per displayMode.

---

## Verdict

**Overall: PASS — both idioms.** Idiomatic `UISplitViewController` + standard `pushViewController:` deliver, on iPhone (collapsed) and iPad (expanded/adaptive), the exact chrome behaviours Zapp keeps breaking: sidebar-first collapse, native back button, interactive edge-swipe-back, correct per-VC toolbar, and adaptive tile/overlay — all with **ZERO custom navigation code**.

**UIKit free behaviours confirmed (no custom code):**
- Sidebar-first on iPhone collapse (`topColumnForCollapsingToProposedTopColumn: → Primary`).
- Native back button + `interactivePopGestureRecognizer` edge-swipe on every push (iPhone stack AND iPad content column).
- Per-VC toolbar via `navigationItem.{left,right}BarButtonItems` — UIKit swaps items to match the top VC automatically; no reapply, no duplication, no stale items.
- Adaptive presentation (tile at full width, overlay sidebar when narrow / Stage Manager) — UIKit decides by size class.
- Selection via `[content showSection:]` + `showColumn:Secondary`.
- Drill-down via bare `[nav pushViewController:detail]`.

**Gaps / surprises (all polish, none architectural):**
- N1: section-tap-while-drilled needs a `popToRoot` on the content nav before switching (one line; = Zapp's lateral-nav semantics).
- N2: content bleeds under the overlay sidebar → safe-area/inset handling per displayMode (Phase 2 / kitchen-sink-inset territory).

**Implication for Zapp — the recommendation:**
R1's iPhone bugs (lost swipe, double toolbar, transient back) and iPad #771's bugs (disabled back/fwd, toolbar drop, sticky route) are **NOT** UIKit limitations — they are **manufactured by Zapp's hand-management** of what UIKit wants to own: the manual VC-stack reconcile loop, the `didShow` toolbar-reapply, the `UINavigationControllerDelegate` pop-detection, and the manual inset injection. The same bug family survived two different architectures (N3a per-route-VC-on-split, R1 owned-nav) precisely because both fight UIKit instead of driving it.

**Therefore: rebuild Zapp's iOS routing to drive `UISplitViewController` idiomatically** — push real VCs, set per-VC `navigationItem`, let UIKit own collapse / back / swipe / toolbar / adaptive presentation — and **delete** the reconcile + reapply + pop-detect machinery (and the R1 owned-nav fork). One native rewrite fixes BOTH idioms; #771 falls out of it. The only Zapp-specific work left is (1) hosting the WKWebView in the content/route VCs with correct safe-area insets [Phase 2 de-risks this], and (2) the JS/Nim-router ↔ native-VC bridge (when JS routes, native pushes; when the user pops, native tells JS).

**Open before the rebuild design:** Phase 2 (swap plain VCs → WKWebView-hosting VCs, same idiomatic nav) to characterise the safe-area/inset behaviour (N2) with real webviews — the single riskiest part of the rebuild — before committing the full design.
