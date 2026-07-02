# iPad-Expanded Routing Parity — Full #771 Close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close #771 fully per the approved spec `docs/superpowers/specs/2026-07-02-ipad-routing-parity-771-design.md`: land the routing WIP, fix the three G3 datums (inset bleed, toolbar drop, stale back/fwd), move to per-displayed-VC toolbar stamping, ship R2′ push options (`router.push(url, { title?, toolbar?, navbar?: { hidden } })`), retire the `nativeRouting` gate (R3′ remainder), fix the two newly-found issues (drop-target global, mid-stack teardown gap), then cleanup + docs.

**Architecture:** All native work is in `native/platform/ios/{routing,toolbar,sidebar,window,webview}.m` + the Nim router seam (`native/nim/router.nim`). Datum 1 is solved by factoring the existing constraint-pair edge model (leading/trailing Full+Safe pairs, trait-driven swap) into ONE shared helper in `sidebar.m` and making `ZappRouteVC` its third consumer. Datum 3 is solved structurally: the per-window `ZappIOSToolbarEntry` stays the source of truth and the nav delegate re-stamps the DISPLAYED VC at every willShow/didShow — killing the item-generation mismatch. R2′ rides the existing `router:push` window-action as a compact chrome JSON forwarded to a widened `zapp_ios_push_route_vc` seam; per-VC chrome (title / toolbar-override entry) is stored via associated objects in `toolbar.m` and applied by the same stamping choke point. The hidden-navbar + swipe-back recipe (risk gate) implements the 3-layer pattern from `.superpowers/sdd/swipe-back-research.md` with `ZappRouteNavDelegate` as the single pop-gesture owner. Two human gates: G1 (iPad-expanded, mid-cycle after datums + new issues), G2 (final combined iPhone+iPad+macOS-quick-look).

**Tech Stack:** ObjC/UIKit, Nim (ORC), TypeScript runtime (bun:test TDD for the TS surface), Bun.

## Global Constraints (binding, from the spec — unchanged)

