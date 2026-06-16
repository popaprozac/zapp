# Nim Migration — Phase 2 Breadth, Batch 5a: Router Framework + Available Routes — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration breadth phase (`2026-06-15-nim-migration-design.md`); applies
the type-modeling convention (`2026-06-15-nim-type-modeling-convention-design.md`).
B1-B4 done. **This is Batch 5a** — the first slice of the router (`router.zc`, 1891 LOC).

## Why split

`router.zc` dispatches into many leaf features, ~half of whose target `.m` files aren't
compiled into the Nim build yet (dock/sidebar/inspector/popover/toolbar → B8 native-chrome;
dialog/notif/shortcuts/screen → B6 leaf services; worker actions → B7). The router can't
land in one batch, and shouldn't: **each leaf-feature's route lands with its leaf** (B6/B8
add the `.m` + its route together). B5 splits into:
- **B5a (this spec):** the dispatch framework + the routes whose targets exist today +
  the t:4 action permission gate (B3 deferral).
- **B5b (next):** the t:4 window/app/panel/shell action surface (the mechanical bulk).

## Goal

Port the `router_handle_message` dispatch spine, the `__zapp:*` and `__app:*` t:1 routes,
and `permission_id_for_action` + the t:4 action permission gate to Nim — **fixing the
`Workers.list()` → NOT_FOUND** the runtime currently hits, and laying the gated t:4 handler
seam that B5b/B8 fill.

## Scope

**In:**
- **`permission_id_for_action(action: cstring): cstring`** in `permissions.nim` (next to
  `permission_id_for_invoke`, same pure-mapping/leaf-testable pattern). Mirrors
  `router.zc:40-54`: `tray:` → `tray`; `dock:` → `dock`; the panel actions
  (`panelCreate`/`panelSetBounds`/`panelLoadUrl`/`panelExecJs`/`panelPostMessage`/`panelShow`/
  `panelHide`/`panelReload`/`panelBack`/`panelForward`/`panelDestroy`) → `embed`;
  `setMenu`/`showContextMenu` → `menu`; `openExternal`/`openPath` → `shell:open`;
  `showItemInFolder` → `shell:reveal`; `trashItem` → `shell:trash`; else `""` (ungated:
  window ops, app lifecycle, plumbing). Unit-tested in `permissions_test.nim`.
- **`router.nim` t:1 routing additions** (in `routeMessage`, after the existing permission
  gate + `__clipboard:` block, before the service-registry fallthrough):
  - `__zapp:` prefix → a `routeZapp` proc: `__zapp:workers-list` → dispatch
    `zapp_workers_registry_list_json()` (the existing `zapp.nim` stub returns a **static**
    `"[]"`; **do NOT `free` it** — the zc frees a malloc'd registry string, but the B5 stub
    is static; B7 re-adds the free when the registry mallocs); `__zapp:permissions` →
    `permissions_bootstrap_json()` (real, from B3); else reply bare `UNKNOWN_ZAPP_METHOD`.
    Mirrors `router.zc:1352-1375`. **Fixes the user-visible `Workers.list()` NOT_FOUND** (now
    returns `[]`).
  - `__app:` prefix → a `routeApp` proc: `__app:setLoginItem` → `darwin_set_login_item(bool)`,
    `__app:getLoginItem` → `darwin_get_login_item()` (both `importc`, platform.m ✓); reply the
    bool as a JSON literal (`"true"`/`"false"`); else reply `UNKNOWN`. Mirrors
    `router.zc:1377-1415` (macOS path).
- **`router.nim` t:4 handler restructure** — extract the current inline t:4 handling
  (`subscribe`/`unsubscribe`/`ready`) into a `routeWindowAction(action, a, windowId)` proc
  whose HEAD is the **t:4 action permission gate** (mirrors `router.zc:380-385`): compute
  `permission_id_for_action(action)`; if non-empty and `not permissions_check(id, action)`,
  return (fire-and-forget: log + drop, no reply channel). Below the gate: the existing
  `subscribe`/`unsubscribe`/`ready` (ungated — `permission_id_for_action` returns `""` for
  them). `routeMessage` calls `routeWindowAction` for `f.t == 4`. The window/app/panel/shell
  action arms are **B5b** (added below the gate).

