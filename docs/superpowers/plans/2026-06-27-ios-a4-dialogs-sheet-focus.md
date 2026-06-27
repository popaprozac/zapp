# iOS A4 — Dialogs + Sheet `#sheet=` Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make iOS dialogs (open/save/message) return real native results and make iOS sheets honor the `#sheet=` content URL — restoring macOS parity for both.

**Architecture:** Dialogs — the async UIKit implementations already exist in `native/platform/ios/dialog.m`; the Nim router (`router.nim`) calls the sync stubs instead. Add a compile-gated iOS branch (`when defined(zappIos):`, enabled by a new `-d:zappIos` nim define for iOS targets) that calls the async variants and defers the bridge reply to a `{.cdecl.}` callback. Sheet focus — thread `wopts_url` through `ios/window.m`'s deferred-window struct to the content webview's `url_override`, exactly as macOS already does. macOS paths are untouched.

**Tech Stack:** Nim (ORC), Objective-C (UIKit/WKWebView), TypeScript (Bun) CLI.

## Global Constraints

- Branch `feat/nim-native`, kept UNMERGED. Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Per-file `git add` only — never `git add -A`/`.` (pre-existing unrelated WIP under assets/, benchmarks/, vendor/, spikes/ must stay unstaged).
- Bun, never Node. NO iOS simulator interaction in-session — build-only gates + human smoke on the user's device/sim.
- iOS build = arm64, min iOS 15.0; sim functional / device compile-only. Default iOS engine = zjs.
- **macOS is the parity reference** — `native/platform/darwin/dialog.m`, `native/platform/darwin/window.m`, and the macOS sync `routeDialog` path are NOT modified. macOS dialog + sheet behavior must be byte-for-byte unchanged.
- Native-first parity: restore the existing TS `Dialog` + sheet-url contracts on iOS; no new public API.
- `native/app/router.zc` is unchanged — it already has the correct iOS async branch; we bring `router.nim` to parity, not the reverse.

## Non-smoke gates (run for each task as noted)

- `bun run check` (tsc) — clean.
- `bun test cli/src` — green (incl. the new define test).
- `bun run test:native` — green (Nim unit tests; confirms `dialog.nim` still compiles host-side).
- iOS-sim compile: `cd kitchen-sink && bun run build --platform ios` → must print `[zapp] build complete:`.
- macOS build: `cd kitchen-sink && bun run build` → must print `[zapp] build complete:`.

---

## Task 1: Dialogs — route iOS through the existing async UIKit path

**Files:**
- Modify: `cli/src/native.ts` (add `nimDefinesForTarget`, wire into the nim `args` at ~1293)
- Test: `cli/src/native.test.ts` (new `nimDefinesForTarget` tests)
- Modify: `native/nim/dialog.nim` (add a `when defined(zappIos):` async block)
- Modify: `native/nim/router.nim` (add a `when defined(zappIos):` callback + branch `routeDialog`)

**Interfaces:**
- Produces: `nimDefinesForTarget(target: BuildTarget): string[]` (exported from `cli/src/native.ts`); `ZappDialogCb` type + `dialogOpenFileAsync`/`dialogSaveFileAsync`/`dialogMessageAsync(windowId, id: int; optionsJson: string; cb: ZappDialogCb)` (exported from `native/nim/dialog.nim`, only under `-d:zappIos`).
- Consumes (already exist): `isIOSTarget(target)` (`cli/src/native.ts`); the C-ABI async funcs in `ios/dialog.m` (`darwin_dialog_open_file_async`/`_save_file_async`/`_message_async`, sig `(int32_t window_id, int32_t request_id, const char* options_json, zapp_ios_dialog_cb cb)`; cb = `void(*)(int32_t,int32_t,bool,const char*)`); `sendInvokeResponse(windowId, requestId: int, ok: bool, payload: string)` (`bridge.nim`); `dialogGrantedPaths(resultJson: string): seq[string]` + `dialogOpenFile`/`dialogSaveFile`/`dialogMessage` (`dialog.nim`); `fsGrantPath` (`fs.nim`). `router.nim` already imports `bridge, fs, dialog`.

