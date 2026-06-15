# Nim Migration — Phase 1 Walking Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a Nim-driven build that boots a macOS Zapp window, loads the bundled web assets, and round-trips one bridge call + clipboard — proving the real Nim-driven build + orchestration ergonomics on the actual codebase.

**Architecture:** Nim drives the build (`nim c`, not `zc build`). The platform `.m` layer is reused **untouched**. The Nim↔`.m` boundary is **bidirectional C-ABI**: Nim `{.importc, cdecl.}`s the `darwin_*` functions and `{.exportc, cdecl.}`s every `zapp_*`/`wopts_*` symbol the `.m` files call back into. Between Nim orchestration modules: normal Nim imports. Write **idiomatic Nim, not transliterated Zen-C** (see the design's *Guiding principle*).

**Tech Stack:** Nim 2.x (ORC GC), clang (ObjC backend via Nim `{.compile.}`), Bun/TS CLI, WKWebView/Cocoa. Spec: `docs/superpowers/specs/2026-06-15-nim-migration-design.md`. Branch: `feat/nim-native` (already cut).

---

## Working rules (read first)

- **Branch:** all work on `feat/nim-native` (already cut off `origin/main`). `main` keeps shipping on `zc`.
- **Reuse the `.m`/`.c` platform layer untouched.** Do not edit `native/platform/**`. If a `.m` needs a symbol, Nim must `{.exportc.}` it with the *exact* name + signature the `.m`'s `extern` decl uses.
- **Idiomatic Nim.** Re-express, don't transliterate. `{.emit.}` only when genuinely unavoidable. Per module, note in the assessment where Nim beat (or didn't beat) the Zen-C original.
- **Boundary rules (the `.m`↔Nim contract is good patterns — these keep it debt-free):**
  1. **cstring lifetime:** every `{.exportc.}` getter returning a `cstring` is backed by a module-level `let`, never a temporary string literal (the `.m` may read it past the call — temporary = use-after-free).
  2. **No `{.emit.}` for struct ABIs:** any C struct the `.m` reads directly (e.g. `ZappEmbeddedAsset`) is a layout-matched `{.exportc.}` Nim object, not inline `{.emit.}`. `{.emit.}` only if a layout truly can't be expressed — and flag it.
  3. **`ZAPP_NATIVE_LANG=nim` is temporary scaffolding** — the `nim c` vs `zc build` fork is explicitly time-boxed, deleted at cutover. Don't entrench it.
  - `wopts_*` accessors + `zapp_build_*` getters are **kept deliberately** (opaque-handle encapsulation / config-pull — standard patterns, not Zen-C debt). Do not "fix" them into shared structs in the skeleton.
- **NEVER stage user-WIP:** `kitchen-sink/`, `native/worker/engines/zjs-cross-eval-test.c`, `vendor/txiki.js/`, `vendor/bare`, `hello-world/src/worker.ts`, `hello-world/zapp.config.ts`. Stage by explicit path only — never `git add -A`.
- **Commit trailer (exact):** end every commit with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Always Bun, never Node.
- **Build success** = the native build's last line is `[zapp] build complete: <path>` AND a fresh binary mtime — *not* an intermediate "compiled OK". CLI type-checks via `bun run check` (esbuild build does NOT type-check).
- macOS only this plan. iOS/Windows = later phases.

## ABI reference (verbatim — the load-bearing contracts)

**Nim must `{.importc, cdecl.}` (provided by the `.m` layer):**
```
void  darwin_platform_init(const char* app_name);
int   darwin_platform_run(bool terminate_after_last_window);
void* darwin_window_create(void* opts);                 // opts opaque; .m reads it via wopts_*
void  darwin_window_register_numeric_id(void* handle, int32_t numeric_id);
void  darwin_window_eval_js(int32_t window_id, const char* js);
void  darwin_window_set_bridge_ready(const char* window_id);
char* darwin_clipboard_read_text(void);                 // see clipboard.h for the full set
bool  darwin_clipboard_write_text(const char* text);
char* darwin_clipboard_read_html(void);
bool  darwin_clipboard_write_html(const char* html);
char* darwin_clipboard_read_files(void);
bool  darwin_clipboard_has(const char* fmt);
void  darwin_clipboard_clear(void);
```

**Nim must `{.exportc, cdecl.}` (called BY the untouched `.m` layer):**
```
// webview.m → orchestration
void        zapp_handle_message_from_window(void* app, char* msg, int32_t window_id);
const char* zapp_webview_bootstrap_script(void);        // GENERATED (Task 2)
// webview.m → generated build config (GENERATED, Task 2)
const char* zapp_build_initial_url(void);
int         zapp_build_use_embedded_assets(void);
const char* zapp_build_csp(void);
int         zapp_build_is_dev(void);
const char* zapp_build_asset_root(void);
const char* zapp_build_custom_protocols_json(void);
int         zapp_build_webview_autoplay_without_user_gesture(void);
int         zapp_build_webview_back_forward_gestures(void);
int         zapp_build_webview_text_interaction_enabled(void);
int         zapp_build_webview_minimum_font_size(void);
int         zapp_build_dev_tools_default(void);
// app.zc had: zapp_log_init() — provide a no-op stub for the skeleton
void        zapp_log_init(void);
// window.m → WindowOptions accessors (opaque opts). FULL set window.m references
// (return real values for title/size/etc.; sane defaults for unused features):
const char* wopts_title(void* opts);  int32_t wopts_width(void* opts);  int32_t wopts_height(void* opts);
int32_t wopts_x(void* opts);  int32_t wopts_y(void* opts);  bool wopts_auto_center(void* opts);
bool wopts_visible(void* opts);  bool wopts_resizable(void* opts);  bool wopts_closable(void* opts);
bool wopts_minimizable(void* opts);  bool wopts_maximizable(void* opts);  bool wopts_borderless(void* opts);
bool wopts_transparent(void* opts);  bool wopts_always_on_top(void* opts);  const char* wopts_background_color(void* opts);
int32_t wopts_numeric_id_prealloc(void* opts);  int32_t wopts_web_content_inspectable(void* opts);
const char* wopts_sidebar_url(void* opts);  const char* wopts_inspector_url(void* opts);
const char* wopts_toolbar_json(void* opts);  int32_t wopts_as_sheet_of_id(void* opts);
// (+ the remaining wopts_* window.m declares — enumerate exhaustively from
//    native/platform/darwin/window.m extern lines in Task 4, return defaults.)
```
> **Authoritative source for the full `wopts_*` set: `grep -n 'extern .*wopts_' native/platform/darwin/window.m`.** Task 4 enumerates and exports *all* of them.

