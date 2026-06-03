# Logging & Verbosity (DX Part A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ad-hoc `[native]`/`[js-console]` logging with a framework-provided, level-gated logger (`[zapp]` / `[zapp/<worker>]`), add `--verbose`/`--debug` levels across the CLI and the running app (via a `ZAPP_LOG` env var), and stop swallowing build/linker errors.

**Architecture:** A new native log module (`native/log/log.zc`) holds a `zapp_log_level` global (set from `ZAPP_LOG` at startup) and emits `[zapp] …` via `fprintf(stderr)` gated by level. The framework exposes `log()`/`logv()`/`logd()` to Zen-C app code; the worker engines reprefix console output to `[zapp/<worker>]`; the CLI parses `--verbose`/`--debug`, gates its own output, injects `ZAPP_LOG` when spawning the dev app, and prints real build errors by default. hello-world drops its hand-rolled `log()` helper.

**Tech Stack:** Zen-C (native log module + worker engines in C), TypeScript (CLI), Bun (test + spawn).

**Spec:** `docs/superpowers/specs/2026-06-02-dev-experience-design.md` (Part A only; Part B = build-manifest, separate plan).

**Build-verify rule:** native builds succeed only when the LAST line is `[zapp] build complete: <path>` (per `feedback_verify_native_build`) — note Part A changes some log plumbing, so re-confirm that line still prints. Vite's `✓ built` is NOT sufficient.

---

## File Structure

| File | Responsibility | Type |
|---|---|---|
| `native/log/log.zc` | Native log primitive: `zapp_log_level` global, `zapp_log_init()`, `zapp_log_emit(level,msg)`, Zen-C `log()`/`logv()`/`logd()` | Create |
| `native/app/app.zc` | Call `zapp_log_init()` at `App::new` startup; ensure the new module is compiled in | Modify |
| `native/worker/engines/zjs.c:730` | `host_console_log` → `[zapp/<display-name>]` | Modify |
| `native/worker/engines/bare.c:500` | `host_console_log` → `[zapp/<display-name>]` | Modify |
| `cli/src/log.ts` | CLI log helper: `cliLevel` + `clog(level, …)` gating `[zapp]` lines | Create |
| `cli/src/log.test.ts` | `bun test` unit tests for the level gating | Create |
| `cli/src/zapp-cli.ts` | parse `--verbose`/`--debug` → level; migrate noisy build/dev `[zapp]` logs to `clog`; inject `ZAPP_LOG` env on app spawn (macOS + iOS) | Modify |
| `cli/src/native.ts` | stop swallowing the linker error (always print real stderr); `--debug` adds full invocation | Modify |
| `hello-world/zapp/app.zc` | drop the local `log()` helper; reclassify its 24 calls (lifecycle → `logv`, milestones → `log`) | Modify |
| `docs/api-reference.md` / `cli/README.md` | document `--verbose`/`--debug`, `ZAPP_LOG`, and the `log()`/`logv()`/`logd()` app API | Modify |

---

## Task 1: Native log module + startup init

**Files:**
- Create: `native/log/log.zc`
- Modify: `native/app/app.zc` (call `zapp_log_init()` in `App::new`, ~line 386)

- [ ] **Step 1: Create the native log module**

Create `native/log/log.zc`. The C primitive is concrete; the three Zen-C wrappers (`log`/`logv`/`logd`) follow the file's `raw {}` idiom (mirror how `native/app/app.zc` and `native/worker/registry.zc` wrap C in Zen-C `fn` + `raw {}`):

```zc
// Framework logging — a single level-gated stderr logger so apps don't
// hand-roll NSLog helpers. Level comes from the ZAPP_LOG env var (set by the
// CLI in dev, or by the user on a packaged app). Format: "[zapp] <msg>".

raw {
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>

    // 0 = default (always shown), 1 = verbose, 2 = debug.
    int zapp_log_level = 0;

    void zapp_log_init(void) {
        const char* e = getenv("ZAPP_LOG");
        if (!e) { zapp_log_level = 0; return; }
        if (strcmp(e, "debug") == 0) zapp_log_level = 2;
        else if (strcmp(e, "verbose") == 0) zapp_log_level = 1;
        else zapp_log_level = 0;
    }

    // A message tagged `level` prints when the active level is >= it, so
    // default(0) always prints, verbose(1) prints at --verbose+, debug(2) at
    // --debug only.
    void zapp_log_emit(int level, const char* msg) {
        if (zapp_log_level >= level) {
            fprintf(stderr, "[zapp] %s\n", msg ? msg : "");
        }
    }
}

// App-facing Zen-C surface. `log` = default level, `logv` = verbose,
// `logd` = debug. (String-arg, so distinct from the stdlib math `log(double)`.)
fn log(msg: string) -> void {
    raw { zapp_log_emit(0, (const char*)msg); }
}
fn logv(msg: string) -> void {
    raw { zapp_log_emit(1, (const char*)msg); }
}
fn logd(msg: string) -> void {
    raw { zapp_log_emit(2, (const char*)msg); }
}
```

