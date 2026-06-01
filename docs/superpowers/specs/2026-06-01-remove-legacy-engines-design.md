# Remove legacy `jsc` + `txiki` worker engines — design

**Status:** approved by user 2026-06-01 (post-brainstorm). Implementation plan: TBD via `superpowers:writing-plans`.

**Goal:** Delete the deprecated `jsc` and `txiki` worker engines from Zapp. After this work, the engine taxonomy shrinks from 8 strings to 6: `zjs` (default, cross-platform) + `bare-jsc` (macOS JIT) + `bare-v8` (Win/Linux JIT) + `bare-quickjs` / `bare-mqjs` / `bare-hermes` (niche). The "deprecated compat tier" goes away entirely.

**Why now.** Both engines have been marked deprecated in `docs/engines.md` and emit CLI warnings on use since the 6-engine taxonomy commit `bb960ac`. The supervisor-restart cycle (just shipped, 34 commits on main) had to maintain symmetry across 8 engines instead of 6. Zero known users in the wild — Zapp is pre-release, and the recommended engines (zjs, bare-jsc) have been the default in `zapp init` and the docs for the entire deprecation window. Keeping the legacy engines costs ongoing cross-engine work; removing them is pure simplification.

## Scope locked during brainstorm

| Decision | Locked value |
|---|---|
| Cadence | Atomic removal in one branch/PR (no further deprecation alphas — zero users in the wild) |
| Commit shape inside branch | 4 phased commits, each producing working software (bisectable) |
| Migration messaging | Clear config-parse error from CLI when user has `engine: "jsc"`/`"txiki"`; no formal deprecation period |
| Benchmark apps | `benchmarks/apps/zapp-{jsc,txiki}/` deleted with the engines |
| Historical record | Supervisor-restart spec/plan/memory + `benchmarks/apps/zapp-host-bridge/RESULTS.md` left alone (they accurately describe past state) |

## Architecture

### Deleted

**Engine sources (6 files):**
- `native/worker/engines/jsc.{zc, h, m}`
- `native/worker/engines/txiki.{zc, c, h}`

**Benchmark apps (2 directories):**
- `benchmarks/apps/zapp-jsc/`
- `benchmarks/apps/zapp-txiki/`

### Modified — narrowed (drop branches/cases)

**Type system + CLI:**
- `cli/src/config.ts`: shrink `HeadlessWorkerConfig.engine` union from 8 → 6 strings; delete the deprecation-warning code (lines ~782–798); add a config-parse error path that rejects `"jsc"`/`"txiki"` if they slip through (untyped config loaders, copy-paste, etc.) with a clear migration message.
- `cli/src/build-config.ts`: drop jsc/txiki branches in `generateEngineOverlay`, drop the legacy engine ID constants.
- `cli/src/native.ts`: drop platform/engine wiring for these engines.
- `cli/src/init.ts`: drop scaffolding templates referring to these engines (if any).
- `cli/src/entitlements.ts`, `cli/src/paths.ts`: drop any engine-specific paths.
- `runtime/worker.ts`: shrink the engine-string union accepted by `new Worker(url, { engine })`.

**Native plumbing:**
- `native/build.zc`: drop `ZAPP_WORKER_ENGINE_JSC` / `ZAPP_WORKER_ENGINE_TXIKI` defines.
- `native/worker/router.zc`: drop dispatch-table cases.
- `native/worker/registry.zc`: drop engine ID constants (review enum values to avoid leaving gaps if other code relies on numeric IDs).
- `native/worker/worker.zc`: drop per-engine create branches.
- `native/bridge/dispatch.zc`: drop per-engine event-broadcast branches.
- `native/app/{app.zc, app_events.zc}`: drop any wiring.
- `native/window/callbacks.zc`: drop callback paths.
- `native/bridge/json_builder.zc`: drop any references.
- `native/worker/engines/{bare.h, bare.zc}`: drop any jsc/txiki interop.
- `native/platform/darwin/{shortcuts.m, sync.m}`: drop `#ifdef ZAPP_WORKER_ENGINE_JSC` blocks.

**Bootstrap + Vite:**
- `bootstrap/codegen.ts`, `bootstrap/webview.ts`: drop engine-specific code paths.
- `vite/src/index.ts`: drop engine-inheritance logic for these names.