Per-file `git add`; NO worktree/amend/merge-without-ask; commit trailer exactly `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` + `Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv`; no iOS-sim interaction in-session (human smokes; `[zapp] build complete:` + fresh mtime); Bun; parity test green; macOS must not regress (this cycle: NO darwin/* changes at all); iOS-sim + macOS builds gated per native task. SDD execution, ledger `.superpowers/sdd/progress.md`. Models: Fable 5 orchestrator + native-diff reviews + judgment tasks; Sonnet 5 implementers (escalate on block) + mechanical reviews.

Every commit in this plan ends with EXACTLY these two lines (referred to below as `<TRAILER>` — expand verbatim):

```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
```

**Verification commands (used by the gate steps):**
- iOS-sim build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios-simulator` → REQUIRE the `[zapp] build complete: <path>` line, then `ls -lT` (or `stat -f "%Sm %N"`) on the reported binary to confirm a fresh mtime. Vite `✓ built` alone is NOT success.
- macOS build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → same `[zapp] build complete:` + fresh-mtime requirement.
- Parity: `cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts`
- TS: `cd /Users/zach/code/zapp && bun run check` · `bun test runtime/router.test.ts` · `bun test runtime/window.test.ts` (where `runtime/window.ts` changes)

**Spec work-item → task map:** item 1 (WIP) → Task 0 · item 2 (edge-pin, datum 1) → Tasks 1+2 · item 3 (toolbar stamping, datum 3) → Tasks 3+4 · item 7 (new issues A+B) → Task 5 · G1 → Task 6 · item 5 (swipe risk gate) → Task 7 · item 4 (R2′ push options) → Task 8 · item 6 (R3′ gate retirement) → Task 9 · item 8 (cleanup) → Task 10 · items 9+10 (docs + kitchen-sink) → Task 11 · G2 → Task 12.

**Execution-order note:** the spec pins G1 "mid-cycle after items 1-3+7", and G1's checklist includes drag-drop targeting and the depth-2 zombie check — so the new-issues task (spec item 7) runs BEFORE gate G1, not after the push-options work. Datum 2 (toolbar drop) has no code task: its root cause is already fixed at `132ddfc`; G1 verifies the iPad-expanded cell.

**Line-number caveat:** file:line references below were verified against the working tree on 2026-07-02 but WILL drift as tasks land. Always anchor edits by the quoted code/symbol, never by line number.

---

## Task 0: Land the foreign WIP (spec item 1)

The working tree carries unstaged changes in exactly four files that this cycle depends on. Commit them as-is (they are the user's own workstream). Everything else that is dirty (`assets/*`, `spikes/*`, `vendor/bare`, `benchmarks/*`, `docs/superpowers/swiftui-pane-followups-for-review.txt`, `native/worker/engines/zjs-cross-eval-test.c`, `superpowers/`, untracked files) is NOT part of this task and must stay unstaged.

**Files:**
- Modify (commit only — no edits): `native/platform/ios/toolbar.m`, `native/platform/ios/webview.m`, `native/nim/router.nim`, `kitchen-sink/src/sections/multiwindow.ts`

**Interfaces:**
- Produces: bar-visibility single ownership — `ZappRouteNavDelegate.willShowViewController:` (routing.m, already committed) becomes the ONLY writer of `navigationBarHidden`; toolbar.m's four writes are gone. `webview.m`'s doc-start env() script appends to `(document.head||document.documentElement)` — **load-bearing for datum 1** (route webviews rely entirely on this script for insets).

- [ ] **Step 1: Read each diff.** Run and read in full:

```bash
cd /Users/zach/code/zapp
git diff native/platform/ios/toolbar.m
git diff native/platform/ios/webview.m
git diff native/nim/router.nim
git diff kitchen-sink/src/sections/multiwindow.ts
```

Confirm the content matches the spec's description: toolbar.m = removal of all four `navigationBarHidden` writes (apply_to_nav, collapsed apply path, both `darwin_toolbar_remove` branches) + `[zapp-nav]` diagnostics + `#include <stdio.h>`; webview.m = the `(document.head||document.documentElement).appendChild(s);` fix only; router.nim = `[zapp-nav]` diagnostics only (c_fprintf/c_fflush/cstderr_nav helpers + 6 log sites); multiwindow.ts = formatting only (no semantic change — verify by scanning the diff for anything that isn't reflow/quotes).

- [ ] **Step 2: Verify the three bar-primer sites still exist** (with toolbar.m no longer writing `navigationBarHidden`, these are what make the bar correct at launch before any willShow fires):

```bash
grep -n "setNavigationBarHidden:NO animated:NO" native/platform/ios/sidebar.m   # didCollapse primer (~line 662)
grep -n "ctNav.navigationBarHidden = NO" native/platform/ios/sidebar.m          # construction primer (~line 853)
grep -n "contentNav.navigationBarHidden = NO" native/platform/ios/window.m      # hidden-Primary primer (~line 824)
```

Each must return exactly one hit. If any is missing, STOP and report — do not commit.

- [ ] **Step 3: Build gates.** iOS-sim build (`[zapp] build complete:` + fresh mtime), macOS build (same), parity test, `bun run check` (multiwindow.ts touched).

- [ ] **Step 4: Commit 1 (behavior files):**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/toolbar.m native/platform/ios/webview.m
git commit -m "fix(ios): willShow owns nav-bar visibility (drop toolbar.m navigationBarHidden writes) + doc-start env() head fix

toolbar.m: all four navigationBarHidden writes removed — ZappRouteNavDelegate's
willShowViewController: (routing.m) is now the exclusive bar-visibility owner.
Launch primers verified in all three window shapes (sidebar.m didCollapse +
construction, window.m hidden-Primary). Also carries [zapp-nav] apply-path
diagnostics (swept at end of #771).
webview.m: document.head is null at AtDocumentStart — append the :root env()
style to documentElement so route webviews get their safe-area vars (load-
bearing for the #771 inset-bleed fix).

<TRAILER>"
```

- [ ] **Step 5: Commit 2 (diagnostics + formatting):**

```bash
git add native/nim/router.nim kitchen-sink/src/sections/multiwindow.ts
git commit -m "chore: [zapp-nav] router.nim push/pop diagnostics + multiwindow formatting pass

Diagnostics are temporary (#771 cleanup sweep removes every [zapp-nav] site).

<TRAILER>"
```

---

## Task 1: Shared edge-pin helper (spec item 2, first half)

Extract the duplicated constraint-pair edge model into ONE exported helper pair in `sidebar.m`; refactor both existing consumers onto it. This task does NOT touch routing.

**Files:**
- Modify: `native/platform/ios/sidebar.m` (new helpers + `zapp_ios_update_content_edges` + `zapp_ios_sidebar_set_content_webview` become thin wrappers)
- Modify: `native/platform/ios/window.m` (`zapp_updateContentEdges` + `zapp_ios_pin_content_webview_no_sidebar` become thin wrappers)

**Interfaces:**
- Produces (consumed by Task 2's `ZappRouteVC` and by both refactored call sites):

```objc
void zapp_ios_edge_pin_webview(WKWebView* wv, UIView* container,
                               NSLayoutConstraint* __autoreleasing * outLeadingFull,
                               NSLayoutConstraint* __autoreleasing * outLeadingSafe,
                               NSLayoutConstraint* __autoreleasing * outTrailingFull,
                               NSLayoutConstraint* __autoreleasing * outTrailingSafe);
void zapp_ios_edge_pin_update(BOOL isRegular,
                              NSLayoutConstraint* leadingFull,
                              NSLayoutConstraint* leadingSafe,
                              NSLayoutConstraint* trailingFull,
                              NSLayoutConstraint* trailingSafe,
                              UIView* layoutView);
```

- [ ] **Step 1: Add the helpers in sidebar.m**, directly above `zapp_ios_update_content_edges` (keep the existing "Content-webview edge constraint management" doc comment — it documents the model both helpers implement):

```objc
// --- Shared edge-pin helper (#771) ------------------------------------------
//
// ONE implementation of the constraint-pair edge model documented above
// (leading+trailing Full/Safe pairs; top/bottom always full-frame), consumed
// by all three content surfaces: the sidebar shape (this file), the
// hidden-Primary shape (window.m), and pushed route VCs (routing.m).
//
// zapp_ios_edge_pin_webview converts wv from autoresizingMask (set by
// webview.m) to explicit Auto Layout, pins top/bottom to the container, and
// creates — WITHOUT activating — the four leading/trailing constraints,
// returned via the out-params. The caller stores them in strong properties
// and calls zapp_ios_edge_pin_update to activate the pair for the current
// trait (and again on every trait / size-transition change).
void zapp_ios_edge_pin_webview(WKWebView* wv, UIView* container,
                               NSLayoutConstraint* __autoreleasing * outLeadingFull,
                               NSLayoutConstraint* __autoreleasing * outLeadingSafe,
                               NSLayoutConstraint* __autoreleasing * outTrailingFull,
                               NSLayoutConstraint* __autoreleasing * outTrailingSafe) {
    if (!wv || !container) return;
    wv.translatesAutoresizingMaskIntoConstraints = NO;
    // Top / bottom stay full-frame (not safe-area): the pane is the visible
    // surface; no top/bottom insets (device notches must not shrink content).
    [NSLayoutConstraint activateConstraints:@[
        [wv.topAnchor constraintEqualToAnchor:container.topAnchor],
        [wv.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];
    if (outLeadingFull)
        *outLeadingFull  = [wv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor];
    if (outLeadingSafe)
        *outLeadingSafe  = [wv.leadingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor];
    if (outTrailingFull)
        *outTrailingFull = [wv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor];
    if (outTrailingSafe)
        *outTrailingSafe = [wv.trailingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor];
}

// Activate the correct pair for the given size class: regular → safe-area
// anchors (track the tiled sidebar's leading inset and the iOS-26 Inspector
// column's trailing inset), compact → raw view anchors (full-bleed).
// layoutView is forced through a layout pass so the swap takes effect
// immediately.
void zapp_ios_edge_pin_update(BOOL isRegular,
                              NSLayoutConstraint* leadingFull,
                              NSLayoutConstraint* leadingSafe,
                              NSLayoutConstraint* trailingFull,
                              NSLayoutConstraint* trailingSafe,
                              UIView* layoutView) {
    if (!leadingFull || !leadingSafe || !trailingFull || !trailingSafe) return;
    if (isRegular) {
        leadingFull.active  = NO;
        trailingFull.active = NO;
        leadingSafe.active  = YES;
        trailingSafe.active = YES;
    } else {
        leadingSafe.active  = NO;
        trailingSafe.active = NO;
        leadingFull.active  = YES;
        trailingFull.active = YES;
    }
    [layoutView setNeedsLayout];
    [layoutView layoutIfNeeded];
}
```

- [ ] **Step 2: Refactor sidebar.m's own consumers.** Replace the body of `zapp_ios_update_content_edges` (keep its guards — `c.splitVC` is the trait source here):

```objc
static void zapp_ios_update_content_edges(ZappIOSSidebarController* c) {
    if (!c || !c.leadingFull || !c.leadingSafe) return;
    if (!c.trailingFull || !c.trailingSafe) return;
    if (!c.splitVC) return;
    BOOL isRegular = (c.splitVC.traitCollection.horizontalSizeClass
                      == UIUserInterfaceSizeClassRegular);
    zapp_ios_edge_pin_update(isRegular, c.leadingFull, c.leadingSafe,
                             c.trailingFull, c.trailingSafe, c.contentVC.view);
}
```

and the pin block inside `zapp_ios_sidebar_set_content_webview` (everything from `wv.translatesAutoresizingMaskIntoConstraints = NO;` through the four `c.trailingSafe = trailingSafe;` assignments) with:

```objc
        NSLayoutConstraint *leadingFull = nil, *leadingSafe = nil,
                           *trailingFull = nil, *trailingSafe = nil;
        zapp_ios_edge_pin_webview(wv, container,
                                  &leadingFull, &leadingSafe,
                                  &trailingFull, &trailingSafe);
        c.leadingFull  = leadingFull;
        c.leadingSafe  = leadingSafe;
        c.trailingFull = trailingFull;
        c.trailingSafe = trailingSafe;
```

(keep the trailing `zapp_ios_update_content_edges(c);` call and the explanatory comments about WHY pairs exist on both edges — move them onto the helper call).

- [ ] **Step 3: Refactor window.m's consumers.** Add file-scope externs near the other `zapp_ios_*` externs in window.m:

```objc
// Shared edge-pin helper (ios/sidebar.m, #771): one implementation of the
// Full/Safe constraint-pair edge model. See sidebar.m's header comment.
extern void zapp_ios_edge_pin_webview(WKWebView* wv, UIView* container,
                                      NSLayoutConstraint* __autoreleasing * outLeadingFull,
                                      NSLayoutConstraint* __autoreleasing * outLeadingSafe,
                                      NSLayoutConstraint* __autoreleasing * outTrailingFull,
                                      NSLayoutConstraint* __autoreleasing * outTrailingSafe);
extern void zapp_ios_edge_pin_update(BOOL isRegular,
                                     NSLayoutConstraint* leadingFull,
                                     NSLayoutConstraint* leadingSafe,
                                     NSLayoutConstraint* trailingFull,
                                     NSLayoutConstraint* trailingSafe,
                                     UIView* layoutView);
```

Replace `-[ZappIOSHiddenPrimarySplitViewController zapp_updateContentEdges]`'s body:

```objc
- (void)zapp_updateContentEdges {
    if (!self.leadingFull || !self.leadingSafe) return;
    if (!self.trailingFull || !self.trailingSafe) return;
    BOOL isRegular = (self.traitCollection.horizontalSizeClass
                      == UIUserInterfaceSizeClassRegular);
    zapp_ios_edge_pin_update(isRegular, self.leadingFull, self.leadingSafe,
                             self.trailingFull, self.trailingSafe,
                             self.contentContainer);
}
```

and `zapp_ios_pin_content_webview_no_sidebar`'s body (keep the function + its "why a window.m helper" comment, but note the shared factoring supersedes the "mirroring ~25 lines" rationale — update that comment paragraph to say the constraint construction now lives in the shared helper, only the storage-on-split differs):

```objc
static void zapp_ios_pin_content_webview_no_sidebar(
        ZappIOSHiddenPrimarySplitViewController* split,
        WKWebView* wv, UIView* container) {
    if (!split || !wv || !container) return;

    NSLayoutConstraint *leadingFull = nil, *leadingSafe = nil,
                       *trailingFull = nil, *trailingSafe = nil;
    zapp_ios_edge_pin_webview(wv, container,
                              &leadingFull, &leadingSafe,
                              &trailingFull, &trailingSafe);

    split.contentContainer = container;
    split.leadingFull  = leadingFull;
    split.leadingSafe  = leadingSafe;
    split.trailingFull = trailingFull;
    split.trailingSafe = trailingSafe;

    // Activate the correct pair for the current trait.
    [split zapp_updateContentEdges];
}
```

- [ ] **Step 4: Behavior-preservation check.** `git diff` review: the four constraints created, the anchors used, the activation order, and the layout-force target (`c.contentVC.view` / `self.contentContainer`) must be byte-for-byte semantically identical to the pre-refactor code. No routing.m changes in this task.

- [ ] **Step 5: Gates.** iOS-sim build + macOS build (both `[zapp] build complete:` + fresh mtime) + parity test.

- [ ] **Step 6: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/sidebar.m native/platform/ios/window.m
git commit -m "refactor(ios): extract shared edge-pin helper from the sidebar.m + window.m constraint-pair copies

zapp_ios_edge_pin_webview / zapp_ios_edge_pin_update: one implementation of
the Full/Safe leading+trailing pair model. Both existing consumers (sidebar
shape, hidden-Primary shape) are thin wrappers now; route VCs become the
third consumer next (#771 datum 1).

<TRAILER>"
```

---

## Task 2: `ZappRouteVC` adopts the edge-pin model (spec item 2, second half — datum 1)

**Files:**
- Modify: `native/platform/ios/routing.m`

**Interfaces:**
- Consumes: `zapp_ios_edge_pin_webview` / `zapp_ios_edge_pin_update` (Task 1 signatures above).
- Produces: `ZappRouteVC` with stored constraint properties (`leadingFull/leadingSafe/trailingFull/trailingSafe`) swapped on trait + size changes. The dead injector call + extern are deleted.

- [ ] **Step 1: Replace the `ZappRouteVC` interface** (current lines ~59-61) with:

```objc
// Route VC: a plain UIViewController hosting its own WKWebView.
// Tagged so the delegate can distinguish route VCs from the root contentVC.
// Edge model (#771 datum 1): the webview is pinned via the shared Full/Safe
// constraint-pair helper (sidebar.m) — on iPad regular width UIKit expresses
// the tiled sidebar (leading) and the iOS-26 Inspector column (trailing) as
// SAFE-AREA INSETS on the full-width Secondary column, so a raw-pinned route
// webview slides under both. The pairs are stored here and swapped per
// horizontal size class, exactly like the content webview's.
@interface ZappRouteVC : UIViewController
@property (nonatomic, weak) WKWebView* webview;
@property (nonatomic, strong) NSLayoutConstraint* leadingFull;
@property (nonatomic, strong) NSLayoutConstraint* leadingSafe;
@property (nonatomic, strong) NSLayoutConstraint* trailingFull;
@property (nonatomic, strong) NSLayoutConstraint* trailingSafe;
@end
```

- [ ] **Step 2: Replace the `viewDidLayoutSubviews` override** (the dead injector hook, current lines ~68-74) inside `@implementation ZappRouteVC` with the edge-swap triggers (same two re-switch triggers the other consumers use):

```objc
- (void)zapp_updateEdges {
    if (!self.leadingFull || !self.leadingSafe) return;
    if (!self.trailingFull || !self.trailingSafe) return;
    BOOL isRegular = (self.traitCollection.horizontalSizeClass
                      == UIUserInterfaceSizeClassRegular);
    zapp_ios_edge_pin_update(isRegular, self.leadingFull, self.leadingSafe,
                             self.trailingFull, self.trailingSafe, self.view);
}
- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self zapp_updateEdges];
}
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil
                                     completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            (void)ctx;
            [self zapp_updateEdges];
        }];
    } else {
        [self zapp_updateEdges];
    }
}
```

Keep `viewDidDisappear:` unchanged.

- [ ] **Step 3: Delete the dead extern** — remove these lines near the top of routing.m:

```objc
// Inject --zapp-* safe-area vars into a route VC's webview after layout.
extern void zapp_ios_toolbar_inject_webview_safe_area(WKWebView* wv);
```

and add the shared-helper externs in their place:

```objc
// Shared edge-pin helper (ios/sidebar.m, #771): Full/Safe constraint-pair
// model; route VCs are its third consumer (datum 1 — iPad-expanded inset bleed).
extern void zapp_ios_edge_pin_webview(WKWebView* wv, UIView* container,
                                      NSLayoutConstraint* __autoreleasing * outLeadingFull,
                                      NSLayoutConstraint* __autoreleasing * outLeadingSafe,
                                      NSLayoutConstraint* __autoreleasing * outTrailingFull,
                                      NSLayoutConstraint* __autoreleasing * outTrailingSafe);
extern void zapp_ios_edge_pin_update(BOOL isRegular,
                                     NSLayoutConstraint* leadingFull,
                                     NSLayoutConstraint* leadingSafe,
                                     NSLayoutConstraint* trailingFull,
                                     NSLayoutConstraint* trailingSafe,
                                     UIView* layoutView);
```

Also update routing.m's file-header comment: drop the "Kept verbatim: … viewDidLayoutSubviews" clause (now false).

- [ ] **Step 4: Pin the route webview at push.** In `zapp_ios_push_route_vc`, immediately after the loop that locates `vc.webview` (the `for (UIView* sub in vc.view.subviews)` block), add:

```objc
    // #771 datum 1: convert the create_ext frame+autoresizing mount to the
    // shared edge-pin model so the route webview honors the tiled-sidebar
    // (leading) and inspector-column (trailing) safe-area insets on iPad
    // regular width, and stays full-bleed on compact.
    if (vc.webview) {
        NSLayoutConstraint *lf = nil, *ls = nil, *tf = nil, *ts = nil;
        zapp_ios_edge_pin_webview(vc.webview, vc.view, &lf, &ls, &tf, &ts);
        vc.leadingFull  = lf;
        vc.leadingSafe  = ls;
        vc.trailingFull = tf;
        vc.trailingSafe = ts;
        [vc zapp_updateEdges];
    }
```

- [ ] **Step 5: Gates.** iOS-sim build + macOS build (`[zapp] build complete:` + fresh mtime each) + parity test. Also `grep -n "zapp_ios_toolbar_inject_webview_safe_area" native/platform/ios/routing.m` must return nothing (the toolbar.m no-op definition itself is deleted in Task 10 after a repo-wide reference check).

- [ ] **Step 6: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/routing.m
git commit -m "fix(ios): route VCs adopt the safe-area edge-pin model — no more bleed under sidebar/inspector (#771 datum 1)

ZappRouteVC stores the Full/Safe constraint pairs (shared helper) and swaps
them on trait + size-transition changes, exactly like the content webview.
Deletes the dead per-route inset injector call (no-op since the R3' env()
migration).

<TRAILER>"
```

---

## Task 3: Displayed-VC toolbar stamping (spec item 3, native half — datum 3)

Kill the toolbar-item generation mismatch: the per-window `ZappIOSToolbarEntry` keeps the defs/instances as source of truth, and the nav delegate stamps the DISPLAYED VC at every willShow/didShow. `darwin_toolbar_update_item` then always patches the instances that are actually on screen.

**Files:**
- Modify: `native/platform/ios/toolbar.m` (extract `zapp_ios_toolbar_stamp_items`, add public `zapp_ios_toolbar_stamp_vc`, dedupe the collapsed apply path)
- Modify: `native/platform/ios/routing.m` (willShow/didShow stamping)

**Interfaces:**
- Produces (consumed by routing.m here, and made override-aware in Task 8):

```objc
// toolbar.m — stamp the window's registered toolbar onto a specific VC's
// navigationItem (main thread only). No-op when no toolbar is registered.
void zapp_ios_toolbar_stamp_vc(void* window_ptr, UIViewController* vc);
```

- [ ] **Step 1: Extract the stamping body.** In toolbar.m, above `zapp_ios_toolbar_apply_to_nav`, add:

```objc
// ─── zapp_ios_toolbar_stamp_items (internal) ─────────────────────────────────
//
// #771 datum 3 (structural): the single place item buckets are written onto a
// navigationItem. Every apply path funnels here so the DISPLAYED VC always
// carries the entry's CURRENT UIBarButtonItem instances — there is no longer a
// "generation" of items left behind on a hidden VC.
static void zapp_ios_toolbar_stamp_items(UIViewController* vc,
                                         ZappIOSToolbarEntry* entry,
                                         BOOL includeToggleSidebar) {
    if (!vc || !entry) return;
    NSArray<UIBarButtonItem*>* leading = includeToggleSidebar
        ? entry.leadingItems
        : entry.leadingNoToggle;
    // Keep the system back button when items are stamped onto a pushed VC
    // (a non-nil leftBarButtonItems otherwise suppresses it).
    vc.navigationItem.leftItemsSupplementBackButton = YES;
    vc.navigationItem.leftBarButtonItems  = leading ?: @[];
    vc.navigationItem.rightBarButtonItems = entry.trailingItems ?: @[];
    // E2 / #779 collapsible→enabled wiring (live read at stamp time).
    entry.toggleSidebarButton.enabled =
        zapp_ios_sidebar_is_collapsible_for_window(entry.windowPtr);
    entry.toggleInspectorButton.enabled =
        zapp_ios_inspector_is_collapsible_for_window(entry.windowPtr);
    vc.navigationItem.title = entry.centerTitle;       // nil clears it
    vc.navigationItem.titleView = entry.centerView;    // nil clears it
}
```

Then reduce `zapp_ios_toolbar_apply_to_nav` to (keep its `[zapp-nav]` diagnostic and header comment; the E2/#779 comments move to the extracted fn):

```objc
static void zapp_ios_toolbar_apply_to_nav(UINavigationController* nav,
                                          ZappIOSToolbarEntry* entry,
                                          BOOL includeToggleSidebar) {
    if (!nav || !entry) return;
    UIViewController* vc = nav.topViewController;
    if (!vc) return;

    // [zapp-nav] diagnostic: apply_to_nav — shows which nav+topVC gets items
    fprintf(stderr, "[zapp-nav] toolbar_apply win=%d fn=apply_to_nav nav=%p topVC=%p\n",
            (int)entry.hostSlot, (__bridge void*)nav, (__bridge void*)vc);
    fflush(stderr);

    zapp_ios_toolbar_stamp_items(vc, entry, includeToggleSidebar);

    // Bar visibility is owned exclusively by ZappRouteNavDelegate's
    // willShowViewController: (routing.m). Do NOT touch navigationBarHidden here.
}
```

- [ ] **Step 2: Dedupe the collapsed apply path.** In `zapp_ios_toolbar_apply_for_window_hidden`'s collapsed branch, replace the inline stamping block (from `NSArray<UIBarButtonItem*>* leading = entry.leadingItems; // include toggleSidebar` through `contentVC.navigationItem.titleView = entry.centerView;    // nil clears it`) with:

```objc
            // Collapsed always includes the manual toggleSidebar (UIKit shows
            // no system reveal button in compact).
            zapp_ios_toolbar_stamp_items(contentVC, entry, YES);
```

Keep the surrounding comments about targeting the authoritative contentVC.

- [ ] **Step 3: Add the public per-VC stamp entry point** (after `zapp_ios_toolbar_apply_for_window`):

```objc
// ─── zapp_ios_toolbar_stamp_vc ───────────────────────────────────────────────
//
// #771 datum 3: stamp the window's registered toolbar onto a SPECIFIC VC —
// called by ZappRouteNavDelegate (routing.m) at willShow/didShow so the VC
// being shown always receives the entry's current item instances (content VC
// after a pop, route VC at push). The include-toggle decision is the same
// live-state read set_items uses. Main thread only.
void zapp_ios_toolbar_stamp_vc(void* window_ptr, UIViewController* vc) {
    if (!window_ptr || !vc || !zapp_ios_toolbars) return;
    NSCAssert([NSThread isMainThread],
              @"zapp_ios_toolbar_stamp_vc must be called on the main thread");
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSToolbarEntry* entry = zapp_ios_toolbars[key];
    if (!entry) return;
    BOOL collapsed = zapp_ios_split_is_collapsed_for_window(window_ptr);
    BOOL includeToggle = collapsed
        ? YES
        : !zapp_ios_split_display_mode_is_secondary_only(window_ptr);
    zapp_ios_toolbar_stamp_items(vc, entry, includeToggle);
}
```

- [ ] **Step 4: Stamp from the nav delegate.** In routing.m, add the extern near `zapp_toolbar_inject_metrics`'s:

```objc
// #771 datum 3: stamp the window's toolbar defs onto the VC being shown
// (defined in ios/toolbar.m).
extern void zapp_ios_toolbar_stamp_vc(void* window_ptr, UIViewController* vc);
```

In `willShowViewController:`, after the `if (nav.navigationBarHidden == showBar) { ... }` visibility block, add:

```objc
    // #771 datum 3 (structural): stamp the window's toolbar defs onto the VC
    // being shown. UIKit mutates viewControllers before this delegate fires,
    // so the incoming VC gets the CURRENT item instances during the
    // transition — and the revealed content VC gets them back after a pop
    // (this is what killed the old generation mismatch: a pop used to reveal
    // a bar holding instances that updateItem no longer patched).
    if (showBar && win) zapp_ios_toolbar_stamp_vc(win, vc);
```

In `didShowViewController:`, after the `if (willPopFromNative) { ... }` block, add:

```objc
    // #771 datum 3: re-stamp after the transition settles — covers cancelled
    // interactive swipes (willShow fired for a VC that never landed; didShow
    // always reports the real top) and guarantees the displayed bar holds the
    // instances darwin_toolbar_update_item patches.
    void* winPtr = darwin_window_get_by_numeric_id(self.windowId);
    if (winPtr) {
        UIViewController* shownContentVC = zapp_ios_content_vc_for_window(winPtr);
        BOOL shownIsContent = (shownContentVC && vc == shownContentVC);
        BOOL shownIsRoute = [vc isKindOfClass:[ZappRouteVC class]];
        if (shownIsContent || shownIsRoute)
            zapp_ios_toolbar_stamp_vc(winPtr, vc);
    }
```

- [ ] **Step 5: Retire the push-time comment.** In `zapp_ios_push_route_vc`, replace the "Don't force-stamp toolbar items at push time…" comment block (5 lines ending "…not the route-specific items.") with:

```objc
    // Toolbar items are stamped by the nav delegate (zapp_ios_toolbar_stamp_vc
    // at willShow/didShow) — defs-as-truth, displayed-VC stamping. Nothing to
    // do at push time.
```

- [ ] **Step 6: Gates.** iOS-sim build + macOS build (`[zapp] build complete:` + fresh mtime each) + parity test.

- [ ] **Step 7: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/toolbar.m native/platform/ios/routing.m
git commit -m "fix(ios): displayed-VC toolbar stamping — willShow/didShow re-stamp kills the item-generation mismatch (#771 datum 3)

One stamping choke point (zapp_ios_toolbar_stamp_items); the nav delegate
stamps the shown VC on every transition, so a pop reveals a bar holding the
SAME instances darwin_toolbar_update_item patches. Collapsed apply path
deduped onto the same helper.

<TRAILER>"
```

---

## Task 4: Kitchen-sink `syncToolbar` on route webviews (spec item 3, TS half)

**Files:**
- Modify: `kitchen-sink/src/shell/main-pane.ts`

**Interfaces:**
- Consumes: existing `RouterHandle.on/current()` + `ToolbarHandle.updateItem` (no signature changes).

- [ ] **Step 1: Fix the fixed-route early return.** In `renderMainPane`'s `win.router.on` handler, replace:

```ts
    if (Platform.isIOS) {
      if (myRoute) return;            // fixed-route webview — never re-renders
```

with:

```ts
    if (Platform.isIOS) {
      if (myRoute) {
        // Fixed-route webview: never re-renders, but its toolbar back/fwd
        // items must still track live router state (#771 datum 3 sibling —
        // without this, pushed pages render back/fwd permanently disabled).
        syncToolbar(e.canGoBack, e.canGoForward);
        return;
      }
```

- [ ] **Step 2: Seed on boot.** Replace the fixed-route bootstrap branch:

```ts
  if (Platform.isIOS && myRoute) {
    // Pushed route VC: render its own fixed route once.
    renderRoute(myRoute);
  } else {
```

with:

```ts
  if (Platform.isIOS && myRoute) {
    // Pushed route VC: render its own fixed route once, then seed the toolbar
    // back/fwd enabled state from the authoritative router snapshot (#771).
    renderRoute(myRoute);
    win.router.current()
      .then((snap) => syncToolbar(snap.canGoBack, snap.canGoForward))
      .catch(() => { /* best-effort */ });
  } else {
```

- [ ] **Step 3: Gates.** `bun run check` + iOS-sim build (`[zapp] build complete:` + fresh mtime — the sim bundle carries the TS).

- [ ] **Step 4: Commit:**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/main-pane.ts
git commit -m "fix(kitchen-sink): route webviews run syncToolbar — live back/fwd on pushed pages (#771)

<TRAILER>"
```

---

## Task 5: New issues A + B — drop-target retarget + covered-VC teardown (spec item 7)

**Files:**
- Modify: `native/platform/ios/webview.m` (expose a setter for the file-static drop global)
- Modify: `native/platform/ios/routing.m` (didShow retarget; explicit teardown in `zapp_ios_pop_to_content`; `tornDown` idempotency flag)

**Interfaces:**
- Produces: `void zapp_ios_set_drop_webview(void* webview_ptr)` (webview.m); `ZappRouteVC.tornDown` (BOOL, internal).
- Consumes: `zapp_ios_content_webview_for_slot(int32_t)` (already extern'd in routing.m), `zapp_route_vc_teardown` (same file).

- [ ] **Step 1 (A): Setter in webview.m.** `zapp_ios_drop_webview` is `static WKWebView* zapp_ios_drop_webview = nil;` (~line 411) — not externally assignable. Add directly below the `zapp_ios_drop_webview = webview;` site's function (i.e., after `darwin_webview_create_ext`'s closing brace, before `darwin_webview_create`):

```objc
// #771 new-issue A: every create_ext retargets the app-wide drop webview at
// the newest webview and teardown never restored it — after a route push the
// system drag-drop targeted the route webview, and after a pop a TORN-DOWN
// one. routing.m retargets on every nav transition via this setter (the
// underlying global is static to this file).
void zapp_ios_set_drop_webview(void* webview_ptr) {
    zapp_ios_drop_webview = (__bridge WKWebView*)webview_ptr;
}
```

- [ ] **Step 2 (A): Retarget on every nav transition.** In routing.m, add the extern near the other webview.m externs:

```objc
// #771 new-issue A: retarget the app-wide drag-drop webview (ios/webview.m).
extern void zapp_ios_set_drop_webview(void* webview_ptr);
```

In `didShowViewController:` (after Task 3's re-stamp block, inside the same `if (winPtr)` scope — merge them), add:

```objc
        // #771 new-issue A: system drag-drop targets the webview of the VC
        // now on screen — the route VC's own webview after a push, the
        // window's content webview after a pop to content.
        WKWebView* dropWv = nil;
        if (shownIsRoute)        dropWv = ((ZappRouteVC*)vc).webview;
        else if (shownIsContent) dropWv = zapp_ios_content_webview_for_slot(self.windowId);
        if (dropWv) zapp_ios_set_drop_webview((__bridge void*)dropWv);
```

(Reuse `shownIsContent`/`shownIsRoute` from the Task 3 block; if Task 3's block was written with different local names, unify.)

- [ ] **Step 3 (B): Teardown idempotency flag.** Add to the `ZappRouteVC` interface:

```objc
// #771 new-issue B: set by zapp_route_vc_teardown so the explicit teardown in
// zapp_ios_pop_to_content and the viewDidDisappear: self-teardown can both
// fire in any order without double-running the brk-1 sequence.
@property (nonatomic, assign) BOOL tornDown;
```

and make `zapp_route_vc_teardown` guard on it:

```objc
static void zapp_route_vc_teardown(ZappRouteVC* vc) {
    if (vc.tornDown) return;
    vc.tornDown = YES;
    WKWebView* wv = vc.webview;
    if (!wv) return;
    [wv stopLoading];
    wv.navigationDelegate = nil;
    wv.UIDelegate = nil;
    @try {
        [wv.configuration.userContentController removeScriptMessageHandlerForName:@"zapp"];
    } @catch (__unused id e) {}
}
```

- [ ] **Step 4 (B): Explicit teardown of covered VCs.** In `zapp_ios_pop_to_content`, replace:

```objc
    if (containsContent)
        [nav popToViewController:contentVC animated:NO];
```

with:

```objc
    if (containsContent) {
        // #771 new-issue B: popToViewController: removes COVERED route VCs
        // (depth ≥ 2) without a moving-from-parent viewDidDisappear:, so their
        // self-teardown never runs — "zapp" handlers stay registered, zombie
        // bridges accumulate. Collect every route VC above the content VC
        // first, pop, then tear each down explicitly (idempotent via the
        // tornDown flag — the topmost VC's own viewDidDisappear: may also fire).
        NSMutableArray<ZappRouteVC*>* covered = [NSMutableArray array];
        NSUInteger contentIdx = [nav.viewControllers indexOfObject:contentVC];
        for (NSUInteger i = contentIdx + 1; i < nav.viewControllers.count; i++) {
            UIViewController* v = nav.viewControllers[i];
            if ([v isKindOfClass:[ZappRouteVC class]])
                [covered addObject:(ZappRouteVC*)v];
        }
        [nav popToViewController:contentVC animated:NO];
        for (ZappRouteVC* v in covered) zapp_route_vc_teardown(v);
    }
```

- [ ] **Step 5: Gates.** iOS-sim build + macOS build (`[zapp] build complete:` + fresh mtime each) + parity test.

- [ ] **Step 6: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/webview.m native/platform/ios/routing.m
git commit -m "fix(ios): drop-target follows the displayed webview; explicit teardown of covered route VCs on popToContent (#771 A+B)

A: didShow retargets zapp_ios_drop_webview at the shown VC's webview (route
push) / the window's content webview (pop) — no more drops into torn-down
webviews. B: popToViewController: at depth ≥2 never fired the covered VCs'
self-teardown; collect + tear down explicitly, idempotent via tornDown.

<TRAILER>"
```

---

## Task 6: → GATE G1 (human, iPad-expanded)

- [ ] **Step 1: Fresh builds for the human.** Re-run the iOS-sim build; report the exact `[zapp] build complete:` path + `xcrun simctl` install/launch commands the human should use (match whatever `bun run dev --platform ios` / prior cycles used — read `cli/src/zapp-cli.ts`'s dev/build output if unsure). NO simulator interaction in-session.

- [ ] **Step 2: Present the G1 checklist** (spec verbatim — human runs on an iPad-expanded simulator, sidebar + inspector visible):
  1. Push `/detail` → **no bleed** under sidebar OR inspector (rotate + size-class change too).
  2. Toolbar complete on the pushed route **incl. the inspector toggle** (datum 2 cell).
  3. Back → **back/fwd binding correct** (datum 3): back/fwd enabled states track the stack on both the revealed content page and pushed pages.
  4. Lateral nav (sidebar section switch) during a pushed route behaves (route pops to content, section renders).
  5. Drag-drop targets the right webview after push and after pop.
  6. Depth-2 push → popToRoot → **no zombie** (dev console: no orphaned bridge/"zapp" handler errors; `[zapp-nav]` logs may assist — they are still in place until Task 10).
- [ ] **Step 3: HALT for human sign-off.** Record results in the ledger. Any failure → systematic-debugging on the failing datum before proceeding; do NOT continue to Task 7 on a red gate.

---

## Task 7 (RISK GATE): Hidden navbar + swipe-back (spec item 5)

Implement the 3-layer recipe from `.superpowers/sdd/swipe-back-research.md` (read it FIRST): (1) robust delegate re-arm — custom delegate object, never `nil`, guarded by an in-transition flag (AHKNavigationController pattern; a naive `count>1`/nil-delegate intermittently freezes ALL touch); (2) WKWebView gesture arbitration (`requireGestureRecognizerToFail:` + `allowsBackForwardNavigationGestures = NO` + simultaneous recognition); (3) iOS-26 `interactiveContentPopGestureRecognizer` for hidden-bar routes. Behind a per-VC `navbarHidden` flag. This task gates Task 8's `navbar.hidden` surface — a frozen-touch regression here invalidates the approach.

**Files:**
- Modify: `native/platform/ios/routing.m` (delegate gesture ownership, `navbarHidden` flag, seam widened to carry chrome JSON)
- Modify: `native/platform/ios/sidebar.m` (hand pop-gesture ownership to the route delegate; delete the old gate)
- Modify: `native/nim/router.nim` (push arm forwards `navbar.hidden`; importc signature)
- Modify: `runtime/window.ts` (`RouteOptions.navbar` + push passthrough)
- Modify: `runtime/router.test.ts` (TDD the passthrough)
- Modify: `kitchen-sink/src/shell/main-pane.ts` (hidden-navbar demo route `/detail-clean`)

**Interfaces:**
- Produces (consumed/extended by Task 8):
  - Seam: `void zapp_ios_push_route_vc(int32_t windowId, const char* url, const char* chrome_json)` — chrome_json is a compact JSON object; this task defines/consumes only `{"navbarHidden": bool}`; Task 8 adds `title`/`toolbarJson`.
  - `ZappRouteVC.navbarHidden` (BOOL) — THE flag Task 8's options set; willShow's bar rule and the iOS-26 content-pop enable key off it.
  - TS: `RouteOptions.navbar?: { hidden: boolean }` — wire: `a.navbar = { hidden: true }` on `router:push`.
- Consumes: `zapp_route_install_delegate` (same file), `zapp_ios_sidebar_rearm_pop` call sites (sidebar.m ~lines 645, 1073, 1082).

- [ ] **Step 1 (TDD): failing TS test.** In `runtime/router.test.ts`, inside the `"router handle ops post correct wire messages"` describe, add:

```ts
  test("push({url, navbar}) forwards navbar to the wire", () => {
    const win = createWindowHandle("win-8");
    win.router.push({ url: "/clean", navbar: { hidden: true } });
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.m).toBe("router:push");
    expect(msg.a.navbar).toEqual({ hidden: true });
  });
```

Run `bun test runtime/router.test.ts` → the new test FAILS (navbar undefined).

- [ ] **Step 2: TS surface.** In `runtime/window.ts`: add to `RouteOptions` (after `presentation`):

```ts
  /**
   * iOS native routing only: hide the native navigation bar for this pushed
   * route (bring-your-own-chrome pages). Edge swipe-back KEEPS working — the
   * framework re-arms the pop gesture. Ignored on macOS/Windows and by
   * `replace`.
   */
  navbar?: { hidden: boolean };
```

and in `createRouterHandle`'s `push` (NOT `replace`), extend the `windowAction("router:push", {...})` spread:

```ts
        ...(o.navbar !== undefined ? { navbar: o.navbar } : {}),
```

Run `bun test runtime/router.test.ts` → green. Run `bun test runtime/window.test.ts` + `bun run check`.

- [ ] **Step 3: Nim seam.** In `native/nim/router.nim`: change the importc (inside the existing `when defined(zappIos):` block, ~line 35):

```nim
  proc zapp_ios_push_route_vc(windowId: int32, url: cstring, chromeJson: cstring) {.importc, cdecl.}
```

and in the `"router:push"` arm, replace `when defined(zappIos): zapp_ios_push_route_vc(target, url.cstring)` with:

```nim
      when defined(zappIos):
        # R2' per-route chrome: forward push options to the native seam as one
        # compact JSON object. Keys this build understands: navbarHidden
        # (title/toolbarJson land with the full push-options work).
        var chrome = newJObject()
        let navbar = a{"navbar"}
        if not navbar.isNil and navbar.kind == JObject:
          chrome["navbarHidden"] = newJBool(navbar{"hidden"}.getBool(false))
        let chromeStr = (if chrome.len > 0: $chrome else: "")
        zapp_ios_push_route_vc(target, url.cstring, chromeStr.cstring)
```

- [ ] **Step 4: routing.m — flag + parse.** Add to `ZappRouteVC`'s interface:

```objc
// R2' per-route chrome (#771): hide the native nav bar for this route. Set at
// push from the chrome JSON; willShowViewController: applies it and the
// re-armed pop gesture keeps edge swipe-back alive (research recipe).
@property (nonatomic, assign) BOOL navbarHidden;
```

Widen the seam signature and parse the chrome JSON at the top of the function:

```objc
void zapp_ios_push_route_vc(int32_t windowId, const char* url, const char* chrome_json) {
```

and after `ZappRouteVC* vc = [ZappRouteVC new];` / `vc.view.backgroundColor …`:

```objc
    // R2' per-route chrome: parse the compact options JSON the Nim push arm
    // forwarded. Absent/empty → all defaults.
    BOOL navbarHidden = NO;
    if (chrome_json && chrome_json[0]) {
        NSData* cd = [[NSString stringWithUTF8String:chrome_json]
                         dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* chrome = [NSJSONSerialization JSONObjectWithData:cd options:0 error:nil];
        if ([chrome isKindOfClass:[NSDictionary class]]) {
            if ([chrome[@"navbarHidden"] isKindOfClass:[NSNumber class]])
                navbarHidden = [chrome[@"navbarHidden"] boolValue];
        }
    }
    vc.navbarHidden = navbarHidden;
```

- [ ] **Step 5: routing.m — willShow bar rule + iOS-26 content pop.** In `willShowViewController:`, replace:

```objc
    BOOL isContent = (contentVC && vc == contentVC);
    BOOL isRoute = [vc isKindOfClass:[ZappRouteVC class]];
    BOOL showBar = isContent || isRoute;
```

with:

```objc
    BOOL isContent = (contentVC && vc == contentVC);
    BOOL isRoute = [vc isKindOfClass:[ZappRouteVC class]];
    // R2' navbar.hidden: a route that brings its own chrome shows NO bar.
    BOOL routeWantsBarHidden = isRoute && ((ZappRouteVC*)vc).navbarHidden;
    BOOL showBar = (isContent || isRoute) && !routeWantsBarHidden;
```

and after the visibility block (adjacent to Task 3's stamp call — the `showBar` gate already skips stamping hidden-bar routes), add:

```objc
    // Layer 3 (iOS 26+): full-screen content pop for hidden-bar routes — the
    // public replacement for the old FD private-KVC pattern. Enabled ONLY on
    // hidden-bar routes (they lose the visual back affordance; everywhere else
    // it would fight horizontal web scrolling).
    if (@available(iOS 26.0, *)) {
        nav.interactiveContentPopGestureRecognizer.enabled = routeWantsBarHidden;
    }
```

- [ ] **Step 6: routing.m — single-owner pop-gesture delegate (layers 1+2).** Extend `ZappRouteNavDelegate`:

```objc
@interface ZappRouteNavDelegate : NSObject <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, assign) int32_t windowId;
@property (nonatomic, assign) BOOL lastFromVCWasRouteVC;
// Swipe-back re-arm (research recipe, layer 1): the nav whose pop gesture we
// own, and an in-transition guard. A pop gesture that begins mid-transition
// desyncs UIKit's stack and freezes ALL touch (the pixeldock/AHK failure) —
// willShow sets the guard, didShow clears it.
@property (nonatomic, weak) UINavigationController* nav;
@property (nonatomic, assign) BOOL duringTransition;
@end
```

Set the guard at the very top of `willShowViewController:`:

```objc
    self.duringTransition = YES;
```

and at the very top of `didShowViewController:`:

```objc
    self.duringTransition = NO;
```

Add the gesture-delegate methods to the implementation (after `didShowViewController:`):

```objc
// Layer 1 (robust re-arm): a hidden nav bar (or custom back item) makes UIKit's
// internal delegate refuse the edge-pop gesture — we own the delegate instead.
// Gate: something to pop, and no transition in flight (the AHK guard).
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)g {
    UINavigationController* nav = self.nav;
    if (nav && g == nav.interactivePopGestureRecognizer) {
        return nav.viewControllers.count > 1 && !self.duringTransition;
    }
    return YES;
}

// Layer 2 (webview arbitration): a full-bleed WKWebView's pan/scroll
// recognizers otherwise swallow the edge swipe before it can begin — allow the
// pop to be recognized alongside them (we are only ever the pop recognizer's
// delegate, so a blanket YES is scoped to it).
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    (void)g; (void)other;
    return YES;
}
```

Extend `zapp_route_install_delegate` to arm the recognizer:

```objc
static void zapp_route_install_delegate(UINavigationController* nav, int32_t windowId) {
    if (!g_route_delegates) g_route_delegates = [NSMutableDictionary dictionary];
    ZappRouteNavDelegate* d = g_route_delegates[@(windowId)];
    if (!d) {
        d = [ZappRouteNavDelegate new];
        d.windowId = windowId;
        g_route_delegates[@(windowId)] = d;
    }
    if (nav.delegate != d) nav.delegate = d;   // single owner; re-assert if UIKit reset it
    // Layer 1: own the edge-pop gesture too (single owner — sidebar.m's old
    // rearm handed ownership here). Keep it enabled; our shouldBegin gates it.
    d.nav = nav;
    if (nav.interactivePopGestureRecognizer.delegate != d)
        nav.interactivePopGestureRecognizer.delegate = d;
    nav.interactivePopGestureRecognizer.enabled = YES;
}
```

- [ ] **Step 7: routing.m — per-webview arbitration at push.** In `zapp_ios_push_route_vc`, inside Task 2's `if (vc.webview) { ... }` block (after `[vc zapp_updateEdges];`), add:

```objc
        // Layer 2: the edge pop wins at the edge; the webview's own pan runs
        // only if the pop fails. And route history lives in the NATIVE stack —
        // never let WKWebView eat the swipe for its web history.
        [vc.webview.scrollView.panGestureRecognizer
            requireGestureRecognizerToFail:nav.interactivePopGestureRecognizer];
        vc.webview.allowsBackForwardNavigationGestures = NO;
