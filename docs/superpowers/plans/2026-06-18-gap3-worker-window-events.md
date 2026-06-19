# Gap #3 — window events to zjs workers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make native window-lifecycle events (resize/focus/close/…) reach **zjs** workers via the same typed API the rest of the framework uses (`Events.on(WindowEvent.RESIZE, cb)`), by closing two independent breaks + correcting the stale record.

**Architecture:** Two breaks, two fixes. **(1) Native/engine:** `zjs.c` lacks the `subscribeWindowEvent` host fn that arms the per-window backend-listener bitmask (`bare.c` has it) — add it, mirroring `bare.c`. **(2) Worker-side TS:** arming fires for specific names (`window:resize`) but native delivers under the internal `'window:event'` envelope with no remap, so handlers never fire — add a reverse-map in `bootstrap/worker.ts._onEvent` and a `WindowEvent`-enum overload to `Events.on`. Then correct stale docs + rewrite the hello-world demo + live-smoke.

**Tech Stack:** TypeScript (Bun, `bun:test`), C (zjs.c, the zjs embed ABI), Nim doc-comments, Markdown.

**Spec:** `docs/superpowers/specs/2026-06-18-gap3-worker-window-events-design.md`.

**Key facts (verified):**
- zjs host fn idiom: `static ZjsValue host_x(ZjsContext* ctx, ZjsValue* argv, uint32_t argc)`, ints via `zjs_as_int32(argv[i])`, void-return `zjs_undefined()` (no ctx arg), register via `zjs_register_host_function(ctx,"__zapp_x",fn)` + `zjs_set_property(ctx,bridge,"x",fn)`.
- `bare.c:1139-1159` / `1681-1684` is the reference for the host fn.
- Window-event cap = `64` (`callbacks.zc:11`); `zapp_window_set_backend_listener` bounds-checks internally.
- `bootstrap/worker.ts` is a self-contained IIFE (`(function(){…})()`, no imports) injected into workers — its `windowEventIds` (string→number) map is at ~lines 45-49, `bridge.on` at ~52-57 (already arms), `_onEvent` at ~140.
- `runtime/events.ts`: `Events.on(name: EventName, h) → getBridge().on(name, h)` (~line 195); `eventName(WindowEvent|AppEvent)` (~line 185) maps an enum value → string via `WINDOW_EVENT_NAMES`/`APP_EVENT_NAMES`. `WindowEvent`/`AppEvent` are numeric enums (WindowEvent 0-19, AppEvent 100+ — no numeric overlap).
- Bridge mock precedent for tests: `globalThis[Symbol.for("zapp.bridge")] = {...}` (see `runtime/worker.test.ts`).

---

## File Structure

- **Modify** `runtime/events.ts` — widen `Events.on` to accept `WindowEvent`/`AppEvent` enum values (coerce via `eventName`). One responsibility: the public event API.
- **Create/extend** `runtime/events.test.ts` — unit test the enum coercion + string passthrough.
- **Modify** `bootstrap/worker.ts` — reverse-map the internal `'window:event'` envelope to the specific typed listener in `_onEvent`.
- **Modify** `native/worker/engines/zjs.c` — add `host_subscribe_window_event` + register `subscribeWindowEvent` on the bridge.
- **Modify** `native/nim/app_events.nim`, `native/nim/callbacks.nim` — correct stale doc-comments.
- **Modify** `docs/nim-migration-roadmap.md` — reframe gap #3.
- **Modify** `hello-world/src/workers/supervised.ts` — rewrite the window-event demo to the specific typed name.

---

### Task 1: Worker-side TS coherence (break #2)

**Files:**
- Modify: `runtime/events.ts`
- Test: `runtime/events.test.ts`
- Modify: `bootstrap/worker.ts`

- [ ] **Step 1: Write the failing test** for the `Events.on` enum coercion. Check whether `runtime/events.test.ts` exists; if not, create it. Add:

