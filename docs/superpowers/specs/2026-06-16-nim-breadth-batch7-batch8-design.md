# Nim Migration — Batches 7 (worker subsystem) & 8 (native-chrome) — Design + Decision

**Status:** Design (2026-06-16, overnight autonomous run). **Branch:** `feat/nim-native`.
Maps from two deep exploration passes. B6 complete (9 leaves). This covers the
last two breadth batches before iOS/Windows parity + the single `main` merge.

## B8 — native-chrome (sidebar / inspector / toolbar / popover) — EXECUTING TONIGHT

**Why B8 first:** mechanical, build-verifiable, follows the proven B6 recipe
(compile `.m`, delete zapp.nim stubs, wire t:4 routes). `window.nim` already
carries every chrome opt (`wopts_sidebar_*`/`wopts_inspector_*`/`wopts_toolbar_json`
exported), so compiling the chrome `.m` makes window construction build the chrome.

**Scope (tonight):**
- **Compile** `sidebar.m`, `inspector.m`, `toolbar.m`, `popover.m` in the build root
  (`zapp.nim`). **Delete** the 8 TEMP stubs in zapp.nim (`zapp_sidebar_register`/
  `unregister`, `zapp_inspector_register`/`unregister`, `darwin_toolbar_attach`,
  `zapp_toolbar_unregister`, `zapp_toolbar_inject_metrics`, `zapp_popover_unregister_window`)
  — the real `.m` define them; keeping the stubs = duplicate symbol.
  - **Compile order / shared symbols (verified):** `zapp_resolve_icon` is defined ONLY
    in menu.m (B6f, compiled) — toolbar.m `extern`s it (no collision). `zapp_pane_emit`
    is defined in sidebar.m, `extern`'d by inspector.m (linker resolves). No new framework
    (all Cocoa/WebKit, in passL). No `zapp.nim` stub other than the 8 collides.
- **t:4 control routes** in `routeWindowAction` (all ungated — chrome ops aren't in
  `permission_id_for_action`, like window ops):
  - `sidebar:toggle`/`collapse`/`expand`/`setWidth` → `darwin_sidebar_*`. Self-resolve
    the target: `windowId` arg → `darwin_window_numeric_id_for_string`, else the sender
    `windowId`. `setWidth` reads `width`.
  - `inspector:toggle`/`collapse`/`expand`/`setWidth` → `darwin_inspector_*` (identical shape).
  - `toolbar:setItems`/`updateItem`/`remove` → resolve `darwin_window_get_by_numeric_id`
    handle + numeric target, then `darwin_toolbar_set_items(h, toolbarJson, target)` /
    `darwin_toolbar_update_item(h, itemJson)` / `darwin_toolbar_remove(h)`. (Confirm exact
    arg keys against router.zc:921-962 during impl.)
  - `popover:show`/`hide`/`destroy` → `darwin_popover_show(pid, extractArgs(payload), windowId)`
    / `darwin_popover_hide(pid)` / `darwin_popover_destroy(pid)`. Arg `popoverId`. (show passes
    the extracted args subtree — reuse the dialog/menu payload approach.)
- **Accessory-pane sender resolution** (router.zc:484-512) at `routeWindowAction`'s head,
  **ported via darwin helpers** (the Nim build has no `app.window` WindowManager): if
  `darwin_window_get_by_numeric_id(windowId)` is nil (the sender is an accessory pane slot,
  not a real window), remap `windowId` → host via `darwin_window_id_string(windowId)` →
  `darwin_window_numeric_id_for_string`. So window ops + chrome ops invoked from inside a
  sidebar/inspector pane target the host window. Place BEFORE the existing arms.

**Deferred (documented follow-up):**
- **`popover:create`** (router.zc:230-265) — needs `app.window.alloc_slot()`, the zc
  WindowManager's transport-slot allocator, which the Nim build lacks (it has no ported
  WindowManager; windows resolve via `darwin_window_get_by_numeric_id`, and sidebar/inspector
  slots come from window-create opts). Wiring `popover:create` needs a Nim slot allocator
  that won't collide with window.m's dispatch-table indices — really a slice of the
  WindowManager port. So popover show/hide/destroy routes land (correct + linked) but
  popover is not end-to-end functional until create lands. **Follow-up: "Nim window-slot
  allocator / WindowManager port"** (also unblocks any other runtime-slot feature).