- [ ] **Step 1: Write the failing test for `nimDefinesForTarget`**

Add to `cli/src/native.test.ts` (import line already imports from `./native`; extend it):

```ts
import { detectTarget, isIOSTarget, nimDefinesForTarget } from "./native";

test("nimDefinesForTarget: iOS targets get -d:zappIos", () => {
  expect(nimDefinesForTarget("ios-simulator")).toEqual(["-d:zappIos"]);
  expect(nimDefinesForTarget("ios-device")).toEqual(["-d:zappIos"]);
});
test("nimDefinesForTarget: macos/windows get no extra defines", () => {
  expect(nimDefinesForTarget("macos")).toEqual([]);
  expect(nimDefinesForTarget("windows")).toEqual([]);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test cli/src/native.test.ts`
Expected: FAIL — `nimDefinesForTarget` is not exported (import error / undefined).

- [ ] **Step 3: Implement `nimDefinesForTarget` and wire it into the nim args**

In `cli/src/native.ts`, add the exported function near `isIOSTarget` (top of file, after the `isIOSTarget` definition ~line 40):

```ts
/**
 * Extra `nim c` `-d:` defines for a build target. iOS targets get `-d:zappIos`
 * so hand-written Nim (router.nim/dialog.nim) can compile-gate iOS-only branches
 * (the async UIKit dialog path) — the Nim-layer analog of router.zc's
 * `#if TARGET_OS_IPHONE`. We use a project-namespaced symbol (NOT `ios`) to avoid
 * colliding with Nim's built-in `defined(ios)` OS conditional, which is keyed off
 * `--os:` (we compile with the host `--os:macosx` + iOS clang flags).
 */
export function nimDefinesForTarget(target: BuildTarget): string[] {
  return isIOSTarget(target) ? ["-d:zappIos"] : [];
}
```

Then thread it into the `args` array in `buildNativeNim` (currently `native.ts:1293`). Change:

```ts
  const args = ["c", "--cc:clang", "--mm:orc", "--threads:on", "-d:release", "--opt:size",
                `--path:${zappDir}`, `--path:${nimFrameworkDir}`,
                ...iosArgs,
                `-o:${output}`, ...(verbose ? [] : ["--hints:off"]), nimRoot];
```

to:

```ts
  const args = ["c", "--cc:clang", "--mm:orc", "--threads:on", "-d:release", "--opt:size",
                ...nimDefinesForTarget(target),
                `--path:${zappDir}`, `--path:${nimFrameworkDir}`,
                ...iosArgs,
                `-o:${output}`, ...(verbose ? [] : ["--hints:off"]), nimRoot];
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test cli/src/native.test.ts`
Expected: PASS (all `nimDefinesForTarget` + existing `detectTarget` tests green).

- [ ] **Step 5: Add the iOS async block to `native/nim/dialog.nim`**

Append at the END of `native/nim/dialog.nim` (after the existing typed wrappers). This block compiles ONLY under `-d:zappIos`, so the host build / `dialog_test.nim` (which compile without it) are unaffected — `dialog.nim` stays a pure C-ABI leaf (no `bridge`/`fs` import), preserving the B6a rule in its header.

```nim
# --- iOS async dialog path (compile-gated; -d:zappIos) ---------------------
# iOS dialogs are async-presentation only: UIDocumentPickerViewController (open/
# save) and UIAlertController (message) cannot run modally. The real impls live
# in native/platform/ios/dialog.m (darwin_dialog_*_async). The reply callback is
# supplied by router.nim (which owns sendInvokeResponse + the FS grant) — keeping
# dialog.nim a bridge-free leaf. options_json is consumed synchronously by the C
# fn before it returns (it parses to NSData up front), so the cstring is valid for
# the call's duration.
when defined(zappIos):
  type ZappDialogCb* = proc(wid, rid: int32; ok: bool; json: cstring) {.cdecl.}
  proc darwin_dialog_open_file_async(windowId, requestId: int32;
                                     optionsJson: cstring; cb: ZappDialogCb) {.importc, cdecl.}
  proc darwin_dialog_save_file_async(windowId, requestId: int32;
                                     optionsJson: cstring; cb: ZappDialogCb) {.importc, cdecl.}
  proc darwin_dialog_message_async(windowId, requestId: int32;
                                   optionsJson: cstring; cb: ZappDialogCb) {.importc, cdecl.}

  proc dialogOpenFileAsync*(windowId, id: int; optionsJson: string; cb: ZappDialogCb) =
    darwin_dialog_open_file_async(windowId.int32, id.int32, optionsJson.cstring, cb)
  proc dialogSaveFileAsync*(windowId, id: int; optionsJson: string; cb: ZappDialogCb) =
    darwin_dialog_save_file_async(windowId.int32, id.int32, optionsJson.cstring, cb)
  proc dialogMessageAsync*(windowId, id: int; optionsJson: string; cb: ZappDialogCb) =
    darwin_dialog_message_async(windowId.int32, id.int32, optionsJson.cstring, cb)
