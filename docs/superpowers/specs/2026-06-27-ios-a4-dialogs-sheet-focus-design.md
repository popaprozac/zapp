# iOS A4 — Dialogs + Sheet `#sheet=` Focus — Design

**Status:** approved (brainstorm), pending plan
**Program:** iOS/iPadOS A+B+C parity sweep (see `docs/superpowers/specs/2026-06-26-ios-ipados-program-matrix.md`). Fourth correctness sub-cycle of Tier A (A1 + A2 + A3-pending). Goal of the sweep: bring iOS up to feature-rich macOS, section by section, each sub-cycle ending in a kitchen-sink human-smoke gate — before the Windows parity push, then removing Zen-C, then merging `feat/nim-native` to main.
**Branch:** `feat/nim-native` (UNMERGED). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Per-file `git add`. Bun.

## Global Constraints

- Branch `feat/nim-native`, kept UNMERGED. Trailer exactly `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Per-file `git add` only — never `git add -A`/`.` (pre-existing unrelated WIP under assets/, benchmarks/, vendor/, spikes/ stays unstaged).
- Bun, never Node. NO iOS simulator interaction in-session — build-only gates + human smoke on the user's device/sim.
- iOS build = arm64, min iOS 15.0; sim functional / device compile-only (no signing). Default iOS engine = zjs.
- **macOS is the parity reference** — `native/platform/darwin/dialog.m` and the macOS `routeDialog` sync path are NOT modified. macOS dialog behavior must be byte-for-byte unchanged after this cycle.
- Native-first parity: the fix restores the existing TS `Dialog` contract on iOS; no new public API surface.

## Scope

Two independent, deterministic fixes from the 2026-06-26 grounding:

1. **Dialogs broken on iOS** — `Dialog.openFile`/`saveFile` return `{"cancelled":true}`, `Dialog.message` returns `{"button":0}`, no native UI. The async UIKit implementations already exist in `native/platform/ios/dialog.m`; the Nim router never calls them.
2. **iOS sheet ignores `#sheet=` focus** — a window opened `asSheetOf` with `url: "#sheet=settings"` loads the default page instead of the requested route, because the iOS window-create path never reads `wopts_url`.

