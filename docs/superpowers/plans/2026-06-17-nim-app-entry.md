# Nim App Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an app ship its own Nim entry (`zapp/app.nim`) that the Nim build compiles instead of the hardcoded skeleton, and port kitchen-sink so `greet` returns its real value on the Nim build — proving "Nim runs a real app."

**Architecture:** `native/nim/zapp.nim` becomes a framework umbrella (re-`export`s the app-facing modules) whose skeleton boot is guarded by `when isMainModule:`. An app's `zapp/app.nim` does `import zapp` + its own boot. `buildNativeNim` compiles the app's `app.nim` as the Nim root when present (adding `native/nim` to the Nim search path), else falls back to `zapp.nim` (skeleton). zc build is untouched (still driven by `app.zc`).

**Tech Stack:** Nim (`nim c`, ORC, clang), TypeScript (`cli/src/native.ts`, Bun), the existing C-ABI to the shared `.m`/engine `.c`.

**Design principles (from the spec):** idiomatic Nim at the app/internal layer; thin `exportc` seam (don't prettify); TS stays the default home for app logic; the app-authoring API is ergonomic (`proc(args: JsonNode): string` + `registerService`); raw-`importc` native services are a first-class power-user path. zc + Zen-C apps stay the default this cycle.

---

## File Structure

- **Modify** `native/nim/zapp.nim` — add `export` of app-facing modules; extract the boot block into `proc zappDefaultMain*(): int`; guard the top-level boot with `when isMainModule:`. (Framework-as-library + skeleton-as-fallback.)
- **Modify** `cli/src/native.ts` (`buildNativeNim`, ~1075–1226) — select the app's `zapp/app.nim` as the Nim root when it exists; add `--path:<nativeDir>/nim` so `import zapp` resolves from any root.
- **Create** `kitchen-sink/zapp/app.nim` — the idiomatic-Nim analog of `kitchen-sink/zapp/app.zc` (`greet` + `runApp`). Coexists with `app.zc` (zc build uses `.zc`, nim build uses `.nim`).
- **Modify** `docs/api-reference.md` (or a short `docs/` note) — document authoring an app in Nim (`app.nim`) for the Nim build.
- **No** iOS/Windows stubs, runtime, or router changes — this is build-orchestration + app-layer Nim only (the `#281` lint + tsc gates are unaffected).

---

### Task 1: Framework-as-library — `zapp.nim` exports + `when isMainModule:` boot

**Files:**
- Modify: `native/nim/zapp.nim` (imports block + boot block at lines ~242-264)

The current boot runs at module top-level. Extract it into a reusable proc and guard execution so importing `zapp` (from an app's `app.nim`) does NOT trigger the skeleton boot. Re-`export` the app-facing modules so `import zapp` gives an app everything it needs.

- [ ] **Step 1: Add `export` of the app-facing modules.** After the existing `import` block in `native/nim/zapp.nim`, add:

```nim
# Re-export the app-facing surface so an app's `app.nim` gets everything via
# `import zapp` (newApp/run, AppConfig, WindowOptions/newWindowOptions/createWindow,
# registerService, TriState, JsonNode). The C-ABI side-effect modules stay
# import-only (their exportc procs are pulled in by being compiled).
export app          # newApp, run, App, registerSkeletonServices
export window       # WindowOptions, newWindowOptions, createWindow, windowOptsApplyJson
export service      # registerService, ServiceHandler, LifecycleHook
export appconfig    # AppConfig, Inspectable
export coretypes    # TriState, etc.
import std/json
export json         # JsonNode for service handlers
```

(`std/json` is already imported; the `export json` makes `JsonNode` visible to `import zapp` consumers. Keep the existing `import std/json` — if duplicate, drop the new `import` line and keep only `export json`.)

- [ ] **Step 2: Extract the boot block into a proc.** Replace the top-level boot (lines ~242-264, `let appName = ...` through `quit(a.run())`) with:

```nim
proc zappDefaultMain*(): int =
  ## The skeleton boot — used as the fallback when an app provides no app.nim.
  let appName = $zapp_build_name()
  let a = newApp(if appName.len > 0: appName else: "Zapp Nim Skeleton")
  registerSkeletonServices()
  let windowJson = $zapp_window_config_json()
  var opts: WindowOptions
  if windowJson.len > 0:
    opts = newWindowOptions("Zapp")
    windowOptsApplyJson(opts, parseJson(windowJson))
  else:
    opts = newWindowOptions("Zapp v2 (Nim)")
    opts.width = 900
    opts.height = 650
  opts.inspectable = (if zapp_build_dev_tools_default() > 0: TriState.On else: TriState.Off)
  discard createWindow(opts)
  a.run()

when isMainModule:
  ## Compiled directly (no app.nim) → run the skeleton.
  quit(zappDefaultMain())
```

- [ ] **Step 3: Build the Nim binary (zapp.nim still the root) — confirm no regression.**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | grep -iE "build complete|error" | grep -v "UNRESOLVED_IMPORT\|esbuild"`
Expected: `[zapp] build complete: …/kitchen-sink (… KB)` (skeleton path unchanged — kitchen-sink has no `app.nim` yet, so `zapp.nim` is still the root, `isMainModule` true, skeleton boots exactly as before).

- [ ] **Step 4: Commit.**

```bash
cd /Users/zach/code/zapp && git add native/nim/zapp.nim && git commit -m "$(cat <<'EOF'
refactor(nim): zapp.nim framework-as-library — export app surface, guard boot

Re-export the app-facing modules (app/window/service/appconfig/coretypes/json)
so `import zapp` gives an app's app.nim everything it needs, and move the
skeleton boot into `zappDefaultMain*()` behind `when isMainModule:`. No
behavior change when zapp.nim is the compiled root (skeleton still boots);
this enables an app.nim to import zapp without triggering the skeleton.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2 (RISK GATE): CLI selects `app.nim` root + framework on path; prove with a trivial app.nim

**Files:**
- Modify: `cli/src/native.ts` (`buildNativeNim`, the `nimRoot`/`args` construction ~lines 1213-1222)
- Create (interim): `kitchen-sink/zapp/app.nim` (trivial — proves the mechanism)
- Test: `cli/src/native-nim-root.test.ts` (new, bun:test)

This is the #1 risk: an app-supplied `app.nim` (outside `native/nim/`) compiling + linking the framework + `.m`/engine + generated `.zapp/*.nim`, and booting. Prove it with a trivial `app.nim` that just delegates to `zappDefaultMain()` before porting real logic.

- [ ] **Step 1: Add the root-selection + framework path. Edit `cli/src/native.ts`** — find:

```ts
  const nimRoot = path.join(nativeDir, "nim", "zapp.nim");
```

Replace with:

```ts
  // An app may supply its own Nim entry at <root>/zapp/app.nim (the idiomatic
  // analog of app.zc). When present, compile it as the Nim root; it does
  // `import zapp` to reach the framework. Else fall back to the skeleton.
  const appNim = path.join(root, "zapp", "app.nim");
  const nimRoot = existsSync(appNim) ? appNim : path.join(nativeDir, "nim", "zapp.nim");
```

And in the `args` array (the `nim c …` construction), add the framework dir to the search path so `import zapp` resolves when the root is the app's `app.nim`. Find:

```ts
  const args = ["c", "--cc:clang", "--mm:orc", "--threads:on", "-d:release", "--opt:size",
              `--path:${zappDir}`, `--passL:${providerO}`,
              `-o:${output}`, ...(verbose ? [] : ["--hints:off"]), nimRoot];
```

Replace the `--path:${zappDir}` entry so BOTH the generated modules and the framework are importable:

```ts
  const nimFrameworkDir = path.join(nativeDir, "nim");
  const args = ["c", "--cc:clang", "--mm:orc", "--threads:on", "-d:release", "--opt:size",
              `--path:${zappDir}`, `--path:${nimFrameworkDir}`, `--passL:${providerO}`,
              `-o:${output}`, ...(verbose ? [] : ["--hints:off"]), nimRoot];
```

(Confirm `existsSync` is already imported at the top of `native.ts`; it is used for `providerO`. If not, add `import { existsSync } from "node:fs";`.)

- [ ] **Step 2: Write a bun test for the root-selection logic.** Create `cli/src/native-nim-root.test.ts`. Since `buildNativeNim` is not exported, extract the one-liner into a tiny exported pure helper `chooseNimRoot(root, nativeDir)` in `native.ts` and test that:

```ts
import { test, expect } from "bun:test";
import { chooseNimRoot } from "./native";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

test("chooseNimRoot prefers the app's zapp/app.nim when present", () => {
  const root = mkdtempSync(path.join(tmpdir(), "zapp-"));
  mkdirSync(path.join(root, "zapp"), { recursive: true });
  writeFileSync(path.join(root, "zapp", "app.nim"), "import zapp\n");
  expect(chooseNimRoot(root, "/native")).toBe(path.join(root, "zapp", "app.nim"));
});

test("chooseNimRoot falls back to the skeleton when no app.nim", () => {
  const root = mkdtempSync(path.join(tmpdir(), "zapp-"));
  expect(chooseNimRoot(root, "/native")).toBe(path.join("/native", "nim", "zapp.nim"));
});
```

Add to `native.ts`:
```ts
/** Pick the Nim compile root: the app's own zapp/app.nim if it exists, else the skeleton. */
export function chooseNimRoot(root: string, nativeDir: string): string {
  const appNim = path.join(root, "zapp", "app.nim");
  return existsSync(appNim) ? appNim : path.join(nativeDir, "nim", "zapp.nim");
}
```
…and use `chooseNimRoot(root, nativeDir)` for `nimRoot` in `buildNativeNim`.

- [ ] **Step 3: Run the test.** Run: `cd /Users/zach/code/zapp/cli && bun test src/native-nim-root.test.ts`
Expected: 2 pass.

- [ ] **Step 4: Create the trivial proof `app.nim`.** Create `kitchen-sink/zapp/app.nim`:

```nim
## Kitchen-sink Nim app entry (interim — Task 3 fills in the real greet/runApp).
## Proves the app-supplied-Nim-root path compiles + links + boots.
import zapp

quit(zappDefaultMain())
```

- [ ] **Step 5: RISK GATE — build the Nim binary with the app.nim root.**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | grep -iE "build complete|error|Error:|cannot open|undeclared" | grep -v "UNRESOLVED_IMPORT\|esbuild" | tail -20`
Expected: `[zapp] build complete: …` with NO Nim errors (`cannot open file: zapp`, `undeclared identifier`, link errors). This proves `app.nim` → `import zapp` → framework + `.m`/engine + `.zapp/*.nim` all compile + link from the app-root.
If it fails on `cannot open file: zapp`, the `--path:${nimFrameworkDir}` isn't taking — re-check the args edit.

- [ ] **Step 6: Confirm zc build still uses app.zc (unaffected).**
Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | grep -iE "build complete|error" | grep -v "UNRESOLVED_IMPORT\|esbuild"`
Expected: `[zapp] build complete` (zc path; `app.nim` is ignored by the zc build).

- [ ] **Step 7: Commit.**

```bash
cd /Users/zach/code/zapp && git add cli/src/native.ts cli/src/native-nim-root.test.ts kitchen-sink/zapp/app.nim && git commit -m "$(cat <<'EOF'
feat(cli): compile an app's zapp/app.nim as the Nim root when present

buildNativeNim now picks <root>/zapp/app.nim as the Nim compile root (else
the zapp.nim skeleton) and adds native/nim to the Nim search path so the
app's `import zapp` resolves the framework. chooseNimRoot extracted + bun-
tested. Interim kitchen-sink app.nim delegates to zappDefaultMain to prove
the app-root path compiles/links/boots (RISK GATE). zc build unaffected.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3 (GATE): Port kitchen-sink `app.zc` → real `app.nim`

**Files:**
- Modify: `kitchen-sink/zapp/app.nim` (replace the trivial delegate with real `greet` + `runApp`)

Mirror `kitchen-sink/zapp/app.zc`'s `run_app` + `greet` in idiomatic Nim. The window is created with the same sidebar/inspector opts. `app.zc` uses `visible=false` + `on_ready` to show the window after first paint; the Nim window-ready wrapper is a deferred parity item (see Out of Scope), so this port sets `visible=true` (the chrome shell + first paint make the brief appearance acceptable for the proof).

- [ ] **Step 1: Write the real `kitchen-sink/zapp/app.nim`:**

```nim
## Kitchen-sink, authored in Nim — the idiomatic analog of zapp/app.zc.
## The Nim build (ZAPP_NATIVE_LANG=nim) compiles this as its root; the zc
## build still uses app.zc. greet is a real Nim service handler.
import zapp

proc greet(args: JsonNode): string =
  ## Mirrors app.zc's greet — returns the real value (no more [object Object]).
  "Hello from Zapp!"

proc runApp(): int =
  let a = newApp("kitchen-sink", terminateAfterLastWindowClosed = true)
  registerService("greet", greet)

  var opts = newWindowOptions("Kitchen Sink")
  opts.width = 1100
  opts.height = 700
  opts.sidebarUrl = "#sidebar-pane"
  opts.sidebarWidth = 240
  opts.inspectorUrl = "#inspector-pane"
  opts.inspectorWidth = 300
  opts.inspectorCollapsed = true
  # Web Inspector parity with the skeleton: on in dev, off in prod.
  opts.inspectable = (if zapp_build_dev_tools_default() > 0: TriState.On else: TriState.Off)
  discard createWindow(opts)

  a.run()

quit(runApp())
```

(If `zapp_build_dev_tools_default` isn't visible via `import zapp`, add `export zapp_build_config` to `zapp.nim` in a follow-up step, or drop the `inspectable` line — it's a nicety, not required for the gate. Prefer keeping parity: confirm `zapp_build_config` getters are reachable; if not, `import zapp_build_config` directly in app.nim, which resolves via `--path:${zappDir}`.)

- [ ] **Step 2: Build the Nim binary.**
Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | grep -iE "build complete|error|Error:|undeclared" | grep -v "UNRESOLVED_IMPORT\|esbuild" | tail`
Expected: `[zapp] build complete: …`, no Nim errors.

- [ ] **Step 3: GATE — human smoke (note in commit; the agent verifies the build, the human verifies behavior).** On `ZAPP_NATIVE_LANG=nim bun run dev` in kitchen-sink: the native-chrome shell boots (title "Kitchen Sink", sidebar + inspector), and **Home shows `greet → Hello from Zapp!`** (the real value, not `[object Object]`). On `bun run dev` (zc default), unchanged.
Agent-verifiable proxy: confirm the build links and the bundle is unchanged; the greet-value smoke is the human gate.

- [ ] **Step 4: Commit.**

```bash
cd /Users/zach/code/zapp && git add kitchen-sink/zapp/app.nim && git commit -m "$(cat <<'EOF'
feat(kitchen-sink): author the app in Nim (app.nim) — greet runs on the Nim build

Port app.zc's run_app + greet to idiomatic Nim. The Nim build now runs the
app's OWN code: greet returns "Hello from Zapp!" (no more [object Object]),
the native-chrome shell boots from app.nim. app.zc stays for the zc build.
First real app authored end-to-end in Nim — the migration-completing proof.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Docs + final verification

**Files:**
- Modify: `docs/api-reference.md` (a short "Authoring an app in Nim" note)

- [ ] **Step 1: Add a docs note.** In `docs/api-reference.md`, near the app/build section, add a short subsection: an app may provide `zapp/app.nim` (idiomatic Nim: `import zapp`, define service handlers as `proc(args: JsonNode): string`, `registerService("name", handler)`, build windows with `newWindowOptions`/`createWindow`, `newApp(...).run()`); the Nim build compiles it as the root, the zc build uses `app.zc`. Note power-user `importc` services and that TS remains the default home for app logic.

- [ ] **Step 2: Full gate.** Run both builds + tsc + the iOS-parity lint:
```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | grep -E "build complete" && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | grep -E "build complete"
cd /Users/zach/code/zapp/cli && bun test src/native-nim-root.test.ts src/ios-platform-parity.test.ts
```
Expected: two `[zapp] build complete` lines; tests pass.

- [ ] **Step 3: Commit docs.**
```bash
cd /Users/zach/code/zapp && git add docs/api-reference.md && git commit -m "$(cat <<'EOF'
docs: authoring a Zapp app in Nim (zapp/app.nim)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Out of scope (this cycle)

- **`on_ready` / window-ready callback in Nim** (`win.on_ready` in app.zc): the C-ABI exists (`callbacks.nim` `zapp_window_set_on_ready/trigger`), but `window.nim` has no app-facing wrapper. The port sets `visible=true` instead. Add `window.nim onReady*` + a `show`/ready path as a fast follow-up if the flash matters.
- **hello-world `app.nim`** — port after kitchen-sink proves the path.
- **nim→js services / Nim-sourced TS client codegen** — future spike (JS backend has no C-FFI/threads; pure-logic subset only).
- **Flipping the default to Nim / retiring Zen-C** — later cycle, once Nim-app parity is proven across apps.
- **`zapp init` Nim-app template** — after the model is proven.

## Self-review notes

- Spec coverage: framework-as-library (T1) ✓, app.nim entry (T1+T2) ✓, CLI compiles it (T2) ✓, kitchen-sink port/proof (T3) ✓, principles honored (idiomatic app.nim, free-proc `registerService`, TS-default unchanged) ✓.
- Type consistency: uses the real signatures — `newApp(name, terminateAfterLastWindowClosed=true)`, `registerService(name, ServiceHandler)` (free proc, `proc(args: JsonNode): string`), `newWindowOptions(title)` + field sets, `createWindow(opts)`, `a.run()`. No struct-`AppConfig` constructor (newApp builds it internally).
- Risk first: T2 gates the library/entry/compile mechanism with a trivial delegate before T3 ports real logic.
- Flagged unknown: `zapp_build_dev_tools_default` visibility from `import zapp` (T3 Step 1 has a fallback).
