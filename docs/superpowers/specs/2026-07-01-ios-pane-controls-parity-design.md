# iOS Pane Controls Parity (FU-3 + FU-1) — Design

**Date:** 2026-07-01
**Branch:** `feat/ios-native-nav` (UNMERGED), base `ac470e0`
**Status:** Approved design → ready for writing-plans
**Foundation:** the native Inspector-column model (commits `2c716a7`..`ac470e0`) — `doubleColumn` split (Primary=sidebar, Secondary=content) + `UISplitViewControllerColumnInspector` (iOS 26+), modal-sheet fallback below 26. Human-smoked STRONG PASS on iPhone + iPad (iOS 26.5).

---

## 1. Problem

The rework replaced the iOS inspector's *presentation* machinery but left its *control surface* behind. A control-surface audit (runtime → router → Nim → native, both panes, both platforms) found the plumbing complete and symmetric everywhere **except the iOS inspector**:

1. **Create-time fields silently dropped (iOS only).** `native/platform/ios/window.m:1002-1011` reads only `url`/`numericId`/`width`/`collapsed` from `InspectorOptions`; `minWidth`, `maxWidth`, `collapsible`, `resizable`, `backgroundColor`, `material` are never read and never reach `zapp_ios_inspector_register` (`native/platform/ios/inspector.m:188-190`, which takes only `(width, collapsed)`). `backgroundColor`/`material` are a visible styling regression; the sidebar path reads its full option set (`window.m:967-995`).
2. **Runtime setters are silent no-ops (iOS only).** `darwin_inspector_set_resizable` (`ios/inspector.m:400-402`) and `darwin_inspector_set_collapsible` (`ios/inspector.m:393-395`) are documented no-ops — but the documentation was written for the OLD (pushed-VC/sheet) model. On the new Inspector column the user CAN drag-resize (smoke-confirmed), so at minimum `setResizable(false)` is now meaningful (lock the width) and the no-op rationale is stale. `darwin_inspector_set_width` works on 26+ (`preferredInspectorColumnWidth`, `ios/inspector.m:374-388`).
3. **The demo lies.** Kitchen-sink exposes Collapsible/Resizable toggle buttons for the inspector (`kitchen-sink/src/sections/inspector.ts:15-20`) whose labels flip with zero native effect on iOS and **no warning anywhere**.
4. **FU-1: iPad content bleeds under the inspector.** Smoke observed the content text CUT OFF (not reflowed) at the inspector divider. The reference spike explicitly displaces ("the content canvas stays visible, it is not replaced" — `spikes/ios-splitview-reference/INSPECTOR_COLUMN_SPIKE.md:75-81`), and Zapp's content webview is edge-pinned to `contentVC.view` (the Secondary column's own container, which UIKit should shrink) via `zapp_ios_sidebar_set_content_webview` (`ios/sidebar.m:709-748`). Zapp bleeding where the spike displaces is a **discrepancy to root-cause**, not expected behavior. A stale comment (`ios/sidebar.m:734-735`) claims inspector.m "will later replace" the trailing constraint — no such code exists.

Everything else is healthy: sidebar controls are wired on both platforms (with iOS-specific ownership semantics for width/resizable, `ios/sidebar.m:935-1049`); the macOS inspector is fully wired (`darwin/inspector.m:111-192`); reverse events are symmetric across platforms (six event names, both `.m` implementations).

**Decisions (user-approved):**
- **Ambition: full parity + honesty.** Wire every iOS inspector control the new column allows; restore all dropped create-time fields; fix FU-1. Anything UIKit genuinely cannot do emits a one-time dev-build warning — never a silent no-op.
- **Scope: core + free cleanups.** Include the trivially-adjacent nits in the same files (missing `INSPECTOR_RESIZED` typed `on()` overload; stale comments). Defer the no-sidebar+inspector edge case.

---

## 2. Design

### 2.1 Phase 0 — Discovery gate (resolve the two unknowns first)

Nothing is wired until this gate produces two artifacts:

**(a) The wireable-vs-warn map.** Read the iOS 26 SDK header (`$(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/UIKit.framework/Headers/UISplitViewController.h`) and enumerate every Inspector-column-relevant knob: `preferredInspectorColumnWidth` (known), any `minimumInspectorColumnWidth`/`maximumInspectorColumnWidth`, anything gating divider-drag or user-collapse for that column, and any relevant delegate callbacks. For each of `minWidth`/`maxWidth`/`resizable`/`collapsible`, classify: **WIREABLE directly** (a dedicated property exists), **WIREABLE via ownership pattern** (no direct knob, but achievable the way the sidebar does it — e.g. `resizable:false` = pin min==max==width, `ios/sidebar.m:994-1030`), or **WARN** (genuinely unachievable). The map is recorded in the plan and drives Phases 1–2 verbatim.

