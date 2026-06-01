# Remove legacy `jsc` + `txiki` worker engines — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the deprecated `jsc` and `txiki` worker engines from Zapp's codebase, shrinking the engine taxonomy from 8 strings to 6 (`zjs`, `bare-jsc`, `bare-v8`, `bare-quickjs`, `bare-mqjs`, `bare-hermes`).

**Architecture:** One branch (`chore/remove-legacy-engines`), 4 phased commits. Commit 1 tightens the CLI config schema and adds a config-parse error. Commit 2 deletes the native engine sources and removes router/registry/dispatch branches. Commit 3 deletes the two benchmark apps and sweeps the docs. Commit 4 is the final cleanup audit (dead constants, dead imports, final grep).

**Tech Stack:** TypeScript (CLI, runtime, vite plugin), Zen-C (.zc), C (.c), Objective-C (.m), Markdown (docs). No automated test suite — verification is `bun run build` success + targeted greps + hello-world supervisor demo smoke verification post-merge.

**Spec:** [`docs/superpowers/specs/2026-06-01-remove-legacy-engines-design.md`](../specs/2026-06-01-remove-legacy-engines-design.md)

---

## Task 0: Create the branch

**Files:** none (git only)

- [ ] **Step 1: Confirm starting state**

Run from `/Users/zach/code/zapp`:
```bash
git status --short
git branch --show-current
```
Expected: working tree may have uncommitted vendor submodule pointers (that's fine; we'll stash). Branch should be `main`.

- [ ] **Step 2: Stash any working-tree drift**

If `git status --short` shows any modifications:
```bash
git stash push -u -m "pre-remove-legacy-engines stash $(date +%s)"
```
If empty, skip this step.

- [ ] **Step 3: Create + switch to the working branch**

```bash
git checkout -b chore/remove-legacy-engines
```

Expected: `Switched to a new branch 'chore/remove-legacy-engines'`.

---

## Task 1: Commit 1 — Tighten CLI config schema + add parse-time error

**Goal:** Drop `"jsc"` and `"txiki"` from the engine type union in `cli/src/config.ts` and the mirror in `runtime/worker.ts`. Delete the deprecation-warning machinery. Add a clear config-parse error that fires when a user's `zapp.config.ts` includes either string (catches untyped config loaders or copy-paste).

**Files:**
- Modify: `cli/src/config.ts`
- Modify: `runtime/worker.ts`

- [ ] **Step 1: Read the current engine union in cli/src/config.ts**

```bash
grep -n 'engine?: "jsc"\|engine?:.*jsc\|"jsc" |\| "txiki" |' /Users/zach/code/zapp/cli/src/config.ts | head -5
```

Read the file around lines 318–336 (HeadlessWorkerConfig.engine union) and lines 782–798 (deprecation warning code). Use the Read tool with offset=315 limit=30, then offset=780 limit=25 to confirm exact line numbers — the file may have drifted slightly.

- [ ] **Step 2: Narrow the engine union in cli/src/config.ts**

In the `HeadlessWorkerConfig` discriminated union (around lines 318–336), find the engine declaration. It currently reads something like:

```typescript
engine?: "jsc" | "txiki" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes" | "zjs";
```

Replace with:

```typescript
engine?: "zjs" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes";
```

Order matters for readability: put `zjs` first (default), `bare-jsc` second (macOS JIT), `bare-v8` third (Win/Linux JIT), then the niche `bare-*` entries.

**The same edit may appear in TWO union sites within this file** — the discriminated union has both a `bytecode: true` variant and a default variant. Use `grep -n` to find both:
```bash
grep -n '"jsc" | "txiki"\|"jsc"\s*|\s*"txiki"' /Users/zach/code/zapp/cli/src/config.ts
```
Apply the same narrowing to each match.

- [ ] **Step 3: Replace the deprecation-warning code with a parse-time error**

Find the deprecation warning block (around lines 782–798 per the audit memory). It contains module-scoped `let` flags like `let _legacyJscWarned = false;` plus the warning logic.

Read it first:
```bash
sed -n '775,805p' /Users/zach/code/zapp/cli/src/config.ts
```

