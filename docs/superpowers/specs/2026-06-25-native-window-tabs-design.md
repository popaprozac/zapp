# Native Window Tabs — Design Proposal (PRE-STAGED, pending review)

**Status:** ⚠️ DRAFT PROPOSAL — pre-staged while the user was away. **Not approved.**
Contains proposed defaults (flagged) + Open Questions that need the user's answer
before this becomes an approved spec and goes to writing-plans. No implementation
has started (brainstorming HARD-GATE: design approval required first).
**Branch:** `feat/nim-native` (UNMERGED). **Task:** roadmap item "native window tabs" (#643-adjacent / project_native_elements_roadmap candidate #3).
**Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

## Goal

Let Zapp apps group their windows into a **native macOS tab bar** (Finder/
Terminal/Safari-style) via `NSWindow` tabbing — windows that share a
`tabbingIdentifier` collapse into one window with a native tab bar. This is
"native chrome you can't fake in CSS" (the roadmap's stated highlight family),
with very little framework surface: mostly create-time options + one event.

## Scope (proposed)

- **macOS only**, create-time. Consistent with all other window chrome
  (`titleBarStyle`, `vibrancy`, toolbar, traffic lights are macOS-only; iOS
  no-ops). iOS `darwin_window_create` simply won't read the new fields — no iOS
  stub needed, cross-compile/parity gate stays green (verified in exploration).
- **v1 is deliberately minimal** (see Open Question 3): create-time
  `tabbingIdentifier` + `tabbingMode`, plus a `NEW_TAB_REQUESTED` event so the
  app can add tabs when the user clicks the tab bar's "+". Programmatic
  tab-group control (select/reorder/overview) is proposed as v2.

## Background (verified 2026-06-25)

- `WindowOptions` (TS `runtime/window.ts:75–239`; Nim `native/nim/window.nim`
  `WindowOptions` ref object) → wire JSON → `windowOptsApplyJson` → `wopts_*`
  exportc getters → read in `native/platform/darwin/window.m` `darwin_window_create`.
  A new string field follows the exact `asSheetOf`/`titleBarStyle` pattern.
- The `NSWindow` is configured in `darwin_window_create` (~`window.m:692–777`,
  the pre-webview zone). `window.tabbingMode` / `window.tabbingIdentifier` set
  here, right after the traffic-light block (~line 754).
- `NSWindowDelegate` = `ZappWindowDelegate` (`window.m:361–538`) — already emits
  FOCUS (windowDidBecomeKey), CLOSE (windowShouldClose/windowWillClose), etc.
  **Tab selection reuses FOCUS; tab close reuses CLOSE** — no new delegate
  wiring needed for those.
- Window events 12–20 are **string events** broadcast via
  `globalThis[Symbol.for('zapp.bridge')]._onEvent(name, json)` +
  `darwin_webview_eval_all` + `worker_broadcast_eval_js` (the toolbar pattern,
  `toolbar.m:95–111`). A tab event reuses this exactly — **no numeric `#define`
  / coretypes id needed.**
- `WindowEvent` enum (`runtime/events.ts:22–67`) max = `TOOLBAR_GROUP_SELECTED = 20`.
  Next free = **21**.
- Multi-window already works: `Window.create` → router → `windowOptsApplyJson`
  → `createWindow` → `darwin_window_create`, monotonic ids. N windows sharing a
  `tabbingIdentifier` is just N normal creates carrying the field.

## Proposed API

### TS (`runtime/window.ts` WindowOptions)

```ts
/** macOS native window tabs. Windows that share a `tabbingIdentifier` collapse
 *  into one window with a native tab bar (Finder/Terminal-style). macOS only;
 *  create-time. Ignored when `borderless: true` (no titlebar to host the bar)
 *  or when the window is an `asSheetOf` sheet. */
tabbingIdentifier?: string;
/** How this window participates in tabbing. "preferred" = always tab with
 *  same-identifier windows; "automatic" = respect the user's system "Prefer
 *  tabs" setting; "disallowed" = never tab. Default: see Open Question 2. */
tabbingMode?: "automatic" | "preferred" | "disallowed";
```

### Event (`runtime/events.ts`)

```
NEW_TAB_REQUESTED = 21   →  "window:new-tab-requested"
```

Payload `{ windowId }` — the window whose tab bar "+" was clicked. The app
responds by calling `Window.create({ tabbingIdentifier: <same>, ... })`. If the
app does not subscribe, the "+" button does nothing (AppKit's `newWindowForTab:`
has no default action — see Open Question 1 for the alternative).

### Native (`window.m`)

In `darwin_window_create`, after traffic lights (~line 754):
```objc
const char* tabId = wopts_tabbing_identifier(opts);
if (tabId && tabId[0]) window.tabbingIdentifier = [NSString stringWithUTF8String:tabId];
// tabbingMode: map "automatic"/"preferred"/"disallowed"; default per OQ2.
window.tabbingMode = <resolved>;
```
`ZappWindowDelegate` (or the window's `newWindowForTab:`) emits
`window:new-tab-requested` via the toolbar emit pattern.

### Nim (`window.nim`)

Add `tabbingIdentifier*: string` + `tabbingMode*: string` to `WindowOptions`;
parse both in `windowOptsApplyJson` (`jHasStr`); add `wopts_tabbing_identifier`
+ `wopts_tabbing_mode` cstring getters. (No iOS-side change.)

## Open Questions (need the user's answer before approval)

**OQ1 — The tab bar "+" button behavior.**
- **(a) Emit `NEW_TAB_REQUESTED`, app creates the tab** *(recommended — native-first, maximally flexible).* The app decides what a new tab is (new URL, duplicate, blank). Costs: the app MUST handle the event or "+" is inert.
- (b) Auto-duplicate the current window (Zapp creates a same-options tab automatically). Simpler for trivial apps, but rarely what a real app wants, and "duplicate" is ambiguous (same URL? same state?).
- (Could support both: emit the event always; add an opt-in `autoTab: true` later. v1 pick one default.)

**OQ2 — Default `tabbingMode` when `tabbingIdentifier` is set but `tabbingMode` is omitted.**
- **(a) `preferred`** *(recommended)* — same-identifier windows always tab together. Predictable "these are tabs" UX regardless of the user's system pref.
- (b) `automatic` — respect the macOS "Prefer tabs when opening documents" system setting (windows tab only if the user opted in globally). More OS-deferential, less predictable.
- (With no `tabbingIdentifier` at all → leave AppKit default `automatic`, i.e. effectively off unless the system pref says otherwise.)

**OQ3 — v1 scope: just create-time + the event, or also programmatic tab-group control?**
- **(a) Minimal v1** *(recommended)*: `tabbingIdentifier` + `tabbingMode` + `NEW_TAB_REQUESTED`. Tab select/close reuse FOCUS/CLOSE. Ship the 90% case small; defer `NSWindowTabGroup` control (select tab, reorder, toggle the Mission-Control-style overview, move-tab-to-new-window) to v2.
- (b) Include programmatic control in v1: `win.tabs.select(id)`, `win.tabs.list()`, `win.tabs.showOverview()`, a `TAB_SELECTED` event distinct from FOCUS. More complete, but a meaningfully bigger surface + more native plumbing.

**OQ4 — `tabTitle` override?**
- **(a) Defer** *(recommended)* — the tab label is the window `title` (AppKit default); apps already control `title`. No new field in v1.
- (b) Add `tabTitle?: string` now for a tab label distinct from the window title.

## Known interactions to document (from exploration)

- `borderless: true` → `NSWindow` is `StyleMaskBorderless`; tabbing requires a
  titled window → `tabbingMode` is silently ignored. Document as a no-op combo.
- `asSheetOf` sheets force `visible=false` + `beginSheet:` → not first-class tab
  members → `tabbingIdentifier` on a sheet is a no-op. Document.
- `titleBarStyle: "hidden"/"hiddenInset"` (FullSizeContentView) is compatible —
  the tab bar lives in the (present) titlebar; content flows under. But
  `titlebarAppearsTransparent` can hurt tab-label contrast, and the
  `unifiedCompact` toolbar style (set for `hiddenInset`) shares the titlebar row
  with the tab bar → possible height squeeze. **Risk-gate: smoke
  tabs × {default, hiddenInset+toolbar} early.**
- `ZAPP_MAX_WINDOW_CALLBACKS = 64` (`window.m:102`) caps total live windows incl.
  tabs — pre-existing ceiling, note it.

## Proposed plan shape (AFTER approval — not started)

Likely 3 tasks, mirroring the W2/grouping/color cadence:
1. **T1 (RISK GATE)** — set `tabbingIdentifier`/`tabbingMode` on the NSWindow +
   prove two `Window.create` calls with the same id visibly tab together
   (human visual), incl. the `hiddenInset`+toolbar combo from the interactions
   list. Wire `newWindowForTab:` → `NEW_TAB_REQUESTED`.
2. **T2** — TS WindowOptions fields + `NEW_TAB_REQUESTED` event + Nim parity
   (fields/getters/windowOptsApplyJson) + native read, TDD where unit-testable
   (the wire round-trip in windowmanager_test). macOS + iOS-sim build gates.
3. **T3** — kitchen-sink Multi-window "Tabs" demo (open N tabbed windows + a
   `NEW_TAB_REQUESTED` handler that adds tabs) + api-reference docs + full gates
   + human visual smoke.

## Non-goals (v1)

- iOS tabs (UIWindowScene / UITabBar) — future, like all iOS chrome.
- Programmatic tab-group control + overview (unless OQ3 → b).
- Cross-`tabbingIdentifier` merging / drag-between-groups beyond AppKit defaults.
