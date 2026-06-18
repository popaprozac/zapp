# Nim `Inspectable` Unified Enum + Cascade — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace `WindowOptions.inspectable: TriState` + the free `inspectableAuto()` with the single shared `Inspectable` enum (member access `Inspectable.Auto`), resolved as a cascade: per-window → AppConfig → dev-vs-prod.

**Architecture:** `Inspectable` moves to the shared `coretypes` module and gains `Inherit`. `WindowOptions.inspectable: Inspectable = Inspectable.Inherit`; `AppConfig.inspectable` stays `Auto`. The per-window accessor `wopts_inspectable` resolves the cascade (window `Inherit` → app resolver). `TriState` and `inspectableAuto()` are deleted. The webview JS-config flag is routed to the resolved per-window value. Deliberate Nim-only divergence from zc (logged in the spec).

**Tech Stack:** Nim 2.2 (`{.pure.}` enums, field defaults), the C-ABI, `cli/src` (scaffold), Nim `nim c -r` unit tests, the zc iOS-simulator build.

**Spec:** `docs/superpowers/specs/2026-06-18-nim-inspectable-cascade-design.md`

**Coupling note:** moving `Inspectable` to coretypes + removing `TriState` + removing `inspectableAuto()` breaks `appconfig.nim`, `window.nim`, the test, kitchen-sink, and the scaffold simultaneously — so Task 1 is one atomic commit. Task 2 (webview.m) is independent ObjC. Task 3 is docs + final gate + smoke.

---

### Task 1: Unified `Inspectable` enum + cascade resolver (atomic)

**Files:**
- Modify: `native/nim/coretypes.nim` (add `Inspectable`, remove `TriState`)
- Modify: `native/nim/appconfig.nim` (import `Inspectable` from coretypes; getter `Inherit` arm)
- Modify: `native/nim/window.nim` (field type+default; resolver; delete `inspectableAuto`; comments)
- Modify: `native/nim/zapp.nim` (export comments)
- Modify: `native/nim/tests/appconfig_test.nim`, `native/nim/tests/windowmanager_test.nim`
- Modify: `kitchen-sink/zapp/app.nim`, `cli/src/init.ts`

- [ ] **Step 1: Add `Inspectable` to coretypes, remove `TriState`.** In `native/nim/coretypes.nim`, inside the `type` block, DELETE the `TriState* {.pure.} = enum ...` stanza (Unset/Off/On) and add:

```nim
  Inspectable* {.pure.} = enum
    ## Web-inspector enablement, used by both AppConfig (app-wide) and
    ## WindowOptions (per-window) and resolved as a cascade
    ## (window-explicit > AppConfig > dev-vs-prod default).
    Inherit   ## defer to the level above (window → AppConfig); app-level Inherit == Auto
    Auto      ## decide by build: dev-tools flag on → on, else off
    On        ## force on
    Off       ## force off
```

- [ ] **Step 2: appconfig.nim — import the enum + handle `Inherit`.** In `native/nim/appconfig.nim`:
  - Add `import coretypes` at the top (it currently imports nothing); DELETE the local `Inspectable* {.pure.} = enum Auto, On, Off` definition (now in coretypes).
  - Update the stale doc comment that contrasts with `coretypes.TriState` (lines ~6-8) — say `Inspectable` is the shared enum resolved to a bool at the getter (drop the TriState contrast).
  - In `app_get_bootstrap_web_content_inspectable()`, add an `Inherit` arm so the `case` is exhaustive (resolves like `Auto`):

```nim
proc app_get_bootstrap_web_content_inspectable*(): bool {.exportc, cdecl.} =
  case gAppConfig.inspectable
  of Inspectable.On: true
  of Inspectable.Off: false
  of Inspectable.Auto, Inspectable.Inherit: zapp_build_dev_tools_default() > 0
```

  (`AppConfig.inspectable` default stays `Inspectable.Auto`.)

- [ ] **Step 3: window.nim — field type, resolver, delete `inspectableAuto`.** In `native/nim/window.nim`:
  - Line 15: change the `export coretypes` comment from "WindowOptions.inspectable is a coretypes.TriState" → "WindowOptions.inspectable is a coretypes.Inspectable".
  - Line ~29: the `TitleBarStyle` doc comment references "inspectable TriState (Unset/Off/On)" as an analogy — change to "the inspectable cascade enum" (keep the titleBarStyle point intact).
  - Line 61: change `inspectable*: TriState = TriState.Unset  # ...` to:
    ```nim
    inspectable*: Inspectable = Inspectable.Inherit  # cascade: window > AppConfig > dev/prod
    ```
  - Add `import appconfig` near the other imports (appconfig is a leaf — no cycle) so the resolver can call the app-level resolution.
  - Replace the `inspectableAuto` block (the comment + `proc inspectableAuto*()`, keeping the `zapp_build_dev_tools_default` importc) with a cascade resolver:
    ```nim
    # Resolve a per-window Inspectable to the effective bool. Cascade:
    #   On/Off → forced; Auto → dev-tools flag; Inherit → AppConfig's resolution
    #   (app On/Off forced, app Auto/Inherit → dev-tools flag). Mirrors zc's intent.
    proc zapp_build_dev_tools_default(): cint {.importc, cdecl.}
    proc resolveInspectable*(w: Inspectable): bool =
      case w
      of Inspectable.On: true
      of Inspectable.Off: false
      of Inspectable.Auto: zapp_build_dev_tools_default() > 0
      of Inspectable.Inherit: app_get_bootstrap_web_content_inspectable()
    ```
  - Rewrite the accessor (line ~144) to resolve before returning the 0/1 `window.m` thresholds with `> 0`:
    ```nim
    proc wopts_inspectable(p: pointer): int32 {.exportc, cdecl.} =
      if resolveInspectable(opt(p).inspectable): 1 else: 0
    ```

