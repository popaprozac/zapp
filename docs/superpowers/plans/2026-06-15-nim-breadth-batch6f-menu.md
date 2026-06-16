# Nim Breadth Batch 6f — menu Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the webview Menu surface — the t:4 `setMenu` / `showContextMenu` action arms in `routeWindowAction`, passing the full bridge payload to `darwin_menu_*_from_payload` (menu.m builds the NSMenu + resolves icons + handles clicks).

**Architecture:** menu.m does ALL the work from the JSON payload (extracts `"a"` items, builds the NSMenu, `zapp_resolve_icon`, click → JS/worker eval). So the Nim side is two thin payload-passthrough arms. The one structural change: `routeWindowAction` must receive the **raw bridge message** (it currently only gets the parsed `a`) — menu.m wants the full envelope. Thread `payload: string` through (reused by tray B6g). `menu.m` is compiled in the build root (`zapp.nim`); no framework or stub change.

**Tech Stack:** Nim, `importc` of `menu.m`'s `darwin_menu_*_from_payload`.

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build only. Spec: `…batch6-leaf-services-design.md` (B6f).
- **The webview path** (`runtime/menu.ts` → router.zc:1072-1098): `Menu.setApplicationMenu(...)` → t:4 action `setMenu`; `Menu.showContextMenu(...)` → t:4 `showContextMenu`. Both fire-and-forget (no reply).
- **Native targets** (defined in `native/platform/darwin/menu.m`, NOT yet compiled): `void darwin_menu_set_from_payload(const char* payload_json)`, `void darwin_menu_show_context_from_payload(const char* payload_json, int32_t window_id)`. **menu.m extracts `full[@"a"]` from the FULL bridge message** (menu.m:386-393, comment "extract 'a' from full bridge message") — so the Nim side must pass the **raw envelope** `{t:4,m:"setMenu",a:[…items…]}`, NOT just the parsed args.
- **menu.m's callbacks all already resolve in the Nim build** (verified): `darwin_webview_eval_all` (webview.m, compiled), `worker_broadcast_eval_js` (dispatch.nim, B4), `app_get_bootstrap_name` (appconfig.nim, B4), `darwin_window_get_webview` (window.m, compiled). So menu-item CLICK delivery to JS/workers works out of the box once menu.m links — no new wiring.
- **`zapp_resolve_icon` is DEFINED in menu.m** (menu.m:142; toolbar.m references it `extern` — menu.m:141 "Shared with toolbar.m (declared extern there)"). So compiling menu.m provides the icon resolver; B8's toolbar.m will reference it. **No duplicate** (menu.m = the one definition). No zapp.nim stub collides.
- **Framework:** AppKit (Cocoa, already in passL). None to add.
- **Permission gate:** `permission_id_for_action("setMenu"|"showContextMenu")` → `"menu"` (permissions.nim; confirmed by permissions_test) — gated at `routeWindowAction`'s head.
- **The `payload` threading** is reused by **B6g tray** (`darwin_tray_*_from_payload`) — a shared structural change, not menu-specific waste.
- **Native-first menu builders deferred:** menu.zc's `menu_set`/`menu_show_context` (taking `MenuItem*` structs) are the native-first API — struct-array marshaling, no webview/Nim caller. Deferred (like notification's typed wrappers); the webview path uses the `_from_payload` .m variants.
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only `native/nim/router.nim`, `native/nim/zapp.nim`. Never `hello-world/` etc. No `{.emit.}`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/router.nim` | thread `payload` into `routeWindowAction`; `setMenu`/`showContextMenu` arms + `darwin_menu_*` importc | Modify |
| `native/nim/zapp.nim` | compile `menu.m` | Modify |

*(No `menu.nim` module: the webview path is 2 payload-passthrough calls, like screen; native-first struct builders deferred. No pure-logic unit test — build + runtime + human-smoke gated.)*

---

## Task 1: thread payload + menu arms + compile menu.m → build → GATE

**Files:** Modify `native/nim/router.nim`, `native/nim/zapp.nim`.

- [ ] **Step 1: Add the menu importc decls**

In `native/nim/router.nim`, after the B6e screen importc block (the `darwin_screen_for_window_json` / `c_free` decls), add:
```nim
# --- t:4 menu targets (menu.m; payload = the FULL bridge envelope, menu.m
# extracts "a"). menu.m builds the NSMenu + icons + click delivery itself. ---
proc darwin_menu_set_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_menu_show_context_from_payload(payloadJson: cstring, windowId: int32) {.importc, cdecl.}
```

- [ ] **Step 2: Thread `payload` into `routeWindowAction`**

Change `routeWindowAction`'s signature (currently `proc routeWindowAction(action: string, a: JsonNode, windowId: int) =`) to add a `payload` param:
```nim
proc routeWindowAction(action: string, a: JsonNode, windowId: int, payload: string) =
```
Update the ONLY call site in `routeMessage` (currently `routeWindowAction(f.m, f.a, windowId)`) to:
```nim
    routeWindowAction(f.m, f.a, windowId, msg)
