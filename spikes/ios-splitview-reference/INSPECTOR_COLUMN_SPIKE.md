# iOS 26 Inspector-column spike — doubleColumn + `UISplitViewControllerColumnInspector`

## What this proves

The crux question: does the iOS-26 dedicated **Inspector column**
(`UISplitViewControllerColumnInspector`, `API_AVAILABLE(ios(26.0))`) attach to a
**`doubleColumn`** base, or does UIKit require `tripleColumn`?

This spike takes the **doubleColumn hypothesis**:

| Column      | Style role                | VC                      |
|-------------|---------------------------|-------------------------|
| Primary     | sidebar list              | `SidebarViewController` |
| Secondary   | permanent content canvas  | `ContentViewController` |
| Inspector   | iOS-26 hideable column    | `InspectorViewController` |

Content is now **Secondary** (the permanent canvas), NOT Supplementary. The
inspector is the first-class iOS-26 Inspector column, distinct from Secondary.

### Result

- `initWithStyle:UISplitViewControllerStyleDoubleColumn` +
  `setViewController:forColumn:UISplitViewControllerColumnInspector`
  **compiles cleanly** (no errors, no warnings) against SDK iPhoneSimulator 26.5,
  deployment target ios15.0, with the iOS-26 symbols guarded by
  `if (@available(iOS 26.0, *))`.
- SDK evidence supporting doubleColumn: in `UISplitViewController.h` the
  `Supplementary` enum case is annotated **"Valid for
  UISplitViewControllerStyleTripleColumn only"**, whereas the `Inspector` case
  carries **no such style restriction** — it is orthogonal to the base style.
- Runtime confirmation is via logs (see checklist) — the human runs the sim.

## Build

```sh
cd /Users/zach/code/zapp/spikes/ios-splitview-reference
./build.sh          # must print: [splitref] build complete: build/SplitRef.app
```

## Install + launch (human runs this)

```sh
xcrun simctl install booted build/SplitRef.app && \
xcrun simctl launch booted dev.zapp.splitref
```

Stream the instrumentation logs in another terminal:

```sh
xcrun simctl spawn booted log stream --level debug \
  --predicate 'eventMessage CONTAINS "[zapp-nav]"'
```

### Key log line to confirm the experiment

At launch you should see the Inspector column VC reported non-nil:

```
[zapp-nav] launch DOUBLECOLUMN split style=1 preferredDisplayMode=... preferredSplitBehavior=1
[zapp-nav] inspector-column VC after setup = UINavigationController (non-nil=1)
```

`style=1` is `UISplitViewControllerStyleDoubleColumn`. `non-nil=1` means the
Inspector column accepted a VC on a doubleColumn base — the hypothesis holds at
the API level.

## Smoke checklist

Run on an **iPad simulator** (regular width) AND an **iPhone simulator**
(compact width). The inspector is bright amber with a big **"INSPECTOR COLUMN"**
label so you can confirm the real inspector renders (not a blank).

### iPad (regular width)

- [ ] Cold launch shows sidebar | content side-by-side (content is the canvas).
- [ ] Tap the trailing **`sidebar.right`** toolbar button on Content → the
      **INSPECTOR COLUMN** (amber) appears as a hideable column beside the
      content. The content canvas **stays visible** (it is not replaced).
- [ ] The inspector column shows a **drag grabber / resizable divider**; dragging
      resizes it.
- [ ] Tap the button again → inspector column hides; content canvas remains.
- [ ] Log shows `showColumn:Inspector` / `hideColumn:Inspector` and
      `isShowingColumn` driving the toggle.

### iPhone (compact width)

- [ ] Cold launch lands on the **sidebar** (collapse → Primary override).
- [ ] Tapping a sidebar row lands on **content** (Secondary), not the inspector.
- [ ] Tap the trailing inspector button on Content → the **INSPECTOR COLUMN**
      appears as an **auto-presented sheet** (UIKit presents the Inspector column
      as a sheet on compact width).
- [ ] Dismissing the sheet returns to content.

### Shared (both)

- [ ] **Land-on-content** still works: selecting any sidebar row shows that
      section in the content canvas; if content was drilled into Detail it pops to
      root first (`popToRoot before showSection` in log).
- [ ] **Back/forward detail push** still works: tap "Push detail →" in content →
      Detail (purple, no navbar) pushes; left-edge swipe or the in-content Back
      button pops cleanly; `detail dealloc` appears in the log (no leak).

## Pre-iOS-26 fallback (informational)

Below iOS 26 the Inspector column is skipped; the Content toolbar button instead
presents `InspectorViewController` **modally as a sheet** (medium + large detents,
grabber visible). This path is only exercised on a pre-26 runtime — the current
sim is 26.5 so the column path runs.

## Files touched

- `src/AppDelegate.m` — doubleColumn construction + Inspector column attach + logs.
- `src/ContentViewController.m` — `toggleInspector` → iOS-26 show/hideColumn:Inspector
  (visibility via `isShowingColumn:`), pre-26 modal-sheet fallback.
- `src/SidebarViewController.m` — land-on-content now targets **Secondary**.
- `src/InspectorViewController.m` — bright "INSPECTOR COLUMN" label + section text.

`DetailViewController.m` (push/swipe-back) is unchanged.