---

## Task 0: Branch sanity + Nim toolchain + skeleton dir

**Files:**
- Create: `native/nim/README.md` (placeholder marker for the Nim tree)

- [ ] **Step 1: Confirm branch + Nim toolchain**

Run:
```bash
cd /Users/zach/code/zapp
git branch --show-current            # must print: feat/nim-native
nim --version | head -1               # expect: Nim Compiler Version 2.x
```
Expected: branch is `feat/nim-native`; Nim 2.x present. If Nim is missing: `brew install nim`.

- [ ] **Step 2: Prove `nim c` + ORC produce a running binary (toolchain smoke)**

Run:
```bash
cat > /tmp/nimsmoke.nim <<'EOF'
echo "nim-orc-ok"
EOF
nim c --mm:orc -d:release --opt:size -o:/tmp/nimsmoke /tmp/nimsmoke.nim && /tmp/nimsmoke
```
Expected: prints `nim-orc-ok`. Confirms Nim + ORC + the C backend work on this machine.

- [ ] **Step 3: Create the Nim tree marker**

```bash
mkdir -p native/nim
printf '%s\n' "# Nim orchestration layer (feat/nim-native). Greenfield rebuild of the .zc layer; see docs/superpowers/specs/2026-06-15-nim-migration-design.md" > native/nim/README.md
```

- [ ] **Step 4: Commit**

```bash
git add native/nim/README.md
git commit -m "$(printf 'chore(nim): scaffold native/nim tree + confirm Nim 2.x/ORC toolchain\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 1: ObjC-via-Nim build (the #1 risk — de-risked first)

**Goal:** Prove `nim c` can `{.compile.}` a real platform `.m` file with `-fobjc-arc`, link Cocoa, and call `darwin_platform_init` — the single biggest unknown. No app yet; just the build mechanism.

**Files:**
- Create: `native/nim/platform.nim`
- Create: `native/nim/smoke_main.nim` (throwaway, deleted in Task 3)

- [ ] **Step 1: Write the platform binding (idiomatic Nim, `importc` the C-ABI)**

`native/nim/platform.nim`:
```nim
## Platform boot bindings. The ObjC lives in native/platform/darwin/*.m,
## reused untouched; we only bind the plain-C entry points.
{.passC: "-I " & currentSourcePath().parentDir & "/../platform/darwin".}

import std/os

proc darwin_platform_init(appName: cstring) {.importc, cdecl.}
proc darwin_platform_run(terminateAfterLastWindow: bool): cint {.importc, cdecl.}

proc platformInit*(name: string) = darwin_platform_init(name.cstring)
proc platformRun*(terminateAfterLastWindow: bool): int =
  darwin_platform_run(terminateAfterLastWindow).int
```

- [ ] **Step 2: Write the throwaway smoke main that compiles ONE `.m` + links Cocoa**

`native/nim/smoke_main.nim`:
```nim
## THROWAWAY (deleted in Task 3). Proves: Nim {.compile.}s an ObjC .m with ARC,
## links Cocoa, and calls into it. Compiles only platform.m (its only dep here).
{.passL: "-framework Cocoa -framework CoreFoundation".}
{.compile: ("../platform/darwin/platform.m", "-fobjc-arc").}

import platform

platformInit("nim-smoke")
echo "darwin_platform_init returned — ObjC-via-Nim build works"
# Do NOT call platformRun here (it blocks in NSApp run); init is enough to prove linkage.
```
> If `platform.m` pulls in other `.m` symbols at link time (undefined symbols), add the minimal extra `{.compile: ("../platform/darwin/<file>.m", "-fobjc-arc").}` lines until it links — and record which were needed (informs Task 3/4).

- [ ] **Step 3: Build it**

Run:
```bash
cd /Users/zach/code/zapp/native/nim
nim c --cc:clang --mm:orc -d:release --opt:size -o:/tmp/nimsmoke_app smoke_main.nim 2>&1 | tail -20
```
Expected: compiles and links with **0 errors**; produces `/tmp/nimsmoke_app`.
**If it fails on ObjC/ARC:** fall back to the Bare-runtime pattern — precompile the `.m`(s) to a `.a` (`clang -c -fobjc-arc -x objective-c …` then `ar rcs`) and `{.passL: "…/libzapp_platform.a".}` instead of `{.compile.}`. Record which path worked; the rest of the plan uses whichever links.

- [ ] **Step 4: Run it**

Run: `/tmp/nimsmoke_app`
Expected: prints `darwin_platform_init returned — ObjC-via-Nim build works`, exit 0. (A Dock icon may flash — fine.)

- [ ] **Step 5: Commit** (commit `platform.nim`; the smoke main is throwaway but commit it for the record — it's deleted in Task 3)

```bash
cd /Users/zach/code/zapp
git add native/nim/platform.nim native/nim/smoke_main.nim
git commit -m "$(printf 'feat(nim): ObjC-via-Nim build proven — {.compile.} platform.m + ARC + Cocoa\n\nNim {.compile.}s the untouched darwin platform.m with -fobjc-arc, links\nCocoa, and calls darwin_platform_init. De-risks the skeleton (highest\nunknown). Records the {.compile.} vs precompiled-.a path that worked.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: Generated build-config + bootstrap → Nim (the exportc surface webview.m needs)

