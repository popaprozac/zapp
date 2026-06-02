# Workers.list() Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `Workers.list()` runtime debug API + optional worker `name` field + compact `[zapp/<name>] ...` log format as one coherent change.

**Architecture:** Single source of truth in `native/worker/registry.zc` (new `name` field, new `zapp_workers_registry_list()` + `zapp_worker_registry_get_display_name()` helpers). Per-engine host objects (zjs.c, bare.c) expose `__zappBridge.listWorkers` to worker context; a `__zapp:workers-list` IPC route exposes it to webview context. The runtime `Workers.list()` wrapper is identical in both contexts. Log lines across 3 native files switch to compact prefix via the display-name helper.

**Tech Stack:** Zen-C (registry, router), C (zjs.c, bare.c), TypeScript (runtime/, bootstrap/, cli/), NAPI (bare host bridge), ZjsValue API (zjs host bridge), libuv (IPC async-response).

**Spec:** `docs/superpowers/specs/2026-06-02-workers-list-design.md`

**Testing note:** This codebase has no unit test harness for the touched layers. Each task verifies via (1) build verify — must see `[zapp] build complete: ...` as the **last** line of output (Vite's `✓ built in XXms` is NOT sufficient — see `feedback_verify_native_build`), and (2) manual smoke per task.

---

## File Structure

| File | Responsibility | Type |
|---|---|---|
| `native/worker/registry.zc` | Add `name` field to `ZappWorkerEntry`; add `zapp_workers_registry_list()` + `zapp_worker_registry_get_display_name()` helpers; add `_with_name` constructor variants | Modify |
| `native/worker/worker.zc` | Thread `name` through `zapp_start_headless_worker_full` signature | Modify |
| `native/worker/engines/zjs.c` | Register `__zappBridge.listWorkers` host function (ZjsValue array build); rewrite ~3 log call sites to compact prefix | Modify |
| `native/worker/engines/bare.c` | Register `__zappBridge.listWorkers` host function (NAPI array build); rewrite ~3 log call sites to compact prefix | Modify |
| `native/app/router.zc` | New route handler `__zapp:workers-list` — calls registry, JSON-serializes, returns via `dispatch_invoke_response` | Modify |
| `bootstrap/webview.ts` | Add `bridge.listWorkers = () => invoke("__zapp:workers-list", null)`; thread `name` arg into `createWorker` message | Modify |
| `bootstrap/worker.ts` | (no-op; zjs/bare register `listWorkers` natively at worker init) | Reference only |
| `runtime/worker.ts` | Add `WorkerInfo` interface + `Workers.list()` method; widen `new Worker(url, opts)` to accept `name` | Modify |
| `cli/src/config.ts` | Add `name?: string` to `HeadlessWorkerConfig` | Modify |
| `cli/src/build-config.ts` | Update `generateHeadlessWorkers` codegen to emit `name` as 6th arg to `zapp_start_headless_worker_full(...)` | Modify |
| `hello-world/zapp.config.ts` | Add `name: "sync-engine"` to supervised entry (smoke validation) | Modify |
| `hello-world/src/main.ts` | Add "Show workers" button + handler that pretty-prints `Workers.list()` | Modify |

---

## Task 1: Registry — `name` field + helpers

**Files:**
- Modify: `native/worker/registry.zc:23-104,221-229`

- [ ] **Step 1.1: Add `name` field to `ZappWorkerEntry` struct**

In `native/worker/registry.zc:23-42`, add a `char name[64]` field after `worker_id`:

```c
typedef struct {
    char worker_id[64];
    char name[64];                                    // NEW — empty string when unset
    char script_url[256];
    char owners[ZAPP_MAX_OWNERS_PER_WORKER][64];
    int owner_count;
    int shared;
    int active;
    int engine;
    int restart_max;
    int restart_window_ms;
    int fail_count;
    long long fail_window_start_ms;
    int gave_up;
} ZappWorkerEntry;
```

Initialize `name[0] = 0;` in every `_add*` constructor body.

- [ ] **Step 1.2: Add `_with_name` constructor variants**

Add two new constructors in `native/worker/registry.zc` after the existing `_full_with_engine` and `_full` variants (around line 100):

```c
int zapp_worker_registry_add_full_with_engine_and_name(
    const char* worker_id,
    const char* owner_id,
    int shared,
    const char* script_url,
    int engine,
    const char* name
) {
    int slot = zapp_worker_registry_add_full_with_engine(worker_id, owner_id, shared, script_url, engine);
    if (slot >= 0 && name && name[0]) {
        strncpy(zapp_worker_registry[slot].name, name, 63);
        zapp_worker_registry[slot].name[63] = 0;
    }
    return slot;
}

int zapp_worker_registry_add_full_with_name(
    const char* worker_id,
    const char* owner_id,
    int shared,
    const char* script_url,
    const char* name
) {
    return zapp_worker_registry_add_full_with_engine_and_name(
        worker_id, owner_id, shared, script_url, ZAPP_ENGINE_ZJS, name
    );
}
```

Same shape exposed in the `.zh` header if present (check `native/worker/registry.zh` for existing exports — mirror them).

- [ ] **Step 1.3: Add `zapp_worker_registry_get_display_name` helper**

After the `zapp_worker_registry_get` function (around line 230), add:

```c
const char* zapp_worker_registry_get_display_name(const char* worker_id) {
    if (!worker_id) return "";
    ZappWorkerEntry* e = zapp_worker_registry_get(worker_id);
    if (!e) return worker_id;
    if (e->name[0]) return e->name;
    return e->worker_id;
}
```

Mirror in the `.zh` header.

- [ ] **Step 1.4: Add `zapp_workers_registry_list` walk function**

Add a list builder that returns a heap-allocated JSON string of the active registry. Place near other registry walkers around line 240:

```c
// Caller frees with free().
char* zapp_workers_registry_list_json() {
    // Allocate generous buffer — at worst ZAPP_MAX_WORKERS * ~512 bytes.
    size_t cap = 4096;
    char* buf = (char*)malloc(cap);
    if (!buf) return NULL;
    size_t off = 0;
    off += snprintf(buf + off, cap - off, "[");
    int first = 1;
    for (int i = 0; i < ZAPP_MAX_WORKERS; i++) {
        ZappWorkerEntry* e = &zapp_worker_registry[i];
        if (!e->active) continue;
        if (off + 1024 > cap) {
            cap *= 2;
            char* nb = (char*)realloc(buf, cap);
            if (!nb) { free(buf); return NULL; }
            buf = nb;
        }
        // engine int → string
        const char* engine_str = "zjs";
        switch (e->engine) {
            case ZAPP_ENGINE_ZJS:           engine_str = "zjs"; break;
            case ZAPP_ENGINE_BARE_JSC:      engine_str = "bare-jsc"; break;
            case ZAPP_ENGINE_BARE_V8:       engine_str = "bare-v8"; break;
            case ZAPP_ENGINE_BARE_QUICKJS:  engine_str = "bare-quickjs"; break;
            case ZAPP_ENGINE_BARE_MQJS:     engine_str = "bare-mqjs"; break;
            case ZAPP_ENGINE_BARE_HERMES:   engine_str = "bare-hermes"; break;
        }
        off += snprintf(buf + off, cap - off, "%s{\"id\":\"%s\"", first ? "" : ",", e->worker_id);
        if (e->name[0]) {
            off += snprintf(buf + off, cap - off, ",\"name\":\"%s\"", e->name);
        }
        off += snprintf(buf + off, cap - off,
            ",\"scriptUrl\":\"%s\",\"engine\":\"%s\",\"shared\":%s,\"owners\":[",
            e->script_url, engine_str, e->shared ? "true" : "false");
        for (int o = 0; o < e->owner_count; o++) {
            off += snprintf(buf + off, cap - off, "%s\"%s\"", o == 0 ? "" : ",", e->owners[o]);
        }
        off += snprintf(buf + off, cap - off, "]");
        if (e->restart_max > 0) {
            off += snprintf(buf + off, cap - off,
                ",\"supervisor\":{\"maxRetries\":%d,\"withinMs\":%d,\"failCount\":%d,\"gaveUp\":%s}",
                e->restart_max, e->restart_window_ms, e->fail_count, e->gave_up ? "true" : "false");
        }
        off += snprintf(buf + off, cap - off, "}");
        first = 0;
    }
    off += snprintf(buf + off, cap - off, "]");
    return buf;
}
```

Mirror in the `.zh` header.

> **Why JSON, not a typed record?** The zjs/bare host objects will parse this once, but webview's IPC path needs JSON anyway. Single JSON path keeps the registry surface lean. The per-engine host functions parse this small JSON in their own thread — cost is negligible vs. wire-IPC.

- [ ] **Step 1.5: Build verify**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
```

Expected: last line of output is `[zapp] build complete: <path-to-binary>`. (Per `feedback_verify_native_build` — Vite's `✓ built in XXms` does NOT count.) Also confirm `ls -la zapp/build/<bin>` shows fresh mtime (within last minute).

- [ ] **Step 1.6: Commit**

```bash
git add native/worker/registry.zc native/worker/registry.zh
git commit -m "$(cat <<'EOF'
feat(registry): add worker name field + list + display-name helpers

Adds char name[64] to ZappWorkerEntry, _with_name constructor variants,
zapp_worker_registry_get_display_name() (name > worker_id fallback), and
zapp_workers_registry_list_json() — heap-allocated active-worker dump used
by both Workers.list() paths (per-engine host objects + webview IPC).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Worker.zc — thread `name` through start helper

**Files:**
- Modify: `native/worker/worker.zc` (search for `zapp_start_headless_worker_full`)

- [ ] **Step 2.1: Widen signature**

Find `zapp_start_headless_worker_full` in `native/worker/worker.zc`. Add a `const char* name` parameter at the end of the signature (after `restart_window_ms`):

```c
void zapp_start_headless_worker_full(
    const char* worker_id,
    const char* url,
    int engine,
    int restart_max,
    int restart_window_ms,
    const char* name   // NEW
) {
    // ... existing body ...
}
```

Inside the body, where the registry is populated, swap the registry-add call to the `_with_name` variant from Task 1. If the existing body calls `zapp_worker_registry_add_full_with_engine(...)`, change it to `zapp_worker_registry_add_full_with_engine_and_name(..., name)`.

Mirror the signature change in `native/worker/worker.zh` if present.

> **Backward-compat:** Pass `""` (empty string) where existing callers don't have a name. The `_with_name` helper from Task 1 short-circuits on `name[0] == 0`, so empty stays empty.

- [ ] **Step 2.2: Update callers within worker.zc**

Grep for `zapp_start_headless_worker_full(` within the file. Any internal call that wasn't going through codegen needs the trailing `, ""` added.

```bash
grep -n "zapp_start_headless_worker_full(" /Users/zach/code/zapp/native/worker/worker.zc
```

Add `, ""` to each call.

- [ ] **Step 2.3: Build verify**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
```

Expected: build fails because `cli/src/build-config.ts` codegen still emits the 5-arg form. **This is expected** — we'll fix in Task 3.

Confirm the failure is the expected "too few arguments to function" / wrong-arity error referencing `zapp_start_headless_worker_full`. If it's a different error, investigate.

- [ ] **Step 2.4: Commit (intentional broken state)**

```bash
git add native/worker/worker.zc native/worker/worker.zh
git commit -m "$(cat <<'EOF'
feat(worker): thread name through zapp_start_headless_worker_full

Adds trailing const char* name param. Internal callers pass "" (empty).
Codegen update lands in next commit — build is briefly broken in between
on purpose so the codegen change is its own small reviewable diff.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: CLI config + codegen — `name` field

**Files:**
- Modify: `cli/src/config.ts` (HeadlessWorkerConfig type)
- Modify: `cli/src/build-config.ts:131-185` (generateHeadlessWorkers)

- [ ] **Step 3.1: Add `name` to `HeadlessWorkerConfig`**

In `cli/src/config.ts`, find the `HeadlessWorkerConfig` interface (or the inline shape in the object-form headless map). Add:

```ts
export interface HeadlessWorkerConfig {
  script: string;
  engine?: WorkerEngine;
  name?: string;             // NEW — display-only label for logs + Workers.list()
  bytecode?: boolean;
  shared?: boolean;
  restart?: { maxRetries?: number; withinMs?: number } | false;
  // ... preserve any other existing fields ...
}
```

If the type is duplicated inline inside `generateHeadlessWorkers` opts (per the explore report at lines 131-139), add `name?: string` there too.

- [ ] **Step 3.2: Emit `name` in codegen**

In `cli/src/build-config.ts`, find the entries map around line 145-170. Replace the `zapp_start_headless_worker_full(...)` emit line with a 6-arg form, escaping the name string:

```ts
const name = typeof value === "string" ? "" : (value.name ?? "");
const escapedName = name.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
// ...
return `    zapp_start_headless_worker_full("h-${id}", "${url}", ${engineId}, ${max}, ${within}, "${escapedName}");`;
```

For the `typeof value === "string"` branch (lines ~149-152), update too — those go through `zapp_start_headless_worker(...)` (the 2-arg form), which doesn't take a name. Leave that branch alone unless the worker.zc shim routes both through the same path. If unsure, grep:

```bash
grep -n "zapp_start_headless_worker(" /Users/zach/code/zapp/native/worker/worker.zc
```

If `zapp_start_headless_worker` delegates to `_full`, it must now pass `""` for name in its delegation. Apply same `, ""` fix as Task 2.2.

- [ ] **Step 3.3: Build verify**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
```

Expected: last line `[zapp] build complete: <path>`. Build that failed in Task 2.3 now succeeds.

Then run the binary to confirm it still launches (no semantic regression):

```bash
cd /Users/zach/code/zapp/hello-world
bun run dev
```

Expected: app window opens, headless workers spawn normally (look for existing `[zapp]` log lines about supervised + ticker), no crash.

`Ctrl+C` to stop.

- [ ] **Step 3.4: Commit**

```bash
git add cli/src/config.ts cli/src/build-config.ts
git commit -m "$(cat <<'EOF'
feat(cli): plumb optional name through HeadlessWorkerConfig

Adds name?: string to HeadlessWorkerConfig; codegen emits it as the 6th
arg to zapp_start_headless_worker_full(). Closes the broken-arity build
state from the previous commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Router IPC — `__zapp:workers-list` route

**Files:**
- Modify: `native/app/router.zc:21-128` (route dispatcher)

- [ ] **Step 4.1: Add route prefix dispatch**

In `native/app/router.zc`, locate the route-prefix block around lines 21-52 (where `__dialog:`, `__notif:`, `__clipboard:`, `__shortcuts:` are wired up). Add a new branch for `__zapp:`:

```c
if (startswith(parsed.method, "__zapp:")) {
    return router_handle_zapp(window_id, parsed);
}
```

Place it alongside the other prefix dispatchers.

- [ ] **Step 4.2: Implement `router_handle_zapp`**

Add the handler function. The shape mirrors `__protocol:respond` (router.zc:58-91) — synchronous compute + `dispatch_invoke_response`:

```c
static int router_handle_zapp(int window_id, ParsedInvoke parsed) {
    if (strcmp(parsed.method, "__zapp:workers-list") == 0) {
        char* json = zapp_workers_registry_list_json();
        if (!json) {
            dispatch_invoke_response(window_id, parsed.request_id, false, "\"alloc-failed\"");
            return 1;
        }
        dispatch_invoke_response(window_id, parsed.request_id, true, json);
        free(json);
        return 1;
    }
    // Unknown __zapp:* method
    dispatch_invoke_response(window_id, parsed.request_id, false, "\"unknown-zapp-method\"");
    return 1;
}
```

Forward-declare or include `zapp_workers_registry_list_json()` from the registry header at the top of router.zc.

- [ ] **Step 4.3: Build verify**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
```

Expected: last line `[zapp] build complete: <path>`. Fresh mtime on binary.

- [ ] **Step 4.4: Commit**

```bash
git add native/app/router.zc
git commit -m "$(cat <<'EOF'
feat(router): __zapp:workers-list IPC route

Webview-context Workers.list() goes through this route. Calls
zapp_workers_registry_list_json() and returns via dispatch_invoke_response.
Mirrors the __protocol:respond fire-and-forget shape.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: zjs host object — `__zappBridge.listWorkers`

**Files:**
- Modify: `native/worker/engines/zjs.c` (locate the bridge-setup region near worker bootstrap)

- [ ] **Step 5.1: Find existing host function registration pattern**

```bash
grep -n "set_global\|__zappBridge\|invokeService\|host_function" /Users/zach/code/zapp/native/worker/engines/zjs.c | head -30
```

The zjs host objects are registered alongside `invokeService`, `postToWebview`, `dispatchEventToAll` etc. Find the block that registers these (likely a single function per worker init). The pattern uses `ZjsValue` / `zjs_new_object` / `zjs_set_property` style APIs.

- [ ] **Step 5.2: Add the `listWorkers` host function**

Add a static C function adjacent to the other `zjs_host_*` handlers:

```c
static ZjsValue zjs_host_list_workers(ZjsContext* ctx, ZjsValue thisVal, int argc, ZjsValue* argv) {
    char* json = zapp_workers_registry_list_json();
    if (!json) {
        return zjs_new_array(ctx, 0);
    }
    // Re-use zjs's own JSON.parse — host returns a JS array of objects.
    ZjsValue result = zjs_json_parse(ctx, json);
    free(json);
    return result;
}
```

> **Note on `zjs_json_parse`:** if the zjs engine exposes a JSON parser as a host helper, use it. If not, the simpler path is to keep emitting JSON and have the runtime wrapper `JSON.parse` it — but that wastes the zjs perf wedge. Check `vendor/zjs/include/zjs.h` for `zjs_json_parse` or equivalent. If it doesn't exist, fall back to: return the JSON as a `ZjsValue` string, and in `runtime/worker.ts` do `JSON.parse(await bridge.listWorkers())`. **Document the chosen path in the commit message.**

Register it where the other bridge methods are registered (look for `zjs_set_property(ctx, bridge, "invokeService", ...)` or similar):

```c
zjs_set_property(ctx, bridge, "listWorkers",
    zjs_new_function(ctx, zjs_host_list_workers, "listWorkers"));
```

- [ ] **Step 5.3: Build verify**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
```

Expected: last line `[zapp] build complete: <path>`. Fresh mtime.

- [ ] **Step 5.4: Commit**

```bash
git add native/worker/engines/zjs.c
git commit -m "$(cat <<'EOF'
feat(zjs): __zappBridge.listWorkers host function

Worker-context Workers.list() on zjs goes through this host function —
calls zapp_workers_registry_list_json() and returns the parsed JS array
directly (or returns the JSON string when zjs_json_parse is unavailable;
runtime wrapper handles either shape).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: bare host object — `__zappBridge.listWorkers`

**Files:**
- Modify: `native/worker/engines/bare.c` (NAPI host registration region near line 500-560)

- [ ] **Step 6.1: Find existing NAPI host function registration**

```bash
grep -n "napi_create_function\|napi_set_named_property.*invokeService\|bare_host_" /Users/zach/code/zapp/native/worker/engines/bare.c | head -20
```

The NAPI pattern from explore (lines 500-560) uses `js_get_callback_info` / `js_create_string_utf8`. Find the registration site where `invokeService` is added to the bridge object.

- [ ] **Step 6.2: Add `bare_host_list_workers` callback**

Adjacent to `bare_host_invoke_service`:

```c
static js_value_t* bare_host_list_workers(js_env_t* env, js_callback_info_t* info) {
    char* json = zapp_workers_registry_list_json();
    if (!json) {
        js_value_t* empty;
        js_create_array(env, &empty);
        return empty;
    }
    // Use NAPI's JSON.parse equivalent — call global JSON.parse via js_call_function.
    js_value_t* global;
    js_value_t* json_obj;
    js_value_t* parse_fn;
    js_value_t* json_str;
    js_value_t* result;
    js_get_global(env, &global);
    js_get_named_property(env, global, "JSON", &json_obj);
    js_get_named_property(env, json_obj, "parse", &parse_fn);
    js_create_string_utf8(env, json, NAPI_AUTO_LENGTH, &json_str);
    js_value_t* args[] = { json_str };
    js_call_function(env, json_obj, parse_fn, 1, args, &result);
    free(json);
    return result;
}
```

Register it:

```c
js_value_t* list_workers_fn;
js_create_function(env, "listWorkers", NAPI_AUTO_LENGTH, bare_host_list_workers, NULL, &list_workers_fn);
js_set_named_property(env, bridge, "listWorkers", list_workers_fn);
```

Place this registration where `invokeService` / `postToWebview` / etc. are registered (one of the bare bootstrap functions, likely called per-worker).

- [ ] **Step 6.3: Build verify (bare)**

The default build is zjs-only. To verify bare compiles, temporarily switch hello-world to bare-jsc:

```bash
# Manual edit: hello-world/zapp.config.ts — change `engine: "zjs"` to `engine: "bare-jsc"` on one worker
cd /Users/zach/code/zapp/hello-world
bun run build
```

Expected: last line `[zapp] build complete: <path>`. Fresh mtime.

**Revert the engine change before committing** (this was a build-time validation only).

- [ ] **Step 6.4: Commit**

```bash
git add native/worker/engines/bare.c
git commit -m "$(cat <<'EOF'
feat(bare): __zappBridge.listWorkers NAPI host function

Worker-context Workers.list() on bare-* engines goes through this host
function — calls zapp_workers_registry_list_json() and parses via global
JSON.parse. Shared across all 5 bare engines (single bare.c).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Runtime `Workers.list()` + bootstrap

**Files:**
- Modify: `runtime/worker.ts:191-261` (Workers namespace)
- Modify: `bootstrap/webview.ts:35-66, 140-146` (invoke + createWorker)

- [ ] **Step 7.1: Add `WorkerInfo` type + `Workers.list()` in runtime**

In `runtime/worker.ts`, before the `Workers` namespace export, add:

```ts
export interface WorkerInfo {
  id: string;
  name?: string;
  scriptUrl: string;
  engine: "zjs" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes";
  shared: boolean;
  owners: string[];
  supervisor?: {
    maxRetries: number;
    withinMs: number;
    failCount: number;
    gaveUp: boolean;
  };
}
```

Add `list()` to the `Workers` namespace (lines 191-261):

```ts
export const Workers = {
  terminate(id: string): void { /* existing */ },
  postMessage(targetId: string, data: unknown): void { /* existing */ },
  send(targetId: string, channel: string, data: unknown): void { /* existing */ },

  async list(): Promise<WorkerInfo[]> {
    const bridge = getBridge() as any;
    const result = await bridge.listWorkers();
    // Both paths return either a parsed array or a JSON string (bare/zjs may
    // differ depending on whether the host parsed). Normalize.
    if (typeof result === "string") return JSON.parse(result) as WorkerInfo[];
    return result as WorkerInfo[];
  },
};
```

- [ ] **Step 7.2: Widen `new Worker(url, opts)` to accept `name`**

Find the `Worker` class declaration in `runtime/worker.ts` (search for `class Worker` or `constructor(url`). Update the constructor signature to accept `name`:

```ts
constructor(url: string, opts?: { shared?: boolean; name?: string }) {
  // existing body — thread opts.name into the createWorker call
  const bridge = getBridge() as any;
  this.id = bridge.createWorker(url, { engine: opts?.engine, name: opts?.name });
  // ...
}
```

(Adjust the actual code to match the existing constructor shape — the explore report shows `createWorker(scriptUrl, opts?: { engine?: string })` is the bridge method, so widen that signature too in the type declaration.)

- [ ] **Step 7.3: Wire `bridge.listWorkers` in webview bootstrap**

In `bootstrap/webview.ts`, near the existing invoke definitions around line 35-66, add:

```ts
bridge.listWorkers = () => invoke("__zapp:workers-list", null);
```

Place it next to other bridge methods that are set on the same object.

- [ ] **Step 7.4: Thread `name` through `createWorker` message**

In `bootstrap/webview.ts:140-146`, widen the `createWorker` definition:

```ts
createWorker(scriptUrl: string, opts?: { engine?: string; name?: string }): string {
  const id = "w-" + nextId++;
  if (nextId > 65535) nextId = 1;
  bridge._workers[id] = { onmessage: null, _messageHandlers: [] };
  post(JSON.stringify({
    t: 5,
    m: "create",
    a: { scriptUrl, workerId: id, engine: opts?.engine, name: opts?.name }
  }));
  return id;
},
```

Then update the native side that handles `t: 5, m: "create"` to read `a.name` and pass it to the worker-creation function. Grep for the dispatch handler:

```bash
grep -rn "\"create\"" /Users/zach/code/zapp/native/bridge/dispatch.zc /Users/zach/code/zapp/native/worker/
```

Thread `name` into whichever native function creates a worker from a webview request. If that function calls into `zapp_worker_registry_add_full_with_engine`, swap to the `_with_name` variant.

- [ ] **Step 7.5: Build verify**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
```

Expected: last line `[zapp] build complete: <path>`. Fresh mtime.

- [ ] **Step 7.6: Smoke test — `Workers.list()` from webview**

```bash
cd /Users/zach/code/zapp/hello-world
bun run dev
```

Open the dev console in the app window. Run:

```js
await Workers.list()
```

Expected: an array with at least `h-supervised` (supervisor populated: maxRetries: 2, withinMs: 30000, failCount: 0, gaveUp: false) and `h-ticker` (no supervisor field).

`Ctrl+C` to stop.

- [ ] **Step 7.7: Commit**

```bash
git add runtime/worker.ts bootstrap/webview.ts native/bridge/dispatch.zc
git commit -m "$(cat <<'EOF'
feat(workers): Workers.list() runtime API + bootstrap wiring

Adds the public Workers.list() method, WorkerInfo type, and the optional
name plumbing for new Worker(url, { name }). Webview bridge round-trips
through __zapp:workers-list; worker-context uses the per-engine host
object registered in Tasks 5+6.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Compact log format — `[zapp/<name>] ...` sweep

**Files:**
- Modify: `native/worker/engines/zjs.c` (~3 log sites with worker_id context)
- Modify: `native/worker/engines/bare.c` (~3 log sites with worker_id context)
- Modify: `native/worker/worker.zc` (~2-3 log sites)
- Modify: `native/worker/registry.zc` (supervisor restart log if it lives here)

- [ ] **Step 8.1: Identify per-worker log sites**

```bash
grep -n 'fprintf.*\[zapp\].*%s' /Users/zach/code/zapp/native/worker/engines/zjs.c
grep -n 'fprintf.*\[zapp\].*%s' /Users/zach/code/zapp/native/worker/engines/bare.c
grep -n 'fprintf.*\[zapp\].*%s' /Users/zach/code/zapp/native/worker/worker.zc
```

For each match, check if it has `worker_id` in the format args. Those are the targets. App-level logs that don't reference a worker stay flat `[zapp] ...`.

Per the explore report, the key restart log lines are:
- `native/worker/engines/zjs.c:1521` — `"[zapp] zjs worker '%s' restarting (incarnation %d, fail_count %d/%d in %dms window)\n"`
- `native/worker/engines/bare.c:1768` — `"[zapp] bare worker '%s' restarting (incarnation %d, fail_count %d/%d in %dms window)\n"`
- `native/worker/engines/bare.c:1599` — `"[zapp] bare worker created: %s\n"`

- [ ] **Step 8.2: Add a compact time formatter helper**

In `native/worker/registry.zc` (alongside `get_display_name`):

```c
// Returns a short static buffer per call — not thread-safe; called from log paths only.
const char* zapp_fmt_compact_ms(int ms) {
    static char buf[32];
    if (ms < 1000) {
        snprintf(buf, sizeof(buf), "%dms", ms);
    } else {
        int s = ms / 1000;
        int frac = (ms % 1000) / 100;
        if (frac == 0) snprintf(buf, sizeof(buf), "%ds", s);
        else snprintf(buf, sizeof(buf), "%d.%ds", s, frac);
    }
    return buf;
}
```

Mirror in the `.zh` header.

> **Thread-safety note:** the static buffer is fine because all log calls happen from one of (main thread, worker thread holding its own loop) and the helper return value is consumed immediately by `fprintf`. If anything ever calls this from two places in the same `fprintf` arg list, that would be a bug — flag it in review.

- [ ] **Step 8.3: Rewrite zjs restart log**

In `native/worker/engines/zjs.c:1521`, replace:

```c
fprintf(stderr, "[zapp] zjs worker '%s' restarting (incarnation %d, fail_count %d/%d in %dms window)\n",
    worker_id, incarnation, fail_count, restart_max, restart_window_ms);
```

with:

```c
fprintf(stderr, "[zapp/%s] restart %d (fail %d/%d in %s)\n",
    zapp_worker_registry_get_display_name(worker_id),
    incarnation, fail_count, restart_max,
    zapp_fmt_compact_ms(restart_window_ms));
```

- [ ] **Step 8.4: Rewrite bare logs**

In `native/worker/engines/bare.c:1768` (restart):

```c
fprintf(stderr, "[zapp/%s] restart %d (fail %d/%d in %s)\n",
    zapp_worker_registry_get_display_name(worker_id),
    incarnation, fail_count, restart_max,
    zapp_fmt_compact_ms(restart_window_ms));
```

In `native/worker/engines/bare.c:1599`:

```c
fprintf(stderr, "[zapp/%s] created\n",
    zapp_worker_registry_get_display_name(slot->worker_id));
```

> **Note on the `[bare:%s]` helper at line 496:** that's a separate logging path used by the bare engine internals (script stderr capture). Leave it alone — it's not the worker-lifecycle prefix this spec targets.

- [ ] **Step 8.5: Rewrite worker.zc lifecycle logs**

```bash
grep -n 'fprintf.*\[zapp\]' /Users/zach/code/zapp/native/worker/worker.zc
```

For each match that has a `worker_id` variable in scope, swap to the `[zapp/%s] ...` prefix using `zapp_worker_registry_get_display_name(worker_id)`.

Per the explore report there's also an engine-fallback downgrade log around line 121-123 — keep that one flat `[zapp] ...` if it fires before the worker is in the registry (no display name available yet).

- [ ] **Step 8.6: Add includes**

Wherever you call `zapp_worker_registry_get_display_name` or `zapp_fmt_compact_ms`, ensure `#include "registry.zh"` is at the top of that file (or the appropriate forward declaration is present).

- [ ] **Step 8.7: Build verify**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
```

Expected: last line `[zapp] build complete: <path>`. Fresh mtime.

- [ ] **Step 8.8: Smoke — verify new log format**

```bash
cd /Users/zach/code/zapp/hello-world
bun run dev
```

Watch the terminal output. Expected:
- `[zapp/h-ticker] ...` instead of `[zapp] ... 'h-ticker' ...`
- `[zapp/h-supervised] ...` instead of `[zapp] ... 'h-supervised' ...`
- App-level lines still `[zapp] ...` (e.g., `[zapp] initializing app...`).

Click the "Force crash" supervisor button in the app. Expected log line:
```
[zapp/h-supervised] restart 1 (fail 1/2 in 30s)
```

`Ctrl+C` to stop.

- [ ] **Step 8.9: Commit**

```bash
git add native/worker/registry.zc native/worker/registry.zh native/worker/engines/zjs.c native/worker/engines/bare.c native/worker/worker.zc
git commit -m "$(cat <<'EOF'
refactor(logs): compact [zapp/<display-name>] prefix for per-worker logs

App-level logs stay [zapp] ...; per-worker lifecycle/restart/create logs
move to [zapp/<name-or-id>] ... format. Uses display-name helper from
registry (prefers config name, falls back to worker_id). Adds compact-ms
time formatter (30000ms -> 30s).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: hello-world — `name` smoke + "Show workers" UI

**Files:**
- Modify: `hello-world/zapp.config.ts:42-77` (add name to supervised)
- Modify: `hello-world/src/main.ts:152-159` (Workers section)

- [ ] **Step 9.1: Add `name` to hello-world supervised config**

In `hello-world/zapp.config.ts`, locate the `supervised` headless entry:

```ts
supervised: {
  script: "src/workers/supervised.ts",
  name: "sync-engine",          // NEW — smoke validation
  restart: { maxRetries: 2, withinMs: 30_000 },
  engine: "zjs",
},
```

- [ ] **Step 9.2: Add "Show workers" button to main.ts**

In `hello-world/src/main.ts`, find the Workers section (lines 152-159). Add a button:

```html
<section>
  <h2>Workers</h2>
  <button id="btn-worker-create">Create Worker</button>
  <button id="btn-worker-ping">Send Ping</button>
  <button id="btn-worker-service">Invoke Service</button>
  <button id="btn-worker-terminate">Terminate</button>
  <button id="btn-worker-terminate-by-id">Workers.terminate("h-supervised")</button>
  <button id="btn-workers-list">Show workers</button>
  <div id="worker-result" class="result"></div>
</section>
```

Then in the event-wiring section (search for `btn-worker-create` to find the pattern):

```ts
document.querySelector<HTMLButtonElement>("#btn-workers-list")?.addEventListener("click", async () => {
  const list = await Workers.list();
  const result = document.querySelector<HTMLDivElement>("#worker-result");
  if (result) result.textContent = JSON.stringify(list, null, 2);
});
```

Ensure `Workers` is imported at the top of `main.ts` (search for existing `import.*Workers` — if not present, add `import { Workers } from "@zappdev/runtime/worker";`).

- [ ] **Step 9.3: Build + smoke**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
bun run dev
```

Expected:
1. Build last line `[zapp] build complete: <path>`.
2. App launches with new "Show workers" button.
3. Click "Show workers" — result div shows pretty-printed JSON with:
   - `h-supervised` entry has `"name": "sync-engine"` and a `"supervisor"` block.
   - `h-ticker` entry has no `name` field and no `supervisor` block.
4. Log lines in terminal show `[zapp/sync-engine] ready` (or equivalent lifecycle log).
5. Click "Force crash" supervisor button — log shows `[zapp/sync-engine] restart 1 (fail 1/2 in 30s)`.

If any of those fail, debug before committing.

`Ctrl+C` to stop.

- [ ] **Step 9.4: Commit**

```bash
git add hello-world/zapp.config.ts hello-world/src/main.ts
git commit -m "$(cat <<'EOF'
feat(hello-world): Workers.list() smoke UI + name validation

Adds name: "sync-engine" to supervised headless entry so the new compact
log format + Workers.list() name field are exercised end-to-end. New
"Show workers" button pretty-prints the registry snapshot.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: bare-jsc cross-engine smoke (verification only — no commit)

- [ ] **Step 10.1: Temporarily switch supervised to bare-jsc**

Edit `hello-world/zapp.config.ts` — change supervised's `engine: "zjs"` to `engine: "bare-jsc"`. Keep the `name: "sync-engine"`. Make sure `bare-jsc` is in the `engines` array if hello-world has one.

- [ ] **Step 10.2: Build + smoke**

```bash
cd /Users/zach/code/zapp/hello-world
bun run build
bun run dev
```

Expected: same Workers.list() output, but supervised's `engine` field is now `"bare-jsc"`. "Show workers" still works.

- [ ] **Step 10.3: Revert config**

```bash
git checkout hello-world/zapp.config.ts
```

(Revert to the `zjs` + `sync-engine` state from Task 9 — don't commit the temporary bare-jsc switch.)

> **Other bare-* engines** (v8, quickjs, mqjs, hermes) deferred to manual followup per spec — if any are trivial to swap, optionally repeat 10.1-10.3 for them.

---

## Self-Review

### Spec coverage

| Spec section | Implementing task(s) |
|---|---|
| Public API: `WorkerInfo` interface | Task 7 (Step 7.1) |
| Public API: `Workers.list()` | Task 7 (Step 7.1) |
| Public API: `new Worker(url, { name })` | Task 7 (Step 7.2) |
| Public API: `HeadlessWorkerConfig.name` | Task 3 (Step 3.1) |
| Architecture: registry single source of truth | Task 1 (Steps 1.1-1.4) |
| Architecture: per-engine host object (zjs) | Task 5 |
| Architecture: per-engine host object (bare) | Task 6 |
| Architecture: webview IPC route | Task 4 |
| Architecture: runtime wrapper shape | Task 7 (Step 7.1) |
| Log format: `[zapp/<display-name>] ...` | Task 8 |
| Log format: app-level stays `[zapp] ...` | Task 8 (Step 8.5 guidance) |
| Log format: compact ms→s formatter | Task 8 (Step 8.2) |
| Native: `ZappWorkerEntry.name` | Task 1 (Step 1.1) |
| Native: `_with_name` constructors | Task 1 (Step 1.2) |
| Native: `get_display_name` helper | Task 1 (Step 1.3) |
| Native: `zapp_workers_registry_list_json` | Task 1 (Step 1.4) |
| Codegen: `name` arg into `zapp_start_headless_worker_full` | Tasks 2 + 3 |
| Verification: build + manual smoke | Tasks 7 (7.6), 8 (8.8), 9 (9.3), 10 |
| Cross-engine smoke (bare-jsc) | Task 10 |

All spec sections covered.

### Placeholder scan

- `cli/src/config.ts` Step 3.1 says "preserve any other existing fields" — that's a deliberate "the engineer sees what's there and keeps it" instruction, not a placeholder. Acceptable.
- Step 5.2 has a fallback path documented for `zjs_json_parse` not existing — that's a discovered-during-implementation branch, with explicit instructions for both outcomes. Acceptable.
- No `TBD`/`TODO`/"add validation" patterns found.

### Type consistency

- `WorkerInfo.engine` union in Task 7 matches the engine-string mapping in Task 1.4 (`zjs`, `bare-jsc`, `bare-v8`, `bare-quickjs`, `bare-mqjs`, `bare-hermes`). ✓
- `WorkerInfo.supervisor` field shape in Task 7 matches JSON shape emitted in Task 1.4 (`maxRetries`, `withinMs`, `failCount`, `gaveUp`). ✓
- `HeadlessWorkerConfig.name` is `string` (optional), `ZappWorkerEntry.name` is `char[64]`. Truncation to 63 chars in Task 1.2 — acceptable since this is a display label, not a key.
- `zapp_workers_registry_list_json()` referenced consistently in Tasks 1, 4, 5, 6.
- `zapp_worker_registry_get_display_name()` referenced consistently in Tasks 1, 8.
- `zapp_fmt_compact_ms()` defined in Task 8.2, used in 8.3, 8.4.

No drift.

---

## Plan complete and saved to `docs/superpowers/plans/2026-06-02-workers-list.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review (spec compliance + code quality) between tasks, fast iteration. Best for this plan because tasks 5/6 have a discovery branch (zjs_json_parse availability) that a focused implementer will resolve cleanly.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints. Lower coordination overhead but I keep the implementation context.

Which approach?
