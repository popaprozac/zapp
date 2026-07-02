# Research: overriding UISplitViewController's user-drag column width (iOS 26)

**Date:** 2026-07-01 · **Question:** can Zapp's `setWidth` be made to work after the user drags a column divider (sidebar Primary / iOS-26 Inspector column), where `preferred*ColumnWidth` becomes a no-op?

## Verdict

**`POLICY: user-resize-wins` — by Apple's design, with no public reset now or coming.** But two public-API workarounds remain genuinely untested (the prior "nothing evicts the pin" testing predates the Inspector column's own show/hide path), and UIKit ships a built-in *user-side* reset we didn't know about. A cheap spike probe settles it.

## Evidence

### 1. No sanctioned API — exhaustively confirmed
- iOS 26.5 SDK `UISplitViewController.h` (all 314 lines inventoried): only preferred/min/max per column, `hide/showColumn:`, displayMode/splitBehavior, delegate callbacks. No reset, no interaction-state, no resize delegate.
- **iOS 27.0-beta SDK header is byte-identical** — no relief in the next major release.
- Apple docs for `preferredInspectorColumnWidth` / `preferredPrimaryColumnWidth`: no discussion of user interaction at all. WWDC25 243 ("you can now resize columns by dragging the separators") and 282 mention customizing min/max/preferred — never resetting.

### 2. UIKitCore binary archaeology (26.4 sim runtime) — the mechanism
- The ownership model is an explicit internal boolean: `-[_UISplitViewControllerAdaptiveImpl _updatePreferredColumnsEnforcingColumnPreferences:]` + log format `"...updatedEnforcingColumnPreferences = %d"`. A user drag flips *enforcement of column preferences* OFF for that column; layout then re-applies the privately stored user width. This matches Zapp's A2-era instrumentation exactly (the `preferred*` property stays at the Automatic sentinel through a drag).
- **UIKit ships its own user-side reset:** the separator carries a private tap recognizer whose handler is literally `_handleResizeColumnToPreferredSizeTapGestureRecognizer:` — *tapping the divider snaps the column back to the preferred size*. The pin is resettable by design; the reset is just user-initiated, not programmatic.
- Private resize-delegate SPI exists (`_splitViewController:willBeginResizingColumn:` etc.) — underscore SPI, not App Store-usable. Notably no constrain-SPI for the Inspector column.
- Cross-launch: user widths persist ONLY via opt-in state restoration (`_UISplitViewControllerLayoutState`, gated on restoration identifiers). Zapp doesn't adopt it → the pin is per-scene, in-memory.

### 3. Community + SwiftUI corroboration
- No published iOS-26 workarounds yet (feature too new). Catalyst width-stickiness threads (718651, 717856) sat unanswered for years; SwiftUI's `navigationSplitViewColumnWidth` docs call widths non-binding preferences and FB10749141 (can't programmatically widen after user resize) is years-unfixed. The policy is consistent across frameworks.

### 4. What Zapp already proved (A2-era instrumentation, on-device iOS 26)
- min==max clamp BEATS the pin (basis of `resizable:false`); displayMode/splitBehavior toggles do NOT; detaching the column VC resets it but kills the WKWebView content process (unacceptable).

## Untested candidates → the probe plan

Vehicle: `spikes/ios-splitview-reference` (zero risk to the framework branch) — a "width probe" button running each sequence with per-layout frame-width logging (`viewDidLayoutSubviews`; there is no public current-width getter for the Inspector column). Human smokes on iPad, drags the inspector seam first, then runs:

| # | Probe | Mechanism | Odds | Risk |
|---|---|---|---|---|
| P1 | **Clamp-nudge**: min==max==target → `layoutIfNeeded` → restore real min/max → force 2 more layouts (rotate) | The clamp path and the drag path funnel into the same layout resolution; the clamp may overwrite the stored user width | ~30-40% | none (must serialize with the `resizable:false` lock — same fields) |
| P2 | **Hide/show cycle**: `hideColumn:Inspector` → set preferred while hidden → `showColumn:` | Column re-presentation may re-enter the enforce-preferences path; distinct from displayMode toggles (which never hide the *Inspector*) | ~40-50% | low: VC stays attached (webview unparented briefly, not deallocated); visible blink + one collapsed/expanded event pair |
| P3 | **Separator-tap** (user gesture, works today?): after `setWidth`, tap the divider handle | UIKit's own built-in snap-to-preferred | verify-only | none — if it works, it's the *sanctioned* story: `setWidth` re-arms the preferred width; the user adopts it with a tap |
| P4 | **Trait-collapse cycle** (last resort): force compact → regular | Full column-layout rebuild on expand may drop the pin | unknown | HIGH — pane↔sheet transition historically kills the inspector bridge; only if P1-P3 all fail |

Cross-cutting diagnostic while probing: `xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == "com.apple.UIKit"'` — the `updatedEnforcingColumnPreferences = %d` log line shows which public mutations flip enforcement.

## PROBE RESULTS (2026-07-01, iPad sim iOS 26.4, human-run — VERDICT SEALED)

- **P1 clamp-nudge: FAILED.** Clamp visibly held the target (240) while active; the restore's layout pass snapped straight back to the dragged width (320) — `inspW=320` on the restore layout. The private user-width cache survives clamping. (Also re-confirmed: `preferred*` stays at the Automatic sentinel, printed as `-3.4e38`, through a drag.)
- **P2 hide/show cycle: FAILED.** Column re-presented at the dragged width (~232), not the armed 360. The pin survives full column dismissal.
- **P3 divider reset: WORKS — it is a DOUBLE-tap.** Single tap does nothing; double-tap on the seam animated the column to the armed `preferredInspectorColumnWidth` (240) from ~347. `setWidth` post-drag therefore ARMS the width that the user's double-tap adopts — Apple's ownership model, complete: app arms preferred → user owns actual → double-tap returns to the app's preference.

**Final verdict: `POLICY: user-resize-wins`, no programmatic override via public API. Ship the documented ownership model, enriched with the double-tap affordance.** Probe code lives in the spike's uncommitted WIP (`src/ContentViewController.m` P1/P2 handlers + `src/InspectorViewController.m` width logging) for future re-runs on new iOS releases.

## Decision tree after the probe (resolved: "only P3 works" branch)

- **P1 or P2 works** → decide semantics: make `setWidth` always-authoritative (macOS parity) vs. an explicit `setWidth(w, {force})` — the silent blink/event-churn of P2 argues for opt-in if P2 is the winner; P1 winning is clean enough to be the default path.
- **Only P3 works** → keep the documented ownership model; docs gain "the user can tap the divider to adopt the app's requested width" — a real, Apple-designed affordance.
- **Nothing works** → land the held docs ownership bullet as-is; the model is genuinely UIKit policy.

## Sources
Apple docs (preferredInspectorColumnWidth, preferredPrimaryColumnWidth), WWDC25 sessions 243 + 282, iOS 26.5 + 27.0-beta SDK headers, UIKitCore binary strings (26.4 sim runtime), Apple forums 718651/717856, swiftui-introspect #449, Use Your Loaf (split-view width articles), BiTE Interactive (iOS 14 split-view ordering lore).
