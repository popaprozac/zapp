# Task 6c — iOS A2 tile-fix: report

## What was changed

### 1. Reordered: presentation applied AFTER nav-wrap (`window.m` + `sidebar.m`)

`window.m` previously set `preferredSplitBehavior`/`preferredDisplayMode` on bare column VCs, then called `zapp_ios_sidebar_register` which immediately replaced those VCs with nav-wrapped ones — dropping the resolved behavior. The fix:

- Removed the entire presentation block from `window.m`'s `hasSidebar` materialize path (lines ~280–293 old). Width min/max/preferred are still set there (they're split-level, not VC-scoped, so they survive the nav-wrap re-set).
- `zapp_ios_sidebar_register` now receives `const char* presentation` (new 7th param), stores it as `c.presentation = presMode`, and calls `zapp_ios_apply_presentation(svc, presMode)` **after** `[svc setViewController:sbNav ...]` + `[svc setViewController:ctNav ...]` — i.e. after the final nav-wrapped columns are in place.

### 2. Shared helper: `zapp_ios_apply_presentation` (`sidebar.m`)

Static function `zapp_ios_apply_presentation(UISplitViewController* svc, NSString* mode)` applies the behavior+displayMode pair atomically from one canonical mapping. Called from:
1. `zapp_ios_sidebar_register` (create path, after nav-wrap)
2. `darwin_sidebar_set_presentation` (runtime setter — replaces inline enum checks)
3. `ZappIOSSplitViewController`'s transition hooks (size-change re-apply)

`darwin_sidebar_set_presentation` now also stores `presMode` on `c.presentation` before calling the helper, so the transition hook always has the current mode.

### 3. `ZappIOSSplitViewController` subclass + transition hooks (`sidebar.m` + `window.m`)

New `@interface ZappIOSSplitViewController : UISplitViewController` defined in `sidebar.m`, forward-declared in `window.m` (full `@interface` with superclass for compiler resolution of `initWithStyle:`). Two overrides:

- `viewWillTransitionToSize:withTransitionCoordinator:` — fires before rotation/multitasking resize. Keys off incoming `size.width >= 768.0 || horizontalSizeClass == Regular`. Re-applies the pair only when `c.presentation == "tile"` and the incoming width is regular.
- `traitCollectionDidChange:` — fires after multitasking mode switches (full-screen ↔ split view). Re-applies when `horizontalSizeClass == Regular` and presentation is `"tile"`.

`window.m` instantiates `ZappIOSSplitViewController` (via `[[ZappIOSSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn]`) instead of the bare `UISplitViewController`.

`.automatic` default is unchanged — UIKit handles tile-landscape / overlay-portrait / collapse-compact freely under automatic.

## Build results

```
iOS:   [zapp] build complete: …/kitchen-sink.app/kitchen-sink (1872 KB)  ✓
macOS: [zapp] build complete: …/bin/kitchen-sink (1852 KB)               ✓
tests: 104 pass, 0 fail                                                   ✓
```

## Concerns / follow-ups

- **No new cross-platform symbols added** — `ZappIOSSplitViewController` and `zapp_ios_apply_presentation` are iOS-only static/ObjC; the parity lint sees no new `darwin_*` symbols needing mirrors.
- **Runtime tile behavior** is the human re-smoke (landscape iPad — needs device/simulator run).
- The `size.width >= 768.0` heuristic in `viewWillTransitionToSize:` is conservative; it errs on re-applying when in doubt (UIKit will override to overlay/collapse if width truly can't fit two columns — safe).
- `overlay` mode in `zapp_ios_apply_presentation` sets `preferredDisplayMode = .secondaryOnly` (sidebar starts hidden, summoned as flyout). This matches the original behavior for overlay; no regression expected.