**B8 decomposition:** B8a = compile 4 `.m` + delete 8 stubs + accessory-pane sender
resolution (structural; build proves linkage + no dup symbols; chrome constructs).
B8b = the sidebar/inspector/toolbar/popover-show-hide-destroy routes (control).

## B7 — worker subsystem — DECISION REQUIRED (not gambling overnight)

**Why a decision, not code:** B7 is the highest-risk part of the entire migration, and
it hides a genuine architectural fork that materially changes the migration's character.
I will not pick it unilaterally overnight on the one subsystem whose correctness I cannot
build-verify (it's thread + runtime behavior, smoke-only).

**What B7 needs** (un-stub the zapp.nim worker stubs so they do real work): a real worker
**registry** (`Workers.list()` currently returns `"[]"`), worker `post`/`terminate`/
`disconnect` dispatch, worker→webview + worker→worker delivery, the **supervisor**
(restart policy), targeted `worker_eval_js`, and **sync** (`Sync.wait`/`notify`, whose
`sync.m`/`sync.c` aren't compiled in the Nim build yet). Source: `registry.zc` (~520 LOC),
`worker.zc`, `dispatch.zc`, `sync.zc` (+ platform sync).

**The fork:**

- **Approach A — compile the worker-subsystem `.zc` objects into the Nim build** (like the
  engines' `.c` and the platform `.m` are compiled untouched; the perf-gate already
  compiles `zjson_provider.zc` this way). Replace the zapp.nim stubs by linking the real
  `registry.zc`/`worker.zc`/`dispatch.zc`/`sync.zc`. **Pros:** faithful behavior, preserves
  the lock-free static-array registry + exact worker-thread discipline (ZERO thread-risk —
  it's the proven code), build-verifiable. **Cons:** not a Nim port (defers it); the zc
  emits runtime symbols (`alloc_bytes`/`hash_*`/`Arena`/`panic`) that collide if there are
  two zc-emitted TUs — must consolidate into the single existing provider TU, and
  `worker.zc` imports `App` (transitive `app.zc` pull) which may widen the TU. Build-time
  integration risk, not runtime.
- **Approach B — hand-port to idiomatic Nim** (`registry.nim`/`worker.nim`/sync wiring).
  **Pros:** the true migration; consistent with B1–B6. **Cons:** the registry is a
  **lock-free static C array read from worker pthreads** (display-name, supervisor,
  list_json); a naive Nim port (heap `Table`) breaks that discipline. A correct port must
  be `{.gcsafe.}` + POD + libc-malloc (the permissions.nim B3 pattern) across ~520 LOC +
  the supervisor — and its correctness is **runtime/thread-only verifiable** (I can't smoke
  workers overnight; a subtle gcsafe/race bug would ship silently).

**Recommendation: Approach A** (compile the worker `.zc` objects) for parity now, with the
idiomatic-Nim port as a *later, supervised* refactor (behavior-preserving, can be smoke-
tested deliberately). Rationale: the worker registry/dispatcher is low-level plumbing
tightly coupled to the C engines' thread model — keeping it compiled (like the engines
themselves) is defensible, not a cop-out; the Explore verdict independently recommends it;
and it's the only path that's safe to land without runtime supervision. **Open question for
the user:** accept Approach A (compile-zc), or hold B7 for a supervised idiomatic-Nim port?

**Tonight's B7 action:** present this decision; do NOT land a risky unverifiable port. If
Approach A is chosen, B7 is a focused next cycle (consolidate the provider TU + delete the
stubs + compile platform sync + verify build/link); the user smokes Workers.list / worker
post / sync.

## Gates
- B8: build ends `[zapp] build complete:`; all Nim unit tests pass; chrome constructs +
  toggles (human smoke). popover deferred-noted.
- B7: decision pending; no code landed tonight beyond this doc.
