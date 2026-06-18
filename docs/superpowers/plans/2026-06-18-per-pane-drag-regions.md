# Per-Pane Window Drag Regions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `data-zapp-drag-region` work in sidebar + inspector panes (not just the main pane) so the full-bleed sidebar-chrome window drags from its whole top edge.

**Architecture:** Router-only fix — handle the `setDragRegion` t:4 action with the sender pane's OWN slot (`rawWindowId`), before `resolveAccessoryHost` remaps it to the host window. Then `darwin_webview_set_drag_region(senderSlot)` → `darwin_window_get_webview(senderSlot)` → the pane's own webview (whose `mouseDownCanMoveWindow` drags). No native or bootstrap change. Plus a kitchen-sink demo adding drag strips to the sidebar + inspector panes.

**Tech Stack:** Nim (`router.nim`), Zen-C (`router.zc`), TS/CSS (kitchen-sink web shell).

**Spec:** `docs/superpowers/specs/2026-06-18-per-pane-drag-regions-design.md`

**Note:** the main-pane drag strip already shipped (`d79e653`); this adds the two accessory panes + the router fix that makes pane drag actually target the pane.

---

### Task 1: Route `setDragRegion` by the sender's own slot (nim + zc)

**Files:**
- Modify: `native/nim/router.nim` (`routeWindowAction`)
- Modify: `native/app/router.zc` (the window-action router)

- [ ] **Step 1: Relocate the nim `setDragRegion` arm.** In `native/nim/router.nim` `routeWindowAction`, the `setDragRegion` arm is currently AFTER `let windowId = resolveAccessoryHost(rawWindowId)` (~line 491) and uses `windowId.int32`. Move it to BEFORE that line — alongside the sender-slot-preserving arms (`subscribe`/`unsubscribe`/`ready`, ~lines 470-486) — and use `rawWindowId` (the sender's own slot):
```nim
  if action == "setDragRegion":
    # Sender's OWN slot (not the accessory-host remap): each pane's webview has
    # its own mouseDownCanMoveWindow, so the drag flag must land on the pane that
    # sent it (sidebar/inspector/main). darwin_window_get_webview resolves the
    # slot → that pane's webview.
    let drag = a{"drag"}
    if not drag.isNil:
      darwin_webview_set_drag_region(rawWindowId.int32, drag.getBool(false))
    return
```
Delete the old post-remap `setDragRegion` arm. (Place this new arm with subscribe/ready, before `let windowId = resolveAccessoryHost(...)`.)

- [ ] **Step 2: Relocate the zc `setDragRegion` arm.** In `native/app/router.zc`, find the `setDragRegion`/`darwin_webview_set_drag_region` handling (it currently runs after the accessory-host remap that mirrors `resolveAccessoryHost` — search `setDragRegion`, `darwin_webview_set_drag_region`, and the host-remap block ~lines 484-512). Move it to use the RAW sender window id (before the remap), mirroring the nim change — so a pane's drag toggles its own webview. Match router.zc's existing structure + the windows branch (`windows_webview_set_drag_region`) which is in the same arm — it should use the raw sender id too. READ the surrounding code to place it with the sender-slot-preserving actions (subscribe/ready) and keep the macOS/windows `#if`/branch intact.

- [ ] **Step 3: Build BOTH.**
  - Nim: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`.
  - zc: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:`.

- [ ] **Step 4: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim native/app/router.zc
git commit -m "fix(router): setDragRegion targets the sender pane's webview (sidebar/inspector drag)"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

---

### Task 2 (GATE): kitchen-sink sidebar + inspector drag strips + docs + gate

**Files:**
- Modify: kitchen-sink sidebar + inspector pane render (e.g. `kitchen-sink/src/shell/*` — find where each pane's HTML is built) + `kitchen-sink/src/style.css` (reuse `.drag-strip`)
- Possibly: `docs/api-reference.md` (a line noting drag regions work in any pane)

- [ ] **Step 1: Read the existing main-pane strip.** READ `kitchen-sink/src/shell/main-pane.ts` (the `.drag-strip` element added in `d79e653`) and `kitchen-sink/src/style.css` (`.drag-strip` / `.drag-strip-label`). You'll replicate the same strip in the sidebar + inspector pane render.

- [ ] **Step 2: Add the strip to the sidebar pane.** Find where the sidebar pane's HTML is rendered (search `kitchen-sink/src/shell` / the sidebar pane module). Add a `<div class="drag-strip" data-zapp-drag-region>…</div>` at the top, matching the main-pane strip. The sidebar reaches the window's top-LEFT (under the traffic lights), so KEEP the `padding-left` traffic-light inset (reuse `.drag-strip`'s existing inset, or a sidebar-specific class if the sidebar is narrow — read the sidebar width; if 240px the 78px inset still leaves draggable area). Label optional (the main one has "⠿ … drag to move"); keep it subtle/consistent.

- [ ] **Step 3: Add the strip to the inspector pane.** Find the inspector pane render; add the same `data-zapp-drag-region` strip at its top. The inspector is the TRAILING (right) pane — it does NOT reach the traffic lights, so NO left inset is needed (use a variant without the 78px pad, or a shared class with the inset only where needed). Keep styling consistent.

- [ ] **Step 4 (optional docs):** if `docs/api-reference.md` documents `data-zapp-drag-region`, add a one-line note that it works in any pane (main/sidebar/inspector), enabling whole-top-edge drag on full-bleed sidebar windows. If it's not documented, skip (out of scope to introduce full drag-region docs here).

- [ ] **Step 5: Build + tsc.**
  - `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`.
  - `cd /Users/zach/code/zapp && bun run check` → tsc clean.

- [ ] **Step 6: Commit (do NOT run the GUI — the drag is a human smoke).**
```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src docs/api-reference.md   # adjust to the actual files you changed
git commit -m "demo(kitchen-sink): drag strips on sidebar + inspector panes"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

- [ ] **Step 7: GATE — human smoke (deferred).** In the nim kitchen-sink, dragging the window by the sidebar top strip, the inspector top strip, AND the main strip all move the window; interactive controls in those panes still click. (Human-run; not part of automated execution.)

---

## Self-review notes
- **Root-cause fix, minimal surface:** one router arm relocated in two files; no native (`set_drag_region` already resolves the slot) or bootstrap (panes already post `setDragRegion`) change.
- **Main pane unaffected:** its `rawWindowId` == the host window id, so `darwin_window_get_webview(rawWindowId)` is the main webview — same as today. Only sidebar/inspector behavior changes (their slots now resolve to their own webviews).
- **Parity:** identical relocation in `router.nim` (nim) and `router.zc` (zc); the zc arm also covers the `windows_webview_set_drag_region` branch — both use the raw sender id.
- **Type consistency:** `darwin_webview_set_drag_region(rawWindowId.int32, drag.getBool(false))` — same signature, just the sender slot instead of the resolved host.
- **Traffic-light inset:** sidebar pane reaches the window top-left (keep the inset); inspector is trailing (no inset). Verified by the window layout (traffic lights are top-left).
- **iOS/out of scope:** `darwin_webview_set_drag_region` is already a no-op on iOS; no change there.
