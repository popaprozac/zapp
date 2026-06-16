# Nim Breadth Batch 6d — shortcuts Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the webview global-shortcuts surface to the Nim build — `routeShortcuts` handling t:1 `__shortcuts:register`/`unregister`/`isRegistered`/`unregisterAll` via `darwin_shortcut_*` (Carbon global hotkeys), at parity with the zc.

**Architecture:** A new `native/nim/shortcuts.nim` owns the `darwin_shortcut_*` `importc` decls + thin Nim wrappers. `router.nim` gets `routeShortcuts` (dispatched from `routeMessage`'s t:1 chain). `shortcuts.m` is compiled in the build root (`zapp.nim`) + the missing `-framework Carbon` added to the passL. The hotkey-**press** event needs NO new wiring — shortcuts.m fires it via `zapp_app_dispatch` (app_events.nim, B4) + `worker_broadcast_eval_js` (dispatch.nim, B4) + `darwin_webview_eval_all` (compiled), all already in the Nim build.

**Tech Stack:** Nim, `importc` of `shortcuts.m`'s C-ABI, `bridge.nim` (`sendInvokeResponse`).

---

## Background

- **Branch:** `feat/nim-native`. Additive; macOS / Nim build only. Spec: `docs/superpowers/specs/2026-06-15-nim-breadth-batch6-leaf-services-design.md` (B6d).
- **Runtime contract** (`runtime/shortcuts.ts` → the zc `router_handle_shortcuts`, router.zc:1717-1762): `register`/`unregister`/`isRegistered` reply a **boolean** (the JS promise resolves to it); `unregisterAll` replies `null`. Arg key `"accelerator"`. Missing-arg / unknown → `UNKNOWN_SHORTCUT`.
- **Native targets (shortcuts.h; defined in `native/platform/darwin/shortcuts.m`, NOT yet compiled):** `bool darwin_shortcut_register(const char* accelerator)`, `bool darwin_shortcut_unregister(const char*)`, `bool darwin_shortcut_is_registered(const char*)`, `void darwin_shortcut_unregister_all(void)`.
- **The press event needs no Nim work:** shortcuts.m, on a hotkey fire, calls `zapp_app_dispatch(event_id, data)` (provided by app_events.nim, B4), `darwin_webview_eval_all` (webview.m, compiled), `worker_broadcast_eval_js` (dispatch.nim, B4) — all already present. So registering + pressing a shortcut delivers to JS/workers out of the box once shortcuts.m links.
- **Permission gate:** `permission_id_for_invoke("__shortcuts:*")` → `"shortcuts"` (permissions.nim; confirmed by permissions_test). Gated by `routeMessage`'s existing t:1 checkpoint before `routeShortcuts`.
- **B6a/B6c RULES:** compile `shortcuts.m` in the **build root `zapp.nim`** (NOT self-compiled). It needs **`-framework Carbon`** (global hotkeys; the zc build links it — build-config.ts:698 — but the Nim passL omits it). No zapp.nim stub collides (shortcuts.m defines no currently-stubbed symbol; verified).
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only the files this task lists. Never `hello-world/`, `vendor/`, `kitchen-sink/`. Never edit `native/platform/**` or `native/worker/engines/*.c`. No `{.emit.}`. Build success ONLY when the last line is `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/shortcuts.nim` | `darwin_shortcut_*` importc + thin wrappers | Create |
| `native/nim/router.nim` | `routeShortcuts` + t:1 `__shortcuts:` dispatch | Modify |
| `native/nim/zapp.nim` | compile `shortcuts.m` + add `-framework Carbon` | Modify |

*(No pure-logic unit test — thin importc wrappers + routing; build + runtime + human-smoke gated. One cohesive task.)*

---

## Task 1: shortcuts.nim + routeShortcuts + compile shortcuts.m → build → GATE

**Files:** Create `native/nim/shortcuts.nim`; modify `native/nim/router.nim`, `native/nim/zapp.nim`.

- [ ] **Step 1: Create `native/nim/shortcuts.nim`**

Create `native/nim/shortcuts.nim`:
```nim
## Global shortcuts (Carbon hotkeys) — webview surface. Mirrors the zc
## router_handle_shortcuts (which wraps Shortcuts:: → darwin_shortcut_*).
## MAIN-THREAD (webview->native); idiomatic. The hotkey-press EVENT is fired
## by shortcuts.m via zapp_app_dispatch (app_events.nim) — no Nim wiring here.
##
## NB: darwin_shortcut_* are defined in native/platform/darwin/shortcuts.m,
## compiled by the build root (zapp.nim, which also links -framework Carbon).

proc darwin_shortcut_register(accelerator: cstring): bool {.importc, cdecl.}
proc darwin_shortcut_unregister(accelerator: cstring): bool {.importc, cdecl.}
proc darwin_shortcut_is_registered(accelerator: cstring): bool {.importc, cdecl.}
proc darwin_shortcut_unregister_all() {.importc, cdecl.}

proc shortcutRegister*(accelerator: string): bool = darwin_shortcut_register(accelerator.cstring)
proc shortcutUnregister*(accelerator: string): bool = darwin_shortcut_unregister(accelerator.cstring)
proc shortcutIsRegistered*(accelerator: string): bool = darwin_shortcut_is_registered(accelerator.cstring)
proc shortcutUnregisterAll*() = darwin_shortcut_unregister_all()
```

- [ ] **Step 2: Compile shortcuts.m + add Carbon in zapp.nim**

In `native/nim/zapp.nim`, append `-framework Carbon` to the `{.passL: "…".}` line (after `-framework UserNotifications`), and add to the `{.compile(...).}` block (after the `notification.m` line):
```nim
{.compile("../platform/darwin/shortcuts.m", "-fobjc-arc").}
```

- [ ] **Step 3: Add `import shortcuts` + `routeShortcuts` in router.nim**

In `native/nim/router.nim`, add `shortcuts` to the top `import` line (currently `…, fs, dialog, notification`):
```nim
import bridge, service, clipboard, callbacks, events, permissions, fs, dialog, notification, shortcuts
```
Then add `routeShortcuts` immediately AFTER `routeNotification` (before `proc routeWindowAction`):
```nim
proc routeShortcuts(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__shortcuts:*` (mirror router.zc:1717-1762). register/unregister/
  ## isRegistered reply the boolean; unregisterAll replies null; missing arg /
  ## unknown → UNKNOWN_SHORTCUT. Arg key "accelerator".
  let acc = a{"accelerator"}.getStr("")
  case meth
  of "__shortcuts:register":
    if acc.len == 0: sendInvokeResponse(windowId, id, false, "UNKNOWN_SHORTCUT")
    else: sendInvokeResponse(windowId, id, true, (if shortcutRegister(acc): "true" else: "false"))
  of "__shortcuts:unregister":
    if acc.len == 0: sendInvokeResponse(windowId, id, false, "UNKNOWN_SHORTCUT")
    else: sendInvokeResponse(windowId, id, true, (if shortcutUnregister(acc): "true" else: "false"))
  of "__shortcuts:isRegistered":
    if acc.len == 0: sendInvokeResponse(windowId, id, false, "UNKNOWN_SHORTCUT")
    else: sendInvokeResponse(windowId, id, true, (if shortcutIsRegistered(acc): "true" else: "false"))
  of "__shortcuts:unregisterAll":
    shortcutUnregisterAll()
    sendInvokeResponse(windowId, id, true, "null")
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_SHORTCUT")
```
(The zc only dispatches register/unregister/isRegistered when the `accelerator` arg `is_some()`, else falls to `UNKNOWN_SHORTCUT` — the `acc.len == 0` guard mirrors that. `a{"accelerator"}` is nil-safe on a nil/non-object `a`.)

- [ ] **Step 4: Dispatch `__shortcuts:` in routeMessage**

In `routeMessage`'s t:1 chain, add the `__shortcuts:` branch after the `__notif:` branch and before `invokeService`:
```nim
  if f.m.startsWith("__notif:"):
    routeNotification(f.m, f.a, windowId, f.id)
    return
  if f.m.startsWith("__shortcuts:"):
    routeShortcuts(f.m, f.a, windowId, f.id)
    return
```

- [ ] **Step 5: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_shortcut_*` → the compile line is missing; undefined Carbon symbols / `_RegisterEventHotKey` → the `-framework Carbon` wasn't added.) Do NOT `git add` hello-world/.

- [ ] **Step 6: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/shortcuts.nim native/nim/router.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): shortcuts.nim + routeShortcuts t:1 __shortcuts:* (Batch 6d)\n\nGlobal-hotkey register/unregister/isRegistered/unregisterAll via darwin_shortcut_*\n(Carbon). routeShortcuts replies the boolean (or null for unregisterAll);\nUNKNOWN_SHORTCUT on missing accelerator. shortcuts.m compiled in the build root\n+ -framework Carbon added. The hotkey-press event already fans out via\nzapp_app_dispatch (app_events.nim) — no new wiring.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 8: GATE — human smoke (controller continues; user smokes later)**

`ZAPP_NATIVE_LANG=nim bun run dev`: register a global shortcut (e.g. via the hello-world shortcuts demo), press it outside the app → the registered callback fires (app event reaches JS); `isRegistered` returns true; `unregister`/`unregisterAll` stop it firing.

---

## Self-Review

**1. Spec coverage:** `shortcuts.nim` wrappers → Step 1; t:1 `register`/`unregister`/`isRegistered`/`unregisterAll` → Step 3 (`routeShortcuts`) + Step 4 (dispatch); `shortcuts.m` compiled + Carbon framework → Step 2; press event = no-op (already wired via app_events.nim) → documented. ✓
**2. Placeholder scan:** No TBD/TODO; full module + exact insertions. ✓
**3. Type consistency:** `shortcutRegister`/`shortcutUnregister`/`shortcutIsRegistered(accelerator: string): bool` + `shortcutUnregisterAll()` match shortcuts.nim defs; `darwin_shortcut_*` importc match shortcuts.h (`const char*`↔`cstring`, `bool`↔`bool`); `sendInvokeResponse`/`a{"accelerator"}.getStr` match the B6 idiom; `routeShortcuts(meth, a, windowId, id)` matches the routeMessage call site. ✓