```ts
import { test, expect } from "bun:test";
import { Events, WindowEvent } from "./events";

const BRIDGE = Symbol.for("zapp.bridge");

test("Events.on coerces a WindowEvent enum to its string name before subscribing", () => {
  const calls: string[] = [];
  (globalThis as any)[BRIDGE] = { on: (name: string) => { calls.push(name); return () => {}; } };
  Events.on(WindowEvent.RESIZE, () => {});
  expect(calls).toEqual(["window:resize"]);
  delete (globalThis as any)[BRIDGE];
});

test("Events.on passes a plain custom event name through unchanged", () => {
  const calls: string[] = [];
  (globalThis as any)[BRIDGE] = { on: (name: string) => { calls.push(name); return () => {}; } };
  Events.on("my-custom-event", () => {});
  expect(calls).toEqual(["my-custom-event"]);
  delete (globalThis as any)[BRIDGE];
});
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `cd /Users/zach/code/zapp && bun test runtime/events.test.ts`
Expected: FAIL — the enum test gets `["window:resize"]`? No: currently `Events.on(WindowEvent.RESIZE, …)` passes the **number** `3` to `bridge.on`, so `calls` is `[3]` (or a stringified number) — assertion fails. (If `events.test.ts` had to be created, also confirm the file is picked up by the runner.)

- [ ] **Step 3: Widen `Events.on` to coerce enums.** In `runtime/events.ts`, change the `on` method (keep `emit` as-is). `eventName` is already imported/defined in this file:

```ts
  on(name: EventName | WindowEvent | AppEvent, handler: EventHandler): () => void {
    // WindowEvent/AppEvent are numeric enums; map them to their wire string.
    // Plain custom event names (strings) pass through unchanged.
    const resolved = typeof name === "number" ? eventName(name) : name;
    return getBridge().on(resolved, handler);
  },
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `cd /Users/zach/code/zapp && bun test runtime/events.test.ts`
Expected: PASS (both tests).

- [ ] **Step 5: Add the reverse-map in `bootstrap/worker.ts`.** Just above the `bridge._onEvent = function …` definition (~line 140), build the inverse of `windowEventIds`; then re-route the `'window:event'` envelope to the specific listener inside `_onEvent`. Replace the existing `_onEvent` with:

```ts
  // Inverse of windowEventIds (numeric id → "window:<name>"), built once. The
  // native layer delivers ALL window-lifecycle events under the internal
  // 'window:event' envelope ({windowId,event,w,h,x,y}); we re-route to the
  // specific typed listener (e.g. 'window:resize') the user subscribed to.
  // 'window:event' is internal — never a user-facing listener name.
  const windowEventNameById: Record<number, string> = {};
  for (const [n, id] of Object.entries(windowEventIds)) windowEventNameById[id] = n;

  bridge._onEvent = function (name: string, payload: string) {
    let parsed: any = payload;
    try { parsed = JSON.parse(payload); } catch {}
    let target = name;
    if (name === "window:event" && parsed && typeof parsed === "object") {
      const specific = windowEventNameById[parsed.event];
      if (specific) target = specific;
    }
    for (const h of listeners[target] || []) {
      try { h(parsed); } catch (e) {
        console.error("[worker]", e);
        reportCrash(e);
      }
    }
  };
```

(Leave `bridge.on` unchanged — it already arms via `subscribeWindowEvent(-1, eventId)` for the specific names in `windowEventIds`.)

- [ ] **Step 6: Type-check + full test sweep.**

Run: `cd /Users/zach/code/zapp && bunx tsc --noEmit && bun test`
Expected: `tsc` shows no NEW errors (only the pre-existing baseline, if any); `bun test` green incl. the two new events tests.

- [ ] **Step 7: Commit.**