**Goal:** Teach the CLI to emit the `zapp_build_*` getters + `zapp_webview_bootstrap_script` as **Nim** (`{.exportc.}`), replacing the `.zc` codegen. TDD via the existing `bun:test` suite.

**Files:**
- Modify: `cli/src/build-config.ts` (the `generateBuildConfig` + bootstrap emitters)
- Create: `cli/src/build-config-nim.test.ts`
- Reference: current emitters in `cli/src/build-config.ts` (`generateBuildConfig` ~lines 132-151), `bootstrap/codegen.ts` (`generateBootstrap`)

- [ ] **Step 1: Write the failing test for the Nim build-config emitter**

`cli/src/build-config-nim.test.ts`:
```ts
import { test, expect } from "bun:test";
import { renderBuildConfigNim } from "./build-config";

test("renderBuildConfigNim emits exportc getters the .m layer calls", () => {
  const out = renderBuildConfigNim({
    initialUrl: "zapp://index.html",
    identifier: "com.example.app",
    assetRoot: "",
    embedAssets: true,
    devTools: 1,
    isDev: false,
  });
  // exact symbols webview.m's extern decls require:
  expect(out).toContain('proc zapp_build_initial_url(): cstring {.exportc, cdecl.}');
  expect(out).toContain('proc zapp_build_use_embedded_assets(): cint {.exportc, cdecl.}');
  expect(out).toContain('"zapp://index.html"');
  expect(out).toContain('return 1.cint'); // embedAssets true
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test cli/src/build-config-nim.test.ts`
Expected: FAIL — `renderBuildConfigNim` is not exported.

- [ ] **Step 3: Implement `renderBuildConfigNim` (idiomatic Nim output)**

Add to `cli/src/build-config.ts` (export a pure renderer; keep the existing `.zc` one until cutover so nothing breaks):
```ts
export interface BuildConfigNimOpts {
  initialUrl: string; identifier: string; assetRoot: string;
  embedAssets: boolean; devTools: number; isDev: boolean;
}
export function renderBuildConfigNim(o: BuildConfigNimOpts): string {
  const s = (v: string) => JSON.stringify(v); // safe Nim/C string literal
  const b = (v: boolean) => (v ? "1" : "0");
  return `## AUTO-GENERATED by zapp CLI (Nim). Do not edit.
proc zapp_build_initial_url(): cstring {.exportc, cdecl.} = ${s(o.initialUrl)}.cstring
proc zapp_build_identifier(): cstring {.exportc, cdecl.} = ${s(o.identifier)}.cstring
proc zapp_build_asset_root(): cstring {.exportc, cdecl.} = ${s(o.assetRoot)}.cstring
proc zapp_build_use_embedded_assets(): cint {.exportc, cdecl.} = return ${b(o.embedAssets)}.cint
proc zapp_build_csp(): cstring {.exportc, cdecl.} = "".cstring
proc zapp_build_is_dev(): cint {.exportc, cdecl.} = return ${b(o.isDev)}.cint
proc zapp_build_dev_tools_default(): cint {.exportc, cdecl.} = return ${o.devTools}.cint
proc zapp_build_custom_protocols_json(): cstring {.exportc, cdecl.} = "[]".cstring
proc zapp_build_webview_autoplay_without_user_gesture(): cint {.exportc, cdecl.} = return 0.cint
proc zapp_build_webview_back_forward_gestures(): cint {.exportc, cdecl.} = return 0.cint
proc zapp_build_webview_text_interaction_enabled(): cint {.exportc, cdecl.} = return 1.cint
proc zapp_build_webview_minimum_font_size(): cint {.exportc, cdecl.} = return 0.cint
proc zapp_log_init() {.exportc, cdecl.} = discard
`;
}
```
> Note: returning a `cstring` from a Nim string literal `.cstring` is valid for these short-lived getters webview.m reads synchronously. If a getter's result must outlive the call, back it with a module-level `let` (idiomatic Nim) — note any that need it.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test cli/src/build-config-nim.test.ts`
Expected: PASS.

- [ ] **Step 5: Add the bootstrap emitter test + impl**

Append to the test file:
```ts
import { renderBootstrapNim } from "./build-config";
test("renderBootstrapNim emits the bootstrap script exportc", () => {
  const out = renderBootstrapNim("globalThis.__x=1;");
  expect(out).toContain('proc zapp_webview_bootstrap_script(): cstring {.exportc, cdecl.}');
});
```
Implement in `build-config.ts`:
```ts
export function renderBootstrapNim(webviewJs: string): string {
  // Nim raw string literal r"""...""" avoids escaping; close-sequence guard:
  const safe = webviewJs.replace(/"""/g, '"" + "\\"" + "');
  return `## AUTO-GENERATED bootstrap (Nim).
let zappWebviewBootstrap = r"""${safe}"""
proc zapp_webview_bootstrap_script(): cstring {.exportc, cdecl.} = zappWebviewBootstrap.cstring
`;
}
```
Run: `bun test cli/src/build-config-nim.test.ts` → PASS. Then `bun run check` → no new type errors.

- [ ] **Step 6: Commit**

