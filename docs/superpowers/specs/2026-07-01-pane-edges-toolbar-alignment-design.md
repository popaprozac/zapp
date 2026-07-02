# Pane Edges + Native Toolbar Alignment — Design

**Date:** 2026-07-01
**Branch:** `feat/nim-native` @ `a87cef1` (post inspector-column rework + FU-3 controls-parity, both human-smoked PASS; merged same day)
**Status:** Approved design → ready for writing-plans
**Shape:** one cycle, two phases, three human gates (hidden-Primary spike mini-gate → macOS toolbar visual mini-gate → combined final matrix on iPhone + iPad + macOS).

---

## 1. Problem

The pane foundation is stable; what remains are edges and one cross-platform convention gap:

**iOS pane edges (from the FU-3 cycle's gate findings + deferred list):**
1. The inspector's compact-height full sheet ignores the notch-side safe-area inset in landscape (web content flush to the device edge).
2. `setCollapsible(false)` on iOS silently REMOVES the native sidebar reveal button (SDK-documented: `presentsWithGesture=NO` hides the displayModeButton) where macOS shows a *disabled* button — and the human smoke observed pressing Collapsible also *collapsed* the sidebar (unexplained side-effect).
3. No-sidebar windows with an inspector always take the modal-sheet path, even on iOS 26 (no split exists to attach the Inspector column to — `ios/window.m` no-sidebar windows use `ZappIOSRootViewController`).
4. No live `*-resized` events during a divider drag (#720) — only terminal widths ever emit.
5. Tile→overlay presentation switches are unanimated (#721).
6. Kitchen-sink pane-section button state (collapsible/resizable labels) resets on route nav (#666).

**Toolbar convention gap (both platforms; ground truth from exploration of `native/platform/darwin/toolbar.m` + `native/platform/ios/toolbar.m` + `runtime/window.ts`):**
- Placement today is a flat 3-bucket scheme (`leading`/`center`/`trailing`, default `leading`) + array order; system items (`toggleSidebar`, `toggleInspector`, `trackingSeparator`) are ordinary items with **no native-convention anchoring** (`darwin/toolbar.m:463-541`); the convention exists only as an example in `kitchen-sink/src/shell/toolbar-def.ts`. Native macOS apps pin the sidebar toggle at the RIGHT edge of the sidebar region (adjacent to the divider), migrating to leading-main when the sidebar collapses; Zapp leaves it left-aligned in the region.
- iOS has an identified **double sidebar-toggle race** (`ios/toolbar.m:849-859, 925-926`): the include-Zapp's-toggle decision sometimes trusts `willChangeToDisplayMode:`'s *target* state rather than live split state, so UIKit's system reveal button and Zapp's manual toggle can render simultaneously mid-transition.
- **#744** (momentary segmented group collapses to a blank chevron) and **#745** (`type:"label"` looks clickable in the ≫ overflow) share one root cause: `menuFormRepresentation` is never set anywhere in `darwin/toolbar.m` (grep-zero), so AppKit synthesizes overflow rows from label/enabled state — blank for icon-only unlabeled segments, false-affordance for labels.

**Decisions (user-approved):**
- macOS pane behavior is already right — **no overlay emulation**; `presentation: "overlay"` becomes documented-iOS-only (#646 closes as by-design).
- No-sidebar+inspector on iOS 26+ gets the real Inspector column via a **hidden-Primary split**, spike-first.
- Toolbar scope = **placement conventions + #744/#745**; the per-pane placement config DX is a follow-up cycle, protected by centralizing placement resolution now.
- One cycle, two phases, one combined final matrix (human smoke time is the bottleneck).

---

## 2. Design — Phase 1: iOS pane edges

### E1 — Landscape sheet safe-area (discovery-gated)
Instrument first: does `env(safe-area-inset-left/right)` report real values inside the UIKit-auto-presented Inspector sheet (compact-height landscape)? Human reads the values (the pane HTML can print them, as the spike does).
- env() correct → fix is pane-layer CSS (kitchen-sink inspector pane adds env() padding; framework docs note the requirement).
- env() reads 0 → framework fix: propagate insets to the sheet-presented nav (`additionalSafeAreaInsets` or scroll-inset adjustment on the inspector webview), applied in `ios/inspector.m`'s sheet-affordance path.

### E2 — Collapsible affordance parity + side-effect root-cause
Target semantic (macOS parity): `collapsible:false` disables collapse *affordances*, programmatic ops keep working.
- Keep UIKit hiding its displayModeButton (platform idiom; a visible `.always` button would un-gate collapse).
- **Disable Zapp's own toolbar `toggleSidebar` bar-button** (`enabled=NO`, grey) whenever sidebar `collapsible == false`, re-enabled on true — driven from the stored `ZappIOSSidebarController.collapsible` at toolbar-apply time and on `setCollapsible` calls. Mirrors macOS's disabled button.
- Root-cause the observed side-effect (setCollapsible(false) also collapsed the sidebar): suspect `presentsWithGesture=NO` interacting with an overlay-visible sidebar. Diagnose with a temporary instrumented build if code reading is inconclusive; fix or document per the finding.

### E3 — Hidden-Primary split for no-sidebar+inspector (spike-first)
**Spike gate (no framework changes until PASS):** add a no-sidebar variant to `spikes/ios-splitview-reference` — `doubleColumn` with an empty Primary held permanently hidden (`preferredDisplayMode = SecondaryOnly`, `presentsWithGesture = NO`), Inspector column attached on 26+. Human verifies: NO sidebar artifacts (no edge-swipe reveal, no system reveal button, no display-mode flicker on rotation), inspector column works on iPad, auto-sheet on iPhone, Close/grabber affordances intact.
**Port (after PASS):** `ios/window.m`'s no-sidebar+inspector path builds the hidden-Primary split instead of `ZappIOSRootViewController`; `zapp_ios_inspector_register` receives a real split (existing 26+ machinery — emits, affordances, min/max — applies unchanged). `<26` keeps today's modal sheet. The sidebar registry does NOT register (no sidebar exists); toolbar convention items for the sidebar are absent by the existing lacks-pane drop rule (`runtime/window.ts:880-908`).

### E4 — Live resize emits during drag (#720)
`viewDidLayoutSubviews` on the pane container VCs fires per-frame during a seam drag (proven by the FU-3 width probe). Add width-change detection there for BOTH panes: compare against last-emitted width, coalesce per runloop tick, emit `sidebar-resized` / `inspector-resized` through the existing emit helpers (which already dedupe/fan out). Terminal width settles naturally as the last emit. Guard: no emits when the change originates from collapse/expand transitions (width going to/from 0/full) — only regular-width divider geometry.

### E5 — Animate tile→overlay (#721)
Wrap `zapp_ios_apply_presentation`'s displayMode/behavior pair application in a UIKit animation block; verify no conflict with UIKit's own split transitions (if UIKit already animates a given path, do not double-animate — apply-time check or accept UIKit's animation as-is where present).

### E6 — Kitchen-sink pane-button state (#666)
TS-only: the sidebar/inspector sections re-render on route nav and reset their local toggle labels. Persist per-window pane-control state in the shell (module-level map keyed by window id, seeded from the runtime handles' tracked state where available) so re-renders restore it.

---

## 3. Design — Phase 2: native toolbar alignment

### T1 — Convention-ordering pass (the centerpiece; TS, TDD)
One normalization step inside `normalizeToolbar` (`runtime/window.ts:852-1002`) — the **single centralized placement point** (the future per-pane placement config feeds overrides into exactly this step; nothing else reorders):
- Anchor the system items regardless of where the app declared them:
  - Leading edge becomes `[flexibleSpace, toggleSidebar, trackingSeparator(sidebar)]` — the auto-inserted flexibleSpace right-aligns the toggle within the sidebar region; when the sidebar collapses the trackingSeparator collapses with it and the toggle lands leading-main **statically** (native macOS behavior, zero reflow code).
  - Trailing edge ends with `[trackingSeparator(inspector), toggleInspector]`.
- App items keep their declared buckets and relative order untouched; the existing lacks-pane drop rule and duplicate-id validation run unchanged; the injected flexibleSpace must not double-insert if the app already declared one adjacently.
- The `pane` field on tracking separators is preserved through reordering (native reads `def[@"pane"]` from `buttonsById` — `darwin/toolbar.m:239-250`).
- **Documented behavior change**: existing app toolbars with system items in other positions get the native convention imposed (opinionated native-first, pre-1.0). macOS native (`zapp_toolbar_parse_items`) is untouched — it already consumes array order; the darwin dedupe guard (`darwin/toolbar.m:453-455`) protects against duplicate system identifiers (NSToolbar raises on dups).
- iOS consumes the same normalized order through its existing leading/trailing mapping.

### T2 — iOS double-toggle race fix
Single-source the include-Zapp's-toggle decision from **live** split state read at apply time (replace the `willChangeToDisplayMode:`-supplied target-state parameter at `ios/toolbar.m:849-859, 925-926`), triggered from the settled delegate callbacks (post-2b architecture) rather than will-change. Exactly one of {UIKit system reveal button, Zapp toggle item} visible in every settled state; transitions may briefly show either but never both after settle.

### T3 — #744 + #745: menuFormRepresentation
- `type:"label"` items (`darwin/toolbar.m:371-396`): set an explicit `menuFormRepresentation` = disabled `NSMenuItem` with the label text → the ≫ overflow row stops looking clickable.
- Segmented groups (`darwin/toolbar.m:262-302`): set a `menuFormRepresentation` (or guarantee non-empty labels reach the `labels:` array — fall back to segment id when `label` is absent) so icon-only groups never collapse to a blank chevron.
- TS-side `console.warn` in `normalizeToolbar` when an icon-only segment omits `label` (matches the existing docs warning at `docs/api-reference.md:1546`).

---

## 4. Verify-and-close at the final matrix (no build work)

- **FU-2**: route to /detail → back → per-route toolbar (inspector toggle) restored? Confirm-or-close.
- **#718 (A3)**: iPad Split View / Slide Over across the regular↔compact boundary with the inspector open — expected PASS (UIKit owns the column↔sheet adaptation since the rework; emits flow through the didShow/didHide hooks). PASS closes #718.

## 5. Docs (same cycle)

`presentation: "overlay"` = iOS-only (macOS always tiles — #646 closes as by-design); per-platform presentation defaults table (#621); the T1 toolbar convention (including the behavior change and the future config hook); E-items' behavior where app-visible (live resize events, collapsible affordance semantics, no-sidebar inspector column).

## 6. OUT (explicit)

- Per-pane/per-route placement config DX — follow-up cycle; T1's centralized pass is its designed insertion point.
- macOS overlay emulation — dropped (macOS behavior confirmed correct as-is).
- `<26` sheet behavior; macOS pane behavior (darwin/* touched ONLY by T3's menuFormRepresentation additions and consumes T1's order passively).
- Custom sheet detents; scene-lifecycle adoption (#719); iPad-expanded routing parity (#771).

## 7. Constraints (binding)

- Branch `feat/nim-native`; NO worktree, NO `commit --amend`, NO merge without ask.
- macOS must not regress: darwin/* changes limited to T3 (+ passive consumption of T1 ordering); macOS build verified per native task; toolbar placement verified at the macOS visual mini-gate.
- NO iOS-simulator interaction in-session — human runs all smokes; build complete = `[zapp] build complete:` + fresh binary mtime.
- Per-file `git add`; pre-existing unrelated WIP stays unstaged. Always Bun. iOS parity gate stays green.
- Commit trailer exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
  ```
- SDD execution: Fable 5 orchestrator; implementers Sonnet 5 (escalate on block); native-diff reviewers Fable 5; discovery/judgment tasks Fable 5.

## 8. Testing

- **T1**: full TDD in `runtime/window.test.ts` (pure-TS reordering: anchoring, flex-space injection + no-double-insert, app-order preservation, pane-field preservation, dedupe interplay, lacks-pane drops).
- **T3 TS warn**: unit test alongside.
- **Native items (E2/E4/E5/T2/T3-native)**: iOS-sim + macOS build gates + parity per task; behavior at human gates.
- **E1/E2-side-effect**: instrumented discovery builds, human-read (FU-1 pattern).
- **E3**: spike gate before port; port then covered by the final matrix.
- **Gates**: (G1) E3 spike mini-gate; (G2) macOS toolbar visual mini-gate after T1 (placement + collapse migration + #744/#745 overflow); (G3) combined final matrix (iPhone + iPad + macOS: all Phase-1 behaviors, toolbar conventions on both platforms, FU-2 + #718 verify-and-close, full pane-controls regression).

## 9. Open questions

None blocking. E1's fix layer and E2's side-effect fix are intentionally discovery-gated; E5 defers to UIKit's own animation where one exists.