```

- [ ] **Step 6: Add the iOS callback + branch `routeDialog` in `native/nim/router.nim`**

First, ABOVE `routeDialog` (so the callback is in scope), add a `when defined(zappIos):` block defining the reply callback:

```nim
when defined(zappIos):
  proc dialogAsyncReply(wid, rid: int32; ok: bool; json: cstring) {.cdecl.} =
    ## iOS dialog completion (UIKit main-thread callback). Extends the FS
    ## allowlist with any picked paths — a no-op for save/message results, which
    ## carry no `paths` array (dialogGrantedPaths returns @[]) — then resolves the
    ## invoke promise. Mirrors router.zc's dialog_open_response_cb_zc. Runs on the
    ## main thread (same as routeDialog), so ORC GC is safe; no foreign-thread init.
    let payload = if json.isNil: "null" else: $json
    if ok and not json.isNil:
      for p in dialogGrantedPaths(payload): fsGrantPath(p)
    sendInvokeResponse(wid.int, rid.int, ok, payload)
```

Then replace the body of `routeDialog` (currently `router.nim:282–302`) so iOS dispatches async and macOS keeps the exact current sync path:

```nim
proc routeDialog(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__dialog:*`. macOS (else): sync darwin_dialog_* JSON variant, reply
  ## inline, grant picked paths to the FS session allowlist. iOS (zappIos): the
  ## pickers/alerts are async-presentation only — call the async variant and let
  ## dialogAsyncReply resolve the invoke + grant paths from the UIKit callback.
  let optionsJson = (if a.isNil: "{}" else: $a)
  when defined(zappIos):
    case meth
    of "__dialog:open":    dialogOpenFileAsync(windowId, id, optionsJson, dialogAsyncReply)
    of "__dialog:save":    dialogSaveFileAsync(windowId, id, optionsJson, dialogAsyncReply)
    of "__dialog:message": dialogMessageAsync(windowId, id, optionsJson, dialogAsyncReply)
    else: sendInvokeResponse(windowId, id, false, "UNKNOWN_DIALOG")
    # async: dialogAsyncReply replies later — no inline reply here.
  else:
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

(The `else:` branch is byte-for-byte the current macOS logic — only re-indented under `else:`. Verify the diff shows no macOS behavior change.)

- [ ] **Step 7: Run the host gates (macOS path unchanged)**

Run: `bun run check && bun test cli/src && bun run test:native`
Expected: all green. `test:native` confirms `dialog.nim` still compiles host-side (the `when defined(zappIos)` block is excluded) and `dialog_test.nim` passes unchanged.

- [ ] **Step 8: Build macOS — must stay green and unchanged**

Run: `cd kitchen-sink && bun run build`
Expected: `[zapp] build complete:` (the `else:` sync path compiles; no `-d:zappIos`).

- [ ] **Step 9: Build iOS — links the async symbols under `-d:zappIos`**

Run: `cd kitchen-sink && bun run build --platform ios`
Expected: `[zapp] build complete:` — the `when defined(zappIos)` branch compiles and links `darwin_dialog_*_async` from `ios/dialog.m`. (If it fails to link, confirm Step 3 wired `nimDefinesForTarget` into the args and the importc names match `ios/dialog.m` exactly.)

- [ ] **Step 10: Commit**

```bash
git add cli/src/native.ts cli/src/native.test.ts native/nim/dialog.nim native/nim/router.nim
git commit -F - <<'EOF'
fix(ios): route dialogs through the existing async UIKit path

iOS Dialog.openFile/saveFile returned {"cancelled":true} and message
{"button":0}: router.nim called the sync darwin_dialog_* stubs. The async
UIKit impls (UIDocumentPicker/UIAlertController) already exist in
ios/dialog.m. Add a -d:zappIos nim define for iOS targets and a
when-defined(zappIos) branch in routeDialog that calls the async variants
and defers the bridge reply to a cdecl callback (dialogAsyncReply, which
grants picked paths then sendInvokeResponse). macOS sync path unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

- [ ] **Step 11: HUMAN SMOKE GATE (iPhone + iPad) — pause for the user**

The user runs the iOS build and exercises the kitchen-sink **Dialogs** section (`sections/dialogs.ts` already has the buttons):
- **Open** → `UIDocumentPicker` appears; picking a file returns `{cancelled:false, paths:[...]}` (the section shows the path), cancel returns `{cancelled:true}`.
- **Save** → picker appears; returns the chosen path / cancel.
- **Message / confirm** → `UIAlertController` appears; the tapped button index comes back (NOT a hardcoded `button:0`).
Do NOT mark the task complete until the user confirms the smoke on both iPhone and iPad.

---

## Task 2: Sheet `#sheet=` focus — thread the content URL through iOS window-create

**Files:**
- Modify: `native/platform/ios/window.m` (`ZappIOSDeferred` struct ~48–98; `darwin_window_create` ~726; the two content-pane `darwin_webview_create_ext` calls at lines 356 and 429; the destroy `free` block at ~818)

**Interfaces:**
- Consumes (already exist): `extern const char* wopts_url(void* opts);` (the WindowOptions url accessor macOS uses at `darwin/window.m:781`); `darwin_webview_create_ext(window, inspectable, first_mouse, url_override, ...)` — `url_override` is the 4th argument; `zapp_ios_resolve_url` (`ios/webview.m:116`) already resolves a relative `#sheet=` ref against the initial url once a non-NULL url is passed.
- Produces: nothing external — a new `char* url` field internal to `ZappIOSDeferred`.

- [ ] **Step 1: Add the `url` field to `ZappIOSDeferred`**

In `native/platform/ios/window.m`, in the `ZappIOSDeferred` struct (the `queued_title` lives near the top of the struct ~line 51), add directly under `char* queued_title;`:

```objc
    char* url;                // content webview url override (e.g. "#sheet=settings"); strdup'd; freed in destroy. NULL = default initial url.
```

- [ ] **Step 2: Read `wopts_url` in `darwin_window_create` and store it**

In `darwin_window_create` (`window.m:726`), alongside the existing `wopts_sidebar_url` / `wopts_inspector_url` reads (~756–797), add:

```objc
        // Content webview url override (macOS parity: darwin/window.m reads
        // wopts_url and passes it as url_override). strdup to survive until
        // materialize (like queued_title / sidebarUrl). NULL/empty -> default
        // initial url. This is what makes a sheet opened with url:"#sheet=foo"
        // load the requested route instead of the default page.
        extern const char* wopts_url(void* opts);
        const char* _contentUrl = wopts_url(opts);
        d->url = (_contentUrl && _contentUrl[0]) ? strdup(_contentUrl) : NULL;
```

- [ ] **Step 3: Pass `d->url` as `url_override` at the two CONTENT-pane create_ext calls**

There are four `darwin_webview_create_ext` calls in `zapp_ios_materialize_pending_windows`. Only the two **content-pane** calls currently pass `NULL` for `url_override` (the 4th arg) — the sidebar (371) and inspector (482) calls already pass `d->sidebarUrl` / `d->inspectorUrl` and must be left alone.

At `window.m:356–357` (content pane, sidebar path) change the 4th argument from `NULL` to `d->url`:

```objc
            darwin_webview_create_ext((__bridge void*)window, d->inspectable, d->first_mouse,
                                      d->url, d->numeric_id, false,
                                      (__bridge void*)contentVC.view, d->numeric_id, 0,
                                      /*host_has_sidebar*/true, /*host_has_inspector*/d->hasInspector);
```

At `window.m:429–432` (content pane, no-sidebar path) change the 4th argument from `NULL` to `d->url`:

```objc
            darwin_webview_create_ext((__bridge void*)window, d->inspectable, d->first_mouse,
                                      d->url, d->numeric_id, false,
                                      /*container*/NULL, /*identity*/-1, /*pane_role*/0,
                                      /*host_has_sidebar*/false, /*host_has_inspector*/d->hasInspector);
```

Leave the sidebar call (line 371, `d->sidebarUrl`) and the inspector call (line 482, `d->inspectorUrl`) unchanged.

- [ ] **Step 4: Free `d->url` in the destroy path**

In the destroy/free block (`window.m:~818`, where `free(d->queued_title); free(d->sidebarUrl); ... free(d->inspectorUrl);` live), add:

```objc
        free(d->url);
```

- [ ] **Step 5: Build iOS — must compile**

Run: `cd kitchen-sink && bun run build --platform ios`
Expected: `[zapp] build complete:`.

- [ ] **Step 6: Build macOS — must stay unaffected**

Run: `cd kitchen-sink && bun run build`
Expected: `[zapp] build complete:` (no macOS files changed).

- [ ] **Step 7: Commit**

```bash
git add native/platform/ios/window.m
git commit -F - <<'EOF'
fix(ios): honor the #sheet= content url on sheets/windows (macOS parity)

iOS darwin_window_create never read wopts_url, so the materialize path always
passed NULL as url_override and a window/sheet opened with url:"#sheet=settings"
loaded the default page (JS router fell through to the main pane). Add a url
field to ZappIOSDeferred, read wopts_url at create, and pass it as url_override
at the two content-pane darwin_webview_create_ext calls. Mirrors darwin/window.m.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
```

- [ ] **Step 8: HUMAN SMOKE GATE (iPhone + iPad) — pause for the user**

The user runs the iOS build and exercises the kitchen-sink **Multi-window** section (`sections/multiwindow.ts` already opens `asSheetOf` with `url: "#sheet=…"`):
- A sheet opened with `url: "#sheet=settings"` shows the **settings** route, not the main pane.
- A sheet/window opened with no `url` still shows the default page.
Do NOT mark the task complete until the user confirms.

---

## Self-Review

**1. Spec coverage:**
- Dialogs broken (open/save/message) → Task 1 (CLI define + dialog.nim async block + router.nim branch). ✓
- Sheet `#sheet=` focus → Task 2 (struct field + wopts_url + url_override + free). ✓
- Approach A (`-d:` define + `when defined`) → Task 1 Steps 3/5/6, namespaced `-d:zappIos`. ✓
- macOS untouched → Task 1 `else:` branch is the verbatim sync path; Task 2 touches only `ios/window.m`; macOS build gates in both tasks. ✓
- file-drop out of scope → not in this plan (A4b #726). ✓
- No new KS surfaces / no new public API → smoke uses existing `sections/dialogs.ts` + `sections/multiwindow.ts`. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; every command has an expected result. ✓

**3. Type consistency:** `nimDefinesForTarget(target: BuildTarget): string[]` used identically in test + `buildNativeNim`. `ZappDialogCb`/`dialogOpenFileAsync`/`dialogSaveFileAsync`/`dialogMessageAsync` defined in `dialog.nim` (Step 5) and called in `router.nim` (Step 6) with matching signatures `(windowId, id: int; optionsJson: string; cb: ZappDialogCb)`. `dialogAsyncReply` cdecl signature `(wid, rid: int32; ok: bool; json: cstring)` matches the importc'd C `cb` typedef. `d->url` (`char*`) added (Step 1), set (Step 2), used (Step 3), freed (Step 4). ✓

**Deviation from spec (flag at handoff):** the spec named the define `-d:ios`; the plan uses `-d:zappIos` to avoid colliding with Nim's built-in `defined(ios)` OS conditional (stdlib has `when defined(ios)` guards; we compile with host `--os:macosx`). Same Approach A; safer symbol.
