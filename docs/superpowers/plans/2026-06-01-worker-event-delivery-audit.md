# Worker event delivery audit — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three pre-existing worker event delivery gaps (window events, shortcut events, `Services.invokeSync` results on zjs) plus 10 sibling sites that share the same shape. After this lands, every native-emit app event reaches both webviews **and** active workers regardless of engine, with `Services.invokeSync` from a zjs worker resolving correctly.

**Architecture:** Add `zjs_worker_eval_js` mirroring bare's existing targeted variant. Introduce two unified bridge-layer helpers `worker_broadcast_eval_js(js)` and `worker_eval_js(worker_id, js)` that fan to engines via the existing dispatcher pattern in `worker.zc`. Each native-emit call site adds one line; `dispatch_event_to_all` becomes a consumer of the new broadcast helper. The window-event listener bit-field stays as the gate at that one call site.

**Tech Stack:** Zen-C (`.zc`), C, Objective-C. No external libraries added.

**Reference spec:** `/Users/zach/code/zapp/docs/superpowers/specs/2026-06-01-worker-event-delivery-audit-design.md`

---

## File structure

**New code, additive:**
- `native/worker/engines/zjs.h` — declare `zjs_worker_eval_js`
- `native/worker/engines/zjs.c` — implement `zjs_worker_eval_js` (~30 LOC, mirrors `bare_worker_eval_js` shape)
- `native/worker/registry.zc` — add `zapp_worker_registry_get_engine` exported helper (~10 LOC)
- `native/worker/worker.zc` — add `zapp_dispatch_worker_eval_js` non-static dispatcher in the raw block, mirroring `zapp_dispatch_worker_post` (~15 LOC)
- `native/bridge/dispatch.zc` — add `worker_broadcast_eval_js` + `worker_eval_js` Zen-C functions

**Refactored:**
- `native/bridge/dispatch.zc` — `dispatch_event_to_all` replaces its inline `#if`-block worker broadcast with a call to `worker_broadcast_eval_js`

**Call-site edits (one line each):**
- `native/window/callbacks.zc` (gated on listener bit)
- `native/platform/darwin/{shortcuts,menu,tray,notification,platform,sync}.m`
- `native/platform/ios/{shortcuts,notification,sync}.m`
- `native/app/app_events.zc`

**Smoke harness:**
- `hello-world/src/workers/supervised.ts` — six new `Events.on` listeners

**Total LOC delta estimate:** ~140 LOC added (infrastructure) + ~25 LOC added (call sites) + ~30 LOC added (smoke listeners) − ~20 LOC removed (inline block in `dispatch_event_to_all`).

---

## Task 1: Add `zjs_worker_eval_js` engine API

**Goal:** Symmetric with `bare_worker_eval_js`. No call sites use it yet — this commit is the engine-side prerequisite.

**Files:**
- Modify: `/Users/zach/code/zapp/native/worker/engines/zjs.h`
- Modify: `/Users/zach/code/zapp/native/worker/engines/zjs.c`

- [ ] **Step 1: Read the mirror reference**

Run:
```bash
grep -n "bare_worker_eval_js" /Users/zach/code/zapp/native/worker/engines/bare.c /Users/zach/code/zapp/native/worker/engines/bare.h
```

Read `bare_worker_eval_js` at `bare.c:1210` (the body) and the declaration at `bare.h:37`. That body is what you are mirroring for zjs. The shape:
```c
void bare_worker_eval_js(const char* worker_id, const char* js) {
    if (!worker_id || !js) return;
    pthread_mutex_lock(&bare_mutex);
    BareWorkerSlot* slot = bare_find_slot(worker_id);
    if (slot && slot->async_initialized) {
        bare_msgqueue_push(&slot->eval_inbox, js);
        uv_async_send(&slot->async);
    }
    pthread_mutex_unlock(&bare_mutex);
}
```

Then read `zjs_broadcast_eval_js` (search: `grep -n "void zjs_broadcast_eval_js" native/worker/engines/zjs.c`). It already does the slot-walk + eval_inbox push + cross-thread wake — you'll mirror those primitives, just scoped to one slot instead of every slot.

- [ ] **Step 2: Add the zjs.h declaration**

In `/Users/zach/code/zapp/native/worker/engines/zjs.h`, immediately above the existing `zjs_broadcast_eval_js` declaration (currently line 37), add:

```c
// Evaluate JS in a specific zjs worker's context. Used by sync.m to
// deliver bridge.dispatchSyncResult(payload) to the right worker.
// No-op if the worker isn't found / not yet initialized. Mirrors
// bare_worker_eval_js (bare.h:37).
void zjs_worker_eval_js(const char* worker_id, const char* js);
```

- [ ] **Step 3: Implement `zjs_worker_eval_js` in zjs.c**

In `/Users/zach/code/zapp/native/worker/engines/zjs.c`, immediately above the existing `zjs_broadcast_eval_js` implementation (search: `grep -n "^void zjs_broadcast_eval_js" native/worker/engines/zjs.c`), add:

