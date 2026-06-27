# iOS / UIKit Split-View Behavior — Definitive Reference

**Status:** grounding reference for Zapp iOS chrome defaults (sidebars, detail/secondary, inspectors).
**Scope:** `UISplitViewController` (UIKit) on iPhone + iPad, iOS 14+ column API (iOS 16+ where noted).
**Why this exists:** Zapp's iOS panes are `WKWebView`s hosted inside `UISplitViewController` columns. This doc pins down exactly what UIKit gives us for free, what we must configure, and what Apple simply does not offer — so our native defaults match Apple's own apps and we stop chasing behavior the platform declines to provide.

> Note on terminology: iOS 14 replaced the old "master/detail" `UISplitViewController` with a **column-based** API (`init(style:)`, `setViewController(_:for:)`, `preferredDisplayMode`, `preferredSplitBehavior`). Pre-iOS-14 properties (`.primaryHidden`, `.allVisible`, `.primaryOverlay`, `collapseSecondary:onto:`) are the **legacy** surface and are only reached via `.unspecified` style. Everything below uses the modern API unless it says "legacy."

---

## A. Split styles — `UISplitViewController(style:)`

| Style | Columns | Use when |
|---|---|---|
| `.doubleColumn` | **primary** (sidebar) + **secondary** (detail) | The common master-detail / sidebar+content shape. **This is what Zapp uses.** |
| `.tripleColumn` | **primary** + **supplementary** (middle) + **secondary** (detail) | Account → list → message shapes (Mail, Notes on big iPad). The classic "inbox-style" inspector-adjacent layout. |
| `.unspecified` | n/a (legacy) | "Revert to the split view controller architecture from iOS 13 and before." Do not use for new code. |