```

- [ ] **Step 8: sidebar.m — hand over ownership.** Replace `zapp_ios_sidebar_rearm_pop`'s body (keep the function + call sites — it ALSO lazily captures `collapsedNav`, which must survive):

```objc
static void zapp_ios_sidebar_rearm_pop(ZappIOSSidebarController* c) {
    if (!c) return;
    UINavigationController* nav = c.collapsedNav ?: zapp_ios_collapsed_nav(c.splitVC);
    if (!nav) return;
    c.collapsedNav = nav;
    // Pop-gesture ownership moved to ZappRouteNavDelegate (routing.m, #771):
    // ONE owner, in-transition-guarded (the naive count>1 gate here predated
    // the guard). Installing the route delegate arms the gesture.
    extern void zapp_ios_route_install_nav_delegate(UINavigationController* nav, int32_t windowId);
    zapp_ios_route_install_nav_delegate(nav, (int32_t)c.hostWindowId);
}
```

Delete `-[ZappIOSSidebarController gestureRecognizerShouldBegin:]` (the `count > 1` gate, ~lines 686-695) — the route delegate's gate replaces it. Then `grep -n "interactivePopGestureRecognizer" native/platform/ios/sidebar.m` → only comments (or nothing) may remain; no code writes.

- [ ] **Step 9: Kitchen-sink demo route.** In `kitchen-sink/src/shell/main-pane.ts`:
  - In `renderRoute`, after the `/detail` branch, add:

```ts
    if (url === "/detail-clean") {
      // #771 R2' demo: navbar:{hidden:true} route — NO native chrome; the page
      // brings its own Back. Edge swipe-back must still work (research recipe).
      shownId = "";
      if (typeof teardown === "function") teardown();
      teardown = undefined;
      stage.innerHTML = `<div class="detail-page" style="padding:24px;padding-top:calc(var(--zapp-safe-area-top, 24px) + 8px)">
        <h2>Chrome-less route (/detail-clean)</h2>
        <p>The native nav bar is hidden for this route. Swipe from the left edge to go back — it must NOT freeze the UI.</p>
        <button id="ks-pop-clean">Back (router.pop)</button></div>`;
      stage.querySelector("#ks-pop-clean")?.addEventListener("click", () => Window.current().router.pop());
      return;
    }
