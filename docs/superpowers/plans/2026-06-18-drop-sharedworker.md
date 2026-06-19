# Drop the Zapp SharedWorker API — Implementation Plan

> **For agentic workers:** executed in-session, task-by-task, build/test-gated. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Remove the Zapp `SharedWorker`/`SharedWorkerPort` runtime API and all its native refcount machinery. `SharedWorker` becomes web-native-only (WKWebView's own, Safari/WebKit 16+); Zapp's shared-background path is **headless** + the `Workers` namespace.

**Why:** A Zapp `SharedWorker` (refcounted-across-windows engine worker) is a second, weaker way to do what headless already does better (stable name, supervised, app-scoped, backend-reachable). One blessed path; smaller surface; one less thing to carry through the Nim migration.

**Dependency finding (verified):** `SharedWorker` is self-contained. Dedicated workers use the single `owners[0]`; headless use empty-owner. The multi-owner `owners[1..N]` refcount + `find_shared`/`add_owner`/`remove_owner` + the `is_shared` broadcast branch are SharedWorker-exclusive. No dedicated/headless path breaks.

**Scope decision:** Remove the API + the dead refcount *functions* + the shared code *paths*. KEEP the registry struct fields (`owners[]`, `owner_count`, `shared`) + `WorkerInfo.shared` (now always `false`) as a low-risk vestige — a deeper struct-shape cleanup (dedicated delivery relies on `owners[0]`) is a separate follow-up, not this change.

**Parity:** zc and nim native layers move in lockstep (Task 2 ↔ Task 3 mirror exactly). Final cross-impl review.

**Tech Stack:** TS (runtime/bootstrap/cli/vite), Zen-C, Nim.

---

### Task 1: TS/JS layer

**Files:** `runtime/worker.ts`, `runtime/index.ts`, `bootstrap/webview.ts`, `cli/src/workers.ts`, `cli/src/workers.test.ts`, `vite/src/index.ts`

- [ ] Delete `SharedWorker` + `SharedWorkerPort` classes from `runtime/worker.ts`. In `Workers.terminate`, drop the now-moot `sw-N` doc/no-op note (keep terminate working for `w-`/`h-`). Keep `Worker`, `Workers`, `WorkerInfo` (leave `WorkerInfo.shared` field — always false now).
- [ ] Remove `SharedWorker, SharedWorkerPort` from `runtime/index.ts` exports.
- [ ] `bootstrap/webview.ts`: delete `createSharedWorker` + `disconnectSharedWorker` bridge methods; in the `pagehide` cleanup, drop the `sw-*` branch → always `terminateWorker(id)`. Keep `_workers`, `createWorker`, `_onWorkerMessage`.
- [ ] `cli/src/workers.ts`: drop `SharedWorker|` from the `new (Worker|SharedWorker)(` regex → just `Worker`. `cli/src/workers.test.ts`: delete the SharedWorker test case.
- [ ] `vite/src/index.ts`: drop `SharedWorker|` from its worker-detection regex.
- [ ] Gate: `bun run check` (tsc clean) + `cd cli && bun test src` (pass). Commit `chore(workers): drop the Zapp SharedWorker runtime API (web-native only; headless is the shared path)`.

---

### Task 2: Native Zen-C

**Files:** `native/worker/registry.zc`, `native/worker/worker.zc`, `native/app/router.zc`, `native/app/app.zc`

- [ ] `registry.zc`: delete `zapp_worker_registry_find_shared`, `add_owner`, `remove_owner`. Keep `add`, `add_full_with_engine_and_name`, `owner` accessor, `list_json` (leave `"shared"` serialization — always 0). Remove `is_shared` only if no callers remain after this task.
- [ ] `router.zc`: delete the shared-worker create path (find-by-url + add_owner; new-shared create), the `is_shared` extraction from the bridge message, and the `disconnect` action handler. Simplify the `terminate` action to always terminate (drop the `is_shared` no-op). Dedicated create path unchanged (`shared=0`).
- [ ] `app.zc` (+ `worker.zc`): in `worker_dispatch_to_webview`, remove the `is_shared` broadcast branch (the `owners[]` loop); always use the single-owner path. **MUST preserve** the headless behavior: empty `owner_id` → delivery rejected (unchanged).
- [ ] `worker.zc`: simplify `Workers::terminate` (drop the `sw-*` no-op).
- [ ] Gate: `cd kitchen-sink && bun run build` → `[zapp] build complete:`. Commit `chore(workers/zc): remove shared-worker refcount paths`.

---

### Task 3: Native Nim (mirror of Task 2)

**Files:** `native/nim/registry.nim`, `native/nim/worker.nim`, `native/nim/router.nim`

- [ ] Mirror Task 2 exactly: delete `find_shared`/`add_owner`/`remove_owner` importc+procs in `registry.nim`; remove the shared create/disconnect/`is_shared` paths in `router.nim`; remove the `is_shared` broadcast branch in `worker.nim`'s dispatch (keep the single-owner path + empty-owner headless rejection at `worker.nim:174-177`).
- [ ] Gate: `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`. Commit `chore(workers/nim): remove shared-worker refcount paths (zc parity)`.

---

### Task 4: Docs + final gate + cross-impl review

**Files:** `docs/api-reference.md`, `runtime/README.md`, `hello-world/README.md`

- [ ] Remove the `new SharedWorker()` section from `docs/api-reference.md` + the `Workers.terminate` `sw-*` note; add a one-line note that `SharedWorker` is the web-native API (use headless for shared background). Remove `SharedWorker`/`SharedWorkerPort` from `runtime/README.md` + `hello-world/README.md` import examples.
- [ ] Confirm no remaining non-generated references: `grep -rn "SharedWorker\|createSharedWorker\|find_shared\|add_owner\|remove_owner" runtime/ bootstrap/ cli/src/ native/ docs/ --include=*.ts --include=*.zc --include=*.nim --include=*.md` is clean (ignore `.zapp/` generated + node_modules + historical specs/plans).
- [ ] Full gate: nim build + zc build (`[zapp] build complete:`), `bun run check`, `cd cli && bun test src`, `cd native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/wm tests/windowmanager_test.nim`.
- [ ] Final cross-impl review (zc ↔ nim parity: identical paths removed, identical delivery behavior). Commit `docs: SharedWorker is web-native; headless is the Zapp shared path`.

---

## Self-review notes
- **Headless delivery is the load-bearing invariant** — after removing the `is_shared` branch, the single-owner path must still reject delivery for empty-owner (headless). Verified pre-change at app.zc:273 / worker.nim:174-177; re-verify each native build.
- **Parity is the #1 risk** — Task 2 and 3 must remove the *same* paths; the final review exists to catch drift (the project's proven failure mode).
- **Vestige left on purpose** — registry `owners[]`/`shared` struct + `WorkerInfo.shared` stay (always-false) to avoid a struct-shape refactor that touches dedicated delivery + list_json + the kitchen-sink workers UI; tracked as a follow-up.
- **Out of scope:** `Workers.get(id)` handle (separate additive cycle); the registry struct-shape cleanup.