```bash
cd /Users/zach/code/zapp
git add runtime/events.ts runtime/events.test.ts bootstrap/worker.ts
git commit -m "feat(events): worker window-event coherence — enum-accept + 'window:event' reverse-map

Events.on now accepts WindowEvent/AppEvent enum values (coerced via eventName).
The worker bootstrap re-routes the internal 'window:event' delivery envelope to
the specific typed listener (e.g. 'window:resize'), so a single
Events.on(WindowEvent.RESIZE, cb) both arms and receives. 'window:event' is now
internal-only. Shared TS — fixes the worker-side break for bare too.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: zjs `subscribeWindowEvent` host fn (break #1)

**Files:**
- Modify: `native/worker/engines/zjs.c`

No unit test — this is engine glue registered with the running zjs context; it's exercised by the live smoke in Task 3 (the established pattern for the sibling host fns, none of which have unit tests).

- [ ] **Step 1: Add the extern + host function.** Near the other `extern` declarations at the top of `zjs.c` (around the `app_get_active`/`service_invoke_native` externs, ~line 98), add:

```c
extern void zapp_window_set_backend_listener(int id, int event_id, int has_listener);
```

Then define the host function next to the other `host_*` fns (e.g. just after `host_list_workers`, ~line 643). Match the exact void-return idiom the siblings use (`zjs_undefined()`):

```c
// __zappBridge.subscribeWindowEvent(windowId, eventId) — arm this worker's
// window-event backend listener (negative windowId = all windows). Mirrors
// bare.c:bare_host_subscribe_window_event. The actual fan-out is callbacks.nim
// Layer 3 (gated on the bitmask this sets) → worker_broadcast_eval_js.
static ZjsValue host_subscribe_window_event(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    (void) ctx;
    if (argc < 2) return zjs_undefined();
    int wId = zjs_as_int32(argv[0]);
    int eId = zjs_as_int32(argv[1]);
    if (wId < 0) {
        for (int i = 0; i < 64; i++) zapp_window_set_backend_listener(i, eId, 1);
    } else {
        zapp_window_set_backend_listener(wId, eId, 1);
    }
    return zjs_undefined();
}
```

(If the sibling host fns cast unused `ctx` differently or omit `(void) ctx`, match their style to avoid a new `-Wunused-parameter` warning.)

- [ ] **Step 2: Register it on the bridge.** In `zjs_setup_bridge`, after the `listWorkers` registration (`zjs.c:984`), add:

```c
    ZjsValue sub_fn = zjs_register_host_function(ctx, "__zapp_subscribe_window_event",
                                                 host_subscribe_window_event);
    zjs_set_property(ctx, bridge, "subscribeWindowEvent", sub_fn);