```bash
git add cli/src/build-config.ts cli/src/build-config-nim.test.ts
git commit -m "$(printf 'feat(nim,cli): emit build-config + bootstrap as Nim exportc\n\nrenderBuildConfigNim/renderBootstrapNim produce the zapp_build_* getters\nand zapp_webview_bootstrap_script that the untouched webview.m calls back\ninto, as {.exportc, cdecl.} Nim. bun-tested. Existing .zc emitters kept\nuntil cutover.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: Nim build root + platform/app boot + CLI `nim c` invocation (app launches)

**Goal:** A Nim root that boots the app (`darwin_platform_init` → `darwin_platform_run`), driven by the CLI calling `nim c`. App launches into the NSApp run loop (no window yet) and can be quit.

**Files:**
- Create: `native/nim/app.nim` (App object + run)
- Create: `native/nim/zapp.nim` (root: imports modules, `{.compile.}`s the `.m` set, `{.passL.}` frameworks, top-level boot)
- Modify: `cli/src/native.ts` (add a `nim c` build path, gated behind `--native-lang nim` or detection of `feat/nim-native`)
- Delete: `native/nim/smoke_main.nim`

- [ ] **Step 1: Write `app.nim` (idiomatic Nim — `object`, not struct+impl transliteration)**

`native/nim/app.nim`:
```nim
import platform

type App* = object
  name*: string
  terminateAfterLastWindowClosed*: bool

proc newApp*(name: string, terminateAfterLastWindowClosed = true): App =
  ## Mirrors App::new — init the platform, return the app value.
  zapp_log_init()            # exportc'd no-op stub (generated config provides the real one)
  platformInit(name)
  App(name: name, terminateAfterLastWindowClosed: terminateAfterLastWindowClosed)

proc run*(app: App): int =
  ## Enters the Cocoa run loop (blocks). Services/headless workers wired later.
  platformRun(app.terminateAfterLastWindowClosed)

proc zapp_log_init() {.importc, cdecl.}  # provided by generated config (Task 2) or stub
```
> `zapp_log_init` is `exportc`'d by the generated config in Task 2; here `app.nim` only needs it to exist at link time. For the standalone build before generated config is wired, add a local `{.exportc.}` no-op in `zapp.nim` (Step 2) and remove once generated config is linked.

- [ ] **Step 2: Write the root `zapp.nim` (build manifest + boot)**

`native/nim/zapp.nim`:
```nim
## Nim build root. Compiles the untouched darwin .m layer and links frameworks,
## then boots the app. Generated config (build-config/bootstrap/assets) is added
## to the compile by the CLI (Task 3 Step 4 / Task 4); for now a local stub
## satisfies zapp_log_init.
{.passC: "-I " & currentSourcePath().parentDir & "/../platform/darwin".}
{.passL: "-framework Cocoa -framework WebKit -framework CoreFoundation -framework JavaScriptCore -framework Security".}
{.passL: "-lcompression -lz".}
{.compile: ("../platform/darwin/platform.m", "-fobjc-arc").}
# webview.m/window.m/etc. added in Task 4 when the window path lands.

import app

proc zapp_log_init() {.exportc, cdecl.} = discard  # TEMP until generated config links

let a = newApp("Zapp Nim Skeleton")
quit(a.run())
```

- [ ] **Step 3: Build the root directly to confirm it boots**

Run:
```bash
cd /Users/zach/code/zapp/native/nim
nim c --cc:clang --mm:orc -d:release --opt:size -o:/tmp/zapp_nim zapp.nim 2>&1 | tail -20
```
Expected: 0 errors, `/tmp/zapp_nim` produced. Run `/tmp/zapp_nim &` then `kill %1` after ~1s — it should enter the run loop (process stays alive) without crashing. (No window yet — that's Task 4.)

- [ ] **Step 4: Wire the CLI to drive `nim c` (idiomatic, behind a flag)**

In `cli/src/native.ts`, add a function `buildNativeNim(root, output, opts)` that assembles and runs the `nim c` invocation, mirroring the existing `zc build` step's logging (must end with `[zapp] build complete: <path>`):
```ts
// near the existing zc build assembly (~native.ts:1073)
async function buildNativeNim(root: string, output: string, verbose: boolean) {
  const nimRoot = path.join(root, "native", "nim", "zapp.nim");
  const args = ["c", "--cc:clang", "--mm:orc", "-d:release", "--opt:size",
                `-o:${output}`, ...(verbose ? [] : ["--hints:off"]), nimRoot];
  const proc = Bun.spawn(["nim", ...args], { cwd: root, stdout: "inherit", stderr: "inherit" });
  const code = await proc.exited;
  if (code !== 0) throw new Error(`nim c failed (exit ${code})`);
  console.log(`[zapp] build complete: ${output}`);
}
```
Gate it: call `buildNativeNim` instead of the `zc build` path when `process.env.ZAPP_NATIVE_LANG === "nim"` (the skeleton's opt-in switch — keeps the `zc` path default and untouched).

- [ ] **Step 5: Delete the throwaway smoke main; verify CLI-driven build**

```bash
git rm native/nim/smoke_main.nim
```
Run a real build of hello-world via the CLI with the Nim switch (exact dev/build command per `cli/README.md`, e.g.):
```bash
cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5
```
Expected: last line `[zapp] build complete: <path>`; fresh binary mtime. (App may not show a window until Task 4 — building + linking is the gate here.)

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/app.nim native/nim/zapp.nim cli/src/native.ts
git rm --cached native/nim/smoke_main.nim 2>/dev/null || true
git commit -m "$(printf 'feat(nim): Nim build root + app boot + CLI nim-c driver\n\nzapp.nim {.compile.}s the darwin platform layer + links frameworks and\nboots via darwin_platform_init/run. cli/src/native.ts gains buildNativeNim\n(ZAPP_NATIVE_LANG=nim opt-in); zc path stays default. App enters the run\nloop under a Nim-driven build.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 4: Window + webview + assets → SUB-GATE A

**Goal:** A window appears with a `WKWebView` that loads the bundled assets. Requires: the `WindowOptions` opaque object + the **full `wopts_*` exportc surface** window.m calls; `darwin_window_create`; wiring the generated build-config + bootstrap + assets into the Nim compile.

**Files:**
- Create: `native/nim/window.nim` (WindowOptions object + wopts_* exportc + create)
- Modify: `native/nim/zapp.nim` (compile webview.m/window.m + the rest of the macOS `.m` set; create a window at boot; link generated config/bootstrap/assets Nim)
- Modify: `cli/src/native.ts` / `cli/src/build-config.ts` (write the generated config/bootstrap/assets `.nim` into `.zapp/` and pass them to `nim c`)
- Reference: `native/platform/darwin/window.m` (the `wopts_*` extern list), `native/window/window.zc:34-246`, `cli/src/assets.ts`

- [ ] **Step 1: Enumerate the exact `wopts_*` surface window.m requires**

Run:
```bash
grep -n 'extern .*wopts_' native/platform/darwin/window.m
```
Record every signature. **Every one must be `{.exportc, cdecl.}`'d** in `window.nim` (real value for fields the skeleton sets; sane default otherwise). Missing any = link error.

- [ ] **Step 2: Write `window.nim` (idiomatic WindowOptions + opaque-pointer exportc accessors)**

`native/nim/window.nim` (representative — fill the full `wopts_*` set from Step 1):
```nim
## WindowOptions is opaque to window.m, which reads it via wopts_* C calls.
## We own the layout; the accessors are the ABI. Idiomatic: a ref object +
## exportc thin accessors (no manual struct-field C emission like zc).
type WindowOptions* = ref object
  title*: string
  width*, height*, x*, y*: int32
  autoCenter*, visible*, resizable*, closable*, minimizable*, maximizable*: bool
  borderless*, transparent*, alwaysOnTop*: bool
  backgroundColor*: string
  numericIdPrealloc*: int32
  webContentInspectable*: int32      # -1 inherit, 0 off, 1 on