```c
// --- zjs_worker_eval_js: target a specific worker's eval_inbox ---
//
// Same idea as zjs_broadcast_eval_js but scoped to one slot, looked
// up by worker_id. Mirrors bare_worker_eval_js (bare.c:1210).
//
// Slot lock + eval_inbox push + cross-thread wake (kqueue trigger on
// Apple, uv_async_send elsewhere). Safe to call from any thread.
void zjs_worker_eval_js(const char* worker_id, const char* js) {
    if (!worker_id || !js) return;
    pthread_mutex_lock(&zjs_workers_mutex);
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        ZjsWorkerSlot* slot = &zjs_workers[i];
        if (!slot->active) continue;
        if (strcmp(slot->worker_id, worker_id) != 0) continue;
        // Found it — push onto its eval_inbox and wake the worker thread.
        pthread_mutex_lock(&slot->eval_inbox_mutex);
        zjs_msgqueue_push(&slot->eval_inbox, js);
        pthread_mutex_unlock(&slot->eval_inbox_mutex);
#if defined(__APPLE__)
        if (slot->kq_initialized) apple_trigger_eval_inbox(slot);
#else
        if (slot->loop_initialized) uv_async_send(&slot->eval_inbox_async);
#endif
        break;
    }
    pthread_mutex_unlock(&zjs_workers_mutex);
}
```

The exact field names (`zjs_workers`, `zjs_workers_mutex`, `slot->eval_inbox_mutex`, `apple_trigger_eval_inbox`, `slot->eval_inbox_async`, `slot->loop_initialized`, `slot->kq_initialized`) all already exist — verify by reading the body of `zjs_broadcast_eval_js` and matching the names exactly. If anything doesn't match (e.g. field rename since the spec was written), follow whatever `zjs_broadcast_eval_js` uses.

- [ ] **Step 4: Build verify on macOS**

Run:
```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

LAST line MUST be `[zapp] build complete: /Users/zach/code/zapp/hello-world/bin/hello-world (XXX KB)` — NOT Vite's `✓ built in XXms`. Binary mtime within the last minute.

If the build fails with "implicit declaration" or "undefined reference" pointing at one of the field names, you got the rename. Re-read `zjs_broadcast_eval_js` and adjust. STOP and report BLOCKED if you can't find the matching name.

- [ ] **Step 5: Build verify on iOS Simulator**

Run:
```bash
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/ios/hello-world.app/hello-world
```

LAST line MUST be `[zapp] build complete: /Users/zach/code/zapp/hello-world/bin/ios/hello-world.app/hello-world (XXX KB)`. Binary mtime fresh.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/worker/engines/zjs.h native/worker/engines/zjs.c
git commit -m "$(cat <<'EOF'
feat(zjs): add zjs_worker_eval_js targeted variant

Mirrors bare_worker_eval_js (bare.c:1210). Used in subsequent
commits by the new worker_eval_js bridge helper to dispatch
Services.invokeSync results to the right zjs worker.

Slot lookup by worker_id + eval_inbox push + cross-thread wake
(kqueue trigger on Apple, uv_async_send elsewhere). Safe from any
thread. No-op if the worker has terminated.

No call sites use it yet — engine-side prerequisite.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Bridge infrastructure — registry helper + dispatcher + unified helpers + dispatch_event_to_all refactor

**Goal:** All the bridge-layer plumbing in one cohesive commit. After this lands, the new `worker_broadcast_eval_js` and `worker_eval_js` are callable but no native-emit call site uses them yet (except `dispatch_event_to_all` itself, refactored to consume the new helper).

**Files:**
- Modify: `/Users/zach/code/zapp/native/worker/registry.zc`
- Modify: `/Users/zach/code/zapp/native/worker/worker.zc`
- Modify: `/Users/zach/code/zapp/native/bridge/dispatch.zc`

- [ ] **Step 1: Read the existing dispatcher pattern**

```bash
grep -n "zapp_dispatch_worker_post\|zapp_dispatch_worker_terminate\|static int zapp_resolve_engine" /Users/zach/code/zapp/native/worker/worker.zc
```

Read the bodies of `zapp_dispatch_worker_post` and `zapp_dispatch_worker_terminate` inside `worker.zc`'s `raw { }` block. Note that both are `static` — for `zapp_dispatch_worker_eval_js` you'll DROP the `static` keyword (we need it linkable from `dispatch.zc`). All other shape (the switch on engine ID, the engine ID ranges `case 2..6` for bare-*, `case 7` for zjs) is identical.

Also read `dispatch_event_to_all` in `dispatch.zc` (the inline #if-block under `// Workers` is what you'll replace in Step 5):
```bash
sed -n '95,140p' /Users/zach/code/zapp/native/bridge/dispatch.zc
```

- [ ] **Step 2: Add `zapp_worker_registry_get_engine` to registry.zc**