```

  - In the demo-strip block at the bottom, after the existing `detailBtn` lines, add:

```ts
  const cleanBtn = document.createElement("button");
  cleanBtn.textContent = "Push chrome-less route";
  cleanBtn.onclick = () =>
    Window.current().router.push({ url: "/detail-clean", navbar: { hidden: true } });
  demoStrip.appendChild(cleanBtn);
```

- [ ] **Step 10: Gates.** `bun test runtime/router.test.ts` + `bun test runtime/window.test.ts` + `bun run check` + iOS-sim build + macOS build (`[zapp] build complete:` + fresh mtime each) + parity test.

- [ ] **Step 11: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/routing.m native/platform/ios/sidebar.m native/nim/router.nim runtime/window.ts runtime/router.test.ts kitchen-sink/src/shell/main-pane.ts
git commit -m "feat(ios): hidden-navbar routes keep swipe-back — single-owner pop gesture + webview arbitration + iOS-26 content pop (#771 R2' risk gate)

3-layer recipe: ZappRouteNavDelegate owns interactivePopGestureRecognizer
(duringTransition guard — never nil, never naive count>1), route webviews
arbitrate their pan (requireGestureRecognizerToFail + no WK history swipe),
and iOS 26's interactiveContentPopGestureRecognizer enables full-screen pop
on hidden-bar routes only. Seam widened to carry per-route chrome JSON
(navbarHidden); RouteOptions.navbar on TS. sidebar.m's old re-arm hands
ownership over. Kitchen-sink /detail-clean demo.

<TRAILER>"
```

