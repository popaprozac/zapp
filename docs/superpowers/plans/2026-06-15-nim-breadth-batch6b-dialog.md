# Nim Breadth Batch 6b — dialog Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the webview Dialog surface to the `ZAPP_NATIVE_LANG=nim` build — `routeDialog` handling t:1 `__dialog:open`/`__dialog:save`/`__dialog:message` via the `darwin_dialog_*` JSON variants, replying with the result pass-through, and granting each picked path via `fsGrantPath` (the B6a hook) so `FS`/shell-path ops can then act on it.

**Architecture:** A new `native/nim/dialog.nim` owns the `darwin_dialog_*` `importc` decls + thin JSON wrappers (`dialogOpenFile`/`dialogSaveFile`/`dialogMessage`) + a pure `dialogGrantedPaths` parser + native-first typed wrappers (parity with `dialog.zc`). `router.nim` gets a `routeDialog` proc dispatched from `routeMessage`'s t:1 prefix chain (mirroring `routeClipboard`); on `__dialog:open` it grants each returned path. `dialog.m` is compiled in the build root (`zapp.nim`) per the B6a rule (so the unit test can stub the C-ABI without dragging in `dialog.m` + Foundation).

**Tech Stack:** Nim (`std/json`), `importc` of `dialog.m`'s C-ABI, the B6a `fs.nim` (`fsGrantPath`).

---

## Background

- **Branch:** `feat/nim-native`. Additive; macOS / Nim build only. Spec: `docs/superpowers/specs/2026-06-15-nim-breadth-batch6-leaf-services-design.md` (this is B6b, the second leaf).
- **The webview Dialog path is JSON-in/JSON-out.** `runtime/dialog.ts`: `Dialog.openFile(options)` → `invoke("__dialog:open", options)` → `OpenFileResult {cancelled, paths?}`; `Dialog.save` → `__dialog:save` → `SaveFileResult {cancelled, path?}`; `Dialog.message` → `__dialog:message` → `MessageResult {button}`. The reply is the JSON object the native side returns, passed straight through (the runtime `JSON.parse`s it).
- **The native targets (defined in `native/platform/darwin/dialog.m`, compiled; signatures from `dialog.h`):**
  - JSON variants (the webview path): `const char* darwin_dialog_open_file(const char* options_json)`, `const char* darwin_dialog_save_file(const char*)`, `const char* darwin_dialog_message(const char*)`. Each returns a JSON result string (e.g. `{"cancelled":false,"paths":[...]}`). The return is **not** caller-freed (the zc treats it as a non-owned `const char*`, router.zc:1448 — do NOT `c_free` it).
  - Typed variants (native-first parity, what `dialog.zc` wraps): `const char* darwin_dialog_open_file_typed(const char* title, bool multiple, bool directory)`, `const char* darwin_dialog_save_file_typed(const char* title, const char* default_name)`, `int darwin_dialog_message_typed(const char* message, const char* title, int style)`, `int darwin_dialog_message_buttons_typed(const char* message, const char* title, int style, const char* btn1, const char* btn2, const char* btn3)`.
- **The zc reference** (`router.zc:1430-1497` desktop path + `:1499-1535` grant): `__dialog:open`/`save`/`message` call the JSON variant with `args_json`; on `__dialog:open` with a non-empty result, `router_grant_paths_from_dialog(result)` parses `{"cancelled":bool,"paths":[...]}` and `fs_grant_path`s each path; then `dispatch_invoke_response(true, result)`, or `false, "UNKNOWN_DIALOG"` on an empty result. (iOS async + Windows branches are out of B6b scope — macOS desktop path only.)
- **Permission gate already in place:** `permission_id_for_invoke("__dialog:*")` → `"dialog"` (permissions.nim; confirmed by permissions_test). So `__dialog:` is permission-gated by `routeMessage`'s existing t:1 checkpoint (router.nim:280-284) before `routeDialog` runs.
- **B6a hook:** `fs.nim` exports `fsGrantPath*(path: string)` (already landed). router.nim already `import fs`.
- **B6a RULE (load-bearing):** a new leaf's `.m` is compiled in the **build root `zapp.nim`** compile block (NOT self-compiled in the `.nim`), so the leaf's standalone unit test can `exportc`-stub the C-ABI symbols without a duplicate-symbol/Foundation link failure. `dialog.m` is NOT yet in zapp.nim's block (which has platform/window/webview/screen/panel/fs.m) → this batch adds it.
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only the files each task lists. Never `hello-world/`, `vendor/`, `kitchen-sink/`. Never edit `native/platform/**` or `native/worker/engines/*.c`. No `{.emit.}`. Build success ONLY when the last line is `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/dialog.nim` | `darwin_dialog_*` importc + JSON wrappers + `dialogGrantedPaths` parser + native-first typed wrappers | Create |
| `native/nim/tests/dialog_test.nim` | unit test for `dialogGrantedPaths` (the pure parse) | Create |
| `native/nim/router.nim` | `routeDialog` + t:1 `__dialog:` dispatch | Modify |
| `native/nim/zapp.nim` | compile `dialog.m` in the build-root block | Modify |