**Out (deferred — each lands with its leaf/feature batch):**
- The t:4 **window/app/panel/shell action arms** (`router_handle_window_action`'s body) → **B5b**.
- Leaf t:1 routes `__dialog:`/`__notif:`/`__shortcuts:`/`__screen:` → **B6** (each adds its
  prefix check + handler together; until then they fall through to the service registry →
  NOT_FOUND, unchanged from today).
- t:4 leaf-feature actions dock/sidebar/inspector/popover/toolbar → **B8**.
- `router_handle_worker` (t:4 worker actions) → **B7**.
- **Cancellation guard** (the B4 deferral): NOT ported. `protocol.zc`'s
  `zapp_is_cancelled`/`zapp_clear_cancelled` exist but `zapp_mark_cancelled` is **never
  called anywhere** (verified) — the guard is vestigial in the zc (always false). Porting it
  would be dead code; omitting it is wire-identical. Re-evaluate if a real cancel route lands.

## Architecture / convention

- `permission_id_for_action` joins `permission_id_for_invoke` in `permissions.nim` — pure
  cstring mapping, no state, `{.exportc, cdecl, gcsafe.}` is NOT needed (router-main-thread
  only; unlike `permission_id_for_invoke` which the worker engines call, `permission_id_for_action`
  is router-internal — confirm no worker-engine extern references it; if none, it can be a
  plain Nim `proc` without exportc). Returns string-literal cstrings (static, stable).
- `routeZapp` / `routeApp` / `routeWindowAction` are `router.nim`-internal Nim procs (the
  dispatch DECISIONS live in Nim; the targets are importc'd C symbols / Nim procs). The t:4
  gate runs on the main thread (webview→native), so `$action` / Nim-string building is fine.
- No `{.emit.}`; `.m`/engines untouched. The leaf-prefix seams are left as comments so B6/B8
  slot in cleanly.

## Success criteria (the gate)

- **`Workers.list()` works:** the runtime call returns `[]` (the registry stub), not
  `Error: NOT_FOUND`. (The user hit this; B5a fixes it.)
- **`App.getLoginItem()`/`setLoginItem()`** round-trip a bool on the Nim build.
- **The t:4 action gate** is in place: `permission_id_for_action` maps correctly (unit test)
  and a gated action is denied when the manifest doesn't grant it (verified by unit test of
  the mapping + the existing `permissions_check`; runtime is hard to observe for
  fire-and-forget, so unit is the proof).
- Existing window-event subscribe/unsubscribe/ready still work (refactor preserved behavior).
- Build ends `[zapp] build complete:`; all Nim unit tests pass; `.m`/engines untouched; no `{.emit.}`.

## Risks (into the plan)

- **`zapp_workers_registry_list_json` lifetime:** the zc frees the returned string; the Nim
  stub returns a static `"[]"`. The Nim `routeZapp` must NOT free it. Add a comment so B7
  (malloc'd registry) re-adds the free.
- **`permission_id_for_action` worker-engine refs:** confirm no `zjs.c`/`bare.c` extern calls
  it (only `permission_id_for_invoke` is in their extern surface) — so it needn't be exportc.
  If something does reference it, make it `{.exportc, cdecl, gcsafe.}` like its sibling.
- **t:4 refactor:** moving subscribe/unsubscribe/ready into `routeWindowAction` must preserve
  the exact current behavior (the bridge-ready focus fix from B1). Confirm `ready` still
  signals `darwin_window_set_bridge_ready` + `zapp_window_trigger_on_ready`.
- **`__app:` importc:** `darwin_set_login_item(bool)` / `darwin_get_login_item()` signatures
  — confirm against `platform.m` (return `bool`).
- **routeMessage ordering:** `__zapp:`/`__app:` checks go AFTER the permission gate +
  `__clipboard:` and BEFORE the service-registry fallthrough, matching `router.zc:57-130`.

## References

- `native/app/router.zc:40-54` (`permission_id_for_action`), `:57-130` (dispatch spine),
  `:376-385` (t:4 action gate head), `:1352-1375` (`router_handle_zapp`), `:1377-1415`
  (`router_handle_app`).
- `native/nim/router.nim` (current skeleton: t:1 invoke + clipboard + permission gate + t:4
  subscribe/unsubscribe/ready), `native/nim/permissions.nim` (`permission_id_for_invoke` —
  the sibling mapping), `native/nim/zapp.nim` (`zapp_workers_registry_list_json` stub).
- `native/platform/darwin/platform.m` (`darwin_set_login_item`/`darwin_get_login_item`,
  shell ops — the latter are B5b).