- [ ] **Step 12: → RISK SUB-GATE (human).** Fresh sim build installed; human verifies on BOTH iPhone and iPad-expanded sims:
  1. Push "/detail-clean" → NO native bar; page renders full-bleed under its own chrome.
  2. Edge swipe-back pops the route with the native interactive transition.
  3. Rapid repeated swipes + swipe-during-push attempts do NOT freeze touch (the AHK failure mode).
  4. Normal `/detail` (bar shown) swipe-back + back button still work.
  5. iPhone: content→sidebar swipe at root still works (ownership handover regression check).
  HALT for sign-off. A frozen-touch or dead-swipe result invalidates the approach — STOP the cycle and report (Task 8 must not ship `navbar.hidden` on a red sub-gate).

---

## Task 8: R2′ push options end-to-end — `title` + `toolbar` override (spec item 4)

**Files:**
- Modify: `runtime/window.ts` (`RouteOptions.toolbar`, push serializes via `normalizeToolbar`, `createRouterHandle` gains pane-shape params)
- Modify: `runtime/router.test.ts` (TDD)
- Modify: `native/nim/router.nim` (chrome carries `title` + `toolbarJson`)
- Modify: `native/platform/ios/toolbar.m` (builder extraction + per-VC chrome storage + override-aware stamping)
- Modify: `native/platform/ios/routing.m` (parse title/toolbarJson, store per-VC chrome before push)