proc newWindowOptions*(title: string): WindowOptions =
  WindowOptions(title: title, width: 1200, height: 800, x: 0, y: 0,
    autoCenter: false, visible: true, resizable: true, closable: true,
    minimizable: true, maximizable: true, borderless: false, transparent: false,
    alwaysOnTop: false, backgroundColor: "", numericIdPrealloc: -1,
    webContentInspectable: -1)

# --- ABI accessors window.m calls (opts is the WindowOptions ref as void*) ---
template opt(p: pointer): WindowOptions = cast[WindowOptions](p)
proc wopts_title(p: pointer): cstring {.exportc, cdecl.} = opt(p).title.cstring
proc wopts_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).width
proc wopts_height(p: pointer): int32 {.exportc, cdecl.} = opt(p).height
proc wopts_x(p: pointer): int32 {.exportc, cdecl.} = opt(p).x
proc wopts_y(p: pointer): int32 {.exportc, cdecl.} = opt(p).y
proc wopts_auto_center(p: pointer): bool {.exportc, cdecl.} = opt(p).autoCenter
proc wopts_visible(p: pointer): bool {.exportc, cdecl.} = opt(p).visible
proc wopts_resizable(p: pointer): bool {.exportc, cdecl.} = opt(p).resizable
proc wopts_closable(p: pointer): bool {.exportc, cdecl.} = opt(p).closable
proc wopts_minimizable(p: pointer): bool {.exportc, cdecl.} = opt(p).minimizable
proc wopts_maximizable(p: pointer): bool {.exportc, cdecl.} = opt(p).maximizable
proc wopts_borderless(p: pointer): bool {.exportc, cdecl.} = opt(p).borderless
proc wopts_transparent(p: pointer): bool {.exportc, cdecl.} = opt(p).transparent
proc wopts_always_on_top(p: pointer): bool {.exportc, cdecl.} = opt(p).alwaysOnTop
proc wopts_background_color(p: pointer): cstring {.exportc, cdecl.} = opt(p).backgroundColor.cstring
proc wopts_numeric_id_prealloc(p: pointer): int32 {.exportc, cdecl.} = opt(p).numericIdPrealloc
proc wopts_web_content_inspectable(p: pointer): int32 {.exportc, cdecl.} = opt(p).webContentInspectable
# Defaults for unused-this-skeleton features window.m still queries:
proc wopts_sidebar_url(p: pointer): cstring {.exportc, cdecl.} = "".cstring
proc wopts_inspector_url(p: pointer): cstring {.exportc, cdecl.} = "".cstring
proc wopts_toolbar_json(p: pointer): cstring {.exportc, cdecl.} = "".cstring
proc wopts_as_sheet_of_id(p: pointer): int32 {.exportc, cdecl.} = -1
# ... ALL remaining wopts_* from Step 1, returning safe defaults ...

# --- create ---
proc darwin_window_create(opts: pointer): pointer {.importc, cdecl.}
proc darwin_window_register_numeric_id(handle: pointer, id: int32) {.importc, cdecl.}

var gNextWindowId: int32 = 0
proc createWindow*(o: WindowOptions): tuple[id: int32, handle: pointer] =
  let id = gNextWindowId; inc gNextWindowId
  o.numericIdPrealloc = id
  GC_ref(o)                       # keep alive: window.m holds the pointer past this call
  let h = darwin_window_create(cast[pointer](o))
  darwin_window_register_numeric_id(h, id)
  (id, h)