Asymmetry rule for `.tripleColumn`: "the user might be able to see the supplementary column without seeing the primary column, but it is impossible to see the primary column without also seeing the supplementary column." ([BiTE Interactive](https://www.biteinteractive.com/more-about-split-view-controllers-in-ios-14/))

Hard constraint: assigning a VC to `.supplementary` on a `.doubleColumn` split (and vice-versa, setting `preferredSupplementaryColumnWidth` on double-column) **throws / crashes**. Column existence is fixed by the style at init. ([BiTE Interactive](https://www.biteinteractive.com/more-about-split-view-controllers-in-ios-14/))

WWDC: "The style says up front how many columns you want. Use the double-column style for two columns. We call these primary and secondary… Three columns is just as easy. Use the triple-column style. We call the new column in the middle 'supplementary.'" ([WWDC20 10105 "Build for iPad"](https://developer.apple.com/videos/play/wwdc2020/10105/))

---

## B. `preferredSplitBehavior` — `.tile` / `.overlay` / `.displace` / `.automatic`

`splitBehavior` is the **resolved** value; `preferredSplitBehavior` is the **preference**. The split behavior governs *which display modes are even allowed*:

| Behavior | What it looks like | Allows / disallows |
|---|---|---|
| `.tile` | Columns sit **side-by-side**, none on top of another. (Mail/Notes landscape.) | Allows `*BesideSecondary`. **Disallows** `over` and `displace` modes. |
| `.overlay` | Sidebar **floats over** the secondary, dimming it; tap-out / swipe dismisses. (iPad portrait flyout.) | Allows `*OverSecondary`. **Disallows** `beside` and `displace` modes. |
| `.displace` | Like tile, but revealing the leading column **pushes the secondary partway off-screen** (mostly meaningful with 3 columns). | Disallows `over`; permits `.oneBesideSecondary` but **not** `.twoBesideSecondary`. |
| `.automatic` | System chooses by size class / available width. | Default. |

WWDC phrasing: "if you prefer that the columns are side by side in your app, use the tile behavior… The displace behavior is similar, but when three columns are shown, we push the secondary column partially off-screen… The overlay behavior, of course, uses the overlay display modes." ([WWDC20 10105](https://developer.apple.com/videos/play/wwdc2020/10105/))

**CRUCIAL — `.tile` is a preference, not a guarantee.** "The system substitutes an allowed mode when your requested mode violates split behavior constraints." ([BiTE Interactive](https://www.biteinteractive.com/more-about-split-view-controllers-in-ios-14/)) The split's resolved behavior/mode is chosen from **available width vs the columns' widths**: in compact width there is "clearly no room to show multiple columns" so it collapses; in regular width "because there is so much room, UISplitViewController can show multiple columns side by side." ([WWDC20 10105](https://developer.apple.com/videos/play/wwdc2020/10105/)) If the width the system has cannot fit *both* the primary (at its minimum) **and** a usable secondary, it will not tile — it falls back to an overlay/secondary-only presentation even though you asked for `.tile`.

---

## C. `preferredDisplayMode` — and the "set BOTH together" rule

`displayMode` is resolved; `preferredDisplayMode` is the hint. Double-column-relevant modes in **bold**:

| Mode | Meaning | Style |
|---|---|---|
| **`.secondaryOnly`** | Secondary fills the whole interface; leading column(s) hidden. | both |
| **`.oneBesideSecondary`** | One leading column **side-by-side** with secondary (primary in double, supplementary in triple). | both |
| **`.oneOverSecondary`** | Secondary full-screen; one leading column as a **floating overlay**. | both |
| `.twoBesideSecondary` | All three columns side-by-side. | triple only |
| `.twoOverSecondary` | Primary + supplementary as overlay over secondary. | triple only |
| `.twoDisplaceSecondary` | Secondary beside the others but "darkened… and pushed partway offscreen." | triple only |
| `.automatic` | System picks by horizontal space. iPad: `oneBesideSecondary` (allVisible) in landscape, `oneOverSecondary` (overlay) in portrait; large iPhones use side-by-side in landscape. | both |

For an app that always wants two columns side-by-side (Reminders-style), set `preferredDisplayMode = .oneBesideSecondary`. ([WWDC20 10105](https://developer.apple.com/videos/play/wwdc2020/10105/))

**THE RULE (WWDC 10105 + community consensus): set `preferredDisplayMode` and `preferredSplitBehavior` TOGETHER.** Setting one without the other "will result in lots of weird behavior." The canonical recipe is to pair them per width state — e.g. `.oneBesideSecondary` + `.tile` for side-by-side, `.oneOverSecondary` + `.overlay` for a flyout — and to (re)apply the pair in `viewDidLoad` and again in `viewWillTransition(toSize:)`, keying off actual width (`view.frame.size.width`), **not** orientation, because multitasking can hand a "landscape" app a narrow width. ([Apple Developer Forums 653061](https://developer.apple.com/forums/thread/653061))

Legacy mapping (only via `.unspecified`): `.primaryHidden` ≈ secondaryOnly, `.allVisible` ≈ oneBesideSecondary, `.primaryOverlay` ≈ oneOverSecondary, `.automatic` ≈ same automatic rule. ([Use Your Loaf](https://useyourloaf.com/blog/split-view-controller-display-modes/))

---

## D. Size classes & orientation — the decisive table

`UISplitViewController` keys its entire behavior off the **horizontal size class** of its trait environment. The single most important fact: **horizontally compact ⇒ the split collapses to ONE column (a single nav stack); horizontally regular ⇒ it can show multiple columns.**

| Environment | Horizontal size class | What `UISplitViewController` does |
|---|---|---|
| **iPhone (SE/standard) — portrait** | **compact** | Collapses to single nav stack. No columns ever. |
| **iPhone (SE/standard) — landscape** | **compact** | Still collapses — single nav stack. (Standard phones stay compact in landscape.) |
| **iPhone Plus / Max — portrait** | **compact** | Single nav stack. |
| **iPhone Plus / Max — landscape** | **regular** | Can show columns side-by-side (the *only* phones that do). |
| **iPad — full-screen portrait** | **regular** | Shows columns. `.automatic` ⇒ overlay flyout (`oneOverSecondary`) — primary hidden, summoned over content. |
| **iPad — full-screen landscape** | **regular** | Shows columns. `.automatic` ⇒ side-by-side (`oneBesideSecondary`, "allVisible"). |
| **iPad — Split View / Slide Over** | usually **compact** (regular only for the primary app in 2/3–1/3 landscape, or both apps in a 50/50 landscape split on the largest iPad Pro) | Compact ⇒ collapses to single nav stack, exactly like an iPhone. Regular ⇒ behaves like full-screen iPad. |

Sources: "The larger iPhone Plus and Max models have a regular width in landscape orientation… [smaller iPhones are] regular in portrait but only compact in landscape." All iPhones are compact width in portrait. "A full screen iPad application always has regular height and regular width size classes regardless of orientation or device." ([Use Your Loaf — Size Classes](https://useyourloaf.com/blog/size-classes/)) For multitasking: "On iPad… the horizontal size class is compact for both apps in Slide Over and Split View—except for the single case of the primary app obtaining a regular horizontal size class in landscape 2/3–1/3… Both apps on iPad Pro in 50/50 landscape obtain a regular horizontal size class." ([Apple — Adopting Multitasking on iPad](https://developer.apple.com/library/archive/documentation/WindowsViews/Conceptual/AdoptingMultitaskingOniPad/QuickStartForSlideOverAndSplitView.html))

WWDC restatement: regular width = "iPad full screen and large iPhones in landscape… can show multiple columns side by side"; compact width = "iPad apps in slide over and iPhones in portrait… no room to show multiple columns." ([WWDC20 10105](https://developer.apple.com/videos/play/wwdc2020/10105/))

**Compact-width escape hatch:** you may register a dedicated compact VC via `setViewController(_:for: .compact)` — shown verbatim when collapsed (e.g. a `UITabBarController`). With no compact VC, UIKit *combines* the column VCs into one nav stack for the collapsed presentation.

---

## E. Column widths

- `preferredPrimaryColumnWidth` (points) or `preferredPrimaryColumnWidthFraction` (0–1 of split width). The points form, when not `automaticDimension`, **takes precedence** over the fraction. ([Apple — preferredPrimaryColumnWidthFraction](https://developer.apple.com/documentation/uikit/uisplitviewcontroller/1623183-preferredprimarycolumnwidthfract))
- Preferred is a **clamped hint**: the actual width is bounded by `minimumPrimaryColumnWidth` … `maximumPrimaryColumnWidth`.
- **The ~320 pt cap:** `maximumPrimaryColumnWidth` defaults to **320 points** (`UISplitViewControllerAutomaticDimension`). Any preferred width above 320 is **silently clamped** until you raise the max first. "You must set the preferred maximum width before any other width setting will take effect." ([BiTE Interactive](https://www.biteinteractive.com/more-about-split-view-controllers-in-ios-14/), [Use Your Loaf — column width](https://useyourloaf.com/blog/change-the-width-of-master-view-in-split-view-controller/))
- Triple-column adds `preferred/minimum/maximumSupplementaryColumnWidth` (+ `automaticSupplementaryFillDimension` to fill the leftover). These **throw** on double-column.
- **There is NO public minimum-secondary-width API on double-column** and no public way to read or constrain the secondary's minimum; the secondary takes whatever the split has left after the leading column(s). The system's tile-vs-overlay decision is driven by whether the *leading* column's minimum leaves a usable secondary, not by a secondary-min you can set.
- **No public divider drag.** Unlike AppKit's `NSSplitView`, the user cannot drag the column divider to resize, and **there is no width-changed / resize event** to observe a user-driven width change. Width is system-managed within your preferred/min/max bounds. (Zapp's `setWidth` / `sidebar-resized` are programmatic-only; `setResizable` is a documented no-op.)

---

## F. Detail / secondary behavior

- **Collapse-to-primary on compact:** when horizontally compact, the split collapses to one nav stack. By default UIKit lands on the secondary; you override the landing column via the delegate `splitViewController(_:topColumnForCollapsingToProposedTopColumn:)` (Zapp returns `.primary` to be list-first). For the compact presentation you may also supply a dedicated `.compact` VC.
- **`show(_:sender:)`** pushes/targets a VC in a way that respects the split (in a collapsed split it pushes onto the nav stack; expanded, it can target a column). **`showDetailViewController(_:sender:)`** specifically targets the **secondary/detail**: side-by-side it replaces the detail column; collapsed it pushes onto the single stack. Use `showDetailViewController` for "open this in the detail area," `show` for "push the next level."
- iOS 16+ gives explicit column control: `showColumn(_:)` / `hideColumn(_:)` push/pop or slide a named column (works collapsed and regular). This is the supported way to drive the stack programmatically.

---

## G. Inspector

**UIKit has NO first-class "inspector" column.** The dedicated, system-managed `.inspector` presentation is a **SwiftUI** affordance (`.inspector(isPresented:)`, iOS 17+), not UIKit. State this plainly to avoid chasing a phantom API.

The UIKit-native ways to build an inspector:

1. **iPad / regular width — a trailing pane you build yourself.** Either embed a trailing child VC inside the secondary/detail VC (Auto-Layout constrained — what Zapp's `inspector.m` does), or model it as the `.tripleColumn` **supplementary** column if the inspector is conceptually a third list-like column. There is no system trailing-inspector chrome; you own its width, show/hide, and divider.
2. **iPhone / compact width — a sheet.** The convention is `UISheetPresentationController` with `detents` (`.medium`, `.large`, custom on iOS 16+) and `prefersGrabberVisible`. (Zapp's modal/sheet path already wires detents + grabber; the inspector→sheet on compact is the documented compact fallback.)

So: on iPad an inspector is a hand-built trailing pane (or supplementary column); on iPhone it is a bottom sheet. UIKit gives no turnkey inspector either way.

---

## H. What Apple's own apps do (concrete)

**Mail / Notes / Files** are the reference behaviors:

- **iPhone (any model, any orientation):** single navigation stack. List → detail push. No side-by-side. (Standard phones never tile even in landscape; only Plus/Max could, and Apple's mail still presents stack-first.)
- **iPad full-screen landscape:** sidebar **tiled side-by-side** with content (`.tile` / `oneBesideSecondary`). Mail/Notes additionally expose the **third column** (`.tripleColumn`, accounts → list → message) on wide iPads; "Mailboxes are now always visible on the iPad Pro in Mail" in landscape. ([MacStories](https://www.macstories.net/stories/ios-and-ipados-14-the-macstories-review/12/), [9to5Mac](https://9to5mac.com/2016/06/14/ios-10-adds-three-pane-appearance-for-mail-and-notes-on-ipad-pro-12-9-inch/))
- **iPad full-screen portrait:** sidebar **auto-hides**, summoned as an **overlay** flyout over the content (the `.automatic` portrait default). "In portrait, both secondary columns collapse leaving only the main canvas visible." ([Apple Support — Notes view](https://support.apple.com/guide/ipad/change-the-notes-view-ipade2318ee3/ipados))
- **iPad multitasking:** column count follows the width handed to the app — "the number of columns displayed onscreen is going to change depending on the iPad model… orientation, and whether you're using Split View." Compact width ⇒ collapses to a single stack just like iPhone.

The takeaway: Apple's apps **do not force** tile in portrait or on iPhone. They use `.automatic` (tile-landscape / overlay-portrait / collapse-compact) and accept the system's adaptation. Tile in landscape is the *system's own* choice for that width, achieved with `oneBesideSecondary` + `tile` and column widths that leave a usable secondary.

---

## I. Implications for Zapp (panes = WKWebViews)

| Capability | Status for Zapp |
|---|---|
| Collapse-to-single-stack on iPhone / compact iPad | **Free** — UIKit does it. Zapp adds list-first landing + chrome-less nav-bar hiding via the delegate. |
| Side-by-side tile on iPad **landscape** | **Free under `.automatic`** — the system tiles at that width. (See Diagnosis for why our *forced* tile currently overlays.) |
| Overlay flyout on iPad **portrait** | **Free under `.automatic`** — and works today even when forced (`overlay` + `secondaryOnly`/`oneOverSecondary`). |
| Sidebar width (programmatic) | **Config** — must raise `maximumPrimaryColumnWidth` (default 320) before `preferredPrimaryColumnWidth` takes effect. Zapp sets min/max before preferred. |
| User divider-drag resize + resize event | **Apple offers none** on iOS — honest no-op (`setResizable`). Contrast AppKit. |
| User-collapsible toggle gating | **No knob** — collapse is width-driven/system-owned; `setCollapsible` is a documented no-op. |
| First-class inspector column | **Apple offers none in UIKit** — Zapp hand-builds a trailing pane (iPad) and should fall back to a sheet (iPhone). SwiftUI-only `.inspector` is out of scope for the UIKit path. |
| Forcing `.tile` in portrait / compact | **Fighting the platform.** The system overrides to overlay/collapse when width can't fit two usable columns. Prefer `.automatic` + document, unless the diagnosed fix below lands. |

**Default recommendation:** make Zapp's iOS sidebar default `presentation: "automatic"`, which gives Apple-native tile-landscape / overlay-portrait / collapse-compact for free — matching Mail/Notes — rather than forcing `.tile`.

---

# Diagnosis — why our split overlays in landscape when Mail tiles

**Smoke fact:** on a wide LANDSCAPE iPad, calling `sidebar.setPresentation("tile")` — which sets `preferredSplitBehavior = .tile` **and** `preferredDisplayMode = .oneBesideSecondary` — still renders the sidebar as an **overlay over content**, not side-by-side. Mail tiles in identical conditions.

This is the right config pair (Section C says `.oneBesideSecondary` + `.tile` is the canonical tile recipe, and that pair is exactly what Mail uses). So the bug is **not** the chosen enum values. It is **structural/ordering** in how we build the split. Reading `native/platform/ios/window.m` (~L236–335) and `native/platform/ios/sidebar.m` (`zapp_ios_sidebar_register`, L260–307; `darwin_sidebar_set_presentation`, L452–472):

### Ruled OUT
- **(b) displayMode resolving to secondaryOnly at startup** — `setPresentation("tile")` explicitly forces `oneBesideSecondary`, so the cached startup value is overwritten. Not the live cause.
- **(d) presentsWithGesture / overlay-init** — `presentsWithGesture = YES` only adds the reveal gesture; it does not force overlay. Not causal.
- **(e) primary min too high** — kitchen-sink passes `minWidth:150, maxWidth:500, width:300`. 150–300 pt primary on a >1000 pt landscape iPad leaves a large, usable secondary. The primary easily fits. Not the blocker.

### The actual cause(s) — confirmed in code

**1. (Primary) The columns are re-set AFTER the preferred values, and the nav-wrapping/relayout drops the tile preference.**
`window.m` L257–298 sets `setViewController:forColumn:` on the **bare** VCs, then min/max/preferred/`preferredDisplayMode`/`preferredSplitBehavior` on the split. Immediately after (L330) it calls `zapp_ios_sidebar_register`, which at `sidebar.m` L289–290 calls **`setViewController:forColumn:` a SECOND time** with `UINavigationController`-wrapped VCs, and installs the delegate (L299). Re-assigning columns + attaching the delegate after the preferred values were set, with no re-application of the `displayMode/splitBehavior` pair afterward, lets the subsequent first layout pass re-resolve the behavior from `.automatic`-style defaults. The WWDC rule (Section C) is that the pair must be applied **after** the columns exist and **re-applied on every layout/transition**; we apply it once, before the final columns, and never again at first layout.

**2. (Primary) `.tile` is set at construction-time when the split has NO real bounds yet, and is never re-applied once the window has a regular-width landscape geometry.**
Everything in the `d->hasSidebar` block runs inside `zapp_ios_materialize_pending_windows` *before* `makeKeyAndVisible` (L501) and before the split has its on-screen size/traits. At that moment the trait environment is not yet the final regular-width landscape, so the system's first resolution can land on an overlay/automatic presentation; because we never re-apply the `oneBesideSecondary`+`tile` pair in a `viewWillTransition`/`traitCollectionDidChange` hook, it sticks. Mail re-applies its pair on every size transition; we apply once at build time.

**3. (Contributing) The runtime `setPresentation("tile")` path forces a relayout but not a trait re-resolution.**
`darwin_sidebar_set_presentation` (sidebar.m L459–471) sets the correct pair then calls `setNeedsLayout` + `layoutIfNeeded`. That re-lays-out the *current* resolved mode but does not by itself force `UISplitViewController` to re-pick `.tile` over an already-committed overlay resolution — especially if `displayMode` was already `oneOverSecondary` from the automatic portrait/launch path. A layout pass is weaker than the trait/size re-resolution the system uses to choose tile vs overlay.

### Verdict — **FIXABLE.** It will tile Apple-native in landscape with a concrete change.

The enum values are correct; the failure is **when/where** we apply them. Concrete fix, in priority order:

1. **Apply the `displayMode + splitBehavior` pair AFTER the final (nav-wrapped) columns are set, not before.** Move the `preferredSplitBehavior` / `preferredDisplayMode` (and min/max/preferred-width) assignment to run **after** `zapp_ios_sidebar_register` has done its second `setViewController:forColumn:` — i.e. set columns first, *then* the preferred pair. Today the order is inverted.
2. **Re-apply the pair on size/trait changes.** Add a `viewWillTransition(toSize:)` / `traitCollectionDidChange:` hook on the split (or its delegate, which we already own in `ZappIOSSidebarController`) that, when horizontally regular and the configured presentation is `tile`, re-sets `preferredSplitBehavior = .tile` + `preferredDisplayMode = .oneBesideSecondary` keyed off `view.bounds.size.width` (not orientation). This is exactly the WWDC 10105 recipe and what Mail does.
3. **In `setPresentation`, follow `layoutIfNeeded` with the same re-application after the next runloop turn** (or drive `showColumn(.primary)` on iOS 16+) so a previously-committed overlay resolution is replaced, not just re-laid-out.

If, after (1)+(2), a given width genuinely cannot fit two usable columns, the system will *correctly* decline to tile — at which point `.automatic` is the honest default (Section H: that is precisely what Mail/Notes do). But on a wide landscape iPad with a 150–300 pt primary, two columns fit easily, so the corrected ordering **will** produce Apple-native side-by-side tiling.

**Recommendation:** attempt fix (1)+(2) — it is low-risk and matches the documented recipe. Keep `.automatic` as the **default** presentation (free Mail-parity adaptation); treat forced `.tile` as an opt-in that now actually works in regular width.

---

## Sources

- [WWDC20 Session 10105 — "Build for iPad"](https://developer.apple.com/videos/play/wwdc2020/10105/)
- [Apple Developer — UISplitViewController](https://developer.apple.com/documentation/uikit/uisplitviewcontroller)
- [Apple Developer — maximumPrimaryColumnWidth](https://developer.apple.com/documentation/uikit/uisplitviewcontroller/maximumprimarycolumnwidth)
- [Apple Developer — preferredPrimaryColumnWidthFraction](https://developer.apple.com/documentation/uikit/uisplitviewcontroller/1623183-preferredprimarycolumnwidthfract)
- [Apple Developer — SplitBehavior.tile](https://developer.apple.com/documentation/uikit/uisplitviewcontroller/splitbehavior-swift.enum/tile) · [.overlay](https://developer.apple.com/documentation/uikit/uisplitviewcontroller/splitbehavior/overlay)
- [Apple Developer Forums 653061 — managing displayMode/splitBehavior across transitions](https://developer.apple.com/forums/thread/653061)
- [Apple — Adopting Multitasking on iPad (size classes in Split View / Slide Over)](https://developer.apple.com/library/archive/documentation/WindowsViews/Conceptual/AdoptingMultitaskingOniPad/QuickStartForSlideOverAndSplitView.html)
- [Apple Support — Change the Notes view on iPad](https://support.apple.com/guide/ipad/change-the-notes-view-ipade2318ee3/ipados)
- [BiTE Interactive — More About Split View Controllers in iOS 14](https://www.biteinteractive.com/more-about-split-view-controllers-in-ios-14/)
- [Use Your Loaf — Split View Controller Display Modes](https://useyourloaf.com/blog/split-view-controller-display-modes/) · [Size Classes](https://useyourloaf.com/blog/size-classes/) · [Change the Width of Master View](https://useyourloaf.com/blog/change-the-width-of-master-view-in-split-view-controller/)
- [MacStories — iOS/iPadOS 14 Review (Mail/Notes columns)](https://www.macstories.net/stories/ios-and-ipados-14-the-macstories-review/12/)
- Zapp source: `native/platform/ios/window.m` (split materialize, ~L236–335), `native/platform/ios/sidebar.m` (`zapp_ios_sidebar_register` L260–307, `darwin_sidebar_set_presentation` L452–472)