**Interfaces:**
- Consumes: Task 7's chrome-JSON seam + `ZappRouteVC.navbarHidden`; Task 3's `zapp_ios_toolbar_stamp_vc` / `zapp_ios_toolbar_stamp_items`.
- Produces:

```objc
// toolbar.m — store per-VC chrome (route title + optional toolbar-override
// entry built from wire JSON). Passing NULLs clears. Main thread only.
void zapp_ios_toolbar_set_vc_chrome(void* window_ptr, UIViewController* vc,
                                    const char* title, const char* toolbar_json,
                                    int32_t host_slot);
```

  - TS: `RouteOptions.toolbar?: ToolbarItemDef[]`; wire: `a.toolbarJson` = the same `{"items":[...]}` wire JSON `toolbar:setItems` sends (actions stripped + registered); `a.title` (already sent today, now consumed).
  - Chrome JSON keys (Task 7's object, extended): `{"title": string?, "toolbarJson": string?, "navbarHidden": bool?}`.

- [ ] **Step 1 (TDD): failing tests.** In `runtime/router.test.ts` add (mirror `runtime/toolbar.test.ts`'s click-dispatch pattern for the action test — read that file first and reuse its event-name/fire approach exactly):

```ts
  test("push({url, toolbar}) serializes toolbarJson (actions stripped) and forwards title", () => {
    const win = createWindowHandle("win-10");
    win.router.push({
      url: "/detail",
      title: "Detail",
      toolbar: [{ id: "d-share", icon: "sf:square.and.arrow.up", label: "Share", action: () => {} }],
    });
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.m).toBe("router:push");
    expect(msg.a.title).toBe("Detail");
    expect(typeof msg.a.toolbarJson).toBe("string");
    const wire = JSON.parse(msg.a.toolbarJson);
    expect(wire.items.length).toBe(1);
    expect(wire.items[0].id).toBe("d-share");
    expect(wire.items[0].action).toBeUndefined();   // stripped
    expect(wire.style).toBeUndefined();             // push never sends style
  });

  test("push toolbar actions dispatch on window:toolbar-clicked", () => {
    let hits = 0;
    // wireToolbarClicks' handler builds an ActionContext via Window.current(),
    // which resolves the id from globalThis[Symbol.for("zapp.windowId")] — seed
    // it so the handler doesn't bail in the mock env.
    (globalThis as any)[Symbol.for("zapp.windowId")] = "win-11";
    const win = createWindowHandle("win-11");
    win.router.push({
      url: "/detail",
      toolbar: [{ id: "d-share", label: "Share", action: () => { hits++; } }],
    });
    // Fire the click exactly as native emits it (wireToolbarClicks subscribes
    // to eventName(WindowEvent.TOOLBAR_CLICKED) === "window:toolbar-clicked").
    mock.fire("window:toolbar-clicked", { windowId: "win-11", id: "d-share" });
    expect(hits).toBe(1);
    delete (globalThis as any)[Symbol.for("zapp.windowId")];
  });
```

Run → FAIL (toolbar option not yet forwarded/registered).

- [ ] **Step 2: TS implementation.** In `runtime/window.ts`:
  - `RouteOptions` gains (after `navbar`):

```ts
  /**
   * iOS native routing only: per-route toolbar override for the pushed view
   * controller's nav bar. Falls back to the window's toolbar when absent.
   * Same item defs as `toolbar.setItems` (actions are stripped + registered
   * the same way). `updateItem` keeps targeting the WINDOW toolbar defs —
   * override items are static for their route's lifetime (v1). Prefer item
   * ids distinct from the window toolbar's.
   */
  toolbar?: ToolbarItemDef[];
```

  - `createRouterHandle` signature becomes `function createRouterHandle(windowId: string, hasSidebar = false, hasInspector = false): RouterHandle` and the `createWindowHandle` call site becomes `router: createRouterHandle(windowId, sidebarOpts !== undefined, inspectorOpts !== undefined),`. Verify first that the toolbar action maps + wiring helpers (`toolbarActions`, `toolbarMenuActions`, `wireToolbarClicks`, `wireToolbarGroupSelect`, `wireToolbarMenuClicks`, `recordToolbarMenuIds`, `recordToolbarMenuTree`, `toolbarMenuIdsByWindow`, `toolbarMenuTrees`) are module-scope (they should be — action registries must outlive handles); if any is closure-scoped, hoist it — do not duplicate registries.
  - `push` builds the wire JSON exactly like `toolbar.setItems` but WITHOUT purging (route overrides register additively — the window toolbar's actions must survive the route):

```ts
    push(opts: RouteOptions | string): void {
      const o = typeof opts === "string" ? { url: opts } : opts;
      let toolbarJson: string | undefined;
      if (o.toolbar !== undefined) {
        const { json, actions, menuActions, menuIdsByItem, menuTrees } =
          normalizeToolbar({ items: o.toolbar }, hasSidebar, hasInspector);
        const parsed = JSON.parse(json);
        delete parsed.style;               // per-route override never carries style
        toolbarJson = JSON.stringify(parsed);
        // Register actions ADDITIVELY (no purge — the window toolbar's own
        // actions must keep working after the route pops).
        if (actions.size > 0) {
          wireToolbarClicks();
          wireToolbarGroupSelect();
          for (const [id, fn] of actions) toolbarActions.set(`${windowId}:${id}`, fn);
        }
        if (menuActions.size > 0) {
          wireToolbarMenuClicks();
          for (const [mid, fn] of menuActions) toolbarMenuActions.set(mid, fn);
        }
        recordToolbarMenuIds(windowId, menuIdsByItem, toolbarMenuIdsByWindow);
        for (const [itemId, tree] of menuTrees) recordToolbarMenuTree(windowId, itemId, tree);
      }
      windowAction("router:push", {
        windowId,
        url: o.url,
        ...(o.title !== undefined ? { title: o.title } : {}),
        ...(o.params !== undefined ? { params: o.params } : {}),
        ...(o.presentation !== undefined ? { presentation: o.presentation } : {}),
        ...(o.navbar !== undefined ? { navbar: o.navbar } : {}),
        ...(toolbarJson !== undefined ? { toolbarJson } : {}),
      });
    },
```

(Adapt helper-call arity to the real signatures in the file — read them; e.g. `normalizeToolbar` returns `menuTrees` per the setItems closure.) Run Step 1 tests → green. `bun test runtime/window.test.ts` (existing push tests use `toEqual` on `msg.a` — they still pass since options are conditional) + `bun run check`.

- [ ] **Step 3: Nim chrome extension.** In router.nim's push arm (Task 7's block), after the navbar lines add:

```nim
        if a.hasKey("title") and a["title"].kind == JString:
          chrome["title"] = a["title"]
        if a.hasKey("toolbarJson") and a["toolbarJson"].kind == JString:
          chrome["toolbarJson"] = a["toolbarJson"]
```

and update the comment to name all three keys.

- [ ] **Step 4: toolbar.m — extract the entry builder.** Refactor `darwin_toolbar_set_items`: move the item-building loop (everything from `NSMutableArray<UIBarButtonItem*>* leading = [NSMutableArray array];` through the end of the `for (NSDictionary* def in items)` loop, plus the bucket/registry assignments into the entry) into:

```objc
// ─── zapp_ios_toolbar_populate_entry (internal) ──────────────────────────────
//
// R2' (#771): builds all UIBarButtonItem buckets from a parsed wire `items`
// array into `entry` — extracted from darwin_toolbar_set_items so per-route
// toolbar overrides (zapp_ios_toolbar_set_vc_chrome) reuse the identical
// builder (same click targets, same id maps, same toggle capture).
static void zapp_ios_toolbar_populate_entry(ZappIOSToolbarEntry* entry,
                                            NSArray* items,
                                            int32_t host_slot,
                                            void* window_ptr) {
    ...the moved loop, ending with:
    entry.allItems        = allBuilt;
    entry.leadingItems    = [leading copy];
    entry.leadingNoToggle = [leadingNoToggle copy];
    entry.toggleSidebarButton = toggleSidebarItem;
    entry.toggleInspectorButton = toggleInspectorItem;
    entry.trailingItems   = [trailing copy];
    entry.centerTitle     = centerTitle;
    entry.centerView      = centerView;
    entry.itemsById       = itemsById;
    entry.segmentedById   = segmentedById;
}
```

`darwin_toolbar_set_items` keeps: JSON parse + empty-items guard, registry get-or-create, then calls `zapp_ios_toolbar_populate_entry(entry, items, host_slot, window_ptr);`, then the existing apply + inject_metrics tail. This is a MOVE refactor — `git diff` must show no behavioral change in the loop body (the loop references `host_slot`/`window_ptr` only via the params).

- [ ] **Step 5: toolbar.m — per-VC chrome storage + override-aware stamping.** Add associated-object keys next to the existing ones:

```objc
static const char kZappRouteToolbarEntryKey = 0;
static const char kZappRouteTitleKey = 0;
```

Add after `zapp_ios_toolbar_stamp_vc`:

```objc
// ─── zapp_ios_toolbar_set_vc_chrome ──────────────────────────────────────────
//
// R2' (#771): store per-VC chrome on a pushed route VC — an optional route
// title and an optional toolbar-override entry built from the same wire JSON
// shape as darwin_toolbar_set_items. The stamping choke point reads both:
// override entry replaces the window entry wholesale; the title overrides
// entry.centerTitle. NULL title / NULL toolbar_json clear. Called by
// routing.m before the push (so the first willShow already sees it).
void zapp_ios_toolbar_set_vc_chrome(void* window_ptr, UIViewController* vc,
                                    const char* title, const char* toolbar_json,
                                    int32_t host_slot) {
    if (!vc) return;
    objc_setAssociatedObject(vc, &kZappRouteTitleKey,
        (title && title[0]) ? [NSString stringWithUTF8String:title] : nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ZappIOSToolbarEntry* override = nil;
    if (toolbar_json && toolbar_json[0]) {
        NSData* data = [[NSString stringWithUTF8String:toolbar_json]
                           dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray* items = [root isKindOfClass:[NSDictionary class]] &&
                         [root[@"items"] isKindOfClass:[NSArray class]] ? root[@"items"] : nil;
        if (items.count > 0) {
            override = [[ZappIOSToolbarEntry alloc] init];
            override.hostSlot = host_slot;
            override.windowPtr = window_ptr;
            zapp_ios_toolbar_populate_entry(override, items, host_slot, window_ptr);
        }
    }
    objc_setAssociatedObject(vc, &kZappRouteToolbarEntryKey, override,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
```

Make `zapp_ios_toolbar_stamp_vc` override-aware — replace its entry resolution with:

```objc
    ZappIOSToolbarEntry* entry = nil;
    if (zapp_ios_toolbars) {
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        entry = zapp_ios_toolbars[key];
    }
    // R2': a per-VC toolbar override replaces the window entry wholesale
    // (falls back to the window defs when absent).
    ZappIOSToolbarEntry* override = objc_getAssociatedObject(vc, &kZappRouteToolbarEntryKey);
    if (override) entry = override;
    if (!entry) return;
```

(and relax the function's early `!zapp_ios_toolbars` bail so a window with NO toolbar but a route WITH one still stamps — move that check into the resolution above, as shown). Add the title override at the end of `zapp_ios_toolbar_stamp_items`:

```objc
    // R2': a per-VC route title wins over the entry's center label.
    NSString* routeTitle = objc_getAssociatedObject(vc, &kZappRouteTitleKey);
    if (routeTitle.length) {
        vc.navigationItem.title = routeTitle;
        vc.navigationItem.titleView = nil;
    }
```

- [ ] **Step 6: routing.m — parse + store before push.** Extend Task 7's chrome parse:

```objc
    BOOL navbarHidden = NO;
    NSString* chromeTitle = nil;
    NSString* chromeToolbarJson = nil;
    if (chrome_json && chrome_json[0]) {
        NSData* cd = [[NSString stringWithUTF8String:chrome_json]
                         dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* chrome = [NSJSONSerialization JSONObjectWithData:cd options:0 error:nil];
        if ([chrome isKindOfClass:[NSDictionary class]]) {
            if ([chrome[@"navbarHidden"] isKindOfClass:[NSNumber class]])
                navbarHidden = [chrome[@"navbarHidden"] boolValue];
            if ([chrome[@"title"] isKindOfClass:[NSString class]])
                chromeTitle = chrome[@"title"];
            if ([chrome[@"toolbarJson"] isKindOfClass:[NSString class]])
                chromeToolbarJson = chrome[@"toolbarJson"];
        }
    }
    vc.navbarHidden = navbarHidden;
```

Add the extern next to `zapp_ios_toolbar_stamp_vc`'s:

```objc
extern void zapp_ios_toolbar_set_vc_chrome(void* window_ptr, UIViewController* vc,
                                           const char* title, const char* toolbar_json,
                                           int32_t host_slot);
```

and immediately BEFORE `[nav pushViewController:vc animated:YES];`:

```objc
    // R2': store per-VC chrome before the push so the first willShow (which
    // fires inside pushViewController:) already stamps it.
    zapp_ios_toolbar_set_vc_chrome(win, vc,
        chromeTitle ? chromeTitle.UTF8String : NULL,
        chromeToolbarJson ? chromeToolbarJson.UTF8String : NULL,
        windowId);
```

- [ ] **Step 7: Gates.** `bun test runtime/router.test.ts` + `bun test runtime/window.test.ts` + `bun run check` + iOS-sim build + macOS build (`[zapp] build complete:` + fresh mtime each) + parity test.

- [ ] **Step 8: Commit:**

```bash
cd /Users/zach/code/zapp
git add runtime/window.ts runtime/router.test.ts native/nim/router.nim native/platform/ios/toolbar.m native/platform/ios/routing.m
git commit -m "feat(router): R2' push options — per-route title, toolbar override, navbar.hidden (#771)

router.push(url, { title?, toolbar?, navbar? }): TS serializes the toolbar
override through normalizeToolbar (actions stripped + registered additively),
Nim forwards one chrome JSON to the push seam, and the displayed-VC stamping
choke point applies per-VC chrome (override entry replaces window defs;
route title wins the center slot).

<TRAILER>"
```

---

## Task 9: Retire the `nativeRouting` gate (spec item 6 — R3′ remainder)

**Files:**
- Modify: `native/platform/ios/routing.m` (guard + extern)
- Modify: `native/nim/window.nim` (proc, field, stash, parse)
- Modify: `runtime/window.ts` (option)
- Modify: `kitchen-sink/zapp/app.nim` (drop the opt-in)

**Interfaces:**
- Produces: native routing is default-on for iOS windows. Windows whose content VC has no navigation controller (plain no-split shape) fall through `zapp_route_content_nav`'s `if (!nav) return;` → graceful no-op (in-window ROUTE_CHANGED nav keeps working).

- [ ] **Step 1: Enumerate every reference first:**

```bash
cd /Users/zach/code/zapp
grep -rn "nativeRouting\|zapp_window_native_routing\|gNativeRouting" runtime/ native/ cli/ kitchen-sink/ docs/ --include="*.ts" --include="*.nim" --include="*.m" --include="*.h" --include="*.md" | grep -v node_modules
```

Expected code hits (verify — fix any stragglers the grep finds beyond these): `routing.m` (extern ~29 + guard ~272), `window.nim` (:27 proc, ~:207 field, ~:368 stash, ~:692 parse, plus the `gNativeRouting` table declaration — locate it), `runtime/window.ts` (~:200 option + doc comment), `kitchen-sink/zapp/app.nim` (:42), `kitchen-sink/src/shell/main-pane.ts` (comment only — reword in Task 11's demo pass or here), docs (handled in Task 11 — but note the hits for it).

- [ ] **Step 2: routing.m.** Delete the extern `extern bool zapp_window_native_routing(int32_t window_id);` and the guard line `if (!zapp_window_native_routing(windowId)) return;   // opt-in gate (retired in R3')`. Update the file-header comment to state routing is default-on (and drop stale references to the retired gate).

- [ ] **Step 3: window.nim.** Delete: the `zapp_window_native_routing` exported proc (line ~27) AND the `gNativeRouting` table it reads (find its declaration — likely a `Table[int32, bool]` near the other window-state globals); the `nativeRouting*: bool = false` field on the options object (~207); the stash line `gNativeRouting[id] = o.nativeRouting` (~368); the parse line `if jHasBool(a, "nativeRouting"): ...` (~692). Nim-zc-parity note (memory `feedback_nim_zc_parity`): this is an intentional API retirement on the Nim side — record it in the task report as a deliberate divergence-removal, not a silent one.

- [ ] **Step 4: runtime/window.ts.** Delete the `nativeRouting?: boolean;` field and its full doc comment (the "N3a risk-gate seed" paragraph).

- [ ] **Step 5: kitchen-sink/zapp/app.nim.** Delete the `nativeRouting: true,` line.

- [ ] **Step 6: Verify zero references remain** (re-run the Step 1 grep — only docs hits may remain, and only until Task 11) and that nothing else read the symbol: `grep -rn "zapp_window_native_routing" native/ cli/` → empty.

- [ ] **Step 7: Gates.** `bun run check` + `bun test runtime/window.test.ts` + iOS-sim build + macOS build (`[zapp] build complete:` + fresh mtime each) + parity test.

- [ ] **Step 8: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/routing.m native/nim/window.nim runtime/window.ts kitchen-sink/zapp/app.nim
git commit -m "feat(ios): native routing default-on — retire the nativeRouting window option (#771 R3' remainder)

router.push materializes a native pushed VC on every iOS window with a live
content nav; nav-less plain windows fall through to in-window ROUTE_CHANGED
nav unchanged. Option removed from WindowOptions, window.nim, and the
kitchen-sink config.

<TRAILER>"
```

---

## Task 10: Cleanup sweep (spec item 8)

**Files:**
- Modify: `native/platform/ios/routing.m`, `native/platform/ios/sidebar.m`, `native/platform/ios/toolbar.m`, `native/platform/ios/inspector.m`, `native/platform/ios/window.m`, `native/nim/router.nim`

**Interfaces:** none new — deletions and comment refreshes only. NO behavior changes; the diff must contain no executable-code additions beyond removed-diagnostic scaffolding.

- [ ] **Step 1: `[zapp-nav]` sweep.** Enumerate, then remove EVERY site (committed + T0-landed):

```bash
cd /Users/zach/code/zapp
grep -rn "zapp-nav" native/ | grep -v Binary
```

Expected files: `routing.m` (~12 sites: content_nav, willShow, didShow, push/pop/pop_to_content entries), `sidebar.m` (didCollapse, register_contentVC, show_content, + any others the grep finds), `toolbar.m` (apply_to_nav, apply_for_window_hidden, apply_for_window incl. its `_diagKey`/`_diagEntry` lookup block), `router.nim` (all `c_fprintf`/`c_fflush` calls AND the three helper declarations: `proc c_fprintf`, `proc c_fflush`, `var cstderr_nav`). Keep `sidebar.m`'s `[native] iOS sidebar registered:` line — it is not a `[zapp-nav]` diagnostic. After removal: `grep -rn "zapp-nav" native/` → empty. Then remove now-unused includes: in `routing.m` drop `#include <stdio.h>` and `#include <objc/runtime.h>` IF `grep -n "fprintf\|class_getName\|objc_" native/platform/ios/routing.m` shows no remaining use; in `toolbar.m` drop the T0-added `#include <stdio.h>` if no `fprintf` remains (NSLog does not need it).

- [ ] **Step 2: Dead injector fn.** `grep -rn "zapp_ios_toolbar_inject_webview_safe_area" native/ cli/` — after Task 2 the only hit must be the no-op definition in `toolbar.m` (~lines 213-230, the "N3a: inject the --zapp-* safe-area vars…/N3b: No-op" block). Delete the whole function + its comment.

- [ ] **Step 3: Stale-comment bundle** (anchors verified 2026-07-02; re-locate by content):
  - `inspector.m` header (~lines 1-5): trim the spike attribution "Ported from the proven spike (spikes/ios-splitview-reference/…), human-smoked on iPad + iPhone, iOS 26.5." to a single line "Recipe proven in spikes/ios-splitview-reference." (keep the architectural content).
  - `inspector.m` `zapp_ios_inspector_note_layout_width` guard comments (~254-257): "<26 (or no split): the persistent inspector nav is shown as a modal…" — drop the "(or no split)" parenthetical and the inline "// <26/no-split modal sheet, not a column" → "// <26 modal sheet, not a column" (every window shape has a split since E3).
  - `inspector.m` warn strings ×3 (lines ~438/661/737): `"below iOS 26 (or without a sidebar split) the inspector is a system modal sheet"` → `"below iOS 26 the inspector is a system modal sheet"` (keep each line's suffix, e.g. "…with no adjustable width").
  - `sidebar.m` extern comment (~83-86): "applies with an explicit sidebarHidden state (the transition TARGET) so willChangeToDisplayMode: can drive the toggle change synchronously…" → reword to match the T2 advisory-only reality: "applies with an explicit sidebarHidden hint — ADVISORY ONLY since the double-toggle race fix (the expanded path re-derives the real state from a live displayMode read at apply time)."
  - `toolbar.m` `darwin_toolbar_set_items` early-return comment "// No-sidebar window: deferred (T1 decision). Safe no-op." → "// Nav-less plain window (no split): nothing to attach a bar to. Safe no-op." (hidden-Primary no-sidebar windows DO resolve via the Secondary-nav fallback now).
  - `toolbar.m` file-header block: the "T1.5 collapse-aware delivery" paragraph still says "Bar visibility in collapsed mode is set directly: shown when the content VC is on top (count > 1)" — update to say bar visibility is owned by `ZappRouteNavDelegate.willShowViewController:` (routing.m); also refresh the "Fix (T2): …" sentence if it repeats the direct-set claim.
  - `window.m` duplicated comment block (~lines 903-912): the five-line "Hand the split + columns + ids to the sidebar manager…" paragraph appears twice back-to-back — delete one copy.
  - `routing.m` file header: rewrite to describe the CURRENT model (default-on routing, willShow bar ownership + displayed-VC stamping, edge-pin route webviews, per-VC chrome) and drop the "(R1' RISK GATE, Task 1+2)" era framing and any remaining stale clauses.
  - AppKit-specific warn wording: `grep -rn "NSWindow\|NSToolbar\|AppKit\|macOS" native/platform/ios/*.m` — for any USER-FACING NSLog/fprintf warn that describes iOS behavior in AppKit terms, fix the wording (comments referencing darwin/ mirrors are fine — leave those).
- [ ] **Step 4: Gates.** iOS-sim build + macOS build (`[zapp] build complete:` + fresh mtime each) + parity test + `bun run check` (no TS changes expected — cheap safety).

- [ ] **Step 5: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/routing.m native/platform/ios/sidebar.m native/platform/ios/toolbar.m native/platform/ios/inspector.m native/platform/ios/window.m native/nim/router.nim
git commit -m "chore(ios): #771 cleanup — [zapp-nav] diagnostic sweep, dead inset injector, stale-comment bundle

<TRAILER>"
```

---

## Task 11: Docs + kitchen-sink final demos (spec items 9 + 10)

**Files:**
- Modify: `docs/api-reference.md` (Router section, ~lines 1761-1840; toolbar semantics note; drag-drop note — locate the drag-drop/file-drop section by grep)
- Modify: `kitchen-sink/src/shell/main-pane.ts` (detail-route title+toolbar demo; fixed-route webviews skip window `setItems`)

**Interfaces:**
- Consumes: Task 8's `RouteOptions` surface exactly as shipped (`title` / `toolbar` / `navbar.hidden`).

- [ ] **Step 1: Kitchen-sink — fixed-route webviews must not re-stamp the window toolbar.** In `renderMainPane`, the `myRoute` read currently happens mid-function; move it ABOVE the toolbar attach and gate the attach (a route webview re-calling `setItems` would clobber the per-route override the push installed):

```ts
  // N3a per-route identity — read EARLY: a pushed route VC's webview renders
  // its own fixed route, and (#771 R2') its nav-bar chrome is stamped
  // natively from the push options / window defs. Re-calling setItems from
  // here would clobber a per-route toolbar override.
  const g = globalThis as unknown as Record<symbol, unknown>;
  const myRoute = g[Symbol.for("zapp.route")] as string | undefined;

  // Attach the shell toolbar (late-attach to a toolbar-less window works).
  // Root/content + desktop webviews only — see above.
  if (!myRoute) {
    try {
      Window.current().toolbar.setItems(shellToolbar());
    } catch (e) {
      console.warn("[kitchen-sink] toolbar attach failed:", e);
    }
  }
```

Delete the now-duplicated `const g = …; const myRoute = …;` lines further down (keep a pointer comment). Note: the route webview's `updateItem` calls (Task 4's `syncToolbar`) still patch the WINDOW defs — that is the documented v1 semantics.

- [ ] **Step 2: Kitchen-sink — /detail demonstrates title + per-route toolbar.** Replace the `detailBtn.onclick` line:

```ts
  detailBtn.onclick = () =>
    Window.current().router.push({
      url: "/detail",
      title: "Detail",
      toolbar: [
        {
          id: "d-share",
          icon: "sf:square.and.arrow.up",
          label: "Share",
          action: () => console.log("[ks] /detail share tapped"),
        },
        {
          id: "d-fav",
          icon: "sf:star",
          label: "Favorite",
          placement: "trailing",
          action: () => console.log("[ks] /detail favorite tapped"),
        },
      ],
    });
```

(`/detail-clean` from Task 7 stays as the hidden-navbar demo; back/fwd live-binding on pushed pages already ships via Task 4.)

- [ ] **Step 3: Docs — Router section** (`docs/api-reference.md` "### Router"). Update the example block and add a "Per-route chrome (iOS)" subsection:

```md
```ts
router.push("/settings");
router.push({ url: "/item", params: { id: 42 }, title: "Item" });
router.push({
  url: "/compose",
  title: "Compose",                    // iOS: pushed VC's nav-bar title
  toolbar: [                           // iOS: per-route toolbar override
    { id: "send", icon: "sf:paperplane", label: "Send", action: sendIt },
  ],
  navbar: { hidden: true },            // iOS: chrome-less route
});
```

#### Per-route chrome (iOS native routing)

`router.push` accepts per-route chrome options, applied to the pushed native
view controller:

- `title` — the pushed VC's navigation-bar title (wins over any window
  toolbar center label while the route is on top).
- `toolbar` — a per-route toolbar override (same item defs as
  `toolbar.setItems`; actions work the same way). Falls back to the WINDOW
  toolbar when absent. `toolbar.updateItem` keeps targeting the window
  toolbar defs — override items are static for the route's lifetime (v1);
  prefer item ids distinct from the window toolbar's.
- `navbar: { hidden: true }` — hides the native navigation bar for this
  route (bring-your-own-chrome pages). **Edge swipe-back keeps working** —
  the framework owns the pop gesture independently of bar visibility (and on
  iOS 26+ a full-screen content pop is enabled for hidden-bar routes).

All three are ignored on macOS/Windows (desktop stays in-window nav) and by
`router.replace`.
```

- [ ] **Step 4: Docs — routing default-on + toolbar semantics + drag-drop.** In the same doc:
  - Wherever `nativeRouting` is mentioned (grep the file — Task 9's Step 1 recorded the hits), replace with: native routing is the DEFAULT on iOS windows whose content pane has a navigation controller; plain nav-less windows keep in-window ROUTE_CHANGED navigation. Delete the option from any `WindowOptions` listing.
  - Toolbar section: add a short "iOS per-VC stamping" note — the window's toolbar defs are the source of truth; the framework stamps the DISPLAYED view controller on every native nav transition, so `updateItem` always patches what is on screen (incl. after back/swipe pops).
  - Drag-drop/file-drop section (grep "drop"): add one sentence — on iOS, system drag-drop targets the webview of the view controller currently on screen (route webview while a route is pushed; the window's content webview otherwise).
  - Also fix the stale `nativeRouting:true` wording in `kitchen-sink/src/shell/main-pane.ts`'s N3a comment (~line 113) if Task 9 didn't already.
- [ ] **Step 5: Gates.** `bun run check` + iOS-sim build (`[zapp] build complete:` + fresh mtime) + macOS build + parity test.

- [ ] **Step 6: Commit:**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md kitchen-sink/src/shell/main-pane.ts
git commit -m "docs+demo: per-route chrome (title/toolbar/navbar.hidden), routing default-on; kitchen-sink detail demos (#771)

<TRAILER>"
```

---

## Task 12: → GATE G2 (human, final combined)

- [ ] **Step 1: Fresh builds** — iOS-sim (`[zapp] build complete:` + fresh mtime) AND macOS. Report install/launch commands for iPhone sim, iPad sim, and the macOS app.

- [ ] **Step 2: Present the G2 checklist** (spec verbatim):
  1. **Per-route chrome matrix** (iPhone + iPad-expanded): `/detail` shows title "Detail" + Share/Favorite override toolbar (+ system back); pop restores the window toolbar exactly; `/detail-clean` shows NO bar WITH working swipe-back and no frozen touch (repeat-swipe torture).
  2. **Full routing regression, both form factors** — re-run the pane-edges G3 routing items: push/pop/back-button/swipe, lateral section nav during a pushed route, popToRoot, back/fwd toolbar binding, inspector toggle on pushed routes, rotation + size-class changes mid-route.
  3. **Gate-retired default path**: a window WITHOUT any routing opt-in gets native pushes (the option no longer exists) — kitchen-sink main window is the proof.
  4. **macOS quick look**: zero `darwin/*` changes this cycle — verify the macOS build launches, in-window routing still swaps content on push/pop, and the toolbar demos (incl. updateItem back/fwd) are unchanged.
- [ ] **Step 3: HALT for human sign-off.** Record in the ledger. On pass: #771 closes. On any failure: systematic-debugging; do not close.

---

## Self-review checklist (for the orchestrator, after Task 12)

- Every spec work item mapped: 1→T0, 2→T1+T2, 3→T3+T4, 4→T8, 5→T7, 6→T9, 7→T5, 8→T10, 9+10→T11; gates G1→T6, G2→T12.
- Cross-task signatures consistent: T1's `zapp_ios_edge_pin_webview/update` ↔ T2's consumers; T3's `zapp_ios_toolbar_stamp_vc` ↔ T8's override-aware version; T7's `chrome_json` seam + `navbarHidden` flag ↔ T8's `title`/`toolbarJson` keys; T7's `RouteOptions.navbar` ↔ T8's `RouteOptions.toolbar`.
- No `[zapp-nav]` site survives Task 10 (`grep -rn "zapp-nav" native/` empty); no `nativeRouting` reference survives Task 11 (`grep -rn nativeRouting . --include="*.ts" --include="*.nim" --include="*.m" --include="*.md" | grep -v superpowers` empty).
- macOS: `git diff BASE..HEAD -- native/platform/darwin/` is EMPTY (constraint: no darwin changes at all).