- [ ] **Step 4: zapp.nim export comments.** In `native/nim/zapp.nim`, the comments at ~line 43, 93, 99 list `TriState` in the exported surface. Replace `TriState` with `Inspectable` in those comments (comment-only; `export coretypes` now carries `Inspectable`).

- [ ] **Step 5: kitchen-sink + scaffold to `Inspectable.Auto`.**
  - `kitchen-sink/zapp/app.nim` line ~27: `inspectable: inspectableAuto(),` → `inspectable: Inspectable.Auto,`.
  - `cli/src/init.ts` line ~241: `inspectable: inspectableAuto(),   # web inspector: on in dev, off in prod` → `inspectable: Inspectable.Auto,   # web inspector: on in dev, off in prod`.

- [ ] **Step 6: appconfig_test — add Inherit case.** In `native/nim/tests/appconfig_test.nim`, add an assertion that `Inspectable.Inherit` resolves like `Auto` (tracks the dev-tools stub). Read the existing test to match its stub pattern for `zapp_build_dev_tools_default`; add e.g.:
```nim
block:
  setAppConfig(AppConfig(name: "t", inspectable: Inspectable.Inherit, maxWorkers: 0))
  # Inherit at app level behaves as Auto (resolves to the dev-tools flag).
  # (set the test's dev-tools stub to 1 here, mirroring the existing Auto case)
  doAssert app_get_bootstrap_web_content_inspectable()
```
(Adapt to however the test already controls the dev-tools flag — match the existing Auto-case test exactly, just with `Inherit`.)

- [ ] **Step 7: windowmanager_test — fix the default assertion + add the cascade test.** In `native/nim/tests/windowmanager_test.nim`:
  - Add `import ../appconfig` (for `setAppConfig`, `AppConfig`) near the top.
  - Add a dev-tools stub alongside the existing darwin stubs:
    ```nim
    var gDevTools: cint = 0
    proc zapp_build_dev_tools_default(): cint {.exportc, cdecl.} = gDevTools
    ```
    (One definition serves both window's and appconfig's `importc` of this symbol.)
  - In the defaults block, change `doAssert o.inspectable == TriState.Unset` →
    `doAssert o.inspectable == Inspectable.Inherit, "window inspectable defaults to Inherit"`.
  - Add a cascade block:
    ```nim
    block:
      # Inspectable cascade: window-explicit > AppConfig > dev/prod.
      gDevTools = 0
      doAssert resolveInspectable(Inspectable.On)
      doAssert not resolveInspectable(Inspectable.Off)
      gDevTools = 1
      doAssert resolveInspectable(Inspectable.Auto)
      gDevTools = 0
      doAssert not resolveInspectable(Inspectable.Auto)
      # Inherit cascades to AppConfig:
      setAppConfig(AppConfig(name: "t", inspectable: Inspectable.On, maxWorkers: 0))
      doAssert resolveInspectable(Inspectable.Inherit)
      setAppConfig(AppConfig(name: "t", inspectable: Inspectable.Off, maxWorkers: 0))
      doAssert not resolveInspectable(Inspectable.Inherit)
      setAppConfig(AppConfig(name: "t", inspectable: Inspectable.Auto, maxWorkers: 0))
      gDevTools = 1
      doAssert resolveInspectable(Inspectable.Inherit)
      gDevTools = 0
      doAssert not resolveInspectable(Inspectable.Inherit)
    ```

- [ ] **Step 8: Run both nim unit tests.**
  - `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --warnings:off --mm:orc --threads:on -o:/tmp/wmtest tests/windowmanager_test.nim` → expect `windowmanager ok`.
  - `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --warnings:off --mm:orc --threads:on -o:/tmp/actest tests/appconfig_test.nim` → expect it to pass (read the file for its success line / no doAssert failure).

- [ ] **Step 9: Build the nim kitchen-sink (full cross-file compile).**
  `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → LAST line `[zapp] build complete: ...`.

- [ ] **Step 10: Commit (atomic).**
```bash
cd /Users/zach/code/zapp
git add native/nim/coretypes.nim native/nim/appconfig.nim native/nim/window.nim \
        native/nim/zapp.nim native/nim/tests/appconfig_test.nim \
        native/nim/tests/windowmanager_test.nim kitchen-sink/zapp/app.nim cli/src/init.ts