```

- [ ] **Step 3: Build the Nim app (build gate).**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
Expected: completes with a final `[zapp] build complete: …` line (Vite's `✓ built` is NOT sufficient), fresh binary. A compile error here means the host-fn signature or a zjs API name is off — fix against the sibling host fns.

- [ ] **Step 4: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/worker/engines/zjs.c
git commit -m "feat(zjs): subscribeWindowEvent host fn — arm window-event delivery to zjs workers

Mirrors bare.c. Sets the per-window backend-listener bitmask callbacks.nim
Layer 3 gates on, so window lifecycle events reach zjs workers. zjs.c is shared,
so this fixes the zc build too; jitless, so it works on iOS.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Record correction + hello-world + live smoke

**Files:**
- Modify: `native/nim/app_events.nim`, `native/nim/callbacks.nim`
- Modify: `docs/nim-migration-roadmap.md`
- Modify: `hello-world/src/workers/supervised.ts`

- [ ] **Step 1: Correct the stale Nim doc-comments.** In `native/nim/app_events.nim` (~line 9) and `native/nim/callbacks.nim` (~line 10), replace the `"… DEFERRED no-op (Batch 4/7)"` wording describing the Layer-2/3 worker fan-out with the real state: the worker fan-out was wired in `87d745a` — Layer 2 (app events) is an ungated broadcast, Layer 3 (window events) is gated on the backend-listener bitmask which the zjs `subscribeWindowEvent` host fn now sets. Keep the surrounding doc structure; change only the stale sentences.

- [ ] **Step 2: Rewrite the hello-world demo to the typed name.** In `hello-world/src/workers/supervised.ts` (~line 89), replace the `Events.on("window:event", …)` listener (which never fired — it used the internal envelope name) with the specific typed subscription. Import `WindowEvent` from the runtime if not already imported:

```ts
// Window lifecycle event — now delivered to the specific typed listener.
// Payload: { windowId, event, w, h, x, y }. Fires on resize once the worker
// is subscribed (Events.on arms the backend listener via subscribeWindowEvent).
Events.on(WindowEvent.RESIZE, (data: any) => {
  console.log(`window:resize received: ${JSON.stringify(data)}`);
});
```

- [ ] **Step 3: Reframe gap #3 in the roadmap.** In `docs/nim-migration-roadmap.md`, update the gap #3 row/section to: "Nim has worker-event parity with zc (app/global/targeted verified). The residual window→worker hole had **two** breaks — zjs missing the `subscribeWindowEvent` host fn (engine glue, shared by zc) and the worker-side subscribe/deliver name incoherence (shared TS, the WED 'window auto-subscription' gap) — **both closed** (`2026-06-18`). `Events.on(WindowEvent.RESIZE, cb)` now works in a zjs worker." Keep the note that gap #4 (bare) is deferred and the post-gap-#3 path is zjs-centric (iOS #5, Windows #6, default-flip #7). Match the file's existing format.

- [ ] **Step 4: Type-check + tests still green.**

Run: `cd /Users/zach/code/zapp && bunx tsc --noEmit && bun test`
Expected: no new errors; green.

- [ ] **Step 5: Build hello-world on the Nim path for the smoke.**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build`
Expected: `[zapp] build complete: …`. (Confirm the supervised worker runs on the default **zjs** engine.)

- [ ] **Step 6: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/nim/app_events.nim native/nim/callbacks.nim docs/nim-migration-roadmap.md hello-world/src/workers/supervised.ts
git commit -m "docs+demo: gap #3 record correction + hello-world window:resize subscriber

Correct stale 'deferred no-op' comments (worker fan-out wired in 87d745a);
reframe roadmap gap #3 (two breaks closed); rewrite the hello-world supervised
worker to Events.on(WindowEvent.RESIZE) which now actually fires.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## After all tasks

- **Live smoke (human GUI gate — the real proof):** launch the Nim-built hello-world, resize the window, and confirm the supervised worker logs `[zapp/h-supervised] window:resize received: {…,"windowId":…}`. This proves both breaks closed end-to-end on zjs. Also confirm app/global events to the worker still fire (unchanged paths).
- **Final cross-impl review** (subagent): verify the zjs host fn matches `bare.c`'s semantics + the sibling host-fn idiom; the reverse-map inverts `windowEventIds` correctly and only re-routes the `'window:event'` envelope (custom/app events untouched); the `Events.on` coercion can't mis-handle a numeric custom event (custom events are strings by contract); no zc-build regression (zjs.c change additive).

## Self-Review notes (author)

- **Spec coverage:** break #1 (Task 2 zjs.c), break #2 (Task 1 events.ts overload + worker.ts reverse-map), record correction + hello-world (Task 3), smoke (post-tasks). All spec components mapped.
- **Type consistency:** `windowEventIds` (string→number, worker bootstrap) is inverted in-place; `eventName()` (enum→string, runtime) drives the `Events.on` coercion. The two maps must agree on the wire names — both use the `window:<name>` convention; the live smoke catches any drift.
- **No placeholders:** all code blocks are concrete; the one judgment call (matching the sibling `ctx`-unused style) is explicit.
- **Test reality:** the cleanly-unit-testable piece (enum coercion) is TDD'd; the worker IIFE reverse-map + the C host fn are integration-gated by the live smoke, consistent with how `bootstrap/*` and the sibling zjs host fns are verified (no existing unit tests for either).