**Docs:**
- `README.md`: drop "Zapp (JSC)" + "Zapp (txiki)" columns from benchmarks table. Replace headline numbers with the recommended engines' equivalents (use current zjs / bare-jsc / txiki worker-side numbers from `benchmarks/apps/zapp-host-bridge/RESULTS.md` where they exist; preserve other framework comparison columns).
- `docs/engines.md`: drop the deprecated-tier row from the taxonomy table; drop migration cheat-sheet text referencing deleted engines as starting points.
- `docs/architecture.md`, `docs/patterns.md`: search/replace incidental mentions; some lines need rewriting, not just deleting.
- `WINDOWS_PORTING.md`, `SKILLS.md`, `cli/README.md`: same sweep.
- `hello-world/zapp.config.ts`: clean stale comments referencing jsc/txiki (already uses zjs in code).

### Left alone

- **`vendor/*`** — external dependencies, not Zapp code. (Note: `vendor/bare` internally aliases its libjs as "jsc" in its own namespace — that's the bare project's naming, not Zapp's `jsc` engine. Don't touch.)
- **`spike/bare/*`** — historical spike notes from the bare-integration cycle.
- **`docs/superpowers/specs/2026-06-01-worker-supervisor-restart-design.md`**, the supervisor-restart plan, and `benchmarks/apps/zapp-host-bridge/RESULTS.md` — historical record; the legacy engine numbers there are valid history.
- **Memory files mentioning the deprecated tier** — accurate at the time they were written. Update only `MEMORY.md` index descriptions if they read confusingly post-removal.

## Commit shape

### Commit 1 — CLI config schema

- Drop `"jsc"` and `"txiki"` from the engine union in `cli/src/config.ts` (and the runtime/worker.ts mirror).
- Delete the deprecation-warning code path (the `legacy*Warned` flags + the warning text).
- Add a clear config-parse error: when reading a user's `zapp.config.ts`, if any `headless.<id>.engine` is `"jsc"` or `"txiki"`, throw with the message: *"Engine '<X>' has been removed. Use 'zjs' (cross-platform, default) or 'bare-jsc' (macOS JIT). See docs/engines.md."*

**Build verification:** hello-world (uses `engine: "zjs"`) builds clean. Temporarily edit hello-world to `engine: "jsc"` and verify the new error fires at config parse. Revert.

### Commit 2 — Native engine sources + router/registry/dispatch

- Delete the 6 engine source files.
- Drop the `ZAPP_WORKER_ENGINE_JSC` / `..._TXIKI` defines from `native/build.zc` and the CLI's engine overlay generator.
- Remove the jsc/txiki branches from router.zc, registry.zc, worker.zc, dispatch.zc, app.zc, app_events.zc, callbacks.zc, json_builder.zc, bare.{h,zc}.
- Drop the `#ifdef` blocks from `darwin/{shortcuts.m, sync.m}`.

**Build verification:** hello-world builds clean. A `bare-jsc` benchmark app (`benchmarks/apps/zapp-host-bridge` with engine flipped) builds clean — confirms no surviving jsc/txiki symbol references from the bare wrapper.

### Commit 3 — Benchmark apps + docs

- `git rm -r benchmarks/apps/zapp-jsc benchmarks/apps/zapp-txiki`
- Update `README.md` benchmark tables (binary/bundle/memory/build + bridge latency) to drop the deleted engine columns. Replace with current zjs/bare-jsc numbers where measurements exist; otherwise leave the comparison-vs-other-frameworks columns and note in a footnote that the engine-by-engine breakdown lives in `engines.md` + the host-bridge RESULTS.
- Strip the deprecated tier from `docs/engines.md` and rewrite the platform-recommendation lines to mention only surviving engines.
- Search/replace pass on `docs/architecture.md`, `docs/patterns.md`, `WINDOWS_PORTING.md`, `SKILLS.md`, `cli/README.md`.
- Clean stale comments in `hello-world/zapp.config.ts`.

### Commit 4 — Cleanup pass

- Sweep for dead constants left behind (engine ID enums, fallback chain entries, `legacy*Warned` flags).
- Drop dead extern declarations and imports.
- Confirm fallback chain in router.zc + runtime/worker.ts shrinks correctly to: `zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs`.
- Final scan: `grep -rn 'jsc\b\|txiki\b' --include='*.{zc,c,h,m,ts}'` returns only `vendor/`, `spike/`, the historical supervisor-restart spec/plan, and the macOS `JavaScriptCore.framework` references (that's the system framework, not Zapp's engine).
- Final hello-world build clean.

## Risks + mitigations