**Out of scope (split out):** the **file-drop regression** is now its own systematic-debugging cycle (**A4b**, task #726). It is a WebKit-internals timing fight (WebKit re-installs its own `UIDropInteraction` on `WKContentView` during layout and re-claims the `UIDropSession`, so our `performDrop:` never fires) that needs *iterative device smoke* to land — structurally like the setWidth saga — and would stall these two clean deterministic wins.

## Why these, why now

A1 (pane fan-out, inspectable, viewport-fit, parity-lint) and A2 (sidebar/inspector behavior) shipped. A4 closes the highest-value *functional* parity gap: a developer evaluating Zapp on iPad hits a dead dialog on first try. Both fixes are deterministic and verifiable by build + one human smoke; the native UIKit work for dialogs is already written and the sheet fix is a five-line read-through of the macOS path. The genuinely-uncertain piece (file-drop) is isolated so it can't gate these.

## Architecture decision — iOS gating in the Nim layer

A4 dialogs is the **first** case where hand-written Nim must diverge iOS-vs-macOS (macOS replies inline/sync via `runModal`; iOS must present async and reply from a completion callback). Until now all iOS specialization lived in the `.m` files, selected by the generated platform manifest, while hand-written Nim stayed platform-agnostic and importc'd a C-ABI present on both platforms.

The async dialog symbols (`darwin_dialog_*_async`) exist **only** in `native/platform/ios/dialog.m`, so importc-ing them must be compile-gated or the macOS build won't link.

**Chosen: Approach A — a `-d:ios` Nim compile define + `when defined(ios):` branches.** The CLI passes `--define:ios` (nim `-d:ios`) for iOS build targets; `dialog.nim` and `router.nim` gate the async path behind `when defined(ios):`. This:
- leaves the macOS path **untouched** (zero regression risk on the parity reference),
- is the faithful Nim port of what `router.zc` already does with `#if TARGET_OS_IPHONE` (`native/app/router.zc:1415–1454`), satisfying the Nim-must-mirror-zc tenet,
- establishes the reusable iOS-gating seam the rest of the sweep will need (A4b file-drop and A5 app-events almost certainly require Nim-level iOS branches too).

**Rejected:**
- **B — unified async C-ABI** (router.nim always calls `dialog_*_async`; macOS gains async-wrapper exports that run sync + fire the callback immediately). Keeps Nim 100% platform-agnostic, but *changes the working macOS dialog path* (regression risk on the reference) and adds native surface on both sides for no iOS benefit.
- **C — runtime platform check.** Doesn't solve the link problem: the async symbols don't exist on macOS, so both branches would still have to compile/link.

## Items

### T1 — Dialogs: route iOS through the existing async UIKit path

**Problem.** `routeDialog` (`native/nim/router.nim:282–302`) calls the sync wrappers `dialogOpenFile`/`dialogSaveFile`/`dialogMessage` (`native/nim/dialog.nim`), which importc `darwin_dialog_open_file`/`_save_file`/`_message` — real on macOS (`darwin/dialog.m:49/94/126`, `NSOpenPanel`/`NSSavePanel`/`NSAlert` `runModal`), but **sync stubs on iOS** (`ios/dialog.m:44/50/64`) that hardcode `{"cancelled":true}` / `{"button":0}`. `routeDialog` replies inline (`router.nim:300`). The Nim build runs `router.nim` exclusively (`app.nim` → `routeMessage` → `routeDialog`), so it never reaches `router.zc`'s correct `#if TARGET_OS_IPHONE` async branch.

**The native async path already exists** in `ios/dialog.m`:
- `darwin_dialog_message_async(window_id, request_id, options_json, cb)` (`:92`, `UIAlertController`)
- `darwin_dialog_open_file_async(window_id, request_id, options_json, cb)` (`:265`, `UIDocumentPickerViewController`)
- `darwin_dialog_save_file_async(window_id, request_id, options_json, cb)` (`:306`, folder picker + `defaultName`)
- callback typedef `zapp_ios_dialog_cb = void (*)(int32_t wid, int32_t rid, bool ok, const char* json)` (`:77`)
- result shapes match macOS exactly: open `{"cancelled":bool,"paths":[...]}`, save `{"cancelled":bool,"path":"..."}`, message `{"button":N}`.

**Fix.**
- **CLI:** `buildNativeNim` appends `--define:ios` to the nim compile invocation when the build target is `ios-simulator` or `ios-device` (target already detected via `detectTarget`, `cli/src/native.ts`). TDD'd in the existing `cli/src` nim-build test surface (assert the nim args include `--define:ios` for iOS targets and omit it for macOS).
- **`native/nim/dialog.nim`:** add a `when defined(ios):` block with importc decls for the three async functions + a `ZappDialogCb` callback type matching `zapp_ios_dialog_cb` (`void (*)(int32 wid, int32 rid, bool ok, cstring json)`), and thin wrappers `dialogOpenFileAsync(windowId, id: int; optionsJson: string; cb: ZappDialogCb)` (+ `dialogSaveFileAsync`, `dialogMessageAsync`) that forward to the C async fn. `dialog.nim` stays a **pure C-ABI leaf — no `bridge`/`fs` import** — preserving the B6a rule (its header) that `dialog_test.nim` can stub the C-ABI without pulling in Foundation or the bridge.
- **`native/nim/router.nim`:** in a `when defined(ios):` block, define the reply callback `proc dialogAsyncReply(wid, rid: int32; ok: bool; json: cstring) {.cdecl.}` — it runs `dialogGrantedPaths` → `fsGrantPath` on the JSON (a no-op for save/message results, which carry no `paths` array, so one unconditional callback serves all three; mirrors `router.zc`'s `dialog_open_response_cb_zc`) then `sendInvokeResponse(wid.int, rid.int, ok, $json)`. All three are already in `router.nim` scope. The callback runs on the main thread (same as `routeDialog`), so ORC GC is safe — no foreign-thread init.
- **`routeDialog`:** wrap the body in `when defined(ios):` → for `__dialog:open`/`save`/`message`, call `dialogOpenFileAsync`/`dialogSaveFileAsync`/`dialogMessageAsync(windowId, id, optionsJson, dialogAsyncReply)` and **return** (no inline reply — the callback replies later); unknown method → `sendInvokeResponse(..., false, "UNKNOWN_DIALOG")`. `else:` → the current sync path, unchanged (macOS identical, open-result `fsGrantPath` loop stays inline).

**Layers that already work (verify, no change):** `runtime/dialog.ts` (`Dialog.openFile`/`saveFile`/`message` → `invoke("__dialog:open"/"save"/"message")`, async promises); kitchen-sink `sections/dialogs.ts` (the smoke surface — open/save/message buttons already present).

**Verify.** iOS build `[zapp] build complete:`; macOS build unchanged + green; `bun run check`; `bun test cli/src` (new `--define:ios` test + existing dialog/router tests). **Human smoke (iPhone + iPad):** KS Dialogs section — open shows `UIDocumentPicker` and returns the picked path(s); save shows the picker and returns the path; message/confirm shows `UIAlertController` and returns the tapped button index (not `cancelled`/`button:0`).

### T2 — Sheet `#sheet=` focus: thread the content URL through iOS window-create

**Problem.** The `#sheet=` convention is pure TS routing (`kitchen-sink/src/shell/router.ts`; `Window.create({ url: "#sheet=settings", asSheetOf })` in `sections/multiwindow.ts`). The url string reaches native as `wopts_url(opts)`. macOS reads it (`darwin/window.m:781–782`: `custom_url = wopts_url(opts)` → `url_override` in every `darwin_webview_create_ext`). iOS does **not**: `darwin_window_create` (`ios/window.m:726`) reads sheet/sidebar/inspector options but never `wopts_url`, and `ZappIOSDeferred` (`ios/window.m:48–98`) has no content-url field, so `zapp_ios_materialize_pending_windows` always passes `NULL` as `url_override` (single-pane call `ios/window.m:429`, sidebar call `ios/window.m:356`). The webview loads `zapp_ios_initial_url()` with no fragment → JS router falls through to the main pane. (`zapp_ios_resolve_url`, `ios/webview.m:116`, already resolves a relative `#sheet=` ref against the initial url correctly once it's passed.)

**Fix (self-contained native, `ios/window.m`).**
- Add a `char* url;` field to `ZappIOSDeferred`.
- In `darwin_window_create`, read `wopts_url(opts)` and `strdup` it into `d->url` (NULL/empty → leave NULL; free in the deferred's teardown alongside the other strdup'd fields).
- Pass `d->url` as the `url_override` argument in both `darwin_webview_create_ext` calls in `zapp_ios_materialize_pending_windows` (single-pane `:429`, sidebar `:356`).

This is exactly the macOS shape. No router, runtime, or TS changes.

**Verify.** iOS build green; macOS unaffected. **Human smoke:** KS Multi-window → open a sheet with `url: "#sheet=settings"` (`asSheetOf`) → the sheet shows the **settings** route, not the main pane; a sheet with no `url` still shows the default page.

## Non-goals / deferred

- **File-drop regression → A4b (#726):** its own systematic-debugging cycle (WebKit re-claims `UIDropInteraction`; needs device-smoke iteration).
- **macOS behavior changes:** none. `darwin/dialog.m`, `darwin/window.m`, and the macOS sync `routeDialog` path are the reference, untouched.
- **New kitchen-sink surfaces:** none needed — `sections/dialogs.ts` and the `asSheetOf #sheet=` demos in `sections/multiwindow.ts` already exist as smoke surfaces.
- **New public API:** none — A4 restores the existing `Dialog` + sheet-url contracts on iOS.
- **`router.zc`:** unchanged — it already has the correct iOS async branch; we bring `router.nim` to parity, not the reverse.

## Verification (cycle gates)

- `bun run check` clean; `bun test cli/src` green (incl. the new `--define:ios` define test).
- iOS-sim build (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`) and default macOS build (`bun run build` → `[zapp] build complete:`) both green.
- **Human smoke (iPhone + iPad, per task):** T1 dialogs (open/save/message return real native results); T2 sheet `#sheet=` focus (sheet opens on the requested route).

## Task shape (for the plan)

- **T1 — Dialogs** — CLI `--define:ios` (TDD) + `dialog.nim` iOS async block + `router.nim` `routeDialog` iOS branch. One deliverable (the CLI define is the enabling prerequisite; split it into its own commit only if the diff is large). Verified by iOS+macOS build + `bun test` + human smoke.
- **T2 — Sheet `#sheet=` focus** — `ios/window.m` url field + `wopts_url` read + `url_override` pass-through. Native-only. Verified by iOS build + human smoke.

(T1 and T2 are independent; either can land first. Each ends in its own human-smoke gate.)