- [ ] **Step 2: Ensure the module is compiled + reachable**

The framework's native sources are gathered in `cli/src/native.ts` (the macOS/iOS source lists, e.g. around `native.ts:47-90`). Add `native/log/log.zc` to the compiled source set for every target (macOS, iOS, Windows) the same way other `native/**/*.zc` modules are included. Read how an existing `native/<area>/<area>.zc` (e.g. `native/sync/sync.zc`) is added to the build and mirror it. (If sources are gathered by directory glob, just creating the file may suffice — verify.)

- [ ] **Step 3: Call `zapp_log_init()` at startup**

In `native/app/app.zc`, in `App::new` (around line 386, right before `platform_init(config.name)`), add the init call so the level is read once before anything logs:

```zc
        raw { extern void zapp_log_init(void); zapp_log_init(); }
        platform_init(config.name);
```

(Use the file's existing `raw {}` + `extern` idiom — `app.zc` already calls extern C functions this way.)

- [ ] **Step 4: Build verify**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2
```
Expected: last line `[zapp] build complete: <path>`. The new module compiles. (Nothing calls `log()`/`logv()`/`logd()` from the framework yet — they're the API hello-world will adopt in Task 7. zjs/bare reference `zapp_log_emit`/`zapp_log_level` only after Tasks 2-? — fine, they're not wired yet.)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/log/log.zc native/app/app.zc cli/src/native.ts
git commit -m "$(cat <<'EOF'
feat(log): framework log primitive with ZAPP_LOG level gating

New native/log/log.zc: zapp_log_level (from ZAPP_LOG env, read once at
App::new startup), zapp_log_emit(level,msg), and the app-facing log()/
logv()/logd() Zen-C surface emitting "[zapp] <msg>" via fprintf. Replaces
hand-rolled NSLog loggers; default(0) always prints, verbose(1)/debug(2)
gate on level.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Worker console → `[zapp/<worker>]`

**Files:**
- Modify: `native/worker/engines/zjs.c:730-761` (`host_console_log`)
- Modify: `native/worker/engines/bare.c:500-515` (`host_console_log`)

- [ ] **Step 1: zjs — reprefix with the worker display name**

In `native/worker/engines/zjs.c`, `host_console_log` currently does `fputs("[js-console]", stderr)`. The `slot` is reachable via `ctx` (the function already accesses worker state through ctx elsewhere — find how sibling host fns get `slot`/`worker_id` from `ctx`; e.g. the lifecycle logs at zjs.c:904 already call `zapp_worker_registry_get_display_name(...)`). Replace the prefix:

```c
// was: fputs("[js-console]", stderr);
extern const char* zapp_worker_registry_get_display_name(const char* worker_id);
const char* wid = /* slot->worker_id, obtained the same way sibling logs do */;
fprintf(stderr, "[zapp/%s]", zapp_worker_registry_get_display_name(wid));
```

(Match the exact mechanism the file already uses to get `worker_id` in this function — if `slot` isn't directly in scope in `host_console_log`, get it the same way zjs.c:904's site does. If the worker id genuinely isn't reachable here, report DONE_WITH_CONCERNS describing what's available.)

Worker console is the app's own output → **default level, always shown** (do NOT gate it behind verbose).

- [ ] **Step 2: bare — reprefix with the worker display name**

In `native/worker/engines/bare.c`, `host_console_log` has `slot->worker_id` available (it's `(BareWorkerSlot*)data`). Change:

```c
// was: fprintf(stderr, "[bare:%s] %s\n", worker_id, buf);
extern const char* zapp_worker_registry_get_display_name(const char* worker_id);
const char* worker_id = slot ? slot->worker_id : "?";
fprintf(stderr, "[zapp/%s] %s\n", zapp_worker_registry_get_display_name(worker_id), buf);
```

- [ ] **Step 3: Build verify (both engines)**

zjs (default):
```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2
```
bare: temporarily switch supervised to `engine: "bare-jsc"` in `hello-world/zapp.config.ts`, `bun run build` (last line `[zapp] build complete:`), then `git checkout hello-world/zapp.config.ts`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add native/worker/engines/zjs.c native/worker/engines/bare.c
git commit -m "$(cat <<'EOF'
refactor(log): worker console → [zapp/<worker>] prefix

zjs + bare host_console_log now prefix worker console output with the
registry display name ([zapp/ticker] …) instead of [js-console] / [bare:id],
unifying with the #150 lifecycle format. Worker console is app output —
always shown (not gated by verbosity).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: CLI level + `clog` helper (TDD)

**Files:**
- Create: `cli/src/log.ts`
- Create: `cli/src/log.test.ts`

- [ ] **Step 1: Write the failing test**

Create `cli/src/log.test.ts`:

```ts
import { test, expect } from "bun:test";
import { setCliLevel, levelFromArgv } from "./log";

test("levelFromArgv maps flags to levels", () => {
  expect(levelFromArgv(["dev"])).toBe(0);
  expect(levelFromArgv(["dev", "--verbose"])).toBe(1);
  expect(levelFromArgv(["dev", "-v"])).toBe(1);
  expect(levelFromArgv(["dev", "--debug"])).toBe(2);
  // debug wins over verbose if both present
  expect(levelFromArgv(["dev", "--verbose", "--debug"])).toBe(2);
});

test("envFromLevel maps level to ZAPP_LOG value", async () => {
  const { envFromLevel } = await import("./log");
  expect(envFromLevel(0)).toBe("");
  expect(envFromLevel(1)).toBe("verbose");
  expect(envFromLevel(2)).toBe("debug");
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/zach/code/zapp/cli && bun test src/log.test.ts`
Expected: FAIL — `Cannot find module './log'`.

- [ ] **Step 3: Implement `cli/src/log.ts`**

```ts
// CLI logging — a single level-gated emitter so `bun run dev/build` output
// matches the native ZAPP_LOG levels. 0 = default, 1 = verbose, 2 = debug.

let cliLevel = 0;

export function levelFromArgv(argv: string[]): number {
  if (argv.includes("--debug")) return 2;
  if (argv.includes("--verbose") || argv.includes("-v")) return 1;
  return 0;
}

export function setCliLevel(level: number): void {
  cliLevel = level;
}

export function getCliLevel(): number {
  return cliLevel;
}

// ZAPP_LOG value to hand the spawned native app so its level matches the CLI.
export function envFromLevel(level: number): string {
  return level >= 2 ? "debug" : level >= 1 ? "verbose" : "";
}

// Emit a "[zapp] …" line if `level` <= the active CLI level. Default(0) always
// prints; verbose(1)/debug(2) gate. Errors should use clogError (always).
export function clog(level: number, ...parts: unknown[]): void {
  if (cliLevel >= level) {
    process.stdout.write(`[zapp] ${parts.join(" ")}\n`);
  }
}

export function clogError(...parts: unknown[]): void {
  process.stderr.write(`[zapp] ${parts.join(" ")}\n`);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd /Users/zach/code/zapp/cli && bun test src/log.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/log.ts cli/src/log.test.ts
git commit -m "$(cat <<'EOF'
feat(cli): level-gated clog helper + argv/env level mapping

cli/src/log.ts: levelFromArgv (--verbose/-v → 1, --debug → 2), clog(level,…)
gating [zapp] output, envFromLevel for the ZAPP_LOG handed to the native
app, and clogError (always). Unit-tested via bun test.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire CLI level + migrate noisy build/dev logs

**Files:**
- Modify: `cli/src/zapp-cli.ts` (set level at entry; migrate the noisy `[zapp]` build/dev step lines to `clog(1, …)`; keep milestones at `clog(0, …)`)

- [ ] **Step 1: Set the level at CLI entry**

In `cli/src/zapp-cli.ts`, near the command dispatch (around `:622`, where `process.argv[2]` is switched), import and set the level once:

```ts
import { setCliLevel, levelFromArgv, clog, clogError } from "./log";
// …after argv is available, before dispatch:
setCliLevel(levelFromArgv(process.argv.slice(2)));
```

- [ ] **Step 2: Migrate the noisy step logs to verbose**

The build/dev step lines the user sees on a normal run are the play-by-play. Reclassify in `zapp-cli.ts` (and the obvious noisy ones in `build-config.ts`/`native.ts` that print on every run):

- **Keep at default** (`clog(0, …)` or leave as-is): `build complete: …`, `starting vite dev server…`-equivalent readiness, `launching <app>`.
- **Move to verbose** (`clog(1, …)`): `scanning for services…`, `generated N binding(s)…`, `generating bootstrap…`, `discovered N worker(s)`, `headless worker: …`, `bundled worker: …`, `dev-bundled worker: …`, `compiling native binary…`, `creating dev bundle…`, `embedding assets with brotli…`, `compressed N assets…`.
- **The `workerModules: ["fetch"] … skipping shim` warning**: move to `clog(1, …)` (it's informational and repeats per worker — noisy by default).

Replace each `process.stdout.write("[zapp] …")` / `console.log("[zapp] …")` at those sites with `clog(0|1, "…")` (drop the literal `[zapp] ` prefix — `clog` adds it). Do the highest-traffic ~12-15 dev/build sites; leave rare one-offs as default `clog(0,…)`.

- [ ] **Step 3: Build + dev verify (default is quiet)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3
```
Expected: default build output is condensed — the step play-by-play is gone, last line `[zapp] build complete:`. Then:
```bash
bun run build --verbose 2>&1 | tail -20
```
Expected: the step lines reappear under `--verbose`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/zapp-cli.ts cli/src/build-config.ts cli/src/native.ts
git commit -m "$(cat <<'EOF'
feat(cli): gate build/dev step logs behind --verbose

Sets the CLI level from argv at entry and routes the noisy per-step build/
dev lines (scanning, bundling workers, compiling, compressing, the
workerModules shim notice) through clog(1,…) so the default run is quiet;
milestones (build complete, launching) stay at default.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Inject `ZAPP_LOG` when spawning the dev app

**Files:**
- Modify: `cli/src/zapp-cli.ts:422-426` (macOS spawn) and `:392-395` (iOS simctl launch)

- [ ] **Step 1: macOS — pass ZAPP_LOG env on spawn**

At `zapp-cli.ts:422`, the dev app is spawned `Bun.spawn([execPath], { cwd: root, stdout: "inherit", stderr: "inherit" })`. Add the env so the native `zapp_log_init` picks up the level:

```ts
import { getCliLevel, envFromLevel } from "./log";
// …
appProc = Bun.spawn([execPath], {
  cwd: root,
  stdout: "inherit",
  stderr: "inherit",
  env: { ...process.env, ZAPP_LOG: envFromLevel(getCliLevel()) },
});
```

- [ ] **Step 2: iOS — pass ZAPP_LOG to simctl launch**

At `zapp-cli.ts:392`, the iOS app launches via `xcrun simctl launch --console-pty booted <bundleId>`. simctl forwards env vars prefixed `SIMCTL_CHILD_` to the launched app. Add the env so the simulator app sees `ZAPP_LOG`:

```ts
// build the simctl spawn with SIMCTL_CHILD_ZAPP_LOG so the app's getenv("ZAPP_LOG") sees it
const simEnv = { ...process.env, SIMCTL_CHILD_ZAPP_LOG: envFromLevel(getCliLevel()) };
// pass `env: simEnv` to the Bun.spawn(["xcrun","simctl","launch", …]) call
```

(Read the exact existing simctl spawn call and add `env: simEnv` to it. `SIMCTL_CHILD_<VAR>` is the documented simctl mechanism for passing env to the launched app.)

- [ ] **Step 3: Dev verify — native logs gate by level**

```bash
cd /Users/zach/code/zapp/hello-world && bun run dev   # default: quiet; only [zapp/...] app output + milestones
```
(Ctrl+C, then:)
```bash
bun run dev --verbose   # adds the framework lifecycle [zapp] lines from hello-world's logv() calls (after Task 7)
```
Before Task 7, the native side has no `logv` calls yet, so `--verbose` may not add native lines — that's expected; this task only wires the env. Confirm the app launches and `ZAPP_LOG` reaches it (you can temporarily add `logd("ZAPP_LOG plumbing works")` and confirm it appears only under `--debug`, then remove it).

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/zapp-cli.ts
git commit -m "$(cat <<'EOF'
feat(cli): inject ZAPP_LOG into the dev app on spawn

macOS: pass ZAPP_LOG in the spawn env; iOS: SIMCTL_CHILD_ZAPP_LOG so the
simulator app's getenv sees it. The native zapp_log_init reads it at
startup, so --verbose/--debug now gate the running app's logs to match the
CLI.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Stop swallowing build/linker errors

**Files:**
- Modify: `cli/src/native.ts:989-1018` (the `compileNative` error block)

- [ ] **Step 1: Always print the real error**

Replace the swallow-and-summarize block. The real stderr (with the `Undefined symbols` / `error:` lines) should print by default; `--debug` adds the full output (warnings + invocation). Read the current block at `native.ts:989-1018`, then rewrite:

```ts
const exitCode = await proc.exited;
if (exitCode !== 0) {
  const debug = process.argv.includes("--debug");
  if (debug) {
    // Full output (warnings, notes, the whole invocation).
    process.stderr.write(stderrText);
  } else if (stderrText) {
    // Default: print error lines + their context, but keep the FULL stderr
    // as a fallback so we never hide the actual failure (the old code threw
    // away everything when no "error:" line matched — that hid linker
    // "Undefined symbols" blocks).
    const lines = stderrText.split("\n");
    const kept: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.includes("error:") || line.includes("error :") ||
          line.includes("Undefined symbols") || line.startsWith("ld:") ||
          line.includes("symbol(s) not found")) {
        kept.push(line);
        for (let j = 1; j <= 4 && i + j < lines.length; j++) {
          const next = lines[i + j];
          if (next.startsWith(" ") || next.startsWith("|") || next.match(/^\s*\d+\s*\|/)) {
            kept.push(next);
          } else break;
        }
      }
    }
    // Never swallow: if our filter matched nothing, dump the whole stderr.
    process.stderr.write(kept.length > 0 ? kept.join("\n") + "\n" : stderrText);
  }
  throw new Error(`[zapp] native build failed (exit ${exitCode})` +
    (process.argv.includes("--debug") ? "" : " — run with --debug for the full compiler invocation"));
}
```

- [ ] **Step 2: Verify errors surface by default**

Force a link error (temporarily add a bogus flag, e.g. `native: { linkFlags: ["-lnonexistent_xyz"] }` in `hello-world/zapp.config.ts` if Part B's `native:` exists — otherwise add a bad `//> link:` to `hello-world/zapp/build.zc`). Then:
```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -15
```
Expected: the real linker error (`library not found for -lnonexistent_xyz` / `Undefined symbols`) prints by default — NOT just "compilation failed, run with --verbose". Revert the temporary bad flag.

- [ ] **Step 3: Confirm a clean build still ends correctly**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1
```
Expected: `[zapp] build complete: <path>` (no spurious error output on success).

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/native.ts
git commit -m "$(cat <<'EOF'
fix(cli): surface native build errors instead of swallowing them

compileNative no longer discards stderr when no "error:" line matches — it
now always prints the real failure (incl. linker "Undefined symbols" / ld:
blocks), and --debug prints the full invocation. This is what hid the iOS
zlib link error.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Migrate hello-world off its hand-rolled `log()`

**Files:**
- Modify: `hello-world/zapp/app.zc` (drop the local `log()` at lines 4-13; import the framework module; reclassify the 24 calls)

- [ ] **Step 1: Drop the local helper, import the framework logger**

In `hello-world/zapp/app.zc`, delete the local `fn log(msg: string)` definition (lines 4-13). Add an import of the framework log module alongside the existing framework imports at the top of the file (mirror how `app.zc` imports other framework modules — match the path style of the existing `import` lines; the framework module is `native/log/log.zc`, so the relative import path will resemble the other `../...` framework imports this file already uses). This makes `log()`/`logv()`/`logd()` resolve to the framework's.

- [ ] **Step 2: Reclassify the 24 call sites**

The framework lifecycle play-by-play should be `logv` (verbose); genuine milestones / demo output stays `log` (default). Apply per the spec's quiet-default intent:

- **→ `logv(…)`** (framework plumbing noise): `app created`, `service registered: greet`, `service registered: noop`, `service registered: counter …`, `app events registered`, `menu set: …`, `notification category registered: …`, `service lifecycle: counter started`, `app event: started`, `window created`.
- **Keep `log(…)`** (milestones / demo): `initializing app...`, `window ready, showing`, `service: greet called`, and the demo's own user-facing result logs.

(Use judgment for any not listed — lifecycle/registration → `logv`, user-facing/demo result → `log`.)

- [ ] **Step 3: Build + dev verify the clean default output**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1
bun run dev
```
Expected default `dev` output:
- NO `2026-… hello-world[pid] [native] …` timestamp lines anywhere.
- App milestones as plain `[zapp] initializing app...` / `[zapp] window ready, showing`.
- Worker output as `[zapp/ticker] started`, `[zapp/sync-engine] ready` (Task 2; note hello-world workers may still self-label — see Step 4).
- The per-step registration/lifecycle chatter is GONE (it's now `logv`).

Then `bun run dev --verbose` → the lifecycle lines reappear as `[zapp] app created`, `[zapp] service registered: greet`, etc. (no timestamps). `Ctrl+C`.

- [ ] **Step 4: Stop the workers self-labeling**

So worker output reads `[zapp/ticker] started` not `[zapp/ticker] [ticker] started`, drop the manual self-prefix in the worker scripts. In `hello-world/src/workers/ticker.ts` and `supervised.ts`, change `console.log("[ticker] started")` → `console.log("started")` (and similar self-labeled lines). Rebuild, confirm `[zapp/ticker] started` (single prefix).

- [ ] **Step 5: Full gate**

```bash
cd /Users/zach/code/zapp/cli && bun test           # log.test.ts green
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1   # build complete
```

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add hello-world/zapp/app.zc hello-world/src/workers/ticker.ts hello-world/src/workers/supervised.ts
git commit -m "$(cat <<'EOF'
refactor(hello-world): adopt framework log(); drop hand-rolled NSLog helper

Removes hello-world's local log() (NSLog "[native] …"), imports the
framework logger, and reclassifies its calls: framework lifecycle →
logv() (verbose), milestones/demo → log() (default). Workers stop
self-labeling so console reads [zapp/ticker] started (single prefix).
Default dev output is now clean and timestamp-free.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Docs

**Files:**
- Modify: `cli/README.md` (flags), `docs/api-reference.md` (the `log`/`logv`/`logd` app API + `ZAPP_LOG`)

- [ ] **Step 1: Document the flags + env**

In `cli/README.md`, add `--verbose` / `-v` and `--debug` to the dev/build flag list with a one-line description each (verbose = framework lifecycle; debug = compiler invocation + full build errors). Document `ZAPP_LOG=verbose|debug` as the env equivalent that also works on packaged apps.

- [ ] **Step 2: Document the app logging API**

In `docs/api-reference.md`, add a short "Logging" subsection: the Zen-C `log(msg)` / `logv(msg)` / `logd(msg)` functions (default/verbose/debug), that output is `[zapp] <msg>` (and worker `console.log` is `[zapp/<worker>]`), and that levels are controlled by `--verbose`/`--debug` (dev) or `ZAPP_LOG` (any build).

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/README.md docs/api-reference.md
git commit -m "$(cat <<'EOF'
docs(log): document --verbose/--debug, ZAPP_LOG, and log()/logv()/logd()

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage (Part A):**
- Level model default/verbose/debug → Tasks 3 (CLI) + 1 (native). ✓
- Level reaches native via ZAPP_LOG → Tasks 1 (read) + 5 (inject). ✓
- `log()` NSLog→fprintf, kill timestamp → Tasks 1 (framework primitive) + 7 (hello-world migration drops the NSLog helper). ✓
- Unified `[zapp]` / `[zapp/<worker>]`; drop `[native]`/`[js-console]`/`[bare:]` → Tasks 1, 2, 7. ✓
- Worker console auto-prefix + stop self-labeling → Tasks 2 + 7.4. ✓
- Errors never swallowed → Task 6. ✓
- bun:test where pure TS → Task 3 (clog/level). ✓
- Docs → Task 8. ✓

**Placeholder scan:** Step 2 of Task 1 ("mirror how sources are gathered") and Task 2/7 import-path mirroring are deliberate "match existing pattern + verify" instructions for native-build mechanics that must be read in-situ — each pairs with a concrete build-verify. The C primitive, the CLI helper, and the error block are fully specified. No `TBD`/"handle errors"/"etc." placeholders.

**Type consistency:** levels are integers 0/1/2 everywhere (native `zapp_log_level`, CLI `levelFromArgv`/`clog`); `ZAPP_LOG` string values `""`/`verbose`/`debug` consistent between `envFromLevel` (Task 3) and `zapp_log_init` (Task 1). `zapp_log_emit`/`zapp_log_init`/`zapp_log_level` names consistent across Tasks 1, 2, 5. `clog`/`clogError`/`getCliLevel`/`envFromLevel` consistent across Tasks 3-6.