```
(`msg` is `routeMessage`'s raw-message string param — the full envelope menu.m wants. All other arms ignore `payload`.)

- [ ] **Step 3: Add the menu arms**

In `routeWindowAction`, AFTER the B6a shell-path arm block (the `showItemInFolder`/`openPath`/`trashItem` block) and BEFORE the `# --- handle-based window ops …` comment, insert:
```nim
  # --- menu ops (menu.m parses the full payload; gated "menu" at the head) ---
  if action == "setMenu":
    darwin_menu_set_from_payload(payload.cstring)
    return
  if action == "showContextMenu":
    darwin_menu_show_context_from_payload(payload.cstring, windowId.int32)
    return
```

- [ ] **Step 4: Compile menu.m in zapp.nim**

In `native/nim/zapp.nim`, add to the `{.compile(...).}` block (after the `shortcuts.m` line):
```nim
{.compile("../platform/darwin/menu.m", "-fobjc-arc").}
```

- [ ] **Step 5: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_menu_*` → the compile line is missing. A `duplicate symbol zapp_resolve_icon` would only appear if toolbar.m were also compiled — it isn't yet, so this should not occur.) Do NOT `git add` hello-world/.

- [ ] **Step 6: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): t:4 setMenu/showContextMenu + compile menu.m (Batch 6f)\n\nrouteWindowAction now threads the raw bridge payload (menu.m extracts "a" from\nthe full envelope) and dispatches setMenu -> darwin_menu_set_from_payload /\nshowContextMenu -> darwin_menu_show_context_from_payload. menu.m builds the\nNSMenu + resolves icons + delivers clicks via already-compiled symbols. menu.m\ncompiled in the build root (it defines zapp_resolve_icon; toolbar.m refs it\nextern in B8). Native-first MenuItem-struct builders deferred.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 8: GATE — human smoke (controller continues; user smokes later)**

`ZAPP_NATIVE_LANG=nim bun run dev`: `Menu.setApplicationMenu(...)` sets the app menu bar (with icons if specified); `Menu.showContextMenu(...)` pops a context menu at the cursor; clicking an item fires its action callback into JS.

---

## Self-Review

**1. Spec coverage:** t:4 `setMenu`/`showContextMenu` → Step 3 arms; payload threading (menu.m needs the full envelope) → Step 2; `menu.m` compiled → Step 4; icon resolver + click delivery = menu.m's job, all callback symbols already compiled → documented; native-first struct builders deferred → documented. ✓
**2. Placeholder scan:** No TBD/TODO; full arms + exact signature change + call-site update. ✓
**3. Type consistency:** `routeWindowAction(action, a, windowId, payload)` — the sole call site (`routeMessage`) updated to pass `msg`; all existing arms unaffected (they ignore `payload`). `darwin_menu_set_from_payload(cstring)` / `darwin_menu_show_context_from_payload(cstring, int32)` match menu.m. `payload.cstring` valid for the synchronous call. The arms early-`return` (payload-based, no window handle needed) before the handle-based case. ✓