```
> **Memory note (idiomatic + correct):** the WindowOptions `ref` is handed to C, which dereferences it during `darwin_window_create` and possibly after (auto-show machinery). `GC_ref` pins it so ORC won't collect it while C holds the pointer. Document this in the assessment as a real Nim↔C ownership lesson.

- [ ] **Step 3: Wire generated config + bootstrap + assets into the build**

Extend the CLI (Task 2 emitters + a Nim assets emitter): write `.zapp/zapp_build_config.nim`, `.zapp/zapp_bootstrap.nim`, `.zapp/zapp_assets.nim` and pass them to `nim c` (either `import`ed by `zapp.nim` or added as extra compile units). For assets, port `cli/src/assets.ts` to emit Nim: embed each `.br` with `const data = staticRead("…")` (Nim's compile-time file embed) + a `{.exportc.}` `zapp_embedded_assets`/count matching the `ZappEmbeddedAsset` C struct the scheme handler reads (`webview.m:184+`). Remove the TEMP `zapp_log_init` stub from `zapp.nim` (the generated config now provides it).
> The `ZappEmbeddedAsset` struct layout is read directly by webview.m — Nim must emit a matching `{.exportc.}` array. Define the matching Nim object with `{.exportc.}` + `{.completeStruct.}`-equivalent field order, OR emit the init via a small `{.emit.}` block (a legitimate "unavoidable" use — the struct ABI must match exactly). Prefer the matching Nim object; fall back to `{.emit.}` only if layout control needs it.

- [ ] **Step 4: Create a window at boot**

In `native/nim/zapp.nim`, add the `.m` compile set and create a window:
```nim
{.compile: ("../platform/darwin/window.m", "-fobjc-arc").}
{.compile: ("../platform/darwin/webview.m", "-fobjc-arc").}
{.compile: ("../platform/darwin/screen.m", "-fobjc-arc").}
{.compile: ("../platform/darwin/panel.m", "-fobjc-arc").}
import app, window
let a = newApp("Zapp Nim Skeleton")
let opts = newWindowOptions("Zapp v2 (Nim)")
opts.width = 900; opts.height = 650
discard createWindow(opts)
quit(a.run())
```

- [ ] **Step 5: Build + run → SUB-GATE A**

Run:
```bash
cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5
```
Expected: `[zapp] build complete: <path>`. Launch the produced `.app`.
**SUB-GATE A passes when:** a 900×650 window appears and the `WKWebView` renders the hello-world UI (assets loaded via the `zapp://` scheme handler). If blank: check `zapp_build_use_embedded_assets()` returns 1 and the `zapp_embedded_assets` array is populated (the scheme handler at `webview.m:184` reads them).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/window.nim native/nim/zapp.nim cli/src/native.ts cli/src/build-config.ts cli/src/assets.ts cli/src/*.test.ts
git commit -m "$(printf 'feat(nim): window + webview + embedded assets — SUB-GATE A\n\nNim WindowOptions (opaque ref) + full wopts_* exportc surface window.m\ncalls; createWindow via darwin_window_create with GC_ref pinning.\nGenerated build-config/bootstrap/assets emitted as Nim and linked. A\nNim-driven build now shows a window whose WKWebView loads the bundled\nassets.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 5: Bridge + router + service → one round-trip

**Goal:** A button in hello-world invokes the `greet` service and renders the response. Requires: `zapp_handle_message_from_window` exportc, `bridge_parse`, a minimal router (INVOKE → service), the service registry, and `dispatch_invoke_response` (importc `darwin_window_eval_js`).

**Files:**
- Create: `native/nim/bridge.nim` (parse + dispatch_invoke_response)
- Create: `native/nim/service.nim` (registry + invoke)
- Create: `native/nim/router.nim` (router_handle_message — INVOKE→service for the skeleton)
- Modify: `native/nim/app.nim` (register `greet`; export the message entry)
- Modify: `native/nim/zapp.nim` (import the new modules)
- Reference: `native/bridge/protocol.zc:40-110`, `native/bridge/dispatch.zc:54-93`, `native/app/router.zc:57-303`, `native/service/service.zc:46-148`, `native/build.zc:53-55`

- [ ] **Step 1: Write `bridge.nim` (idiomatic — `std/json` + an object variant for the frame)**

```nim
import std/json, std/options
type BridgeMsg* = object
  t*: int          # message type (1=INVOKE …)
  id*: int         # request id
  m*: string       # method
  a*: JsonNode     # args ("a"), or nil

proc parseBridge*(raw: string): Option[BridgeMsg] =
  try:
    let n = parseJson(raw)
    some BridgeMsg(
      t: n{"t"}.getInt(0), id: n{"id"}.getInt(0),
      m: n{"m"}.getStr(""), a: n{"a"})         # n{"a"} is nil if absent (guarded access)
  except CatchableError: none(BridgeMsg)

proc darwin_window_eval_js(windowId: int32, js: cstring) {.importc, cdecl.}
proc zapp_escape_dup(s: cstring): cstring {.importc, cdecl.}  # reuse the heap escaper
proc free(p: pointer) {.importc, header: "<stdlib.h>".}

proc sendInvokeResponse*(windowId, requestId: int, ok: bool, payload: string) =
  ## Mirrors dispatch_invoke_response: synthesize the bridge IIFE, eval on the window.
  let esc = zapp_escape_dup(payload.cstring)
  let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
           "if(b&&typeof b._onInvokeResult==='function'){b._onInvokeResult(" &
           $requestId & "," & (if ok: "true" else: "false") & ",'" & $esc & "');}})();"
  darwin_window_eval_js(windowId.int32, js.cstring)
  free(esc)
```
> Uses Nim `std/json` with guarded `{}` access (returns nil/default, no raise) — idiomatic + the defensive-JSON the design called for. `n{"a"}` yields `nil` when absent.