---

## Task 1: dialog.nim + dialogGrantedPaths unit test

**Files:** Create `native/nim/dialog.nim`, `native/nim/tests/dialog_test.nim`.

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/dialog_test.nim`:
```nim
import ../dialog

# dialog.nim importc's the darwin_dialog_* symbols (defined in dialog.m, absent
# from a standalone unit test). Stub them to satisfy the link — same pattern as
# fs_test.nim / permissions_test.nim. dialogGrantedPaths is pure (std/json) and
# needs no stub behavior, but the module references the symbols so they must link.
proc darwin_dialog_open_file(o: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_save_file(o: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_message(o: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_open_file_typed(t: cstring, m, d: bool): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_save_file_typed(t, n: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_message_typed(m, t: cstring, s: cint): cint {.exportc, cdecl.} = 0.cint
proc darwin_dialog_message_buttons_typed(m, t: cstring, s: cint, b1, b2, b3: cstring): cint {.exportc, cdecl.} = 0.cint

proc test() =
  # cancelled => no paths
  doAssert dialogGrantedPaths("""{"cancelled":true,"paths":["/a"]}""").len == 0
  # picked paths => returned in order
  let g = dialogGrantedPaths("""{"cancelled":false,"paths":["/a/b","/c"]}""")
  doAssert g == @["/a/b", "/c"]
  # missing/empty paths array => []
  doAssert dialogGrantedPaths("""{"cancelled":false}""").len == 0
  doAssert dialogGrantedPaths("""{"cancelled":false,"paths":[]}""").len == 0
  # empty-string entries skipped
  doAssert dialogGrantedPaths("""{"cancelled":false,"paths":["","/x"]}""") == @["/x"]
  # malformed / non-object / empty => []
  doAssert dialogGrantedPaths("{not json").len == 0
  doAssert dialogGrantedPaths("[1,2]").len == 0
  doAssert dialogGrantedPaths("").len == 0
  echo "dialog ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off dialog_test.nim 2>&1 | tail -5`
Expected: FAIL — `cannot open file: ../dialog`.

- [ ] **Step 3: Create `native/nim/dialog.nim`**

Create `native/nim/dialog.nim`:
```nim
## Dialogs — native file/save/message dialogs. Port of native/dialog/dialog.zc
## (the native-first typed wrappers) PLUS the webview JSON-variant path that
## router.zc handles inline. MAIN-THREAD (webview->native); idiomatic Nim.
##
## NB: darwin_dialog_* are defined in native/platform/darwin/dialog.m, compiled
## by the build root (zapp.nim) — NOT self-compiled here, so dialog_test.nim can
## stub the C-ABI without pulling in dialog.m + Foundation (the B6a rule).
import std/json

# --- C-ABI: dialog.m (dialog.h) -------------------------------------------
# JSON variants — the webview path: options JSON in, result JSON out. The
# returned const char* is NOT caller-owned (do not free; mirrors router.zc).
proc darwin_dialog_open_file(o: cstring): cstring {.importc, cdecl.}
proc darwin_dialog_save_file(o: cstring): cstring {.importc, cdecl.}
proc darwin_dialog_message(o: cstring): cstring {.importc, cdecl.}
# Typed variants — the native-first path (dialog.zc parity).
proc darwin_dialog_open_file_typed(t: cstring, m, d: bool): cstring {.importc, cdecl.}
proc darwin_dialog_save_file_typed(t, n: cstring): cstring {.importc, cdecl.}
proc darwin_dialog_message_typed(m, t: cstring, s: cint): cint {.importc, cdecl.}
proc darwin_dialog_message_buttons_typed(m, t: cstring, s: cint,
                                         b1, b2, b3: cstring): cint {.importc, cdecl.}

# --- Webview JSON wrappers (used by router.nim's routeDialog) --------------
# Each takes the options object as a JSON string and returns the result JSON
# string ("" on a nil/error return — routeDialog maps that to UNKNOWN_DIALOG).
proc dialogOpenFile*(optionsJson: string): string =
  let r = darwin_dialog_open_file(optionsJson.cstring)
  if r.isNil: "" else: $r

proc dialogSaveFile*(optionsJson: string): string =
  let r = darwin_dialog_save_file(optionsJson.cstring)
  if r.isNil: "" else: $r

proc dialogMessage*(optionsJson: string): string =
  let r = darwin_dialog_message(optionsJson.cstring)
  if r.isNil: "" else: $r

# --- Granted-path extraction (mirror router.zc:router_grant_paths_from_dialog)
proc dialogGrantedPaths*(resultJson: string): seq[string] =
  ## Parse an open-dialog result `{"cancelled":bool,"paths":[...]}` and return the
  ## picked paths ([] if cancelled / malformed / empty). routeDialog fsGrantPath's
  ## each so FS/shell-path ops can act on a user-picked file.
  result = @[]
  var root: JsonNode
  try: root = parseJson(resultJson)
  except CatchableError: return
  if root.kind != JObject or root{"cancelled"}.getBool(false): return
  let paths = root{"paths"}
  if paths.isNil or paths.kind != JArray: return
  for p in paths:
    if p.kind == JString and p.getStr("").len > 0: result.add(p.getStr(""))

# --- Native-first typed wrappers (dialog.zc parity; no webview caller) -----
proc dialogOpenFileTyped*(title: string): string =
  $darwin_dialog_open_file_typed(title.cstring, false, false)
proc dialogOpenFolder*(title: string): string =
  $darwin_dialog_open_file_typed(title.cstring, false, true)
proc dialogSaveFileTyped*(title, defaultName: string): string =
  $darwin_dialog_save_file_typed(title.cstring, defaultName.cstring)
proc dialogMessageInfo*(msg: string): int =
  darwin_dialog_message_typed(msg.cstring, "".cstring, 0.cint).int
proc dialogMessageWithTitle*(msg, title: string, style: int): int =
  darwin_dialog_message_typed(msg.cstring, title.cstring, style.cint).int
proc dialogConfirm*(msg, btnYes, btnNo: string): int =
  darwin_dialog_message_buttons_typed(msg.cstring, "".cstring, 0.cint,
                                      btnYes.cstring, btnNo.cstring, "".cstring).int
```
(`$cstring` copies into a Nim string; the typed wrappers return `$result` directly — the typed variants' `const char*` is likewise non-owned, no free, matching dialog.zc which just returns it.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off dialog_test.nim 2>&1 | tail -5`
Expected: last line `dialog ok`. (Link failure on an undefined `darwin_dialog_*` → a stub signature in the test doesn't match dialog.nim's importc — align them.)

- [ ] **Step 5: Regression — the other Nim unit tests still pass**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in fs_test permissions_test router_subscribe_test callbacks_test dispatch_test service_cabi_test; do nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/dialog.nim native/nim/tests/dialog_test.nim
git commit -m "$(printf 'feat(nim): dialog.nim — JSON + typed dialog wrappers + grant parser (Batch 6b)\n\nPort of native/dialog/dialog.zc + the webview JSON-variant path. dialogOpenFile/\nSaveFile/Message wrap the darwin_dialog_* JSON variants (options JSON in, result\nJSON out); dialogGrantedPaths parses an open result {cancelled,paths} (unit-\ntested); typed wrappers mirror dialog.zc for native-first parity. darwin_dialog_*\ndeclared importc; dialog.m compiled by the build root in the next task.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: routeDialog wiring + compile dialog.m → build → GATE

**Files:** Modify `native/nim/router.nim`, `native/nim/zapp.nim`.

- [ ] **Step 1: Compile dialog.m in the build root**

In `native/nim/zapp.nim`, in the `{.compile(...).}` block (after the `fs.m` line added in B6a), add:
```nim
{.compile("../platform/darwin/dialog.m", "-fobjc-arc").}
```

- [ ] **Step 2: Add `import dialog` + the `routeDialog` proc**

In `native/nim/router.nim`, add `dialog` to the top `import` line (currently `import bridge, service, clipboard, callbacks, events, permissions, fs`):
```nim
import bridge, service, clipboard, callbacks, events, permissions, fs, dialog
```
Then add the `routeDialog` proc immediately AFTER `routeClipboard` (before `proc routeWindowAction`):
```nim
proc routeDialog(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__dialog:*` — desktop path (mirror router.zc:1430-1535). Pass the
  ## options object (JSON) to the darwin_dialog_* JSON variant; reply with the
  ## result JSON the runtime JSON.parses. On `__dialog:open`, grant each picked
  ## path to the FS session allowlist (so FS/shell-path ops can act on it).
  ## (iOS async + Windows branches are out of scope; macOS desktop only.)
  let optionsJson = (if a.isNil: "{}" else: $a)
  var resultStr = ""
  case meth
  of "__dialog:open":   resultStr = dialogOpenFile(optionsJson)
  of "__dialog:save":   resultStr = dialogSaveFile(optionsJson)
  of "__dialog:message": resultStr = dialogMessage(optionsJson)
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_DIALOG")
    return
  if meth == "__dialog:open" and resultStr.len > 0:
    for p in dialogGrantedPaths(resultStr): fsGrantPath(p)
  if resultStr.len > 0:
    sendInvokeResponse(windowId, id, true, resultStr)
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_DIALOG")
```

- [ ] **Step 3: Dispatch `__dialog:` in routeMessage**

In `native/nim/router.nim`'s `routeMessage`, in the t:1 prefix chain, add the `__dialog:` branch AFTER the `__app:` branch and BEFORE the `invokeService` fallthrough:
```nim
  if f.m.startsWith("__app:"):
    routeApp(f.m, f.a, windowId, f.id)
    return
  if f.m.startsWith("__dialog:"):
    routeDialog(f.m, f.a, windowId, f.id)
    return
```

- [ ] **Step 4: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_dialog_*` → confirm Step 1 added the `dialog.m` compile.) Do NOT `git add` hello-world/.

- [ ] **Step 5: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line (incl. `dialog ok`, `fs ok`).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): routeDialog t:1 __dialog:* + compile dialog.m (Batch 6b)\n\nrouteMessage now routes __dialog:open/save/message to routeDialog, which calls\nthe darwin_dialog_* JSON variants and replies with the result pass-through. On\n__dialog:open it fsGrantPaths each picked path (the B6a hook) so FS/shell-path\nops can act on user-picked files. dialog.m compiled in the build root.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 7: GATE — human smoke (controller pauses here)**

Build + regression prove it links + nothing regressed. Runtime confirmation (`ZAPP_NATIVE_LANG=nim bun run dev`):
1. `Dialog.openFile(...)` → the native open panel appears; picking a file returns `{cancelled:false, paths:[…]}` (the demo shows the path); cancelling returns `{cancelled:true}`.
2. `Dialog.save(...)` → save panel; returns `{cancelled, path}`.
3. `Dialog.message({message, buttons})` → alert with the buttons; returns `{button:N}`.
4. **The B6a payoff:** after picking a file via `Dialog.openFile`, the hello-world **"Reveal in Finder" / "Open path"** buttons (which gate on `lastPickedPath`) now act on it — confirming `fsGrantPath` extended the allowlist (the dialog→fs→shell chain works end-to-end).

Do not proceed to the final review until the human confirms (or accepts the build+regression gate).

---

## Self-Review

**1. Spec coverage** (B6 spec dialog section):
- `dialog.nim` idiomatic main-thread port of dialog.zc + the webview JSON path → Task 1. ✓
- t:1 `__dialog:open`/`save`/`message` routed → Task 2 (`routeDialog` + routeMessage branch). ✓
- `fs_grant_path` on `:open` result (the cross-dep B6a set up) → Task 2 (`dialogGrantedPaths` → `fsGrantPath`). ✓
- `dialog.m` compiled per the B6a rule (build root, not self-compile) → Task 2 Step 1. ✓
- Pure parse unit-tested; routes build+runtime gated → Tasks 1/2. ✓
- iOS async + Windows branches deferred (out of B6b macOS scope) → documented. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step is complete (full files / exact insertions).

**3. Type consistency:** `dialogOpenFile`/`dialogSaveFile`/`dialogMessage(optionsJson: string): string` and `dialogGrantedPaths(resultJson: string): seq[string]` — signatures used in `routeDialog` (router.nim) match their `dialog.nim` definitions. The `darwin_dialog_*` importc signatures in `dialog.nim` match the `dialog_test.nim` exportc stubs (param/return types identical) and `dialog.h` (`const char*`↔`cstring`, `bool`↔`bool`, `int`↔`cint`). `fsGrantPath(path: string)` matches fs.nim (B6a). `routeDialog(meth: string, a: JsonNode, windowId, id: int)` matches the `routeClipboard` shape and the `routeMessage` call site (`routeDialog(f.m, f.a, windowId, f.id)`). `sendInvokeResponse(windowId, id, bool, string)` matches bridge.nim usage in `routeClipboard`. ✓
