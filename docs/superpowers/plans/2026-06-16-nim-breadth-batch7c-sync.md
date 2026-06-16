# Nim Breadth Batch 7c — Sync (Sync.wait/notify) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Wire cross-context sync (`Sync.wait`/`Sync.notify`) into the Nim build — compile `sync.m`, add the targeted `worker_eval_js` (the result-delivery seam sync.m needs), and route the `t:6` SYNC envelope to `darwin_sync_handle`. Final B7 slice.

**Architecture:** `sync.m` (compiled untouched) owns the pthread-cond wait/notify + result dispatch; it calls back into `darwin_webview_eval_all` (compiled), `worker_broadcast_eval_js` (dispatch.nim, B4), and `worker_eval_js` (targeted single-worker — NEW, added to `worker.nim`). The webview-side `Sync.*` arrives as a `t:6` envelope → `routeMessage` calls `darwin_sync_handle(action, argsJson)`. The worker-side `Sync.wait` calls `darwin_sync_wait_blocking` directly from zjs.c (no Nim involvement beyond sync.m being compiled + `worker_eval_js` resolving).

**Tech Stack:** Nim, `importc` of `sync.m`'s `darwin_sync_handle` + zjs.c's `zjs_worker_eval_js`.

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build. Final B7 slice (B7a registry + B7b dispatcher done).
- **SYNC envelope = `t:6`** (`native/bridge/protocol.zc:27` `SYNC: 6`). `routeMessage` handles t:1/t:4/t:5; ADD t:6 → `darwin_sync_handle(f.m, msg)`. The zc (router.zc:341-349) calls `darwin_sync_handle(parsed.method, parsed.payload)` where **`parsed.payload` is the FULL RAW MESSAGE** (`protocol.zc:106 msg.payload = raw`; router.zc:312 comment "parsed.payload is the full [message]"). So `f.m` is the action (`"wait"`/`"notify"`/`"cancel"`) and the second arg is the **whole envelope** `{t:6,m:"wait",a:{…}}` — NOT just `a`. **VERIFIED against `sync.m:233-242`:** `darwin_sync_handle` explicitly unwraps the nested `"a"` field itself ("Webviews route through the bridge as `{t:6,m:"wait",a:{…}}` and the router forwards the *full* message as payload_json"). Pass the Nim `routeMessage` `msg` param (the raw incoming string), exactly like the existing t:4 arm `routeWindowAction(f.m, f.a, windowId, msg)` passes `msg` where the zc passes `parsed.payload`.
- **`sync.m` C-ABI** (defined in `native/platform/darwin/sync.m`, NOT yet compiled): `void darwin_sync_handle(const char* action, const char* payload_json)` (the entry); `int darwin_sync_wait_blocking(const char* key, int timeout_ms)` (worker-side blocking wait — called by zjs.c directly); `darwin_sync_dispatch_to_webviews`/`darwin_sync_dispatch_to_worker` (internal).
- **`sync.m`'s outbound callbacks:** `darwin_webview_eval_all` (webview.m, compiled ✓), `worker_broadcast_eval_js` (dispatch.nim B4 ✓), and **`worker_eval_js(char* worker_id, char* js)`** (sync.m:294 — targeted single-worker eval) — **NOT in the Nim build yet → B7c adds it to `worker.nim`.**
- **`worker_eval_js`** = the targeted-eval dispatcher (port of dispatch.zc's `worker_eval_js` → `zapp_dispatch_worker_eval_js` → `zjs_worker_eval_js`): look up the worker's engine, eng==7 → `zjs_worker_eval_js(workerId, js)`. gcsafe (sync.m may call it off the main thread). zjs-only (bare cases dropped).
- **`zjs_worker_eval_js`** (zjs.c, compiled): `void zjs_worker_eval_js(const char* worker_id, const char* js)`.
- **No new framework** (sync.m = pthread/libc + Foundation, covered). No zapp.nim stub collides (`darwin_sync_handle`/`worker_eval_js` are new, not stubbed).
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only `native/nim/worker.nim native/nim/zapp.nim native/nim/router.nim`. Never `hello-world/` etc. No `{.emit.}`. Do NOT edit `native/platform/**`/`native/worker/**`/`.m`/`.c`/`.zc`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/worker.nim` | + `worker_eval_js` (targeted single-worker eval, exportc gcsafe) | Modify |
| `native/nim/zapp.nim` | compile `sync.m` | Modify |
| `native/nim/router.nim` | `t:6` SYNC envelope → `darwin_sync_handle` | Modify |

*(No new module / unit test — sync.m does the work; build + runtime + human-smoke gated.)*

---

## Task 1: worker_eval_js + compile sync.m + route t:6 → build → GATE

**Files:** Modify `native/nim/worker.nim`, `native/nim/zapp.nim`, `native/nim/router.nim`.

- [ ] **Step 1: Add `worker_eval_js` to worker.nim**

In `native/nim/worker.nim`, add the `zjs_worker_eval_js` importc (next to the other `zjs_worker_*`) + the exported dispatcher (gcsafe, zjs-only, mirroring `worker_post_message`):
```nim
proc zjs_worker_eval_js(workerId, js: cstring) {.importc, cdecl.}

proc worker_eval_js*(workerId, js: cstring) {.exportc, cdecl, gcsafe.} =
  ## Targeted single-worker JS eval (port of dispatch.zc worker_eval_js →
  ## zapp_dispatch_worker_eval_js). sync.m's darwin_sync_dispatch_to_worker
  ## calls this to deliver a wait-result to one worker. zjs-only.
  if zapp_worker_registry_get_engine(workerId) == 7: zjs_worker_eval_js(workerId, js)
```
(`zapp_worker_registry_get_engine` is already importc'd in worker.nim from B7b.)

- [ ] **Step 2: Compile sync.m in zapp.nim**

In `native/nim/zapp.nim`'s `{.compile(...).}` block (after the chrome `.m` from B8), add:
```nim
{.compile("../platform/darwin/sync.m", "-fobjc-arc").}
```

- [ ] **Step 3: Route the t:6 SYNC envelope in router.nim**

In `native/nim/router.nim`, add the `darwin_sync_handle` importc (near the other darwin importc):
```nim
proc darwin_sync_handle(action, payloadJson: cstring) {.importc, cdecl.}
```
In `routeMessage`, add the `t:6` branch alongside `t:4`/`t:5` (the t:4 arm is `routeWindowAction(f.m, f.a, windowId, msg)` at router.nim:670-671 — place t:6 right after t:5 at ~line 677-679, before the `if f.t != 1: return` guard):
```nim
  if f.t == 6:        # SYNC envelope (protocol.zc:27) — Sync.wait/notify/cancel
    darwin_sync_handle(f.m.cstring, msg.cstring)   # msg = full raw envelope (== zc parsed.payload); sync.m unwraps "a"
    return
```
`msg` is `routeMessage`'s raw-string param. `darwin_sync_handle` copies it synchronously (`[NSString stringWithUTF8String:]`) before returning, so there is no cstring-lifetime issue (same as the t:4 `msg` pass). Do NOT pass `$f.a` — `parsed.payload` is the full message (protocol.zc:106), and sync.m's own unwrap logic (sync.m:238-242) depends on receiving the `{t:6,m,a}` shape.

- [ ] **Step 4: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_sync_handle`/`darwin_sync_wait_blocking` → the sync.m compile line is missing; undefined `worker_eval_js` → Step 1 didn't add it / name mismatch vs sync.m:294's extern; undefined `zjs_worker_eval_js` → importc name vs zjs.c.) Do NOT `git add` hello-world/.

