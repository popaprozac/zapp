# iOS / iPadOS Program — Target & Current-State Matrix

**Status:** brainstorm grounding artifact (living doc — annotated with current-state observations before SP-1 design)
**Branch:** `feat/nim-native` (UNMERGED)
**Scope chosen:** Tiers **A + B + C** (correctness + iOS chrome + iPad multi-window). Tier D (device signing + App Store/.ipa packaging) DEFERRED.
**Proving ground:** kitchen-sink (no packaging this program). Verification = build gates + device/sim human smoke. iPad is first-class.

## Program decomposition (dependency order)

- **SP-1 — iOS Correctness Pass (Tier A)** — foundation, mergeable, de-risks the rest. Risk gate = inspector size-class rotation (bridge-preserving re-parent).
- **SP-2 — `Sync.wait/notify` iOS port** (small parity port; may fold into SP-1).
- **SP-3 — iOS context menu + popover (Tier B transient UI).**
- **SP-4 — iOS toolbar (Tier B — UINavigationBar)** — ties to placement-model (#643). Risk-gated.
- **SP-5 — iPad UIKeyCommand shortcuts (Tier B).**
- **SP-6 — iPadOS multi-window / UIWindowScene (Tier C)** — architectural. Risk gate. Last.

Today markers: ✅ works · ⚠️ bug/partial · 🟥 stub · ➖ intentionally N/A.

---

## §1 — Windowing & scenes

| Feature | iPhone (iOS) target | iPad (iPadOS) target | SP · today | Current observed |
|---|---|---|---|---|
| App launch / primary window | One full-screen scene, content under safe areas | One scene; Stage-Manager / Split-View aware | core · ✅ | iPhone: lands on sidebar/master list full-screen ✅; title hugs status bar slightly. iPad: lands with sidebar as a floating OVERLAY over Home (NOT side-by-side tile); edge-drag-resizable; status bar/date OK. ✅/⚠️ |
| `Window.create` (multi-window) | No 2nd OS window — open as sheet or honest warn | New `UIWindowScene` (real 2nd window) | SP-6 · 🟥 | iPhone: no-op (nothing happens). iPad: no-op (expected; SP-6 adds UIWindowScene). 🟥 |
| Modal sheet (`asSheetOf`) | UIViewController sheet, detents + grabber | Same; centered/form sheet on regular | core · ✅ | iPhone: grabber+detents+dim work ✅ BUT shows full KS shell (faux top bar + Home), not the focused `#sheet=` page → POLISH (SP-1). iPad: form sheet=centered card ✅, page sheet=full-height, bottom sheet ✅; content still full shell (same polish). |
| resize / min / max / zoom / fullscreen / always-on-top | OS-managed (no API) | OS-managed | ➖ | n/a |

## §2 — Sidebar

| Feature | iPhone target | iPad target | SP · today | Current observed |
|---|---|---|---|---|
| Sidebar presentation | Collapsed master-detail; back/swipe returns; hide "collapsible" (no meaning compact) | **DECIDE:** default `.tile` (side-by-side, macOS-like) in regular; `.overlay`/`.automatic` configurable; overlay must dim+tap-dismiss; show/hide in native toolbar | core · ✅/⚠️ | iPhone: lands on sidebar; tap→push detail; ☰/swipe→back ✅ (Apple-correct). iPad: ALWAYS overlay, no dim, no tap-dismiss, only collapses on nav; inspector tiles while sidebar overlays (asymmetric). → SP-1 decision |
| `setWidth` + min/max | N/A (full-width overlay) | Honored within OS clamp | SP-1 · ⚠️ (min/max not enforced) | iPhone: full-width (N/A). iPad: Width 180/320 buttons **WORK initially** ✅, but **after a user edge-drag-resize they stop working** (the manual drag pins the width; setWidth ignored) 🟥 |
| `setCollapsible` / `setResizable` | Collapsible N/A in compact — hide control | Collapsible respected; resizable best-effort | SP-1 · 🟥 (no-ops) | iPhone: collapsible:off still allows back-nav (correct; control meaningless). iPad: collapsible + resizable toggles have NO effect 🟥 |
| Sidebar events reach all panes | Yes | Yes | SP-1 · ⚠️ (#627/#713 misses inspector) | iPhone: can't validate (sidebar↔detail are full-screen; inspector not co-visible). iPad: **dragging sidebar width fires NO events — inspector stays "Live…" placeholder (Image #5)** → #713 confirmed 🟥 |

## §3 — Inspector

| Feature | iPhone target | iPad target | SP · today | Current observed |
|---|---|---|---|---|
| Inspector presentation | Summoned **sheet** (medium/large detents) | Trailing **pane**, animatable width | core · ✅ | iPhone: sheet w/ detents+grabber ✅ (Img6). iPad: trailing pane, toggle animates ✅ (Img8); NOT touch-drag-resizable (UISplitVC has no user-resizable column) |
| Size-class transition | iPhone landscape: keep sheet **dismissable** (Apple drops `.medium` at compact height → full-height; we lose dismiss) | Plain rotation FINE (iPad regular both ways). **RISK = iPad multitasking compact flip** → pane↔sheet without killing bridge | SP-1 · ⚠️ **RISK GATE** (only on width size-class flip, not rotation) | iPhone: rotate→landscape sheet goes FULLSCREEN + **can't dismiss** 🟥 (rotate back restores) (Img7). iPad: pane survives rotation, no issue ✅. iPad multitasking compact: UNTESTED (the real risk) |
| `setWidth` / collapsible / resizable | Sheet detents | Pane width animate (button); collapsible = programmatic toggle | SP-1 · ⚠️/🟥 | iPhone: detents work ✅. iPad: **Width 360 button works + animates** ✅; collapsible/resizable no-op 🟥; no touch-drag so resizable gating untestable |
| Inspector events reach all panes | Yes | Yes | SP-1 · ⚠️ (#627/#713 misses sidebar) | iPad: Inspector-section inspector UPDATES on width/collapse ✅ (INSPECTOR_* reaches inspector pane); **Sidebar-section inspector does NOT update on sidebar change** 🟥 (#713, Img9). iPhone: can't validate (sheet covers) |

## §4 — Toolbar & transient UI

| Feature | iPhone target | iPad target | SP · today | Current observed |
|---|---|---|---|---|
| Toolbar (NSToolbar→`UINavigationBar`) | Nav bar with items; safe-area aware | Nav bar; more room; hosts sidebar show/hide | SP-4 · 🟥 | Both: native nav bar = stub; today the ☰/⊟ "toolbar" is the **web faux top bar** (main-pane.ts). SP-4 DECISION: native UINavigationBar vs keep+polish faux bar (Img10/12/13) |
| Context menu | Long-press → native `UIContextMenuInteraction`/`UIEditMenuInteraction` (web `contextmenu` event NOT delivered on iOS) | Long-press + trackpad secondary-click (both via UIContextMenuInteraction) | SP-3 · 🟥 | Both: long-press selects text in the target; trackpad right-click shows nothing. Web contextmenu event isn't fired on iOS → needs native interaction (SP-3) |
| Popover | Auto-adapts to a sheet (UIKit compact rule) | Real anchored `UIPopover` | SP-3 · 🟥 | Both: popover buttons no-op, nothing shown (stub confirmed) |
| Drag region (window move) | N/A | N/A | ➖ | n/a |

## §5 — Input & lifecycle

| Feature | iPhone target | iPad target | SP · today | Current observed |
|---|---|---|---|---|
| In-app key commands (`UIKeyCommand`) | Works if HW keyboard attached | First-class (HW keyboard common) | SP-5 · 🟥 | Both: not implemented → nothing to press/confirm (UIKeyCommand = app-level ⌘-shortcuts; distinct from global hotkeys) |
| Global hotkeys / tray / menu bar / dock bounce | N/A | N/A | ➖ | Both: global hotkeys fail to register (correct, N/A); tray/menubar/dock N/A |
| App event: THEME_CHANGED | Fires | Fires | SP-1 · 🟥 | Both: **no observable surface** in demo + not dispatched on iOS → can't validate |
| App events: lock/unlock, reopen | Fire (UIKit equivalents) | Fire | SP-1 · 🟥 | Both: no surface + not dispatched on iOS → can't validate |
| App events: sleep/wake, before-quit | N/A (background model, no "quit") | N/A | ➖ | n/a (confirmed) |
| Power / battery events | Fire | Fire | core · ✅/⚠️ | Both: audit says dispatched on iOS, but **no surface** in demo → can't see/confirm |
| External-display connect (SCREENS_CHANGED) | Rare | Fires (more relevant) | SP-1/➖ · ⚠️ | Both: Screen section reports single built-in display ✅; external connect untested (no surface) |

## §6 — Web layer & services

| Feature | iPhone target | iPad target | SP · today | Current observed |
|---|---|---|---|---|
| Safe-area: `viewport-fit` + `--zapp-safe-area-*` | Injected; notch + home-indicator | Injected; rounded corners | SP-1 · ⚠️ (template + iOS injection missing) | kitchen-sink index.html has viewport-fit ✅ (under-notch correct, §1); new-app templates lack it (#577); iOS doesn't inject `--zapp-safe-area-*` (SP-1) |
| `inspectable` (Safari Web Inspector) | Honors config (iOS 16.4+) | Honors config | SP-1 · ⚠️ (hardcoded true) | Both: Safari Web Inspector attaches ✅ (devtools work) — but hardcoded true, so config can't DISABLE it (SP-1 = honor config) |
| Embedded webview z-order | Document limitation (paints above page) | Same | ➖/later · ⚠️ | **No kitchen-sink demo surface for `<zapp-webview>`** → add one (benefits macOS too) — demo gap |
| Workers (zjs) | Native | Native | core · ✅ | Both: send/ping, invoke, Workers.list all work ✅ |
| Notifications / clipboard / dialogs / fs / panel | Work | Work | core · ✅ / ⚠️ | Both: clipboard (incl has/read image) ✅; notifications (incl update/remove) ✅. **Dialogs BROKEN:** open/save return "cancelled", message returns "button:0", no native UI presented (sync-stub path; async UIDocumentPicker/UIAlertController not routed) 🟥; reveal/open-last N/A |
| `Sync.wait/notify` | Works (port) | Works | SP-2 · 🟥 | Both: no-op; UI stuck on waiting/timeout (stub confirmed) |
| Parity lint covers `native/nim/**` importc | — | — | SP-1 · ⚠️ (#637) | build-only (not user-observable) |

---

## Current-state grounding (filled from user screenshots/observations, §1→§6)

### §1 Windowing — iPhone (2026-06-26)
- **Launch:** opens to the sidebar/master list full-screen (correct land-on-sidebar). Safe-area top OK; "KITCHEN SINK" title sits close to the status bar.
- **Window.create (non-sheet):** no-op (nothing happens) — matches SP-6 target of "no 2nd OS window," but should at least honestly warn or present-as-sheet rather than silently nothing.
- **Modal sheet:** UIViewController sheet presents correctly — grabber, detents, dimmed backdrop. **Finding:** the sheet renders the FULL kitchen-sink shell (its own ☰/⊟ faux top bar + Home content), NOT the focused `#sheet=settings/quickadd/drawer` page that macOS now shows. The per-window `url` isn't reaching the iOS modal webview (or the modal re-hosts the main content). → POLISH item folded into SP-1 (iOS sheet should honor the focused `url`, parity with macOS).
- **resize/min/max/etc:** no-op (expected, N/A).
### §1 Windowing — iPad (2026-06-26)
- **Launch:** sidebar presents as a floating OVERLAY panel over Home (NOT a side-by-side tile). Edge-drag resizes it; tapping the main content does NOT dismiss it (no tap-outside-to-dismiss). User wants the toggle/dismiss driven by a toolbar sidebar button (→ SP-4 toolbar). **OPEN DESIGN Q: should iPad default to side-by-side tile vs overlay?** (covered in §2). Minor: small curl artifact bottom-right corner (likely sim affordance).
- **Window.create (non-sheet):** no-op (expected).
- **Modal sheets:** form sheet = centered card ✅; "page" sheet = full-height sheet; bottom sheet works ✅. Content still the full KS shell (same focus polish as iPhone).
- **resize/etc:** no-op (expected).

**§1 STATUS: COMPLETE (iPhone + iPad).** Carry-forward items: (a) iOS sheet content should honor focused `url` (`#sheet=`) like macOS — SP-1 polish; (b) iPad sidebar overlay-vs-tile default + tap/toolbar dismiss — §2/SP-4 design Q; (c) Window.create non-sheet should warn/sheet rather than silent no-op.

**Process note:** going forward, user sends BOTH iPhone + iPad observations per section in one message.

### §2 Sidebar — iPhone + iPad (2026-06-26)
**iPhone:** lands on sidebar (master); tap a row → push detail; ☰ in faux top bar OR left-edge swipe → back to sidebar. Apple-correct compact master-detail. `setWidth` full-width (N/A). "Collapsible: off" still allows back-nav — correct (collapsible has no meaning in compact; **hide the control on iPhone**). Sidebar events: can't validate (sidebar/detail are full-screen, inspector not co-visible on compact).

**iPad:** sidebar is ALWAYS an overlay (floating panel), no dim, no tap-outside-to-dismiss, **only collapses on navigation** — diverges from Apple (which dims + tap-dismisses overlay, and tiles in landscape). The inspector renders as a TILE on the right WHILE the sidebar overlays (asymmetric). `setWidth` (180/320 buttons) **works initially**, but **fails after a user edge-drag-resize** (manual drag pins the column; subsequent `setWidth` ignored — SP-1 must re-assert `preferredPrimaryColumnWidth` + force layout / clear the user-dragged state). `setCollapsible`/`setResizable` toggles have no effect. **#713 confirmed:** with sidebar overlay + inspector both open, dragging the sidebar fires no events — inspector stays on the "Live — collapse, expand, or drag…" placeholder (Image #5).

**OPEN DESIGN DECISION (resolve in SP-1):** iPad sidebar presentation. Proposed: default `.tile`/`oneBesideSecondary` in regular width (macOS-like, both columns visible); `.overlay`/`.automatic` configurable via `sidebarPresentation`; overlay must dim + tap-to-dismiss; expose the OS show/hide affordance via the native toolbar (SP-4, `sidebar.left`). On compact: keep master-detail, hide the collapsible control. Also research orientation behavior (landscape tile / portrait overlay). Related follow-ups: #621 (cross-platform sidebar presentation defaults), #646 (macOS overlay parity).

**Apple reference (for the design):** UISplitViewController — compact = single nav stack (sidebar=root, push detail, back/swipe pops); regular = `preferredSplitBehavior`(tile/overlay/displace/automatic) × `preferredDisplayMode`, auto by orientation; canonical Show/Hide Sidebar button (`sidebar.left`) lives in the nav bar.

### §3 Inspector — iPhone + iPad (2026-06-26)
**iPhone:** inspector = summoned **sheet** w/ medium/large detents + grabber ✅ (Img6). **Bug (SP-1):** rotate→landscape, the sheet goes **full-height AND loses dismiss** (no grabber/swipe-down) — user stuck; rotate back→restored (Img7). Note: full-height in landscape is Apple-correct (`.medium` unavailable at compact height), but losing dismiss is ours — keep it dismissable (grabber + swipe or close affordance). Events: can't validate on compact (sheet covers; section not co-visible).

**iPad:** inspector = trailing **pane**, toggle animates open/closed ✅ (Img8). **NOT touch-drag-resizable** (UISplitVC inspector column isn't user-resizable — only programmatic; design choice: accept, or add a custom drag handle). `setWidth` (Width 360 button) works + animates ✅. `setCollapsible`/`setResizable` no-op 🟥 (and with no drag-resize, resizable gating is untestable). **Events:** Inspector-section inspector UPDATES on width/collapse ✅ (INSPECTOR_* reaches the inspector pane); **Sidebar-section inspector does NOT update** on sidebar change 🟥 — #713 confirmed (Img9), exact mirror of the macOS #627 bug.

**RISK-GATE refinement (important):** plain rotation does NOT trigger the pane↔sheet bridge-kill hazard — iPad is regular-width in both orientations (pane persists), iPhone is compact both ways (stays sheet). The hazard only fires on a true **horizontal size-class flip** (compact↔regular) = **iPad multitasking** (Slide Over / narrow split). So SP-1's risk-gate test is specifically iPad Slide Over, not rotation. This de-risks SP-1 for the common case; the multitasking transition (whether to adapt pane→sheet, or just hide the inspector below a width threshold) is the real SP-1 decision.

**§1–§3 carry-forwards into SP-1 so far:** (a) iOS sheets honor focused `#sheet=` url; (b) iPad sidebar default `.tile` + dim/tap-dismiss overlay + native toolbar show/hide; (c) sidebar `setWidth` (re-assert after manual drag) / collapsible / resizable no-ops; (d) #713 sidebar→inspector fan-out; (e) iPhone landscape inspector-sheet dismiss; (f) iPad multitasking inspector size-class transition (RISK GATE — decide adapt-vs-hide); (g) hide collapsible control on compact; (h) Window.create non-sheet warn/sheet not silent.

### §4 Toolbar & transient UI — iPhone + iPad (2026-06-26)
- **Toolbar:** native UINavigationBar = stub on both. Today's ☰/⊟ "toolbar" is the **web faux top bar** (main-pane.ts `iosTopBar`) — it hosts sidebar+inspector toggles (Img10 iPad, Img13 iPhone). **SP-4 DECISION:** native `UINavigationBar` vs keep+polish the web faux bar; either way it must host the iPad sidebar show/hide affordance (from §2). Placement-model #643.
- **Context menu:** both — long-press selects text in the button/target; trackpad secondary-click shows nothing. **Platform reality:** iOS WKWebView does NOT fire the JS `contextmenu` event (desktop-only); long-press → text selection / callout / link preview. So a web-driven context menu can't work on iOS — SP-3 must register native `UIContextMenuInteraction` on the webview (handles long-press AND iPad trackpad secondary-click); trigger = long-press, not right-click.
- **Popover:** both no-op, nothing shown (stub confirmed). SP-3 = `UIPopoverPresentationController` (auto-adapts to sheet on compact).
- **Drag region:** N/A both (no window drag on iOS; multi-window via OS-managed scenes — SP-6).
- **Polish (safe-area, sidebar pane):** iPad sidebar overlay has a GAP at the top above "KITCHEN SINK" (Img11); iPhone sidebar header HUGS the status bar (§1). Inconsistent top safe-area padding in the sidebar pane → SP-1 safe-area work.
- **Confirmed good:** iPhone launch sits correctly under the notch/Dynamic Island (Img12); iPad detail shows the faux top bar (Img10).

### §5 Input & lifecycle — iPhone + iPad (2026-06-26)
- **In-app key commands (UIKeyCommand):** not implemented (SP-5) — nothing to confirm. Distinct from global hotkeys; these are app-level ⌘-shortcuts (HW keyboard). Global hotkeys (system-wide) are N/A on iOS.
- **Global hotkeys:** fail to register (correct — N/A on iOS). Tray / menu bar / dock bounce N/A (confirmed).
- **App events (THEME_CHANGED, lock/unlock, reopen):** **NO OBSERVABLE SURFACE in the demo** + per audit not dispatched on iOS → can't validate. **KEY SP-1 FINDING:** SP-1 must pair (a) native iOS app-event dispatch with (b) a demo surface (extend Window-log, or add an "App events" log) so they're verifiable — otherwise the human smoke can't confirm them.
- **Power/battery:** audit says dispatched on iOS (platform.m), but again **no surface** → user can't see/confirm. Same demo-surface need.
- **sleep/wake, before-quit:** N/A (confirmed).
- **Screen:** reports the single built-in display ✅ (correct on iOS); external-display connect (SCREENS_CHANGED) untested + no surface.

**§4–§5 carry-forwards:** (i) SP-4 toolbar (native UINavigationBar vs polish faux bar; host iPad sidebar show/hide); (j) SP-3 native context menu (long-press, `UIContextMenuInteraction`) + popover; (k) SP-1 safe-area sidebar-pane padding (iPad top-gap / iPhone status-bar-hug); (l) SP-1 app-event dispatch + a DEMO SURFACE to observe theme/power/lock events (blocker for validating SP-1 app-events); (m) SP-5 UIKeyCommand.

### §6 Web layer & services — iPhone + iPad (2026-06-26)
- **Workers (zjs):** send/ping, invoke, Workers.list all work ✅.
- **Clipboard:** all work incl. has-image + read-image ✅.
- **Notifications:** all work incl. update/remove ✅.
- **Dialogs — BROKEN on iOS (new finding, not in static audit):** open/save file return "cancelled", message returns "button:0", NO native UI presented. The async UIDocumentPicker/UIAlertController paths exist natively but aren't routed/invoked (sync-stub path taken). reveal/open-last N/A (no Finder). → SP-1 (route iOS Dialog calls to the async path).
- **Sync.wait/notify:** no-op; UI stuck on waiting/timeout (stub) → SP-2.
- **File Drop — REGRESSION (new finding):** can grab a photo but drop on the page yields no result; **worked in an early zc version**. → SP-1 investigate (systematic-debugging; see [[reference_ios_wkwebview_drop]] — UIResponder pasteItemProviders swizzle + drop-interaction).
- **Embedded webview:** no kitchen-sink demo surface for `<zapp-webview>` → add a section (benefits macOS testing too) — demo gap.
- **inspectable / DevTools:** Safari Web Inspector attaches ✅ (works because hardcoded true); SP-1 fix = honor config so it can be DISABLED.
- **Safe-area:** kitchen-sink index.html viewport-fit ✅ (under-notch correct); new-app templates lack it (#577); iOS doesn't inject `--zapp-safe-area-*` (SP-1).

---

## GROUNDING COMPLETE (§1–§6, 2026-06-26) — consolidated correctness (Tier A) scope

The correctness tier (originally "SP-1") is larger than one spec — re-decompose into ordered sub-cycles:

- **A1 — low-risk correctness batch (small, mergeable first):** #713 iOS pane-event fan-out (sidebar↔inspector, mirror the macOS fix); `inspectable` honors config (window.m:661); `viewport-fit=cover` in `zapp init` templates (#577); inject `--zapp-safe-area-*` on iOS (macOS parity) + fix sidebar-pane top safe-area (iPad gap / iPhone hug); parity-lint `native/nim/**` importc (#637).
- **A2 — sidebar/inspector behavior:** sidebar `setWidth` re-assert after manual drag; `setCollapsible`/`setResizable` real effect (or honest hide on compact); **iPad sidebar presentation decision** (default `.tile` macOS-like vs overlay; dim + tap-dismiss; relates #621/#646) — coordinate with SP-4 toolbar show/hide button; iPhone landscape inspector-sheet keep-dismissable.
- **A3 — RISK GATE: iPad multitasking inspector size-class transition** (pane↔sheet without killing the bridge; decide adapt-vs-hide-below-threshold) — the one hard item; isolate it.
- **A4 — services bugs:** Dialogs route to async (BROKEN); File-drop regression (systematic-debugging); iOS sheet honor focused `#sheet=` url.
- **A5 — app events + demo surface:** dispatch THEME_CHANGED + lock/unlock/reopen on iOS; add a kitchen-sink "App events" / power log surface so they're verifiable (also add `<zapp-webview>` demo surface).
- **Then B (chrome: SP-3 context-menu+popover, SP-4 toolbar, SP-5 UIKeyCommand) → C (SP-6 multi-window).**

**NEXT:** brainstorm/design **A1** first (small, low-risk, mergeable, de-risks the rest). Open decisions deferred to their sub-cycle: iPad sidebar tile-vs-overlay (A2), inspector multitasking adapt-vs-hide (A3), native-toolbar-vs-faux-bar (SP-4).