- [ ] **Step 2: Write `service.nim` (idiomatic — a `Table` registry, Nim proc handlers)**

```nim
import std/[json, tables, options]
type ServiceHandler* = proc(args: JsonNode): string {.nimcall.}
var registry = initTable[string, ServiceHandler]()
proc addService*(name: string, h: ServiceHandler) = registry[name] = h
proc invokeService*(name: string, args: JsonNode): Option[string] =
  if registry.hasKey(name): some registry[name](args) else: none(string)
```
> Idiomatic win over the Zen-C linear `g_services[]` + raw `for`/`strcmp`: a `Table` lookup, real Nim proc values, `Option` result. (The `App*`-passing + pthread mutex of stateful services is deferred — the skeleton's `greet` is stateless.)

- [ ] **Step 3: Write `router.nim` (skeleton: INVOKE → clipboard prefix (Task 6) | service)**

```nim
import std/[json, options], bridge, service
proc routeMessage*(msg: string, windowId: int) =
  let parsed = parseBridge(msg)
  if parsed.isNone: return
  let f = parsed.get
  if f.t != 1: return            # skeleton handles INVOKE only; others added in breadth
  # __clipboard: prefix is added in Task 6.
  # NB: sendInvokeResponse(windowId, requestId, …) — window first, request id second
  # (matches dispatch_invoke_response's (int window_id, int request_id) order).
  let res = invokeService(f.m, f.a)
  if res.isSome: sendInvokeResponse(windowId, f.id, true, res.get)
  else: sendInvokeResponse(windowId, f.id, false, "\"NOT_FOUND\"")
```

- [ ] **Step 4: Wire the message entry + register `greet` in `app.nim`**

Add to `app.nim`:
```nim
import std/json, router, service
proc greetService(args: JsonNode): string = """{"greeting":"hello from nim"}"""
proc registerSkeletonServices*() = addService("greet", greetService)

proc zapp_handle_message_from_window(app: pointer, msg: cstring, windowId: int32)
    {.exportc, cdecl.} =
  routeMessage($msg, windowId.int)   # $cstring copies to a Nim string (idiomatic)
```
Call `registerSkeletonServices()` in `zapp.nim` before `a.run()`. Add `bridge.nim`, `service.nim`, `router.nim` imports to `zapp.nim`.

- [ ] **Step 5: Build + run → bridge round-trip**

Run:
```bash
cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5
```
Launch the `.app`. In the hello-world UI, trigger the action that calls the `greet` service (the existing demo button).
Expected: the UI renders `hello from nim` (the response round-tripped JS → `zapp_handle_message_from_window` → router → service → `darwin_window_eval_js` → `_onInvokeResult`).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/bridge.nim native/nim/service.nim native/nim/router.nim native/nim/app.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): bridge + router + service — one round-trip\n\nzapp_handle_message_from_window (exportc) -> parseBridge (std/json, guarded)\n-> Table-based service registry -> sendInvokeResponse (darwin_window_eval_js).\nhello-world greet() round-trips on a Nim-driven build. Idiomatic: Table +\nproc values + Option vs the zc linear g_services/strcmp.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 6: Clipboard → GATE B (the recipe exemplar)

**Goal:** Clipboard read/write works via the router `__clipboard:` block. This is the first full leaf-module port and the template for Phase 2.

**Files:**
- Create: `native/nim/clipboard.nim`
- Modify: `native/nim/router.nim` (add the `__clipboard:` prefix dispatch)
- Reference: `native/clipboard/clipboard.zc` (full), `native/platform/darwin/clipboard.h`, `native/app/router.zc:1769-1891`

- [ ] **Step 1: Write `clipboard.nim` (idiomatic — the static-slot memory hack disappears)**

```nim
## Clipboard — ports native/clipboard/clipboard.zc. The zc version used raw{}
## blocks + a static char* slot to keep the malloc'd buffer alive; in Nim the
## cstring->string conversion copies, so we free immediately. No slot, no raw.
proc darwin_clipboard_read_text(): cstring {.importc, cdecl.}
proc darwin_clipboard_write_text(s: cstring): bool {.importc, cdecl.}
proc darwin_clipboard_read_html(): cstring {.importc, cdecl.}
proc darwin_clipboard_write_html(s: cstring): bool {.importc, cdecl.}
proc darwin_clipboard_read_files(): cstring {.importc, cdecl.}
proc darwin_clipboard_has(fmt: cstring): bool {.importc, cdecl.}
proc darwin_clipboard_clear() {.importc, cdecl.}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}

proc takeCString(p: cstring): string =
  ## Copy a malloc'd C string into a Nim string and free the C buffer.
  if p.isNil: "" else: (let s = $p; free(cast[pointer](p)); s)

proc readText*(): string = takeCString(darwin_clipboard_read_text())
proc writeText*(s: string): bool = darwin_clipboard_write_text(s.cstring)
proc readHtml*(): string = takeCString(darwin_clipboard_read_html())
proc writeHtml*(s: string): bool = darwin_clipboard_write_html(s.cstring)
proc readFiles*(): string =
  let s = takeCString(darwin_clipboard_read_files()); (if s.len == 0: "[]" else: s)
proc has*(fmt: string): bool = darwin_clipboard_has(fmt.cstring)
proc clear*() = darwin_clipboard_clear()
```
> Verify the `darwin_clipboard_read_*` ownership contract (clipboard.h says "malloc'd C string (caller frees)") — `takeCString` frees, matching it. Record this as an idiomatic win (the zc static-slot hack → 1 helper).

