# #627 — Window Pane Events Fan-Out Fix — Design

**Status:** approved (brainstorm), pending plan
**Branch:** `feat/nim-native` (UNMERGED)
**Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
**Staging:** explicit per-file `git add` only (never `-A`/`.`). Bun, never Node.
**Scope:** macOS framework fix (`native/platform/darwin/`) + kitchen-sink demo revert + a Nim doc comment. iOS parity is a tracked follow-up, NOT this cycle.

## Problem

A native-chrome window has three webview panes (main/content, sidebar, inspector). Window **pane** chrome events do not reach all panes:

- Sidebar/inspector chrome events go through `zapp_pane_emit` (`native/platform/darwin/sidebar.m:72`), which evals the dispatch JS on only **two** targets: `host_id` (main pane) and the single `accessory_slot` passed in (the one accessory pane for that event family).
- So `SIDEBAR_COLLAPSED/EXPANDED/RESIZED` (ids 12–14) reach `{main, sidebar}` only — never the inspector pane; `INSPECTOR_COLLAPSED/EXPANDED/RESIZED` (ids 17–19) reach `{main, inspector}` only — never the sidebar pane.

**Consequence:** `Window.current().on(WindowEvent.SIDEBAR_*)` registered from inside the *inspector* pane's webview silently never fires (the subscription is real; the event just isn't delivered there). This bit the kitchen-sink Sidebar-section inspector, which currently uses a demo-only Events-bus relay workaround (commit `0ca57ff`).

The general window-event path `zapp_dispatch_event_to_js` (`window.m:270-293`) already fans out correctly to both sidebar + inspector slots via `zapp_sidebar_slot_for` / `zapp_inspector_slot_for`. `zapp_pane_emit` simply never got the same treatment. This is tracked as bug **#627**.

## Background (verified)

