# #627 Pane-Event Fan-Out Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make native macOS window pane events reach all three panes (main + sidebar + inspector) by broadening `zapp_pane_emit`, then drop the kitchen-sink demo workaround so it uses the real `win.on` API.

**Architecture:** `zapp_pane_emit` (darwin/sidebar.m) currently evals the dispatch JS on only the host pane + the one accessory slot passed in. Broaden it to look up *both* sibling slots from `host_id` (via the existing public `zapp_sidebar_slot_lookup` / `zapp_inspector_slot_lookup` helpers, already in window.m and used by toolbar.m) and fan out to host + sidebar + inspector, deduped — mirroring the proven fan-out in `zapp_dispatch_event_to_js`. The `accessory_slot` parameter becomes redundant and is dropped. Then the kitchen-sink Sidebar inspector reverts from the Events-bus relay to direct `win.on(SIDEBAR_*)`, which *is* the verification.

**Tech Stack:** Objective-C (macOS native), Nim (events.nim comment), TypeScript (kitchen-sink demo), Bun.

## Global Constraints

- Branch `feat/nim-native`, kept **UNMERGED**.
- Commit trailer on every commit, EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Staging:** explicit per-file `git add <path>` only. NEVER `git add -A`/`.` (unrelated WIP in the tree). No `git commit --amend`.
- **Always Bun, never Node.**
- Scope: macOS darwin fix only. iOS parity is an explicit non-goal (tracked follow-up).
- Gates: `bun run check` clean; `cd kitchen-sink && bun run build` succeeds (success = a line `[zapp] build complete:`); `bun test` green; `bun test cli/src` (iOS parity gate) green.
- No new unit tests (native ObjC + a demo revert + a doc comment; verification is build + the macOS human visual smoke).

---

### Task 1: Broaden `zapp_pane_emit` to fan out to all three panes (macOS, atomic)

Atomic native fix: the function signature changes, so sidebar.m + inspector.m must update together or the build won't compile. One commit.

**Files:**
- Modify: `native/platform/darwin/sidebar.m` (top externs + `zapp_pane_emit` + `zapp_sidebar_emit` caller)
- Modify: `native/platform/darwin/inspector.m` (the `zapp_pane_emit` extern prototype + `zapp_inspector_emit` caller)

**Interfaces:**
- Consumes (already exist in window.m, non-static): `int32_t zapp_sidebar_slot_lookup(int32_t host_slot)`, `int32_t zapp_inspector_slot_lookup(int32_t host_slot)` (return `-1` when absent); `void darwin_window_eval_js(int32_t window_id, const char* js)`.
- Produces: `void zapp_pane_emit(int32_t host_id, const char* eventName, NSString* dataJson)` — new 3-arg signature (drops `accessory_slot`); delivers the dispatch JS to host + sidebar + inspector panes of `host_id`.

- [ ] **Step 1: Add the two slot-lookup externs at the top of sidebar.m**

In `native/platform/darwin/sidebar.m`, the existing extern block near the top is:
```objc
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
@class NSSplitViewController;
extern NSSplitView* zapp_find_split_view(NSView* v);
```
Add the two lookup externs (mirroring toolbar.m, which already externs these) immediately after the `darwin_window_eval_js` extern:
```objc
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
// window.m slot-lookup helpers: resolve a host window's sidebar/inspector
// transport slots so pane events fan out to every pane (#627).
extern int32_t zapp_sidebar_slot_lookup(int32_t host_slot);
extern int32_t zapp_inspector_slot_lookup(int32_t host_slot);
@class NSSplitViewController;
extern NSSplitView* zapp_find_split_view(NSView* v);
```

- [ ] **Step 2: Rewrite `zapp_pane_emit` — drop `accessory_slot`, fan out to all three panes**