git commit -m "feat(nim): unified Inspectable enum + cascade (remove TriState/inspectableAuto)"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

---

### Task 2: webview JS-config flag = resolved per-window value (both platforms)

**Files:**
- Modify: `native/platform/darwin/webview.m` (~line 864)
- Modify: `native/platform/ios/webview.m` (~line 749)

- [ ] **Step 1: darwin/webview.m.** At ~line 864, change:
```objc
    BOOL inspect = app_get_bootstrap_web_content_inspectable();
```
to use the per-window resolved param the function already receives:
```objc
    // Per-window resolved inspectable (cascade already applied in wopts_inspectable);
    // keep the JS-config flag consistent with the native setInspectable: gate.
    BOOL inspect = inspectable;
```
(Confirm `inspectable` is the `bool` param of `darwin_webview_create_ext` and is in scope here — it is, it's used later for `setInspectable:`.)

- [ ] **Step 2: ios/webview.m.** At ~line 749, make the identical change (`BOOL inspect = app_get_bootstrap_web_content_inspectable();` → `BOOL inspect = inspectable;`). Confirm `inspectable` is the `bool` param of `darwin_webview_create` (line ~706) and in scope.

- [ ] **Step 3: Build macOS (compiles darwin/webview.m).**
  `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`.

- [ ] **Step 4: Build iOS-simulator (compiles ios/webview.m).**
  `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`.
  (This is the zc path — the only gate that compiles `ios/webview.m`. If the iOS toolchain/SDK is unavailable in this environment, report that explicitly rather than claiming success.)

- [ ] **Step 5: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/webview.m native/platform/ios/webview.m
git commit -m "fix(webview): JS inspectable flag uses resolved per-window value"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

---

### Task 3: Docs + final gate + smoke

**Files:**
- Modify: `docs/api-reference.md`

- [ ] **Step 1: Document the enum + cascade.** In `docs/api-reference.md`, in the inspectable/WindowOptions area (and the "Authoring an app in Nim" example which currently shows `inspectable`), document: `Inspectable` = `Inherit | Auto | On | Off`; `WindowOptions.inspectable` defaults to `Inherit`, `AppConfig.inspectable` to `Auto`; resolution cascades **window-explicit > AppConfig > dev-vs-prod**. Replace any `inspectableAuto()` mention with `Inspectable.Auto`. Keep edits tight and accurate.

- [ ] **Step 2: Full gate.** Run each (report the relevant line):
```bash
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build   # [zapp] build complete:
cd /Users/zach/code/zapp/kitchen-sink && bun run build                         # [zapp] build complete: (zc macOS)
cd /Users/zach/code/zapp && bun run check                                      # tsc clean
cd /Users/zach/code/zapp/cli && bun test src                                   # all pass
cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --warnings:off --mm:orc --threads:on -o:/tmp/wm3 tests/windowmanager_test.nim   # windowmanager ok
```

- [ ] **Step 3: Commit docs.**
```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "docs: Nim Inspectable enum + cascade"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

- [ ] **Step 4: GATE — manual smoke.** `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run dev`. Confirm the Web Inspector still opens in dev (kitchen-sink window sets `Inspectable.Auto`). Optionally verify the cascade: set the kitchen-sink window to `inspectable: Inspectable.Off` (or AppConfig Off) and confirm devtools are gone. PAUSE for human confirmation.

---

## Self-review notes

- **Spec coverage:** enum moved to coretypes + Inherit (T1.1) ✓; appconfig import + Inherit arm (T1.2) ✓; window field/default/resolver + delete inspectableAuto (T1.3) ✓; remove TriState (T1.1, refs cleaned T1.3/T1.4) ✓; kitchen-sink + scaffold (T1.5) ✓; tests incl. cascade (T1.6/T1.7) ✓; JS-flag both platforms (T2) ✓; docs (T3.1) ✓; parity divergence spec-only ✓; smoke gate (T3.4) ✓.
- **No-cycle:** `appconfig` imports only `coretypes` (leaf); `window` imports `coretypes` + `appconfig`. `coretypes` imports nothing. No cycle.
- **Single dev-tools symbol:** both `appconfig` and `window` `importc` `zapp_build_dev_tools_default`; the real binary provides it (CLI-generated), the unit test provides one `exportc` stub — one C symbol, both bindings resolve to it.
- **`wopts_inspectable` return contract:** now returns resolved 0/1 (was raw -1/0/1); `window.m`'s only consumer thresholds `> 0`, so behavior is preserved/correct. No other consumer (verified).
- **Type consistency:** `Inspectable` is the single enum in all of coretypes/appconfig/window/tests; `resolveInspectable*(w: Inspectable): bool` and `app_get_bootstrap_web_content_inspectable(): bool` signatures consistent; `AppConfig(... inspectable: Inspectable, maxWorkers: int32)` literal shape matches existing usage.
- **Public surface:** `resolveInspectable*` is newly exported (a useful pure helper, re-exported via zapp) — intentional, keeps the test off the pointer-cast path.