- [ ] **Step 2: Add the `__clipboard:` block to `router.nim`**

```nim
import clipboard, std/strutils
# inside routeMessage, before the service fallback:
  if f.m.startsWith("__clipboard:"):
    # sendInvokeResponse(windowId, requestId, …) — window first, request id second.
    case f.m
    of "__clipboard:readText":  sendInvokeResponse(windowId, f.id, true, escapeJson(readText()))
    of "__clipboard:readHtml":  sendInvokeResponse(windowId, f.id, true, escapeJson(readHtml()))
    of "__clipboard:readFiles": sendInvokeResponse(windowId, f.id, true, readFiles())
    of "__clipboard:has":
      sendInvokeResponse(windowId, f.id, true, $has(f.a{"fmt"}.getStr("")))
    of "__clipboard:writeText":
      discard writeText(f.a{"text"}.getStr("")); sendInvokeResponse(windowId, f.id, true, "{}")
    of "__clipboard:writeHtml":
      discard writeHtml(f.a{"html"}.getStr("")); sendInvokeResponse(windowId, f.id, true, "{}")
    of "__clipboard:clear": clear(); sendInvokeResponse(windowId, f.id, true, "{}")
    else: sendInvokeResponse(windowId, f.id, false, "\"NOT_FOUND\"")
    return
```
> Native string `case … of` — the idiomatic dispatch the design called out (vs the zc `if strncmp` chain). `escapeJson` = `std/json`'s `escapeJson`/`%` to produce a JSON string literal from the text. The image path (`__clipboard:readImagePng`) stays out of scope (it used `darwin_clipboard_read_image_png_b64` directly — deferred to breadth).

- [ ] **Step 3: Build + run → GATE B**

Run:
```bash
cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5
```
Launch the `.app`. **GATE B passes when:** (a) the window shows + webview loads (sub-gate A still holds), (b) the `greet` round-trip works (Task 5), and (c) clipboard write-then-read text/html round-trips through the UI (copy from the app, paste back; or the demo's clipboard buttons). Build's final line is `[zapp] build complete: <path>`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/clipboard.nim native/nim/router.nim
git commit -m "$(printf 'feat(nim): clipboard module + router block — GATE B\n\nFirst full leaf-module port (the recipe exemplar). importc the\ndarwin_clipboard_* C-ABI; the zc static-slot memory hack collapses to one\ntakeCString helper; router uses a native string case. hello-world\nclipboard round-trips on a Nim-driven build. Walking skeleton complete.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 7: Ergonomics assessment (the deliverable) + final gate sign-off

**Files:**
- Create: `docs/superpowers/nim-skeleton-assessment.md`

- [ ] **Step 1: Write the assessment**

Grade the skeleton against the Zen-C friction inventory (from the spec + `spikes/lang-eval/SCORECARD.md`). Required sections, each with concrete evidence from Tasks 1–6:
1. **Build ergonomics** — did `{.compile.}` of `.m` + ARC + frameworks work, or did the `.a` fallback win? Nim-driven build vs `zc build` (speed, clarity, the CLI change surface).
2. **Bidirectional ABI** — the `exportc`/`importc` surface (incl. the `wopts_*` opaque-accessor pattern + `GC_ref` pinning) — friction or clean?
3. **Idiomatic wins, per module** — concretely: clipboard static-slot→`takeCString`; service `Table`+proc vs `g_services`/`strcmp`; router string `case` vs `strncmp`; `std/json` guarded `{}` vs `JsonValue::parse`+`get_*`; `Option`/exceptions vs sentinels.
4. **Idiomatic losses / surprises** — anything Nim made *harder* than Zen-C (ORC↔C ownership, cstring lifetimes, `{.emit.}` needed for the asset struct, etc.).
5. **Verdict** — continue to Phase 2 breadth, or stop. Evidence-based.

- [ ] **Step 2: Confirm all gates green**

Run the build once more (`ZAPP_NATIVE_LANG=nim bun run build` ends with `[zapp] build complete:`) and re-verify sub-gate A + the greet round-trip + clipboard. Run `bun test cli/src/build-config-nim.test.ts` and `bun run check` — green.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/nim-skeleton-assessment.md
git commit -m "$(printf 'docs(nim): Phase-1 skeleton ergonomics assessment + gate sign-off\n\nNim-driven build, bidirectional ABI, per-module idiomatic wins/losses\ngraded vs the Zen-C friction inventory; continue-vs-stop verdict.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Self-review notes (for the executor)

- **Highest risk is Task 1** (ObjC via Nim `{.compile.}`). It is intentionally first and standalone; its fallback (precompiled `.a` + `{.passL.}`) is the known-good Bare-runtime pattern. Everything downstream assumes whichever path linked.
- **The `wopts_*` surface (Task 4 Step 1) must be exhaustive** — window.m calls all of them unconditionally; a missing export is a link error, not a runtime bug.
- **`GC_ref` on WindowOptions (Task 4)** — the one non-obvious ORC↔C ownership rule; if a window's title/size reads as garbage, this is the cause.
- **The asset `ZappEmbeddedAsset` struct ABI (Task 4 Step 3)** is the one place `{.emit.}` may be legitimately unavoidable (exact C struct layout the scheme handler reads). Prefer a matching `{.exportc.}` Nim object; `{.emit.}` is the sanctioned fallback.
- **Scope discipline:** the skeleton ports *minimal* slices (router handles INVOKE + clipboard only; WindowOptions sets the fields hello-world uses, defaults the rest). The remaining methods/fields/modules are Phase 2 — do NOT expand scope here.
- This plan covers **through Gate B only.** Phase 2 (breadth modules → iOS/Windows parity → `main` merge) is separate plans.