In `native/platform/darwin/sidebar.m`, replace the whole `zapp_pane_emit` function (its doc comment + signature + body) with:
```objc
// Shared pane event-emit: dispatch a window event into ALL panes of the host
// window — the host/content pane plus the sidebar and inspector panes (when
// present). eventName is the BARE suffix ("sidebar-collapsed" /
// "inspector-resized" etc.); dispatchWindowEvent in bootstrap/webview.ts
// prepends "window:". dataJson may be nil. Single-quoted JSON literal,
// backslash + quote escaped. Exported — also used by inspector.m.
//
// This deliberately bypasses the gJsListeners bitmask (these event ids aren't
// in the Nim WindowEvent enum / eventNameToId) — see #627. Fan-out mirrors
// zapp_dispatch_event_to_js in window.m.
void zapp_pane_emit(int32_t host_id, const char* eventName, NSString* dataJson) {
    if (!eventName) return;

    NSString* dataArg = @"undefined";
    if (dataJson) {
        NSString* esc = [dataJson stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        dataArg = [NSString stringWithFormat:@"'%@'", esc];
    }
    NSString* event = [NSString stringWithUTF8String:eventName];

    // Build once: dispatchWindowEvent's first arg is the target window id
    // ("win-<hostId>"). All panes belong to the same logical window, so all
    // receive the host's id.
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b.dispatchWindowEvent==='function'){"
        @"b.dispatchWindowEvent('win-%d','%@',%@);}})();",
        host_id, event, dataArg];
    const char* jsc = [js UTF8String];

    // Host/content pane (always).
    darwin_window_eval_js(host_id, jsc);
    // Sidebar pane (if this window has one).
    int32_t sidebar_slot = zapp_sidebar_slot_lookup(host_id);
    if (sidebar_slot >= 0 && sidebar_slot != host_id) {
        darwin_window_eval_js(sidebar_slot, jsc);
    }
    // Inspector pane (if this window has one).
    int32_t inspector_slot = zapp_inspector_slot_lookup(host_id);
    if (inspector_slot >= 0 && inspector_slot != host_id) {
        darwin_window_eval_js(inspector_slot, jsc);
    }
}
```
(The `>= 0 && != host_id` guard matches the existing function's style; `darwin_window_eval_js` validates the slot internally, and a `-1` lookup is skipped.)

- [ ] **Step 3: Update the sidebar caller `zapp_sidebar_emit` (sidebar.m)**

In `native/platform/darwin/sidebar.m`, the wrapper currently reads:
```objc
// Emit a window event into both sidebar panes (host + sidebar slot).
static void zapp_sidebar_emit(ZappSidebarController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, c.sidebarSlotId, eventName, dataJson);
}
```
Drop the now-unused slot argument and refresh the comment:
```objc
// Emit a window event into all panes of the host window (#627 fan-out).
static void zapp_sidebar_emit(ZappSidebarController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, eventName, dataJson);
}
```

- [ ] **Step 4: Update the `zapp_pane_emit` extern + caller in inspector.m**

In `native/platform/darwin/inspector.m`, the extern prototype near the top currently reads:
```objc
extern void zapp_pane_emit(int32_t host_id, int32_t accessory_slot,
                           const char* eventName, NSString* dataJson);
```
Change it to the new 3-arg signature:
```objc
extern void zapp_pane_emit(int32_t host_id, const char* eventName, NSString* dataJson);
```
And the `zapp_inspector_emit` wrapper currently reads:
```objc
// Emit a window event into both inspector panes (host + inspector slot).
static void zapp_inspector_emit(ZappInspectorController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, c.inspectorSlotId, eventName, dataJson);
}
```
Drop the slot argument and refresh the comment:
```objc
// Emit a window event into all panes of the host window (#627 fan-out).
static void zapp_inspector_emit(ZappInspectorController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, eventName, dataJson);
}
```

- [ ] **Step 5: Build-verify the binary compiles**

The `.m` files compile into the default Nim build. Run:
```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build
```
Expected: ends with a line `[zapp] build complete: …/kitchen-sink/bin/kitchen-sink (… KB)`. If the compile fails (e.g., a missed call site or signature mismatch), fix it before committing — grep `zapp_pane_emit` across `native/` to confirm exactly two call sites (sidebar.m, inspector.m) and one extern (inspector.m) plus the definition (sidebar.m), all on the 3-arg form.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/sidebar.m native/platform/darwin/inspector.m
git commit -m "fix(macos): zapp_pane_emit fans out to all panes — sidebar/inspector events reach every pane (#627)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Revert kitchen-sink relay to real API + Nim doc comment + gates + HUMAN VISUAL GATE

With the framework fixed, the demo uses the real `win.on(SIDEBAR_*)` again — and the Sidebar inspector updating live IS the proof the fix works.

**Files:**
- Modify: `kitchen-sink/src/shell/main-pane.ts` (remove the relay block + unused `WindowEvent` import)
- Modify: `kitchen-sink/src/sections/sidebar.ts` (inspector → direct `win.on`; import swap)
- Modify: `native/nim/events.nim` (one-line doc comment at the `eventNameToId` `else: -1`)

**Interfaces:**
- Consumes: `WindowEvent.SIDEBAR_COLLAPSED/EXPANDED/RESIZED` and `WindowHandle.on` (now delivered to the inspector pane by Task 1).

- [ ] **Step 1: Remove the relay block from main-pane.ts**

In `kitchen-sink/src/shell/main-pane.ts`, delete this entire block (it sits between the `ks:nav` `Events.on(...)` line and the `if (registry[0]) show(...)` self-init line):
```ts

  // SIDEBAR_* events reach the main + sidebar panes but NOT the inspector pane
  // (framework #627: zapp_pane_emit fans out to only two panes). Relay them over
  // the Events bus, windowId-scoped, so the Sidebar section's inspector — which
  // lives in the inspector pane — can reflect live sidebar state. (Set up once;
  // renderMainPane runs once per main-pane load.)
  const win = Window.current();
  win.on(WindowEvent.SIDEBAR_COLLAPSED, () => Events.emit("ks:sidebar-state", { state: "collapsed", windowId: win.id }));
  win.on(WindowEvent.SIDEBAR_EXPANDED, () => Events.emit("ks:sidebar-state", { state: "expanded", windowId: win.id }));
  win.on(WindowEvent.SIDEBAR_RESIZED, (d: any) => Events.emit("ks:sidebar-state", { state: "resized", width: d.width, windowId: win.id }));
```
The surrounding lines (the `ks:nav` listener above, the `if (registry[0]) show(registry[0].id);` below) stay.

- [ ] **Step 2: Drop the now-unused `WindowEvent` import in main-pane.ts**

The import line is currently:
```ts
import { Window, Events, Platform, WindowEvent } from "@zappdev/runtime";
```
`WindowEvent` was used only by the removed relay (`Window`, `Events`, `Platform` are still used elsewhere in the file). Change it to:
```ts
import { Window, Events, Platform } from "@zappdev/runtime";
```

- [ ] **Step 3: Revert the Sidebar section inspector to direct `win.on`**

In `kitchen-sink/src/sections/sidebar.ts`, the `inspector(host)` method currently reads:
```ts
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Sidebar</b><div data-state class="muted">Live — collapse, expand, or drag the sidebar to see state.</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    // SIDEBAR_* events don't reach the inspector pane directly (framework #627:
    // zapp_pane_emit fans out to main + sidebar panes only). The main pane relays
    // them over the Events bus as ks:sidebar-state; match windowId so other
    // windows don't cross-drive this inspector.
    const off = Events.on("ks:sidebar-state", ({ state: s, width, windowId }: any) => {
      if (windowId !== win.id) return;
      state.textContent = s === "resized" ? `width ${width}` : s;
    });
    return () => off();
  },
```
Replace it with the direct-subscription form (now that #627 delivers SIDEBAR_* to the inspector pane):
```ts
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Sidebar</b><div data-state class="muted">Live — collapse, expand, or drag the sidebar to see state.</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = [
      win.on(WindowEvent.SIDEBAR_COLLAPSED, () => { state.textContent = "collapsed"; }),
      win.on(WindowEvent.SIDEBAR_EXPANDED, () => { state.textContent = "expanded"; }),
      win.on(WindowEvent.SIDEBAR_RESIZED, (d: any) => { state.textContent = `width ${d.width}`; }),
    ];
    return () => off.forEach((fn) => fn());
  },
```

- [ ] **Step 4: Swap the import in sidebar.ts**

The import line is currently:
```ts
import { Window, Events } from "@zappdev/runtime";
```
`Events` was used only by the removed relay listener; `WindowEvent` is now needed for the direct subscriptions. Change it to:
```ts
import { Window, WindowEvent } from "@zappdev/runtime";
```

- [ ] **Step 5: Add the Nim doc comment at `eventNameToId`'s `else: -1`**

In `native/nim/events.nim`, the `eventNameToId` case ends:
```nim
  of "unfullscreen": 10
  else: -1
```
Insert a comment documenting the intentional gap (so a future change doesn't route pane-event delivery through the bitmask and silently break it):
```nim
  of "unfullscreen": 10
  # Sidebar/inspector chrome events (ids 12-19) are intentionally NOT mapped
  # here: they're delivered directly via zapp_pane_emit -> dispatchWindowEvent
  # in the webview bridge, bypassing the gJsListeners bitmask. Mapping them
  # would route delivery through the bitmask and silently drop them. See #627.
  else: -1
```

- [ ] **Step 6: Run all gates**

```bash
cd /Users/zach/code/zapp
bun run check
bun test
bun test cli/src
cd kitchen-sink && bun run build
```
Expected: `check` exits 0 (clean); `bun test` and `bun test cli/src` pass (no new tests — confirm nothing regressed; the `.m`/comment changes are not expected to trip the iOS `darwin_*` symbol-parity assertion); the build prints `[zapp] build complete:`. Verify `bun run check` via real exit status, not piped output.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/main-pane.ts kitchen-sink/src/sections/sidebar.ts native/nim/events.nim
git commit -m "refactor(kitchen-sink): drop #627 relay — Sidebar inspector uses real win.on; document nim eventNameToId gap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 8: HUMAN VISUAL GATE (macOS)**

STOP. Ask the human to run `cd kitchen-sink && bun run dev` and confirm:
1. **Sidebar section → inspector pane** updates live ("collapsed" / "expanded" / "width N") on collapse, expand, and divider-drag of the sidebar — now via the real `win.on(SIDEBAR_*)` API (the relay is gone).
2. No double-fires / flicker; the value tracks the sidebar accurately.
3. A second window's sidebar does not cross-drive the main window's inspector.
4. (Quick regression) The **Inspector section → inspector pane** still updates on inspector collapse/expand/drag (unchanged path).

Do not consider the cycle complete until confirmed. After confirmation: close #627 for macOS and file the iOS-parity follow-up (`ios/sidebar.m` `zapp_ios_sidebar_emit` + `ios/inspector.m` `zapp_ios_inspector_emit_data` have the same two-target bug; iOS needs slot-lookup tables or per-controller cross-slot storage, and the iPhone inspector is a sheet — iPad-only manifestation).

---

## Self-Review

**Spec coverage:** Fix #1 (broaden `zapp_pane_emit`, drop `accessory_slot`, add externs, update both callers + the inspector.m extern) → Task 1. Fix #2 (revert main-pane.ts relay + sidebar.ts inspector to `win.on`) → Task 2 Steps 1-4. Fix #3 (events.nim doc comment) → Task 2 Step 5. Verification (check/build/test/parity + macOS human gate) → Task 2 Steps 6, 8. Non-goal iOS parity → recorded as the follow-up in Task 2 Step 8. ✓

**Placeholder scan:** No TBD/TODO. Every code step shows exact before/after. The grep-confirm in Task 1 Step 5 is a concrete verification, not a placeholder.

**Type/signature consistency:** `zapp_pane_emit(int32_t host_id, const char* eventName, NSString* dataJson)` is the single new signature used in its definition (sidebar.m), its extern (inspector.m), and both callers (`zapp_sidebar_emit`, `zapp_inspector_emit`) — all 3-arg, no stray 4-arg form left. The kitchen-sink revert restores the exact pre-relay (`74bded5`) shapes: main-pane.ts import `{ Window, Events, Platform }`, sidebar.ts import `{ Window, WindowEvent }`, inspector returns `() => off.forEach((fn) => fn())`. Helper names `zapp_sidebar_slot_lookup` / `zapp_inspector_slot_lookup` match window.m's exports (toolbar.m externs them identically).