In `/Users/zach/code/zapp/native/worker/registry.zc`, add inside the existing `raw { }` block (look for similar helpers like `zapp_worker_registry_get_owner` or similar — if none exist, place near the bottom of the block):

```c
// Returns the engine ID stored on the worker entry matching worker_id,
// or -1 if no active entry matches. Used by dispatch.zc:worker_eval_js
// to route targeted JS-eval dispatches to the right engine without
// re-walking the registry inside each engine's _worker_eval_js. Mirror
// of the lookup loops already present in this file.
int zapp_worker_registry_get_engine(const char* worker_id) {
    if (!worker_id) return -1;
    for (int i = 0; i < ZAPP_MAX_WORKERS; i++) {
        if (zapp_worker_registry[i].active &&
            strcmp(zapp_worker_registry[i].worker_id, worker_id) == 0) {
            return zapp_worker_registry[i].engine;
        }
    }
    return -1;
}
```

Note: function is non-`static` (callable from worker.zc and dispatch.zc).

- [ ] **Step 3: Add `zapp_dispatch_worker_eval_js` to worker.zc**

In `/Users/zach/code/zapp/native/worker/worker.zc`, inside the existing `raw { }` block, immediately after `zapp_dispatch_worker_terminate`, add the new dispatcher (NOT `static` — needs external linkage):

```c
// Engine-aware targeted JS eval — called from dispatch.zc:worker_eval_js
// after looking up the worker's engine via zapp_worker_registry_get_engine.
// Switch on engine ID matches zapp_dispatch_worker_post's structure.
// Engines that aren't compiled in stub out via the #if-stub machinery
// above (each engine block provides no-op stubs when its define is
// missing), so this compiles regardless of engine selection.
//
// Non-static (callable from dispatch.zc).
void zapp_dispatch_worker_eval_js(int eng, const char* worker_id, const char* js) {
    switch (eng) {
        case 2: case 3: case 4: case 5: case 6:
            bare_worker_eval_js(worker_id, js); break;
        case 7: zjs_worker_eval_js(worker_id, js); break;
    }
}
```

Also: at the top of the `raw { }` block where the other engine stub declarations live (search for `void bare_worker_post_message(const char* a, const char* b) { (void)a; (void)b; }`), add stubs for the new functions inside the matching `#ifndef ZAPP_HAS_BARE` / `#ifndef ZAPP_WORKER_ENGINE_ZJS` blocks:

In the `ZAPP_HAS_BARE`-stubs block (search `grep -n "ZAPP_HAS_BARE" /Users/zach/code/zapp/native/worker/worker.zc`):
```c
    void bare_worker_eval_js(const char* a, const char* b) { (void)a; (void)b; }
```
(may already be there — check first; only add if missing)

In the `ZAPP_WORKER_ENGINE_ZJS`-stubs block:
```c
    void zjs_worker_eval_js(const char* a, const char* b) { (void)a; (void)b; }
```

These stubs keep the link clean when an engine isn't compiled in.

- [ ] **Step 4: Add `worker_broadcast_eval_js` to dispatch.zc**

In `/Users/zach/code/zapp/native/bridge/dispatch.zc`, immediately above the existing `dispatch_event_to_all` function (search: `grep -n "fn dispatch_event_to_all" native/bridge/dispatch.zc`), add the new Zen-C function. The body is the SAME engine-fanout block currently inlined in `dispatch_event_to_all`'s `// Workers` section — extracted so other call sites can reuse it:

```c
// Broadcast a JS snippet to every active worker across every engine
// compiled in. Identical to dispatch_event_to_all's inline worker
// block, extracted so other native-emit call sites (shortcuts.m,
// notification.m, menu.m, tray.m, sync.m, app_events.zc, etc.) can
// fan their events to workers in one line.
//
// JS is shared across all engines — each engine strdup/copies on push
// so the caller may free immediately after this returns.
fn worker_broadcast_eval_js(js: string) -> void {
    raw {
        #if defined(ZAPP_WORKER_ENGINE_ZJS)
        extern void zjs_broadcast_eval_js(const char* js);
        zjs_broadcast_eval_js((const char*)js);
        #endif
        #if defined(ZAPP_HAS_BARE)
        extern void bare_broadcast_eval_js(const char* js);
        bare_broadcast_eval_js((const char*)js);
        #endif
    }
}
```

Match the exact `#if` gate names used in the existing `dispatch_event_to_all` inline block (it currently uses `defined(ZAPP_WORKER_ENGINE_ZJS)` and `defined(ZAPP_HAS_BARE)`). Verify with:
```bash
grep -n "ZAPP_WORKER_ENGINE_ZJS\|ZAPP_HAS_BARE" /Users/zach/code/zapp/native/bridge/dispatch.zc
```

- [ ] **Step 5: Add `worker_eval_js` (targeted) to dispatch.zc**

Immediately below `worker_broadcast_eval_js`, add:

```c
// Targeted JS eval — sends the snippet to one specific worker, routed
// by the registry's engine field. No-op when worker_id doesn't resolve
// (e.g. worker terminated between caller and dispatch).
//
// Used by sync.m to deliver bridge.dispatchSyncResult(payload) to the
// requesting worker; the same shape works for any future native code
// that needs per-worker delivery.
fn worker_eval_js(worker_id: string, js: string) -> void {
    raw {
        extern int  zapp_worker_registry_get_engine(const char* worker_id);
        extern void zapp_dispatch_worker_eval_js(int eng, const char* worker_id, const char* js);
        int eng = zapp_worker_registry_get_engine((const char*)worker_id);
        if (eng < 0) return;
        zapp_dispatch_worker_eval_js(eng, (const char*)worker_id, (const char*)js);
    }
}
```

- [ ] **Step 6: Refactor `dispatch_event_to_all` to consume `worker_broadcast_eval_js`**

In `/Users/zach/code/zapp/native/bridge/dispatch.zc`, find the existing inline worker-broadcast block inside `dispatch_event_to_all` — currently between lines ~117–135 (`// Workers — each engine strdup/copies ...` comment through the closing `#endif` for `ZAPP_HAS_BARE`). Read it first:
```bash
sed -n '110,145p' /Users/zach/code/zapp/native/bridge/dispatch.zc
```

Replace the entire `// Workers` block (the `#if defined(ZAPP_WORKER_ENGINE_ZJS) ... #endif` PLUS the `#if defined(ZAPP_HAS_BARE) ... #endif`) with a single call to the new helper. The result inside the existing `raw { }` block should look like:

```c
        // Webviews
        #ifdef __APPLE__
        extern void darwin_webview_eval_all(const char* js);
        darwin_webview_eval_all(js);
        #else
        extern void windows_webview_eval_all(const char* js);
        windows_webview_eval_all(js);
        #endif

        // Workers — single source of truth in worker_broadcast_eval_js
        // (above in this file). One unified fanout point ensures any
        // future engine picks up dispatches here AND at the new direct
        // call sites in shortcuts.m/menu.m/etc., not just one of them.
        extern void worker_broadcast_eval_js(const char* js);
        worker_broadcast_eval_js(js);

        free(js);
```

