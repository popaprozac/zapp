# ios-splitview-reference — Phase 1: Plain VCs

## What this proves

UIKit's `UISplitViewController` (double-column style, iOS 14+) combined with
`UINavigationController` provides back buttons, interactive edge-swipe-back,
per-VC toolbar items, and iPhone-collapse behaviour **entirely for free** when
driven idiomatically — with zero custom machinery.

Zapp's current approach uses a manual VC-stack reconcile loop, toolbar
reapply-on-`viewDidAppear`, a `UINavigationControllerDelegate` pop-detection
hook, and manual safe-area / inset injection. Those are the exact things that
keep breaking across push/pop, collapse/expand, and iPad ↔ iPhone transitions.
This spike measures how much of that breakage disappears when you hand control
back to UIKit.

## The idiomatic recipe (one paragraph)

Create a `UISplitViewController` with `StyleDoubleColumn`, set
`preferredDisplayMode = OneBesideSecondary` and `splitBehavior = Tile`, wrap
each column root in a `UINavigationController`, assign them to
`ColumnPrimary` / `ColumnSecondary`, and set the app delegate as the split
delegate. The only delegate method needed is
`topColumnForCollapsingToProposedTopColumn:` — return `ColumnPrimary` so the
iPhone collapsed stack starts on the sidebar. Selection is then two lines:
`[contentVC showSection:title]` to update the payload, and
`[splitViewController showColumn:Secondary]` to navigate — UIKit decides
whether to push (iPhone) or focus (iPad). Drill-down is one line:
`[navigationController pushViewController:detail animated:YES]` — UIKit
provides back button and interactive swipe-back with no further code.
Per-VC toolbar items are just `self.navigationItem.rightBarButtonItems` — UIKit
swaps them correctly across every push, pop, and collapse transition.

## Hypothesis

**Idiomatic UIKit gives back, edge-swipe, per-VC toolbar, and collapse for
free.** Zapp's manual machinery fights the framework and causes the N3a-class
bugs (sticky toolbar items, incorrect back targets, inset mismatches on
collapse). Replacing that machinery with the idiomatic pattern should close
those bugs at their root.

## Build

```sh
bash spikes/ios-splitview-reference/build.sh
```

Requires Xcode command-line tools. Targets `arm64-apple-ios15.0-simulator`.
ARC is on (fine for reference — the nav/toolbar pattern is
memory-management-agnostic). Output: `build/SplitRef.app`.

## Phase-1 Observe List

Run on **both** an iPhone simulator (collapsed) and an iPad simulator
(expanded) and confirm each item. Results go in `FINDINGS.md`.

### iPhone (collapsed)

- (a) App starts on the **Sidebar** (Sections list) — not the Content VC.
- (b) Tap a section → Content slides in with a **back button** labeled
  "Sections" (or `<`).
- (c) **Edge-swipe from the left pops back to the Sidebar** — no custom code.
- (d) Tap "Push detail →" → Detail VC pushes with a **back button** labeled
  with the Content title.
- (e) **Edge-swipe pops Detail** back to Content — no custom code.
- (f) Toolbar items are **correct per screen** at each step:
    - Sidebar: one "Compose" item (right).
    - Content: "Share" + "Filter" items (right).
    - Detail: one "Trash" item (right).
    - No duplication, no stale items across push/pop transitions.

### iPad (expanded)

- (g) Sidebar + Content appear **side-by-side** on launch.
- (h) Tapping a section updates the Content column label **in place** — sidebar
  stays visible.
- (i) "Push detail →" pushes within the **Content column** — sidebar stays
  visible throughout.
- (j) Back button in the Content column's nav bar returns to Content; toolbar
  items swap correctly per column.