1. **bare may depend on jsc/txiki symbols.** Before committing commit 2, run `grep -n 'jsc_\|txiki_\|jsc.h\|txiki.h' native/worker/engines/bare.{c,h,zc}`. If any references surface, surface as a concern and either inline the dependency or open a follow-up. *Expected hit count: 0 — bare was designed as the modern replacement; integration with the legacy engines was never part of its scope. But verify.*
2. **Router fallback chain shape.** Today: `... > txiki > jsc`. Post-removal: chain terminates at `bare-mqjs`. Strictly improving — bare-mqjs is more capable than the legacy engines. The CLI's auto-build-default-engine logic guarantees at least one bare-* engine is always compiled, so the chain always has a real engine to land on.
3. **Stale `.app` bundles.** Compiled into the binary at build time; not a runtime issue. Solved by commit 1's config-parse error on next rebuild.
4. **Documentation drift.** README's benchmark table loses two columns. Replace with current zjs/bare-jsc numbers; leave the multi-framework comparison rows intact.
5. **No CHANGELOG.** Zapp doesn't maintain a `CHANGELOG.md` — release notes live in npm releases and git history. The PR description for this branch carries the migration note for any future archaeology.

## Testing

| Stage | Verification |
|---|---|
| Commit 1 | hello-world builds clean; synthetic `engine: "jsc"` triggers the new config-parse error |
| Commit 2 | hello-world builds clean; `bare-jsc` benchmark app builds clean (catches any bare→jsc interop) |
| Commit 3 | Read-only docs sweep — no compile changes; hello-world still builds clean |
| Commit 4 | Final hello-world build + grep audit returns only allow-listed mentions |
| Post-merge manual smoke | Hello-world supervisor demo on `engine: "zjs"`: documented 4-crashed / 2-restarted / 2-gave-up sequence (already verified working as of `b3cffd1` + `54a74cb`). Same on `bare-jsc` if convenient. |

No automated test suite exists for this repo — the build itself + hello-world manual smoke are the verification gates, consistent with prior worker-engine cycles.

## Out of scope

- Re-running benchmarks against the surviving engines. The existing `benchmarks/apps/zapp-host-bridge/RESULTS.md` data is recent enough; the only gap is updated webview→native + binary/bundle/memory numbers, which can be a separate cycle.
- Migration helper tooling. At Zapp's current scale (zero known users in the wild), a clear error message is sufficient.
- Doc-archaeology rewrite of historical specs/plans/memories. Those documents describe past state accurately; mutating them to retroactively pretend the legacy engines never existed serves no reader.
- Renaming `bare-jsc` to just `jsc` to claim the freed name. The `bare-` prefix carries useful information (this engine ships via the bare runtime, not the legacy native binding). Leave the prefix.

## File map

| Path | Operation | Commit |
|---|---|---|
| `native/worker/engines/jsc.{zc,h,m}` | delete | 2 |
| `native/worker/engines/txiki.{zc,c,h}` | delete | 2 |
| `benchmarks/apps/zapp-jsc/` | delete (recursive) | 3 |
| `benchmarks/apps/zapp-txiki/` | delete (recursive) | 3 |
| `cli/src/config.ts` | narrow union + add parse error + drop warning code | 1 |
| `runtime/worker.ts` | narrow engine union | 1 |
| `cli/src/build-config.ts` | drop branches + drop ID constants | 2 |
| `cli/src/native.ts`, `cli/src/init.ts`, `cli/src/entitlements.ts`, `cli/src/paths.ts` | drop engine wiring | 2 |
| `native/build.zc` | drop defines | 2 |
| `native/worker/{router,registry,worker}.zc` | drop cases | 2 |
| `native/bridge/{dispatch,json_builder}.zc` | drop cases | 2 |
| `native/app/{app,app_events}.zc`, `native/window/callbacks.zc` | drop wiring | 2 |
| `native/worker/engines/bare.{h,zc}` | drop interop | 2 |
| `native/platform/darwin/{shortcuts,sync}.m` | drop ifdefs | 2 |
| `bootstrap/{codegen,webview}.ts`, `vite/src/index.ts` | drop engine paths | 2 |
| `README.md`, `docs/{engines,architecture,patterns}.md`, `WINDOWS_PORTING.md`, `SKILLS.md`, `cli/README.md` | doc sweep | 3 |
| `hello-world/zapp.config.ts` | comment cleanup | 3 |
| Cross-codebase | dead constants, dead imports, final audit | 4 |