Verify nothing else in `dispatch_event_to_all` references the inline block (search for any cleanup after `// Workers` that you don't want to delete — the `free(js);` and `free(esc_*)` near the end stay).

- [ ] **Step 7: Build verify on macOS**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

LAST line MUST be `[zapp] build complete: ...`. Binary mtime fresh.

If you see "multiple definition of worker_broadcast_eval_js" or "unresolved", you likely have a Zen-C name collision OR a missing extern declaration. Read the error carefully — `dispatch.zc`'s functions become C symbols of the same name.

- [ ] **Step 8: Build verify on iOS Simulator**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/ios/hello-world.app/hello-world
```

LAST line MUST be `[zapp] build complete: ...`. Binary mtime fresh.

- [ ] **Step 9: Smoke verify dispatch_event_to_all still works**

The supervised worker subscribes to `force-crash` (broadcast). Run `cd /Users/zach/code/zapp/hello-world && bun run dev 2>&1 | head -50` and look for `[supervised] starting / ready` in the output (~5 seconds is enough). If those log lines appear, dispatch is reaching workers via the new path. Kill with Ctrl-C.

Don't try to click anything — that's the manual matrix at Task 5.

- [ ] **Step 10: Commit**

```bash
cd /Users/zach/code/zapp
git add native/worker/registry.zc native/worker/worker.zc native/bridge/dispatch.zc
git commit -m "$(cat <<'EOF'
feat(bridge): unified worker eval-js helpers + dispatch.zc refactor

Adds the bridge-layer plumbing the audit needs:
- registry.zc:zapp_worker_registry_get_engine(id) — engine lookup by
  worker id, returns -1 on miss.
- worker.zc:zapp_dispatch_worker_eval_js(eng, id, js) — engine-aware
  targeted dispatch, switch matches zapp_dispatch_worker_post.
- dispatch.zc:worker_broadcast_eval_js(js) — extracts the inline
  per-engine #if block from dispatch_event_to_all.
- dispatch.zc:worker_eval_js(worker_id, js) — registry lookup +
  zapp_dispatch_worker_eval_js. Silent no-op when id is unknown.

dispatch_event_to_all itself now CONSUMES worker_broadcast_eval_js
instead of inlining the engine #ifs. Single source of truth for
"broadcast to all workers" — a future engine landing here lights up
both dispatch_event_to_all and every native-emit call site at once
instead of risking divergence.

Call sites that pick up the new broadcast helper come in the next
commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Apply broadcast helper to all webview-only call sites

**Goal:** Every native-emit site that currently calls `darwin_webview_eval_all` adds one line `worker_broadcast_eval_js(js)` so workers receive the event too. 11 sites total (excluding sync.m targeted which lands in Task 4).

**Files:**
- Modify: `/Users/zach/code/zapp/native/window/callbacks.zc`
- Modify: `/Users/zach/code/zapp/native/platform/darwin/shortcuts.m`
- Modify: `/Users/zach/code/zapp/native/platform/darwin/menu.m`
- Modify: `/Users/zach/code/zapp/native/platform/darwin/tray.m`
- Modify: `/Users/zach/code/zapp/native/platform/darwin/notification.m`
- Modify: `/Users/zach/code/zapp/native/platform/darwin/platform.m`
- Modify: `/Users/zach/code/zapp/native/platform/darwin/sync.m` (broadcast sites only — line ~259 and ~263)
- Modify: `/Users/zach/code/zapp/native/platform/ios/shortcuts.m`
- Modify: `/Users/zach/code/zapp/native/platform/ios/sync.m` (broadcast sites only)
- Modify: `/Users/zach/code/zapp/native/platform/ios/notification.m`
- Modify: `/Users/zach/code/zapp/native/app/app_events.zc`

- [ ] **Step 1: Sanity grep — list every site you're touching**

```bash
grep -rn "darwin_webview_eval_all" /Users/zach/code/zapp/native/ --include="*.zc" --include="*.m" --include="*.c" | grep -v "extern\|^.*//"
```

You should see ~13 hits. Of those:
- `native/bridge/dispatch.zc:117` — already converted in Task 2 (skip)
- `native/platform/darwin/sync.m:290-291` — has `bare_worker_eval_js` (Task 4 handles, skip this commit)
- `native/platform/ios/sync.m` — has its own targeted call (Task 4 handles, skip the targeted, do broadcast)
- Everything else — convert here

Confirm by inspection: each remaining site should currently call ONLY `darwin_webview_eval_all(js)` for its event, with no neighboring worker call.

- [ ] **Step 2: callbacks.zc — gated window event broadcast (Gap A)**

Read the current state:
```bash
sed -n '125,140p' /Users/zach/code/zapp/native/window/callbacks.zc
```

You should see the TODO comment ending around line ~134. Right before the `return 0; // ALLOW` line, add the gated worker broadcast.

The current shape (post-TODO) is approximately:
```c
        // Layer 3: ... TODO comment ...

        return 0; // ALLOW
```

Replace the TODO block with the real implementation. First, the existing JS string that drives the webview Layer 2 dispatch (`zapp_dispatch_event_to_js`) is INTERNAL — it doesn't construct a public-facing IIFE we can hand to workers. Workers consume events through `bridge._onEvent(name, payload_json)` like every other broadcast site.

So we need to build an IIFE here. Below the Layer 2 block (`if (zapp_window_js_listeners[...]) zapp_dispatch_event_to_js(...)`), add:

```c
        // Layer 3: Backend worker (if subscribed to this window+event).
        // Build an IIFE the worker bridge can route via _onEvent.
        // Mirrors the IIFE shape dispatch_event_to_all uses.
        if (zapp_window_backend_listeners[window_id] & (1u << event_id)) {
            raw {
                const char* tmpl =
                    "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
                    "if(b&&typeof b._onEvent==='function'){"
                    "b._onEvent('window:event',"
                    "'{\"windowId\":%d,\"event\":%d,\"w\":%d,\"h\":%d,\"x\":%d,\"y\":%d}');"
                    "}})();";
                int needed = snprintf(NULL, 0, tmpl,
                                      (int)window_id, (int)event_id,
                                      (int)w, (int)h, (int)x, (int)y);
                if (needed > 0) {
                    char* js = (char*)malloc((size_t)needed + 1);
                    if (js) {
                        snprintf(js, (size_t)needed + 1, tmpl,
                                 (int)window_id, (int)event_id,
                                 (int)w, (int)h, (int)x, (int)y);
                        extern void worker_broadcast_eval_js(const char* js);
                        worker_broadcast_eval_js(js);
                        free(js);
                    }
                }
            }
        }

        return 0; // ALLOW
```

The event name `window:event` and payload shape are chosen for JS-side consumption — runtime code listens via `Events.on("window:event", ({windowId, event, w, h, x, y}) => …)`.

If your read of `callbacks.zc` shows variable names different from `window_id`/`event_id`/`w`/`h`/`x`/`y`, adapt to match — they're whatever the enclosing function uses.

- [ ] **Step 3: shortcuts.m (macOS) — Gap B**

Read:
```bash
sed -n '195,215p' /Users/zach/code/zapp/native/platform/darwin/shortcuts.m
```

You'll see the IIFE construction + `darwin_webview_eval_all(js);` call (currently line ~206). Immediately after the `darwin_webview_eval_all(js);` line, add:

```c
    extern void worker_broadcast_eval_js(const char* js);
    worker_broadcast_eval_js(js);
```

The forward-declared `extern` can go at the top of the file next to the existing `extern void darwin_webview_eval_all` — your choice; keeping it inline at the call site is also fine.

- [ ] **Step 4: menu.m (macOS)**

Read:
```bash
sed -n '20,40p' /Users/zach/code/zapp/native/platform/darwin/menu.m
```

Find `darwin_webview_eval_all([js UTF8String]);` (~line 30). Add immediately after:
```c
        extern void worker_broadcast_eval_js(const char* js);
        worker_broadcast_eval_js([js UTF8String]);
```

- [ ] **Step 5: tray.m (macOS)**

Read:
```bash
sed -n '155,175p' /Users/zach/code/zapp/native/platform/darwin/tray.m
```

Find `darwin_webview_eval_all(js);` (~line 167). Add immediately after:
```c
        extern void worker_broadcast_eval_js(const char* js);
        worker_broadcast_eval_js(js);
```

- [ ] **Step 6: notification.m (macOS) — two sites**

Read:
```bash
sed -n '15,40p' /Users/zach/code/zapp/native/platform/darwin/notification.m
```

Find both `darwin_webview_eval_all([js UTF8String]);` calls (~line 23 and ~line 31). Add immediately after EACH:
```c
            extern void worker_broadcast_eval_js(const char* js);
            worker_broadcast_eval_js([js UTF8String]);
```

(Indent appropriately for each context — the first call is inside an `else if` branch, the second in a different branch; mirror their existing indentation.)

- [ ] **Step 7: platform.m (macOS) — theme change**

Read:
```bash
sed -n '130,145p' /Users/zach/code/zapp/native/platform/darwin/platform.m
```

Find `darwin_webview_eval_all([js UTF8String]);` (~line 138). Add immediately after:
```c
        extern void worker_broadcast_eval_js(const char* js);
        worker_broadcast_eval_js([js UTF8String]);
```

- [ ] **Step 8: sync.m (macOS) — broadcast sites only**

Read:
```bash
sed -n '255,270p' /Users/zach/code/zapp/native/platform/darwin/sync.m
```

Find the two `darwin_webview_eval_all` calls (~line 259, ~line 263). Add immediately after EACH:
```c
        extern void worker_broadcast_eval_js(const char* js);
        worker_broadcast_eval_js([js UTF8String]);
```

(For the second call where the variable is `jsCopy`, mirror: `worker_broadcast_eval_js([jsCopy UTF8String]);`.)

DO NOT touch the targeted `bare_worker_eval_js` call around line ~290-291 in this commit — that's Task 4.

- [ ] **Step 9: shortcuts.m (iOS)**

Read:
```bash
grep -n "darwin_webview_eval_all" /Users/zach/code/zapp/native/platform/ios/shortcuts.m
```

Apply the same pattern — `worker_broadcast_eval_js([js UTF8String])` (or `worker_broadcast_eval_js(js)` if the variable is already `const char*`) immediately after the existing `darwin_webview_eval_all` call. If no `darwin_webview_eval_all` is in ios/shortcuts.m (iOS doesn't have global hotkeys in the same way), skip this file — comment in the commit message if so.

- [ ] **Step 10: notification.m (iOS) — two sites**

Read:
```bash
sed -n '15,40p' /Users/zach/code/zapp/native/platform/ios/notification.m
```

Mirror Step 6 — add `worker_broadcast_eval_js([js UTF8String])` after each `darwin_webview_eval_all([js UTF8String])` call.

- [ ] **Step 11: sync.m (iOS) — broadcast sites only**

Read:
```bash
grep -n "darwin_webview_eval_all" /Users/zach/code/zapp/native/platform/ios/sync.m
```

Apply broadcast pattern at each site. Skip any targeted `bare_worker_eval_js` call (Task 4).

- [ ] **Step 12: app_events.zc**

Read:
```bash
sed -n '95,110p' /Users/zach/code/zapp/native/app/app_events.zc
```

Find `darwin_webview_eval_all(js_buf);` (~line 104). Add immediately after, inside the same raw block:
```c
        extern void worker_broadcast_eval_js(const char* js);
        worker_broadcast_eval_js(js_buf);
```

- [ ] **Step 13: Build verify on macOS**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

LAST line MUST be `[zapp] build complete: ...`. Binary mtime fresh.

- [ ] **Step 14: Build verify on iOS Simulator**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/ios/hello-world.app/hello-world
```

LAST line MUST be `[zapp] build complete: ...`. Binary mtime fresh.

- [ ] **Step 15: Commit**

```bash
cd /Users/zach/code/zapp
git add native/window/callbacks.zc \
        native/platform/darwin/shortcuts.m \
        native/platform/darwin/menu.m \
        native/platform/darwin/tray.m \
        native/platform/darwin/notification.m \
        native/platform/darwin/platform.m \
        native/platform/darwin/sync.m \
        native/platform/ios/shortcuts.m \
        native/platform/ios/notification.m \
        native/platform/ios/sync.m \
        native/app/app_events.zc
git commit -m "$(cat <<'EOF'
feat(bridge): fan native-emit events to workers, not just webviews

Every site that currently calls darwin_webview_eval_all (or its iOS
equivalent) for an app event now also calls worker_broadcast_eval_js
so bare + zjs workers' Events.on(name, fn) listeners fire.

Sites covered (~11 across darwin + ios + zc):
- callbacks.zc — window events (gated on zapp_window_backend_listeners
  bit-field to avoid waking workers on every mouse-driven resize)
- shortcuts.m — global shortcut triggered (macOS only; iOS skipped if
  no equivalent path)
- menu.m — menu item activated
- tray.m — tray icon clicked
- notification.m — notification click + action (both macOS + iOS)
- platform.m — theme change etc.
- sync.m — sync result webview broadcast (both macOS + iOS; targeted
  delivery to specific worker lands in next commit)
- app_events.zc — app-level events (reopen, deep link)

Gap A (window events) and Gap B (shortcut events) from the supervisor-
restart followups memo are closed by this commit. Gap C (sync delivery
to zjs workers) lands next.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Switch sync.m targeted delivery to engine-agnostic `worker_eval_js` (Gap C)

**Goal:** Replace the hardcoded `bare_worker_eval_js(worker_id, js_c)` at `sync.m:290-291` (and the iOS sibling) with `worker_eval_js(worker_id, js_c)`. The new helper routes via the registry so zjs workers get sync results too.

**Files:**
- Modify: `/Users/zach/code/zapp/native/platform/darwin/sync.m`
- Modify: `/Users/zach/code/zapp/native/platform/ios/sync.m`

- [ ] **Step 1: Read the macOS targeted-delivery site**

```bash
sed -n '280,300p' /Users/zach/code/zapp/native/platform/darwin/sync.m
```

You'll see something like:
```c
    // bare_worker_eval_js is a no-op when the worker_id doesn't
    // ... (comment)
    extern void bare_worker_eval_js(const char* worker_id, const char* js);
    bare_worker_eval_js(worker_id, js_c);
```

- [ ] **Step 2: Replace with `worker_eval_js`**

Replace both lines with:
```c
    // Engine-agnostic targeted delivery — worker_eval_js looks up the
    // worker's engine via zapp_worker_registry_get_engine and dispatches
    // to bare_worker_eval_js / zjs_worker_eval_js as appropriate. Silent
    // no-op when the worker has terminated between request and result.
    extern void worker_eval_js(const char* worker_id, const char* js);
    worker_eval_js(worker_id, js_c);
```

If the surrounding comment (the `bare_worker_eval_js is a no-op` text above the call) explicitly mentions `bare`, update it to be engine-agnostic in the same step — the no-op semantics are preserved by the registry lookup returning -1.

- [ ] **Step 3: Apply the same change to iOS sync.m**

```bash
grep -n "bare_worker_eval_js" /Users/zach/code/zapp/native/platform/ios/sync.m
```

If a targeted call exists, replace with `worker_eval_js` using the same pattern. If iOS sync.m never had a targeted `bare_worker_eval_js` call, document in the commit message and move on.

- [ ] **Step 4: Build verify on macOS**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

LAST line MUST be `[zapp] build complete: ...`. Binary mtime fresh.

- [ ] **Step 5: Build verify on iOS Simulator**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/ios/hello-world.app/hello-world
```

LAST line MUST be `[zapp] build complete: ...`. Binary mtime fresh.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/sync.m native/platform/ios/sync.m
git commit -m "$(cat <<'EOF'
feat(sync): route Services.invokeSync results via engine-agnostic helper

Replaces the hardcoded bare_worker_eval_js call in sync.m (both macOS
and iOS) with worker_eval_js, which looks up the worker's engine via
zapp_worker_registry_get_engine and dispatches to the matching
*_worker_eval_js. zjs workers that called Services.invokeSync now see
their results resolve; bare workers keep working unchanged.

Closes Gap C from the supervisor-restart followups memo. With this
commit + the previous two, all three gaps and the 10 sibling sites
are fixed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Hello-world supervised worker — six smoke subscribers + manual verification matrix

**Goal:** Add six `Events.on` listeners to the supervised worker, one per gap category, each logging when fired. Then manually exercise each event source on macOS and confirm the log fires.

**Files:**
- Modify: `/Users/zach/code/zapp/hello-world/src/workers/supervised.ts`

- [ ] **Step 1: Read the current supervised worker**

```bash
cat /Users/zach/code/zapp/hello-world/src/workers/supervised.ts
```

The file has three existing `Events.on` registrations (`force-crash`, `relay-to-ticker`) plus a `receive("pong", ...)`. You'll add six more listeners next to them.

- [ ] **Step 2: Add the six smoke subscribers**

Below the existing `Events.on("relay-to-ticker", ...)` block and above the final `console.log("[supervised] ready");`, add:

```typescript
// --- Worker event delivery smoke (audit 2026-06-01) ---
// One listener per gap category. Each logs when it fires, so the
// manual matrix in docs/superpowers/plans/<this plan>.md can verify
// the unified worker_broadcast_eval_js / worker_eval_js path is
// reaching workers for every native-emit event source.

Events.on("window:event", (data: any) => {
  console.log(`[supervised] window:event received: ${JSON.stringify(data)}`);
});

Events.on("app:shortcut-triggered", (data: any) => {
  console.log(`[supervised] app:shortcut-triggered received: ${JSON.stringify(data)}`);
});

Events.on("app:menu", (data: any) => {
  console.log(`[supervised] app:menu received: ${JSON.stringify(data)}`);
});

Events.on("app:tray", (data: any) => {
  console.log(`[supervised] app:tray received: ${JSON.stringify(data)}`);
});

Events.on("app:notification-action", (data: any) => {
  console.log(`[supervised] app:notification-action received: ${JSON.stringify(data)}`);
});

// Sync result: the supervised worker would normally see this via
// Services.invokeSync resolving. Adding a console.log inside the
// invoking method is the actual verification path; this listener
// catches the broadcast variant if sync.m also fans out (it does
// at the broadcast sites covered in Task 3).
Events.on("sync:result", (data: any) => {
  console.log(`[supervised] sync:result received: ${JSON.stringify(data)}`);
});
```

The exact event names (`window:event`, `app:shortcut-triggered`, etc.) should match what each native-emit site is using in its IIFE — verify with:
```bash
grep -rn "_onEvent(" /Users/zach/code/zapp/native/platform/darwin/ /Users/zach/code/zapp/native/window/ /Users/zach/code/zapp/native/app/ --include="*.m" --include="*.zc" | grep -v "extern\|//" | head -20
```
You'll see each site's event name string. Adjust the listener names in supervised.ts to match. If a site uses a name different from what's listed above (e.g. `app:tray-clicked` instead of `app:tray`), match the site's actual name.

- [ ] **Step 3: Build verify on macOS**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

LAST line MUST be `[zapp] build complete: ...`. Binary mtime fresh.

- [ ] **Step 4: Manual smoke matrix (HUMAN-IN-THE-LOOP)**

Run `cd /Users/zach/code/zapp/hello-world && bun run dev` and exercise each event source:

| Gap | How to trigger | Expected log |
|---|---|---|
| Window event | Resize the main window | `[supervised] window:event received: …` |
| Shortcut | Press the app's registered global shortcut (if hello-world registers one — check `src/main.ts` for `Shortcuts.register`) | `[supervised] app:shortcut-triggered received: …` |
| Menu | Click a custom menu item from the app menu | `[supervised] app:menu received: …` |
| Tray | Click the tray icon (if hello-world registers one — check `src/main.ts` for `Tray.create`) | `[supervised] app:tray received: …` |
| Notification | Trigger a notification banner + click it / pick an action | `[supervised] app:notification-action received: …` |
| Sync result | Click the webview's invokeSync demo button if one exists; otherwise add a temporary one to `src/main.ts` calling `Services.invokeSync` | `[supervised] sync:result received: …` OR equivalent log |

Hello-world may not have a UI button for every event source. For categories without a built-in trigger:
- **Shortcut:** if hello-world doesn't register one, register a temporary `Shortcuts.register("CmdOrCtrl+Shift+T")` in `src/main.ts` to test.
- **Tray:** if no tray, add `Tray.create({...})` temporarily.
- **Menu:** likely already wired — click File or Edit menu items.

If a category's log does NOT fire, STOP and report which one — the call site for that category is wrong (most likely event-name mismatch).

- [ ] **Step 5: Commit (smoke + listener additions only — temporary triggers stay out)**

If you added temporary triggers in `src/main.ts` for testing, revert those before committing. Then:

```bash
cd /Users/zach/code/zapp
git add hello-world/src/workers/supervised.ts
git commit -m "$(cat <<'EOF'
test(hello-world): supervised worker subscribes to all 6 event gaps

Six new Events.on listeners on the supervised headless worker, one per
audit gap category (window event, shortcut, menu, tray, notification,
sync result). Each logs when fired — the manual matrix in the audit
plan exercises each event source and confirms the log appears.

Verified on macOS (engine: zjs) — each gap category triggers the
expected listener. iOS Sim coverage is incidental (verification
remains macOS-only per the spec).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist

After landing all 5 tasks:

- [ ] Each gap (A: window events, B: shortcut events, C: sync result on zjs) has a corresponding task + commit
- [ ] Each non-gap-but-same-class site (menu, tray, notification ×4, platform, sync broadcasts, app_events) has a call-site edit in Task 3
- [ ] `dispatch_event_to_all` no longer inlines engine `#if` blocks for the worker broadcast (Task 2 step 6)
- [ ] `zjs_worker_eval_js` declared in zjs.h AND implemented in zjs.c (Task 1)
- [ ] No reference to the removed `jsc` / `txiki` engines anywhere
- [ ] macOS build green at every commit boundary
- [ ] iOS Sim build green at every commit boundary (final commit at minimum)
- [ ] Manual smoke matrix has at least one observed log per gap category

After all 5 tasks complete: dispatch a final cross-implementation code reviewer, then invoke `superpowers:finishing-a-development-branch`.