**(b) The FU-1 root cause + fix.** Instrument (temporary `[zapp-nav]` logs) the Secondary column view's frame AND the content webview's frame on iPad while showing/hiding the inspector. Human smoke reads the numbers. Two hypotheses to discriminate:
- The Secondary column view itself is NOT shrinking (UIKit-level: the split needs a behavior/width hint) → fix at the split level;
- The column shrinks but the webview does not follow (Zapp-level: `zapp_ios_sidebar_set_content_webview`'s constraints not installed or not active on inspector windows in practice — the `16c0d49` fix made the call unconditional, but the smoke that observed the bleed PREDATES verification of that path under a visible inspector) → fix the constraint install.
Whichever it is, the fix lands in this phase with a before/after smoke, and the stale `sidebar.m:734-735` comment is corrected to describe the actual mechanism.

### 2.2 Phase 1 — Create-time parity

Thread all six dropped fields through the iOS path:
- `ios/window.m` deferred-populate block reads `wopts_inspector_min_width`/`max_width`/`can_collapse`/`can_resize`/`background_color`/`material` (accessors already exist, `native/nim/window.nim:294-304`) into `ZappIOSDeferred` fields, mirroring the sidebar block (`window.m:967-995`).
- `zapp_ios_inspector_register` signature widens to carry them (single call site in window.m — change decl + call + definition in lockstep, the established pattern).
- Application at register: `backgroundColor`/`material` styles the inspector VC's backdrop exactly as the sidebar pane does its own; `minWidth`/`maxWidth`/`resizable`/`collapsible` apply per the Phase-0 map (26+ column only; the <26 sheet ignores them via the warn helper).

### 2.3 Phase 2 — Runtime setters + the honesty mechanism

- `darwin_inspector_set_resizable` / `set_collapsible`: replace the no-ops with real implementations per the Phase-0 map. Expected shape (subject to the map): `setResizable(false)` pins the column width (ownership pattern), `setResizable(true)` restores min/max; `setCollapsible` gates whatever user-collapse affordance the column has, or WARNs if none exists. Programmatic ops (`expand`/`collapse`/`toggle`) always keep working regardless of `collapsible`, matching the sidebar's documented semantics (`ios/sidebar.m:981-988`).
- `darwin_inspector_set_width` below iOS 26 / no-split: routes through the warn helper instead of silently emitting a width the pane never adopted.
- **The honesty helper:** `zapp_ios_control_unsupported(const char* control, const char* reason)` in a shared iOS source — `NSLog`s `[zapp] <control> is not supported on iOS: <reason>` ONCE per control per process (static set guard; once-only makes it cheap enough to keep in all build flavors — no release gating), and the caller still emits the parity event so JS-side `collapsed`/`width` getters stay coherent. No new bridge surface or TS API.
- **Free cleanups (ride along):** add the `WindowEvent.INSPECTOR_RESIZED` typed `on()` overload next to `SIDEBAR_RESIZED` (`runtime/window.ts:1186`, payload `InspectorResizedPayload` already exists in `runtime/events.ts:182-186`); fix the stale `"sidebar accessors — unused feature"` / `"inspector accessors — unused feature"` comments (`native/nim/window.nim:281,294`); the `sidebar.m:734-735` stale comment is fixed in Phase 0(b).

### 2.4 Phase 3 — Matrix gate (human smoke)

Kitchen-sink already exposes the needed buttons (sidebar: toggle/width/collapsible/resizable/presentation, `sections/sidebar.ts:17-26`; inspector: toggle/width/collapsible/resizable, `sections/inspector.ts:15-20`). The gate exercises the full matrix on **iPhone + iPad**: every control on both panes, live-state readouts (the `*-collapsed/-expanded/-resized` events) verified against what actually renders, FU-1 confirmed fixed (content reflows when the inspector shows), and no console warnings except where the map says WARN. Plus a **macOS regression pass** (controls were already working there — must stay working; `native/platform/darwin/*` untouched by this cycle).

---

## 3. What stays OUT (explicit)

- **No-sidebar + inspector on iOS** (currently always the modal-sheet path even on 26+, `ios/window.m:688-692`) — deferred, tracked as its own follow-up.
- **The <26 modal-sheet fallback's behavior** — unchanged; width/resizable/collapsible are inherently n/a for a system sheet and route through the warn helper.
- **FU-2** (per-route toolbar not restored on route-back) — parked pending the user's sim re-check; different subsystem (toolbar/route path).
- **macOS** — no functional changes; regression-verified only.
- **Sidebar behavior changes** — the sidebar's iOS ownership semantics (drag-pin supersedes `setWidth` while resizable, documented at `ios/sidebar.m:935-973`) are kept as-is.

---

## 4. Constraints (binding)

- Branch `feat/ios-native-nav`; NO worktree, NO `commit --amend`, NO merge.
- **macOS MUST NOT regress** — `native/platform/darwin/*` untouched; macOS build verified at every native task.
- **NO iOS-simulator interaction in-session** — the human runs every smoke; a build is complete only on `[zapp] build complete:` + fresh binary mtime.
- Per-file `git add` only; pre-existing unrelated WIP stays unstaged.
- Commit trailer exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
  ```
- Always Bun, never Node. iOS symbol-parity gate (`bun test cli/src/ios-platform-parity.test.ts`) stays green.
- Native-first ordering per feature: ObjC primitive → Nim → router → TS runtime → docs in the same phase (here mostly ObjC + TS typing; the Nim/router surface already exists).

---

## 5. Testing

- **Phase 0:** instrumented human smoke (frame numbers in `[zapp-nav]` logs) + SDK-header citations recorded in the plan.
- **Native tasks:** iOS-sim + macOS build gates + parity test per task (no new Nim parse logic expected — accessors exist; if any parse IS added, it gets the standard `windowmanager_test.nim` TDD blocks).
- **TS:** the typed-overload addition gets a compile-level assertion in `runtime/window.test.ts` (mirroring the existing typed-event test pattern) + `bun run check`.
- **Phase 3:** the full-matrix human smoke on iPhone + iPad + macOS regression pass — the cycle's acceptance gate.

---

## 6. Open questions

None blocking. The wireable-vs-warn classification for `minWidth`/`maxWidth`/`collapsible` is intentionally deferred to Phase 0's SDK read — the design commits to the *procedure* (wire if possible, warn if not), not a guess about UIKit's surface.