Replace the entire warning block with a parse-time validator. The replacement should:
1. Run at config-load time (called from wherever `loadConfig` parses the user's `zapp.config.ts` — search for the call site if not obvious).
2. Iterate `config.headless` and check each entry's `engine` field.
3. Throw if `engine === "jsc"` or `engine === "txiki"`.

Replacement code:

```typescript
// Removed engines — surface a clean error before TypeScript's narrowed
// union catches the mistake at compile time. Catches untyped config
// loaders, JSON-deserialized configs, and the occasional copy-paste
// from old example code or chat-bot output.
function rejectRemovedEngines(config: ZappConfig): void {
  const removed = new Set(["jsc", "txiki"]);
  const headless = config.headless ?? {};
  for (const [id, entry] of Object.entries(headless)) {
    if (typeof entry === "object" && entry !== null && "engine" in entry) {
      const engine = (entry as { engine?: string }).engine;
      if (engine && removed.has(engine)) {
        throw new Error(
          `[zapp] headless worker "${id}" specifies engine: "${engine}", ` +
          `which has been removed. Use "zjs" (cross-platform, default) ` +
          `or "bare-jsc" (macOS JIT). See docs/engines.md.`
        );
      }
    }
  }
}
```

Find the existing function that resolves / validates `config` (likely `resolveConfig` or similar — search for the export pattern). Add a call to `rejectRemovedEngines(config)` near the top of that function, before any other validation. Don't add it inside the wrong function — it must run on the user's parsed config.

If you can't immediately find the right host function, STOP and report BLOCKED with the function names you considered.

- [ ] **Step 4: Narrow the engine union in runtime/worker.ts**

Read `/Users/zach/code/zapp/runtime/worker.ts`. Find the `engine?:` field type on `WorkerOptions` or equivalent (search: `grep -n 'engine\?:' /Users/zach/code/zapp/runtime/worker.ts`). Apply the same narrowing:

Before:
```typescript
engine?: "jsc" | "txiki" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes" | "zjs";
```

After:
```typescript
engine?: "zjs" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes";
```

- [ ] **Step 5: Build verification (hello-world)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
```

Expected LAST line: `[zapp] build complete: /Users/zach/code/zapp/hello-world/bin/hello-world (XXX KB)`. If anything else, STOP and report BLOCKED with the last 20 lines.

Confirm binary mtime is fresh:
```bash
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

- [ ] **Step 6: Negative verification — temporarily flip hello-world to engine: "jsc" and assert the error**

```bash
cd /Users/zach/code/zapp/hello-world && cp zapp.config.ts /tmp/zapp.config.ts.bak
```

Edit `zapp.config.ts`: change the `supervised` entry's `engine: "zjs"` to `engine: "jsc"`. Then build:

```bash
bun run build 2>&1 | grep -i "removed\|engine" | head -5
```

Expected: the error message from Step 3 appears: `headless worker "supervised" specifies engine: "jsc", which has been removed. Use "zjs" ...`.

Restore the config:
```bash
cp /tmp/zapp.config.ts.bak /Users/zach/code/zapp/hello-world/zapp.config.ts && rm /tmp/zapp.config.ts.bak
```

Verify restoration:
```bash
grep 'engine:' zapp.config.ts | head -3
```
Expected: shows `engine: "zjs"`, not `"jsc"`.

If the error did NOT fire, the `rejectRemovedEngines` call wasn't wired into the config-load path. STOP and report BLOCKED.

- [ ] **Step 7: Re-confirm hello-world builds clean post-restore**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3
```
Expected `[zapp] build complete: ...` as the last line.

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/config.ts runtime/worker.ts
git commit -m "$(cat <<'EOF'
refactor(cli): narrow engine union to drop jsc/txiki, add parse-time error

The deprecated jsc and txiki engines are being removed. This commit
prepares the CLI surface:

- HeadlessWorkerConfig.engine union (cli/src/config.ts) and Worker
  options engine (runtime/worker.ts) drop "jsc" and "txiki".
- The deprecation-warning code path (legacy*Warned flags + warning
  text) is replaced with rejectRemovedEngines() — a config-parse
  validator that throws a clear migration error when a user's
  zapp.config.ts still references either engine name.

Native engine sources are still present (they'll go in commit 2);
this commit ensures the CLI surface stops accepting the strings
first, so the native cleanup can proceed without having to also
handle "what if user config still names jsc."
EOF
)"
```

---

## Task 2: Commit 2 — Delete native engine sources + remove router/registry branches

**Goal:** Delete the 6 source files for jsc and txiki. Remove their cases from native router, registry, dispatch, worker.zc, app.zc, app_events.zc, callbacks.zc, json_builder.zc, bare interop. Drop their `#ifdef` blocks from darwin/{shortcuts,sync}.m. Drop their `ZAPP_WORKER_ENGINE_*` defines from native/build.zc and CLI's engine overlay generator.

**Files (delete):**
- `native/worker/engines/jsc.zc`
- `native/worker/engines/jsc.h`
- `native/worker/engines/jsc.m`
- `native/worker/engines/txiki.zc`
- `native/worker/engines/txiki.c`
- `native/worker/engines/txiki.h`

**Files (modify):**
- `native/build.zc`
- `cli/src/build-config.ts`
- `cli/src/native.ts`
- `cli/src/init.ts`
- `cli/src/entitlements.ts`
- `cli/src/paths.ts`
- `native/worker/router.zc`
- `native/worker/registry.zc`
- `native/worker/worker.zc`
- `native/bridge/dispatch.zc`
- `native/bridge/json_builder.zc`
- `native/app/app.zc`
- `native/app/app_events.zc`
- `native/window/callbacks.zc`
- `native/worker/engines/bare.h`
- `native/worker/engines/bare.zc`
- `native/platform/darwin/shortcuts.m`
- `native/platform/darwin/sync.m`
- `bootstrap/codegen.ts`
- `bootstrap/webview.ts`
- `vite/src/index.ts`

- [ ] **Step 1: Pre-flight grep for bare interop dependencies**

```bash
cd /Users/zach/code/zapp
grep -n 'jsc_\|jsc\.h\|txiki_\|txiki\.h' native/worker/engines/bare.c native/worker/engines/bare.h native/worker/engines/bare.zc 2>&1 | head -20
```

Expected: **zero matches** (bare was designed as the modern replacement). If any matches appear, STOP and report BLOCKED with the lines — the spec's Risk #1 needs follow-up before this commit can proceed.

- [ ] **Step 2: Delete the 6 engine source files**

```bash
cd /Users/zach/code/zapp
git rm native/worker/engines/jsc.zc \
       native/worker/engines/jsc.h \
       native/worker/engines/jsc.m \
       native/worker/engines/txiki.zc \
       native/worker/engines/txiki.c \
       native/worker/engines/txiki.h
```

Verify:
```bash
ls native/worker/engines/
```
Expected output includes `bare.c`, `bare.h`, `bare.zc`, `zjs.c`, `zjs.h`, `zjs.zc`, and any test files (`zjs-engine-test.c`, `zjs-cross-eval-test.c` if still present). Should NOT include `jsc.*` or `txiki.*`.

- [ ] **Step 3: Drop the engine defines from native/build.zc**

Read `/Users/zach/code/zapp/native/build.zc` (it's small, ~80 lines). Search for `ZAPP_WORKER_ENGINE_JSC` and `ZAPP_WORKER_ENGINE_TXIKI`:
```bash
grep -n 'ENGINE_JSC\|ENGINE_TXIKI' /Users/zach/code/zapp/native/build.zc
```

For every hit, delete the entire line. These will be `//> macos: cflags: -DZAPP_WORKER_ENGINE_JSC` or similar. Don't touch the `BARE_JSC` defines — those are different (the `bare-jsc` engine ID).

- [ ] **Step 4: Drop the engine overlay generation in cli/src/build-config.ts**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/cli/src/build-config.ts | grep -v 'bare-jsc\|comment\|//' | head -20
```

For each match: read the surrounding ~10 lines of context (`sed -n '<line-10>,<line+10>p'`) and remove the jsc/txiki-specific branches. Common shapes:
- `wanted.has("jsc")` / `wanted.has("txiki")` — remove these conditionals + their consequent blocks.
- An `engines` array literal listing engine name → ID mappings — remove `"jsc"` and `"txiki"` rows.
- A `defaultBareEngine` fallback that includes `"jsc"` or `"txiki"` as the final fallback — replace with `"bare-mqjs"` (last surviving non-bare-default).

Be precise about which lines belong to jsc/txiki and which belong to `bare-jsc` / `bare-quickjs`. `bare-` prefix means it's a `bare-*` engine, KEEP it.

- [ ] **Step 5: Drop engine references in cli/src/native.ts**

```bash
grep -n '"jsc"\|"txiki"' /Users/zach/code/zapp/cli/src/native.ts | head -10
```

For each hit: read context, remove the lines or branches that handle these engines specifically. Common shapes:
- An `engineLibs` map: remove the rows.
- A switch/case on engine name: remove the cases.

- [ ] **Step 6: Drop engine references in cli/src/init.ts**

```bash
grep -n '"jsc"\|"txiki"' /Users/zach/code/zapp/cli/src/init.ts | head -10
```

For each hit, remove cleanly. `init.ts` may contain scaffolding templates that suggest engines; update any suggestions to the surviving 6.

- [ ] **Step 7: Drop engine references in cli/src/entitlements.ts and cli/src/paths.ts**

```bash
grep -n '"jsc"\|"txiki"\|jsc\|txiki' /Users/zach/code/zapp/cli/src/entitlements.ts /Users/zach/code/zapp/cli/src/paths.ts | grep -v 'bare-jsc' | head -10
```

For each hit, evaluate whether the reference is to Zapp's removed engine (delete) or to something else (e.g., `JavaScriptCore.framework` entitlement which is the system framework — KEEP if it's about the framework, not Zapp's engine).

- [ ] **Step 8: Drop the engine cases in native/worker/router.zc**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/native/worker/router.zc | head -20
```

For each hit: read context, remove the `if (engine_id == ENGINE_JSC)` or `case ENGINE_TXIKI:` branches and their bodies. Also remove `extern fn jsc_*` / `extern fn txiki_*` declarations at the top of the file.

- [ ] **Step 9: Drop the engine ID constants in native/worker/registry.zc**

```bash
grep -n 'ENGINE_JSC\|ENGINE_TXIKI\|engine_jsc\|engine_txiki' /Users/zach/code/zapp/native/worker/registry.zc
```

Remove the constant definitions. **CAREFUL with numeric IDs**: if other code uses the numeric values directly (rare but possible), gaps in the enum could matter. Read the surrounding code to confirm whether values are referenced by-number elsewhere.

- [ ] **Step 10: Drop the engine cases in native/worker/worker.zc**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/native/worker/worker.zc | head -20
```

For each hit: remove the per-engine create/dispatch branches. Same shape as router.zc.

- [ ] **Step 11: Drop the engine cases in native/bridge/dispatch.zc and json_builder.zc**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/native/bridge/dispatch.zc /Users/zach/code/zapp/native/bridge/json_builder.zc | head -20
```

Same shape — remove the branches.

- [ ] **Step 12: Drop engine wiring in native/app/{app,app_events}.zc and native/window/callbacks.zc**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/native/app/app.zc /Users/zach/code/zapp/native/app/app_events.zc /Users/zach/code/zapp/native/window/callbacks.zc | head -20
```

For each hit: remove the lines or branches. These may be `#ifdef ZAPP_WORKER_ENGINE_JSC` blocks rather than runtime branches.

- [ ] **Step 13: Drop jsc/txiki interop in native/worker/engines/bare.{h,zc}**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/native/worker/engines/bare.h /Users/zach/code/zapp/native/worker/engines/bare.zc | head -20
```

(Step 1 already pre-flighted bare.c; bare.h/bare.zc may still have residual extern declarations or comments referencing the removed engines.) Remove cleanly.

- [ ] **Step 14: Drop #ifdef blocks in native/platform/darwin/{shortcuts,sync}.m**

```bash
grep -n 'ZAPP_WORKER_ENGINE_JSC\|ZAPP_WORKER_ENGINE_TXIKI' /Users/zach/code/zapp/native/platform/darwin/shortcuts.m /Users/zach/code/zapp/native/platform/darwin/sync.m
```

For each hit: read the surrounding `#ifdef ... #endif` block and remove it entirely. Be precise about the matching `#endif`.

- [ ] **Step 15: Drop engine paths in bootstrap/codegen.ts, bootstrap/webview.ts, vite/src/index.ts**

```bash
grep -n '"jsc"\|"txiki"' /Users/zach/code/zapp/bootstrap/codegen.ts /Users/zach/code/zapp/bootstrap/webview.ts /Users/zach/code/zapp/vite/src/index.ts | head -20
```

For each hit: remove the branch. The Vite plugin's engine-inheritance logic (when auto-discovered workers default to the most-common headless engine) just drops the jsc/txiki names from its consideration set.

- [ ] **Step 16: Build verification (hello-world)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
```

Expected LAST line: `[zapp] build complete: ...`. If the build fails with "undefined symbol" / "unknown identifier" pointing to `jsc_` or `txiki_` something, you missed a reference in steps 8–14 — go find it.

Confirm binary mtime fresh:
```bash
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

- [ ] **Step 17: Build verification (bare-jsc benchmark app)**

The bare-jsc benchmark app is `benchmarks/apps/zapp-host-bridge` — temporarily flip its config or check whether it already uses bare-jsc. Read:
```bash
grep -n 'engine' /Users/zach/code/zapp/benchmarks/apps/zapp-host-bridge/zapp.config.ts | head -5
```

If it currently uses `engine: "bare-jsc"` for any worker, build it directly. If it uses `"jsc"` or `"txiki"` (which Task 1's parse-error would now reject), temporarily flip ONE worker to `"bare-jsc"` for the build test, then restore:

```bash
cd /Users/zach/code/zapp/benchmarks/apps/zapp-host-bridge
cp zapp.config.ts /tmp/host-bridge.config.ts.bak
# Edit: replace any "jsc"/"txiki" engine: lines with "bare-jsc" (keep others)
bun run build 2>&1 | tail -3
cp /tmp/host-bridge.config.ts.bak zapp.config.ts && rm /tmp/host-bridge.config.ts.bak
```

Expected: `[zapp] build complete: ...`. This catches any surviving `bare` → removed-engine symbol references.

If the build fails, STOP and report BLOCKED with the link error.

- [ ] **Step 18: Commit**

```bash
cd /Users/zach/code/zapp
git add -A native/ cli/src/build-config.ts cli/src/native.ts cli/src/init.ts cli/src/entitlements.ts cli/src/paths.ts bootstrap/ vite/
git commit -m "$(cat <<'EOF'
refactor(workers): delete jsc + txiki engine sources and dispatch

Removes the deprecated jsc and txiki engine implementations from
Zapp:

- 6 source files deleted (native/worker/engines/jsc.{zc,h,m},
  native/worker/engines/txiki.{zc,c,h}).
- ZAPP_WORKER_ENGINE_JSC / _TXIKI defines removed from native/build.zc
  and from the CLI's engine overlay generator (cli/src/build-config.ts).
- Per-engine branches removed from router.zc, registry.zc, worker.zc,
  dispatch.zc, app.zc, app_events.zc, callbacks.zc, json_builder.zc,
  and the bare/darwin interop layers.
- Bootstrap and Vite plugin engine-paths dropped.

Hello-world (engine: "zjs") and the host-bridge benchmark app
(engine: "bare-jsc") both build clean post-removal — confirms no
surviving symbol references from the surviving engines.

Benchmark apps and docs cleanup follow in commit 3.
EOF
)"
```

---

## Task 3: Commit 3 — Delete benchmark apps + docs sweep

**Goal:** Delete `benchmarks/apps/zapp-jsc/` and `benchmarks/apps/zapp-txiki/`. Update README.md, docs/{engines,architecture,patterns}.md, WINDOWS_PORTING.md, SKILLS.md, cli/README.md to remove the deprecated tier. Clean stale comments in hello-world/zapp.config.ts.

**Files (delete):**
- `benchmarks/apps/zapp-jsc/` (recursive)
- `benchmarks/apps/zapp-txiki/` (recursive)

**Files (modify):**
- `README.md`
- `docs/engines.md`
- `docs/architecture.md`
- `docs/patterns.md`
- `WINDOWS_PORTING.md`
- `SKILLS.md`
- `cli/README.md`
- `hello-world/zapp.config.ts`

- [ ] **Step 1: Delete the two benchmark apps**

```bash
cd /Users/zach/code/zapp
git rm -r benchmarks/apps/zapp-jsc benchmarks/apps/zapp-txiki
```

Verify:
```bash
ls benchmarks/apps/
```
Expected: `zapp-jsc/` and `zapp-txiki/` are gone; `zapp-host-bridge/` (and any wails/tauri/electron comparison apps) remain.

- [ ] **Step 2: Update README.md benchmark tables**

Read `/Users/zach/code/zapp/README.md` (the relevant section spans roughly lines 25–66 per the prior audit). Find the two benchmark tables:
1. The binary/bundle/memory/build table with `Zapp (zjs) | Zapp (jsc) | Zapp (txiki) | Tauri ... | Electron | Electrobun` columns.
2. The bridge-latency-by-context table with the same column structure.

For each:
- Drop the `Zapp (jsc)` and `Zapp (txiki)` columns.
- Keep `Zapp (zjs)` as the lead column. Verify the zjs row uses the current measured numbers from `benchmarks/apps/zapp-host-bridge/RESULTS.md` (worker→native 0.45 µs zjs is the current data).
- Keep all the non-Zapp comparison columns (Tauri, Wails, Electron, Electrobun).
- The webview→native row's number for zjs may not have been re-measured; keep the existing number with the caveat that engines.md / RESULTS.md is the source of truth.

Adjust prose around the tables: the "Which engine?" section needs jsc/txiki removed from the bullet list. The fallback chain mention should read `zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs` (terminate at bare-mqjs).

- [ ] **Step 3: Update docs/engines.md**

Read `/Users/zach/code/zapp/docs/engines.md`. Make these surgical edits:

- Drop the **Deprecated (compat tier)** row from the taxonomy table at the top.
- Drop any "Migrate to ..." cheat-sheet rows that have `jsc` or `txiki` as their starting point.
- Update the fallback chain text from `zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs > txiki > jsc` to `zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs`.
- Update the platform-recommendation lines (macOS, iOS, Windows/Linux) to mention only surviving engines.
- Drop the "Web API hierarchy" subsection's reference to `jsc` or `txiki` if any.

Use the Read tool to inspect the file first; the exact line numbers depend on its current state.

- [ ] **Step 4: Sweep docs/architecture.md**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/docs/architecture.md | grep -v 'bare-jsc' | head -20
```

For each hit: read context. If it's a reference to the legacy engine (e.g., "jsc.m"), update or remove. If it's a reference to `JSC` as the system framework (e.g., "JavaScript Core context"), keep.

- [ ] **Step 5: Sweep docs/patterns.md**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/docs/patterns.md | grep -v 'bare-jsc' | head -20
```

Same evaluation as Step 4.

- [ ] **Step 6: Sweep WINDOWS_PORTING.md, SKILLS.md, cli/README.md**

```bash
grep -n 'jsc\|txiki' /Users/zach/code/zapp/WINDOWS_PORTING.md /Users/zach/code/zapp/SKILLS.md /Users/zach/code/zapp/cli/README.md | grep -v 'bare-jsc' | head -30
```

For each file, read the hits and clean. Note especially:
- `cli/README.md` may have a `TJS_SetCookieJarPath undefined symbol` troubleshooting note — that's txiki-specific; delete the bullet.
- `WINDOWS_PORTING.md` will reference txiki + jsc in its worker-engine narrative; replace with the new bare-* + zjs framing (consistent with the post-doc-refresh state from this session, which already mostly handles this).
- `SKILLS.md`'s engines-overview section needs updating.

- [ ] **Step 7: Clean hello-world/zapp.config.ts comments**

Read `/Users/zach/code/zapp/hello-world/zapp.config.ts`. The file currently uses `engine: "zjs"` in code but has comments mentioning "across zjs, bare-*, and txiki" (around lines 26 and 47). Update those comments to drop "txiki":

Find:
```
// restart-on-crash works end-to-end across zjs, bare-*, and txiki
```
Replace with:
```
// restart-on-crash works end-to-end across zjs and all bare-* engines
```

Find the cross-engine smoke matrix comment:
```
//   zjs       → crashed×3, restarted×2, gave-up×1, 4th click silent
//   bare-jsc  → same sequence
//   txiki     → same sequence
```
Replace with:
```
//   zjs       → crashed×3, restarted×2, gave-up×1, 4th click silent
//   bare-jsc  → same sequence
//   bare-v8   → same sequence (Win/Linux JIT)
```

(If you can't run bare-v8 to verify, drop just the txiki line — that's safer than asserting an untested case.)

Use the Read tool to confirm exact wording before editing.

- [ ] **Step 8: Build verification**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3
```
Expected: `[zapp] build complete: ...`. Docs changes don't affect the build, but this catches any accidental edit to a build-related file.

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add -A benchmarks/ README.md docs/ WINDOWS_PORTING.md SKILLS.md cli/README.md hello-world/zapp.config.ts
git commit -m "$(cat <<'EOF'
docs: drop jsc + txiki references; remove the two benchmark apps

- benchmarks/apps/zapp-jsc and zapp-txiki deleted; the zapp-host-bridge
  benchmark covers the surviving engines.
- README, docs/engines, docs/architecture, docs/patterns,
  WINDOWS_PORTING, SKILLS, cli/README all swept for incidental
  mentions of the removed engines. The fallback chain narrative
  updates to terminate at bare-mqjs; the deprecated tier row in
  docs/engines is gone.
- hello-world/zapp.config.ts comments clean up the cross-engine
  smoke-matrix note to list only surviving engines.

Hello-world still builds clean. Historical references in the
supervisor-restart spec/plan and benchmarks/apps/zapp-host-bridge/RESULTS.md
are intentionally left alone — they describe past state accurately.
EOF
)"
```

---

## Task 4: Commit 4 — Final cleanup audit

**Goal:** Sweep for dead constants, dead imports, dead extern declarations, and dead helper functions left over from the surgical removals. Verify the engine fallback chain is correct. Final grep audit.

**Files:** any from the codebase that still reference the removed engines.

- [ ] **Step 1: Sweep for dead `legacy*Warned` flags**

```bash
cd /Users/zach/code/zapp
grep -rn 'legacy.*Warned\|_legacyJscWarned\|_legacyTxikiWarned' --include='*.ts' 2>&1 | grep -v node_modules | head -10
```

Expected: zero matches (Task 1 should have removed them all). If any survive, delete them inline.

- [ ] **Step 2: Sweep for dead engine ID constants**

```bash
grep -rn 'ENGINE_JSC\|ENGINE_TXIKI' --include='*.zc' --include='*.c' --include='*.h' --include='*.m' --include='*.ts' 2>&1 | grep -v node_modules | grep -v vendor/ | head -10
```

Expected: zero matches. If any survive, delete them.

- [ ] **Step 3: Sweep for dead extern declarations**

```bash
grep -rn 'extern.*jsc_\|extern.*txiki_' --include='*.zc' --include='*.c' --include='*.h' --include='*.m' 2>&1 | grep -v node_modules | grep -v vendor/ | head -10
```

Expected: zero matches. If any survive (orphan `extern fn jsc_worker_create(...)` declarations not removed in commit 2), delete them.

- [ ] **Step 4: Verify the fallback chain in router.zc**

```bash
grep -n 'fallback\|FALLBACK\|chain\|resolver' /Users/zach/code/zapp/native/worker/router.zc | head -10
```

Read the resolver / fallback chain code. Confirm the chain reads (in order): `zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs`. No `txiki` or `jsc` at the end.

- [ ] **Step 5: Verify the runtime/worker.ts fallback chain (if it has one)**

```bash
grep -n 'fallback\|chain\|FALLBACK' /Users/zach/code/zapp/runtime/worker.ts | head -10
```

If the file has a fallback list, verify it matches the same 6-engine chain.

- [ ] **Step 6: Final cross-codebase audit grep**

```bash
cd /Users/zach/code/zapp
grep -rn 'jsc\b\|txiki\b' --include='*.zc' --include='*.c' --include='*.h' --include='*.m' --include='*.ts' --include='*.md' 2>&1 \
  | grep -v node_modules \
  | grep -v vendor/ \
  | grep -v spike/ \
  | grep -v docs/superpowers/specs/2026-06-01-worker-supervisor-restart \
  | grep -v docs/superpowers/plans/2026-06-01-worker-supervisor-restart \
  | grep -v benchmarks/apps/zapp-host-bridge/RESULTS.md \
  | grep -v 'bare-jsc' \
  | grep -v 'JavaScriptCore' \
  | head -30
```

Expected: zero hits (everything that survives the filters is in the allow-list: vendor code, spike notes, historical specs/plans, the host-bridge benchmarks RESULTS, system framework references).

If hits remain, evaluate each:
- A reference to Zapp's removed engine → delete.
- A reference to bare's internal `libjs` aliased "jsc" (in vendor/) → allowed (the filter should have caught it, but if not, add it to your mental filter).
- A reference to macOS's `JavaScriptCore.framework` or `libjavascriptcore` system framework → KEEP (it's a system framework, not Zapp's engine).
- A historical mention in a memory file or older doc that the grep missed → evaluate case-by-case; usually KEEP since memory files describe past state accurately.

- [ ] **Step 7: Build verification (hello-world)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

Expected `[zapp] build complete: ...` last line, fresh binary mtime.

- [ ] **Step 8: Commit (only if anything changed; otherwise skip)**

```bash
cd /Users/zach/code/zapp
git status --short
```

If `git status` is empty, commit 4 is unnecessary — commits 1–3 were thorough. Report `Status: DONE — no commit 4 needed.`

If there are changes:

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(workers): final sweep — dead constants, dead externs, audit grep

Final pass over the codebase after the legacy engine deletion in
commits 1–3. Cleans up:

- (list what was actually swept — e.g., orphan extern declarations,
  unused engine-ID constants, stale fallback-chain entries)

Final cross-codebase grep returns no surviving references to the
removed engines outside vendor/, spike/, historical
docs/superpowers/specs+plans, and the host-bridge benchmark RESULTS
(intentional historical record).
EOF
)"
```

---

## Self-review

**1. Spec coverage.** Walking the spec section by section:

| Spec section | Plan task(s) |
|---|---|
| Scope: cadence (atomic one-branch) | Task 0 creates the branch; tasks 1–4 land within it |
| Scope: commit shape (4 phased) | Tasks 1, 2, 3, 4 = the 4 commits |
| Architecture: deleted files | Task 2 (engine sources), Task 3 (benchmark apps) |
| Architecture: modified files (CLI types) | Task 1 |
| Architecture: modified files (native plumbing) | Task 2 |
| Architecture: modified files (bootstrap + vite) | Task 2 |
| Architecture: modified files (docs) | Task 3 |
| Architecture: left alone (vendor, spike, historical) | Task 4's final grep filter explicitly allow-lists these |
| Migration story (clean error from CLI) | Task 1 Step 3 + Step 6 negative verification |
| Risks: bare interop | Task 2 Step 1 pre-flight |
| Risks: fallback chain shape | Task 4 Steps 4 and 5 verify the new chain |
| Risks: doc drift in README | Task 3 Step 2 explicitly handles the benchmark tables |
| Testing per commit | Each commit task has a build-verification step before the commit step |

No gaps.

**2. Placeholder scan.** Each step lists exact files, exact greps, exact code blocks where code is changing. The error message in Task 1 Step 3 is verbatim. Negative verification in Task 1 Step 6 is explicit about the expected error text. Tasks 2 and 3 use grep-then-read patterns when the exact line numbers can't be known statically — acceptable for deletion-heavy work where the engineer has to interpret context. Task 4 Step 8's commit message has a "(list what was actually swept ...)" hand-wave by design — the cleanup commit's body is necessarily a function of what survives the surgical removals. No TODO/TBD markers in any code block.

**3. Type consistency.** `rejectRemovedEngines` is defined in Task 1 Step 3 and not referenced elsewhere — internal to commit 1. Engine name strings (`"zjs"`, `"bare-jsc"`, `"bare-v8"`, etc.) are consistent across all tasks. Fallback chain (`zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs`) appears in three places (spec, Task 4 Steps 4 + 5, Task 3 Step 3) — all consistent.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-01-remove-legacy-engines.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks. Tasks 1–4 are each well-bounded; per-task isolation keeps the deletion surgical and helps catch any missed references at the per-commit build gate.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints. Faster if you trust the plan completely; harder to recover if a step's grep misses something.

Which approach?