- `zapp_pane_emit(int32_t host_id, int32_t accessory_slot, const char* eventName, NSString* dataJson)` lives in `darwin/sidebar.m`; `inspector.m`'s `zapp_inspector_emit` calls it via an `extern`. The only callers are `zapp_sidebar_emit` (sidebar.m, passing `sidebarSlotId`) and `zapp_inspector_emit` (inspector.m, passing `inspectorSlotId`) — 6 call paths total, no other modules (toolbar/popover/dock do not use it).
- Public slot-lookup wrappers already exist in `window.m` and are non-static: `int32_t zapp_sidebar_slot_lookup(int32_t host_slot)` and `int32_t zapp_inspector_slot_lookup(int32_t host_slot)` (they delegate to the file-static `zapp_*_slot_for`). `toolbar.m` already consumes them via `extern` declarations — the proven pattern to copy. They return `-1` when absent.
- `darwin_window_eval_js(int32_t window_id, const char* js)` is the eval primitive (declared in `window.h`, already `extern`-used in sidebar.m/inspector.m). It validates its window_id internally.
- `zapp_pane_emit` deliberately does NOT consult the `gJsListeners` bitmask; events 12–19 are not in the Nim `WindowEvent` enum nor `eventNameToId` (they'd map to `-1`), so routing through `zapp_dispatch_event_to_js` would re-drop them. The fix must broaden `zapp_pane_emit`'s own fan-out, not reuse the dispatch path.
- General window events (resize/focus/blur/…) use the *separate* `zapp_dispatch_event_to_js` path and already reach all three panes — no overlap, so no double-delivery risk from this change.

## The fix

### 1. Broaden `zapp_pane_emit` fan-out (macOS)

In `darwin/sidebar.m`:
- Add `extern int32_t zapp_sidebar_slot_lookup(int32_t);` and `extern int32_t zapp_inspector_slot_lookup(int32_t);` at the top (alongside the existing `darwin_window_eval_js` extern), mirroring toolbar.m.
- Change `zapp_pane_emit` to take `(int32_t host_id, const char* eventName, NSString* dataJson)` — **drop the now-redundant `accessory_slot` parameter**. Build the dispatch JS as today, then deliver to all three panes, deduped:
  ```objc
  darwin_window_eval_js(host_id, jsc);                          // main/content pane
  int32_t sb = zapp_sidebar_slot_lookup(host_id);
  if (sb >= 0 && sb != host_id) darwin_window_eval_js(sb, jsc); // sidebar pane
  int32_t insp = zapp_inspector_slot_lookup(host_id);
  if (insp >= 0 && insp != host_id) darwin_window_eval_js(insp, jsc); // inspector pane
  ```
  (`darwin_window_eval_js` bound-checks internally; `-1` lookups are skipped by the `>= 0` guard.)
- Update the two callers to drop the slot argument: `zapp_sidebar_emit` (sidebar.m) and `zapp_inspector_emit` (inspector.m), plus the `extern` prototype for `zapp_pane_emit` in inspector.m.

Net: ~8 lines changed across two files, no header changes, signature change invisible outside sidebar.m/inspector.m.

### 2. Revert the kitchen-sink demo relay

The framework now delivers the events, so the demo should use the real API (and this *is* the fix's verification):
- `kitchen-sink/src/shell/main-pane.ts`: remove the three `Events.emit("ks:sidebar-state", …)` relay lines and the relay's `const win = Window.current()`; remove the now-unused `WindowEvent` from the import.
- `kitchen-sink/src/sections/sidebar.ts` `inspector()`: replace the `Events.on("ks:sidebar-state", …)` listener with the direct triplet `win.on(WindowEvent.SIDEBAR_COLLAPSED/EXPANDED/RESIZED, …)` returning `() => off.forEach(fn => fn())`; restore the `{ Window, WindowEvent }` import (drop `Events` if otherwise unused).

This restores the exact pre-relay (`74bded5`) state of those two files' relevant blocks.

### 3. Nim dead-code comment (`native/nim/events.nim`)

Leave ids 12–19 unmapped in `eventNameToId` (intentional — these events are delivered directly via `zapp_pane_emit` → `dispatchWindowEvent`, bypassing the `gJsListeners` bitmask). Add a one-line comment at the `else: -1` arm documenting this, so a future change doesn't route pane-event delivery through the bitmask and silently break it. Doc-only; no behavior change.

## Verification

- `bun run check` clean (kitchen-sink revert is the only TS change).
- `cd kitchen-sink && bun run build` → `[zapp] build complete:` (the default Nim build compiles the `.m` fix into the binary; `.m` platform code is compiled regardless of Nim/zc).
- `bun test` green; also run `bun test cli/src` (iOS parity gate — a `.m`-only change is not expected to trip the `darwin_*` zc-symbol assertion, confirm).
- **Human visual gate (macOS):** `cd kitchen-sink && bun run dev` → Sidebar section; the **inspector pane** updates live ("collapsed" / "expanded" / "width N") on collapse/expand/divider-drag via the real `win.on` API (relay removed). Sanity: no double-fires; a second window doesn't cross-drive.

## Non-goals / follow-ups

- **iOS parity (follow-up, not this cycle):** iOS has the same logical bug but a different-shaped fix — `ios/sidebar.m` and `ios/inspector.m` each inline their own two-target emit (`zapp_ios_sidebar_emit`, `zapp_ios_inspector_emit_data`); there is no shared `zapp_pane_emit` and no iOS slot-lookup tables, and the inspector is a trailing pane on iPad / a sheet on iPhone-compact (no persistent inspector webview there), so it only manifests on iPad and needs its own slot-cross-referencing design. Can't be drag-smoked in-session. File as a tracked follow-up; close #627 for macOS.
- No new runtime/Nim enum entries for ids 12–19 (YAGNI; the bitmask path is dead for these by design).

## Task shape (for the plan)

- **T1 — native darwin fan-out fix:** broaden `zapp_pane_emit` + drop `accessory_slot` + update the two callers/extern; build-verify the binary compiles.
- **T2 — demo revert + Nim comment + gates + HUMAN VISUAL GATE:** revert main-pane.ts + sidebar.ts to direct `win.on`; add the events.nim comment; run all gates; pause for the macOS human visual smoke.
