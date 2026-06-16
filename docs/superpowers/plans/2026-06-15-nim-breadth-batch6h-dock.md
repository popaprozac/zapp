# Nim Breadth Batch 6h — dock Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the webview Dock surface — the t:4 `dock:*` action arms in `routeWindowAction` (showIcon/hideIcon/removeBadge/resetIcon/setBadge/bounce/setProgress/setIcon) calling `darwin_dock_*`.

**Architecture:** dock is arg-based (parsed `a`, NOT payload). A `dock:`-prefixed dispatch in `routeWindowAction` calls the typed `darwin_dock_*` from dock.m. `setProgress` is a **no-op on macOS** (dock.zc:40 has an empty Apple body — no standard dock progress). `dock.m` is compiled in the build root; no framework, stub, collision, or callback.

**Tech Stack:** Nim (`std/json` for args), `importc` of `dock.m`'s `darwin_dock_*`.

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build only. Spec: `…batch6-leaf-services-design.md` (B6h).
- **The webview path** (`runtime/dock.ts` → router.zc:735-768): all `dock:*` are fire-and-forget t:4 (no reply). The zc calls `dock_*` (dock.zc free fns wrapping `darwin_dock_*`).
- **Native targets** (dock.h; defined in `native/platform/darwin/dock.m`, NOT yet compiled): `void darwin_dock_show_icon(void)`, `darwin_dock_hide_icon(void)`, `darwin_dock_set_badge(const char* label)`, `darwin_dock_remove_badge(void)`, `darwin_dock_bounce(int type)`, `darwin_dock_set_icon(const char* image_path)`, `darwin_dock_reset_icon(void)`. (`darwin_dock_get_badge` exists but the dock:* router arms don't use it — skip.)
- **`setProgress` is a no-op on macOS:** dock.zc:40 `fn dock_set_progress(permille, mode) -> void {}` (empty Apple body; only Windows wires it). There is **no `darwin_dock_set_progress`** — the Nim `dock:setProgress` arm is a `discard` (parity).
- **Arg keys** (parsed `a`, per router.zc:739-768): `setBadge`→`"label"` (string, only if present); `bounce`→`"type"` (int, default 0); `setProgress`→`"permille"`/`"mode"` (ints — ignored, no-op); `setIcon`→`"path"` (string, only if present). showIcon/hideIcon/removeBadge/resetIcon take no args.
- **Framework:** AppKit (Cocoa, in passL). None to add. No zapp.nim stub collides. dock.m has no callback externs (no dock events). No `zapp_resolve_icon` use.
- **Permission gate:** `permission_id_for_action("dock:*")` → `"dock"` (permissions.nim `dock:` prefix rule; confirmed by permissions_test) — gated at routeWindowAction's head.
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only `native/nim/router.nim`, `native/nim/zapp.nim`. Never `hello-world/` etc. No `{.emit.}`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/router.nim` | the `dock:*` arms + `darwin_dock_*` importc | Modify |
| `native/nim/zapp.nim` | compile `dock.m` | Modify |

*(No `dock.nim` module: arg-dispatch routing, like screen. No pure-logic unit test — build + runtime + human-smoke gated.)*

---

## Task 1: dock:* arms + compile dock.m → build → GATE

**Files:** Modify `native/nim/router.nim`, `native/nim/zapp.nim`.

- [ ] **Step 1: Add the dock importc decls**

In `native/nim/router.nim`, after the B6g tray importc block (the `darwin_tray_detach_window_from_payload` decl), add:
```nim
# --- t:4 dock targets (dock.m; arg-based, not payload). No darwin set_progress
# (macOS dock has no standard progress — dock.zc:40 is a no-op). ---
proc darwin_dock_show_icon() {.importc, cdecl.}
proc darwin_dock_hide_icon() {.importc, cdecl.}
proc darwin_dock_remove_badge() {.importc, cdecl.}
proc darwin_dock_reset_icon() {.importc, cdecl.}
proc darwin_dock_set_badge(label: cstring) {.importc, cdecl.}
proc darwin_dock_bounce(bounceType: cint) {.importc, cdecl.}
proc darwin_dock_set_icon(imagePath: cstring) {.importc, cdecl.}
```

- [ ] **Step 2: Add the dock dispatch arm**

In `routeWindowAction`, AFTER the B6g tray arm (the `if action.startsWith("tray:"): … return` block) and BEFORE the `# --- handle-based window ops …` comment, insert:
```nim
  # --- dock ops (dock.m; arg-based; gated "dock" at the head) ---
  if action.startsWith("dock:"):
    case action
    of "dock:showIcon": darwin_dock_show_icon()
    of "dock:hideIcon": darwin_dock_hide_icon()
    of "dock:removeBadge": darwin_dock_remove_badge()
    of "dock:resetIcon": darwin_dock_reset_icon()
    of "dock:setBadge":
      let label = a{"label"}
      if not label.isNil: darwin_dock_set_badge(label.getStr("").cstring)
    of "dock:bounce":
      darwin_dock_bounce(a{"type"}.getInt(0).cint)
    of "dock:setProgress": discard      # macOS: no-op (dock.zc:40 empty Apple body)
    of "dock:setIcon":
      let path = a{"path"}
      if not path.isNil: darwin_dock_set_icon(path.getStr("").cstring)
    else: discard
    return
```
(`a{"label"}`/`a{"path"}` nil-safe; `a{"type"}.getInt(0)` defaults 0 — matches the zc's `t = 0` default. `.cint` matches `int type`.)

- [ ] **Step 3: Compile dock.m in zapp.nim**

In `native/nim/zapp.nim`, add to the `{.compile(...).}` block (after the `tray.m` line):
```nim
{.compile("../platform/darwin/dock.m", "-fobjc-arc").}
```

- [ ] **Step 4: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_dock_*` → the compile line is missing.) Do NOT `git add` hello-world/.

- [ ] **Step 5: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): t:4 dock:* + compile dock.m (Batch 6h)\n\nrouteWindowAction dispatches dock:showIcon/hideIcon/removeBadge/resetIcon/\nsetBadge/bounce/setIcon to dock.m'\''s darwin_dock_* (arg-based). dock:setProgress\nis a no-op on macOS (dock.zc:40 empty Apple body — no darwin_dock_set_progress).\ndock.m compiled in the build root; no framework/stub/callback.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 7: GATE — human smoke (controller continues; user smokes later)**

`ZAPP_NATIVE_LANG=nim bun run dev`: `Dock.setBadge("3")` shows a badge; `removeBadge` clears it; `bounce()` bounces the dock icon; `setIcon(path)` swaps the icon; `resetIcon` restores it; `hideIcon`/`showIcon` toggle dock presence. (`setProgress` is intentionally a no-op on macOS.)

---

## Self-Review

**1. Spec coverage:** all 8 `dock:*` actions → Step 2 (7 real + setProgress no-op); arg keys (label/type/path) → Step 2; `dock.m` compiled → Step 3; no framework/stub/collision/callback → documented; setProgress macOS no-op parity → documented. ✓
**2. Placeholder scan:** No TBD/TODO; full arm + exact insertions. ✓
**3. Type consistency:** the 7 `darwin_dock_*` importc match dock.h (`void`/`const char*`/`int`↔`cint`); `a{"label"}`/`a{"path"}` nil-safe string args (dispatch only when present, mirroring the zc `is_some`); `a{"type"}.getInt(0).cint` matches `darwin_dock_bounce(int)` + the zc default-0; `.cstring` valid for the synchronous calls; the `startsWith("dock:")` guard + `return` keeps dock actions out of the handle-based case. ✓
