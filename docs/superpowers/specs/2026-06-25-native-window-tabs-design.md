# Native Window Tabs — Design Proposal (PRE-STAGED, pending review)

**Status:** ✅ APPROVED (2026-06-25). All four open questions answered by the user:
OQ1 = (a) emit `NEW_TAB_REQUESTED`; OQ2 = (a) default `preferred`; OQ3 = (a)
minimal v1; **OQ4 = add `tabTitle` (user override of my "defer" recommendation).**
Ready for writing-plans. (Plan may be pre-staged while the user is away; the
implementation's T1 risk-gate human visual smoke waits for the machine.)
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
 *  tabs" setting; "disallowed" = never tab. Default when `tabbingIdentifier`
 *  is set: "preferred". */
tabbingMode?: "automatic" | "preferred" | "disallowed";
/** Tab label override. Defaults to the window `title` if omitted. Sets
 *  NSWindow.tab.title (macOS 10.13+). macOS only; create-time. */
tabTitle?: string;
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
// tabbingMode: map "automatic"/"preferred"/"disallowed"; default "preferred"
// when a tabbingIdentifier is set, else AppKit default (automatic).
window.tabbingMode = <resolved>;
// tabTitle (optional): override the tab label (macOS 10.13+, the tabbing floor).
const char* tabTitle = wopts_tab_title(opts);
if (tabTitle && tabTitle[0]) window.tab.title = [NSString stringWithUTF8String:tabTitle];
```
`ZappWindowDelegate` (or the window's `newWindowForTab:`) emits
`window:new-tab-requested` via the toolbar emit pattern.

### Nim (`window.nim`)

Add `tabbingIdentifier*: string` + `tabbingMode*: string` + `tabTitle*: string`
to `WindowOptions`; parse all three in `windowOptsApplyJson` (`jHasStr`); add
`wopts_tabbing_identifier` + `wopts_tabbing_mode` + `wopts_tab_title` cstring
getters. (No iOS-side change.)

## Resolved decisions (user-answered 2026-06-25)

- **OQ1 — tab-bar "+" behavior → (a) emit `NEW_TAB_REQUESTED`.** The app handles
  it and creates the tab (decides URL/duplicate/blank). If unsubscribed, "+" is
  inert. Native-first, maximally flexible.
- **OQ2 — default `tabbingMode` → (a) `preferred`** when `tabbingIdentifier` is
  set (same-id windows always tab; predictable). No identifier → AppKit default
  `automatic`.
- **OQ3 — v1 scope → (a) minimal.** `tabbingIdentifier` + `tabbingMode` +
  `tabTitle` + `NEW_TAB_REQUESTED`; tab select/close reuse FOCUS/CLOSE.
  Programmatic `NSWindowTabGroup` control (select/reorder/overview/move-to-new-
  window) + a distinct `TAB_SELECTED` event are **v2 (deferred)**.
- **OQ4 — `tabTitle` → ADD it in v1** (user override of the "defer"
  recommendation). `tabTitle?: string` overrides the tab label (defaults to the
  window `title`); sets `NSWindow.tab.title` (macOS 10.13+).

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
2. **T2** — TS WindowOptions fields (`tabbingIdentifier`, `tabbingMode`,
   `tabTitle`) + `NEW_TAB_REQUESTED` event + Nim parity (fields/getters/
   windowOptsApplyJson) + native read (incl. `window.tab.title` for `tabTitle`),
   TDD where unit-testable (the wire round-trip in windowmanager_test). macOS +
   iOS-sim build gates.
3. **T3** — kitchen-sink Multi-window "Tabs" demo (open N tabbed windows + a
   `NEW_TAB_REQUESTED` handler that adds tabs) + api-reference docs + full gates
   + human visual smoke.

## Non-goals (v1)

- iOS tabs (UIWindowScene / UITabBar) — future, like all iOS chrome.
- Programmatic tab-group control + overview (unless OQ3 → b).
- Cross-`tabbingIdentifier` merging / drag-between-groups beyond AppKit defaults.