- [ ] **Step 5: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in registry_test worker_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/worker.nim native/nim/zapp.nim native/nim/router.nim
git commit -m "$(printf 'feat(nim): sync — compile sync.m + worker_eval_js + t:6 SYNC envelope (Batch 7c)\n\nrouteMessage now routes the t:6 SYNC envelope to sync.m'\''s darwin_sync_handle\n(Sync.wait/notify). worker.nim gains the targeted worker_eval_js dispatcher\n(zjs-only) that sync.m'\''s darwin_sync_dispatch_to_worker needs to deliver a\nwait-result to one worker. sync.m compiled in the build root. Completes B7\n(worker subsystem).\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 7: GATE — human smoke (controller continues; user smokes later)**

`ZAPP_NATIVE_LANG=nim bun run dev`: a `Sync.wait(key, timeout)` in one context blocks until a `Sync.notify(key)` from another (webview↔worker / worker↔worker) wakes it; the waiter resolves with `"notified"` (or `"timed-out"` on timeout). (hello-world's sync demo, if present.)

---

## Self-Review

**1. Spec coverage:** `worker_eval_js` (the sync.m delivery seam) → Step 1; `sync.m` compiled → Step 2; `t:6` SYNC routed → Step 3; build+regression → Steps 4-5. ✓
**2. Placeholder scan:** No TBD/TODO. The arg contract is RESOLVED (not a verify-later note): `parsed.payload` = full raw message (protocol.zc:106) and sync.m:238-242 unwraps `a` → pass `msg`.
**3. Type consistency:** `worker_eval_js(cstring, cstring)` matches sync.m:294's extern `worker_eval_js(char*, char*)`; `zjs_worker_eval_js(cstring,cstring)` matches zjs.h:36 `void zjs_worker_eval_js(const char*, const char*)`; `darwin_sync_handle(cstring,cstring)` matches sync.m:224 + router.zc:344; gcsafe on `worker_eval_js` (sync.m's darwin_sync_dispatch_to_worker may call off-main); `msg` (full raw envelope) is what sync.m parses + unwraps. ✓
