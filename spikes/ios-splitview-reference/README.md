# ios-splitview-reference — Phase 1 + Phase 2

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
Links `UIKit`, `Foundation`, and `WebKit`. ARC is on. Output: `build/SplitRef.app`.

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

---

## Phase 2: WKWebView-hosting VCs

Phase 2 replaces the plain coloured `UIView` in Content and Detail with a
full-bleed `WKWebView` pinned to the **view edges** (not the safe-area layout
guide), exactly as Zapp does today. The HTML contains a safe-area visualiser
that makes the inset behaviour visible at a glance.

### What changed from Phase 1

- `ContentViewController.m` — `WKWebView` pinned to `view.{leading,trailing,top,bottom}`.
  Loads the safe-area HTML. `-showSection:` updates via `evaluateJavaScript:`
  (falls back to `loadHTMLString:` if the page is not yet ready).
  The "Push detail →" link calls `webkit.messageHandlers.nav.postMessage("detail")`
  which is caught by a `WKScriptMessageHandler` named `nav` and triggers the
  same `[nav pushViewController:detail animated:YES]` as Phase 1.
- `DetailViewController.m` — same full-bleed `WKWebView`, indigo background.
  No nav handler needed — back is native.
- `build.sh` — added `-framework WebKit`.
- Phase 1 idiomatic nav (split delegate, `showColumn:`, `pushViewController:`,
  per-VC `navigationItem`) is **unchanged**.

### The safe-area visualiser

The HTML page loaded in both VCs paints four coloured bands along each edge
using `env(safe-area-inset-*)`:

| Band   | Colour   | Meaning |
|--------|----------|---------|
| Top    | Red `#ff3b30`   | `safe-area-inset-top` — should cover the nav bar height |
| Bottom | Green `#34c759` | `safe-area-inset-bottom` — home indicator / bottom bar |
| Left   | Orange `#ff9500` | `safe-area-inset-left` |
| Right  | Purple `#af52de` | `safe-area-inset-right` |

An on-screen `#readout` div prints the actual resolved pixel values by
probing a `position:fixed; top:env(safe-area-inset-top)` element's
`getBoundingClientRect()`.

### The key question

**Is the red top band visible just below the nav bar?**

- **Yes, red band present + `safe-area-inset-top` > 0** → UIKit propagated
  the nav-bar inset to the WKWebView's CSS `env()` for free. Content sits
  below the bar without any manual injection.
- **No red band / readout says 0** → content bleeds under the nav bar.
  Zapp would need to inject `additionalSafeAreaInsets` or equivalent.

### Phase-2 Observe List

Run on **both** an iPhone simulator and an iPad simulator.

#### Safe-area insets (the main question)

- (P2-a) **iPhone — Content screen**: is the red band visible below the nav bar?
  What does `#readout` report for `safe-area-inset-top`? (Expect ~44–96 px if UIKit propagates for free.)
- (P2-b) **iPhone — Detail screen**: same question after pushing via the JS→native link.
  Does the red band appear on the pushed Detail WKWebView?
- (P2-c) **iPhone — bottom inset**: is the green band visible above the home indicator / bottom bar?
- (P2-d) **iPad — expanded, tile mode**: with the sidebar tiled (not overlaid), does Content
  have a left inset (orange band)? (Expected: no — the sidebar is beside, not over, the content.)
- (P2-e) **iPad — overlay sidebar (narrow width / Stage Manager)**: with the sidebar overlaid,
  does Content have a left inset? (Expected: no — overlay sidebars float over content; a bleed
  here is correct / expected UIKit behaviour.)

#### Navigation (Phase 1 parity with webviews)

- (P2-f) Tap "Push detail →" link in the WKWebView → Detail VC pushes (JS→native message handler).
- (P2-g) Native back button in the nav bar pops Detail → Content.
- (P2-h) Edge-swipe from left pops Detail → Content.
- (P2-i) Toolbar items correct per screen: Content = Share+Filter; Detail = Trash. No stale items.
- (P2-j) Sidebar selection still works: tapping a section updates the Content webview title in-place.
