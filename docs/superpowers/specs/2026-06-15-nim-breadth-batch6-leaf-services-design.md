# Nim Migration — Phase 2 Breadth, Batch 6: Leaf Services — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration breadth phase; applies the type-modeling convention.
B1–B5b done. **This is Batch 6** — the leaf services (dialog/notification/shortcuts/
screen/menu/fs/tray/dock/panel) and their router routes.

## Goal

Port the nine leaf-service `.zc` modules to idiomatic Nim and wire each one's
router route, so the demo's `Dialog.*` / `Notification.*` / `Shortcuts.*` /
`Screen.*` / `Menu.*` / `Tray.*` / `Dock.*` / embedded-`panel` / shell-path
(`openPath`/`showItemInFolder`/`trashItem`) surfaces work on the `ZAPP_NATIVE_LANG=nim`
build — at parity with the `.zc` path. Each leaf's `darwin_*` targets are already
compiled into the Nim build (the `native/platform/darwin/*.m` files, untouched).

## Decomposition: per-leaf micro-batches (user-chosen 2026-06-15)

B6 is **nine micro-batches, one per leaf**, dependency-ordered. The user chose
maximum granularity (smallest reviews, most human-smoke gates) over coarser slicing.

| # | Leaf | `.zc` (LOC) | Route shape | Deps / notes |
|---|---|---|---|---|
| **B6a** | **fs** | `native/fs/fs.zc` (496) | App methods + t:4 shell-path arms | **Foundational, goes first.** Allowlist + path-expand + gated IO. **Closes the B5b-deferred shell-path ops** (openPath/showItemInFolder/trashItem). Exposes `fs_grant_path` for B6b. Needs CLI `fs.allow` codegen. |
| **B6b** | **dialog** | `native/dialog/dialog.zc` (84) | t:1 `__dialog:` | Wires `fs_grant_path` on `:open` result → needs B6a. |
| **B6c** | **notification** | `native/notification/notification.zc` (121) | t:1 `__notif:` | Independent. Also a `__notif:`-prefixed event delivery (click). |
| **B6d** | **shortcuts** | `native/shortcuts/shortcuts.zc` (98) | t:1 `__shortcuts:` | Independent. |
| **B6e** | **screen** | `native/screen/screen.zc` (71) | t:1 via `screen_route` | Independent. Also SCREENS_CHANGED event (already in the events table). |
| **B6f** | **menu** | `native/menu/menu.zc` (103) | t:4 `setMenu`/`showContextMenu` | NSMenu-from-JSON build + icon resolution (`zapp_resolve_icon`). Feeds B6g. |
| **B6g** | **tray** | `native/tray/tray.zc` (114) | t:4 `tray:` | `tray:setMenu` uses the menu builder → needs B6f. |
| **B6h** | **dock** | `native/dock/dock.zc` (90) | t:4 `dock:` | Independent. |
| **B6i** | **panel** | `native/panel/panel.zc` (185) | t:4 via `panel_route` | The B5b-deferred embedded-webview ops. |

**`sync` (`native/sync/sync.zc`, 67) → deferred to B7.** It is a worker-coordination
envelope-type pass-through (the router routes the `sync` envelope to the compiled
`darwin_sync_handle`); thematically it belongs with the worker subsystem (B7) and is
trivial there. It is NOT a UI leaf, so it is out of B6.

## Threading verdict (the design crux — investigated 2026-06-15)

**`fs.zc` is reached ONLY from the main thread.** Every caller is a main-thread
router / dialog-result / App-instance-method path. `bare-fs` (`runtime/bare/fs.ts`)
**bypasses `fs.zc` entirely** (libuv direct + a TS-layer allowlist), and there is
**no `__fs:` webview bridge route**. So **`fs.nim` (and every other B6 leaf, all of
which dispatch on the main webview→native thread) can use idiomatic Nim** — heap,
`std/json`, normal `string`/`seq`. **No `{.gcsafe.}` / alloc-free discipline** (that
constraint applies only to the zjs/bare worker-pthread path: `worker_service.nim` /
`permissions.nim`'s check path / a future B7 `service_invoke_sync`).

The `fs.m` ↔ `fs.zc` layering: `fs.zc`'s gated `fs_*` (expand → allowlist → IO)
**call** `fs.m`'s raw `darwin_fs_*` (POSIX/Foundation syscalls, no allowlist). The Nim
port keeps that split: `fs.nim` owns the allowlist + expansion, `importc`s the raw
`darwin_fs_*` for the syscalls.

## The shared per-leaf recipe

Every leaf follows the template B1–B5 proved:

1. **`native/nim/<leaf>.nim`** — port the `.zc`'s gated/helper logic in **idiomatic
   Nim** (lean into Nim: `std/json` for JSON build/parse, `string`/`seq`, `Option`,
   string `case`; magic numbers → `{.pure.}` enums per the type-modeling convention;
   `Table` where the `.zc` used a linear array). `importc` the `darwin_*` C-ABI from
   the untouched `.m`. `{.exportc, cdecl.}` (with `*` so Nim tests/modules can call it)
   only the symbols the `.m` or another TU calls back into.
2. **Wire its route** into `native/nim/router.nim`:
   - **t:1 leaves** (dialog/notification/shortcuts) → a `routeXxx(method, a, windowId, id)`
     proc dispatched from `routeMessage`'s t:1 prefix chain (mirroring `routeClipboard`);
     the per-leaf permission id already resolves via `permission_id_for_invoke`.
   - **t:1 via dedicated route fn** (screen) → mirror the `screen_route` shape.
   - **t:4 leaves** (menu/tray/dock) → action arms in `routeWindowAction` (mirroring
     B5b), gated at the head via the existing `permission_id_for_action`.
   - **t:4 via dedicated route fn** (panel) → mirror `panel_route` (called from
     `routeWindowAction` before the handle-based window `case`).
3. **Drop the matching `zapp.nim` stub** (if any), add a Nim **unit test** for the pure
   logic (path expansion, allowlist matching, JSON menu build, arg parsing), **build**
   (`ZAPP_NATIVE_LANG=nim bun run build` → last line `[zapp] build complete:`), and end
   at a **human-smoke gate**.

CLI codegen is added **only** where a leaf reads `zapp.config.ts` — currently just
**fs** (`fs.allow` static allowlist → a `zapp_build_fs_allowlist_*` emitter in the Nim
build-config, mirroring permissions' `zapp_build_permissions_json`).

## The fs leaf (B6a) in detail

`native/nim/fs.nim` (idiomatic, main-thread):
- **Path-variable expansion**: `$userData`, `$cache`, `$temp`, `$home`, `$downloads`,
  `$documents`, `$appData` (alias of `$userData`); `~/…` → `$home`. (Mirror
  `fs_expand_path`, fs.zc:48; the platform dirs come from `darwin_fs_path_var` in fs.m.)
- **Two-source allowlist**: (1) static set from `zapp.config.ts` `fs.allow` (loaded at
  main-thread init, like permissions B3), (2) runtime session grants via `fs_grant_path`.
  `fs_is_allowed(resolved)` checks both. (Mirror fs.zc:125/200/237.)
- **Gated IO wrappers**: `fs_read_file` / `fs_write_file` / `fs_append_file` /
  `fs_exists` / `fs_read_dir` / `fs_mkdir` / `fs_remove` / `fs_rmdir` / `fs_rename` /
  `fs_copy` — each: expand → allowlist-check → call the raw `darwin_fs_*` (fs.m). Port
  for parity even though no current Nim-build caller exercises the read/write surface
  (the webview has no fs route; bare workers bypass fs.zc) — they are the native-first
  Zen-C/Nim API surface and keep the layer complete.
- **CLI codegen**: emit the `fs.allow` static list for the Nim build (new emitter in the
  Nim build-config path; mirror the permissions emitter).
- **Router wiring (closes the B5b deferral)**: the **shell-path t:4 arms** in
  `routeWindowAction` — `openPath` → `darwin_open_path` (or the app-method equivalent;
  confirm the compiled target in planning), `showItemInFolder` → reveal,
  `trashItem` → trash, **with the FS-allowlist gate on `trashItem`** (router.zc:576-593:
  showItemInFolder/openPath are non-destructive and ungated-by-allowlist; trashItem
  moves data → gate by `fs_is_allowed` so JS can't trash arbitrary paths). `fs_expand_path`
  feeds all three.
- **`fs_grant_path`** is left exported/ready; B6b's dialog `:open` result handler wires
  it (grant the path the user picked so subsequent fs reads of it pass the allowlist).

## Per-leaf specifics (for each leaf's plan)

The exact arg keys, action strings, and `darwin_*` signatures are **confirmed against
the leaf's `.zc` + `.m` during that leaf's planning** (the `.zc` is source of truth —
the B5b lesson: read the `.zc`, don't trust guessed constants). Known shapes:

- **dialog** (t:1): `__dialog:open` / `__dialog:save` / `__dialog:message` → `dialog.m`
  (`darwin_dialog_*`). `:open` result → `fs_grant_path` on the chosen path(s)
  (router.zc:1494-1531). Inline router block today (router.zc:1435-1531).
- **notification** (t:1): `__notif:requestPermission` / `getPermission` / `show` /
  `schedule` / `cancel` / `cancelAll` / `registerCategory` / `removeCategory` /
  `removeDelivered` / `removeAllDelivered` / `update` → `notification.m`. Plus the
  `__notif:`-prefixed **event** delivery (notification click → JS), router.zc:1157.
  **Guard:** `UNUserNotificationCenter` aborts outside an `.app` bundle — the `.m`
  already funnels through `zapp_notification_center()` (nil-safe); no Nim-side concern.
- **shortcuts** (t:1): `__shortcuts:register` / `unregister` / `isRegistered` /
  `unregisterAll` → `shortcuts.m` (Carbon global hotkeys). Router.zc:1721-1751.
- **screen** (t:1 via `screen_route`): `__screen:*` display enumeration (`Screen.getAll()`
  etc.) → `screen.m`. SCREENS_CHANGED event already in the events table (B1). Mirror the
  `screen_route(method, window_id, request_id, args)` shape (screen.zc:6).
- **menu** (t:4): `setMenu` / `showContextMenu` → build NSMenu from the JSON menu tree +
  `zapp_resolve_icon` (sf:/path/data-URL, iconTemplate). Router.zc:1072. The menu builder
  is shared with tray:setMenu and the app menu.
- **tray** (t:4): `tray:create` / `setIcon` / `setTitle` / `setTooltip` / `setMenu` /
  `destroy` / `attachWindow` / `detachWindow` → `tray.m` + the menu builder + icon
  resolver. Registry of tray items. Router.zc:966. **Gotcha (from the tray cycles):** the
  runtime sends `template:false` for WYSIWYG icons — preserve the flag faithfully.
- **dock** (t:4): `dock:showIcon` / `hideIcon` / `removeBadge` / `resetIcon` / `setBadge`
  / `bounce` / `setProgress` / `setIcon` → `dock.m`. Router.zc:735-763.
- **panel** (t:4 via `panel_route`): the embedded-webview ops (create/destroy/setBounds/
  load/etc.) → `panel.m`. Mirror `panel_route(window_id, action, args)` (panel.zc:20),
  called from `routeWindowAction` (router.zc:732). Closes the B5b panel deferral.

## Risks (into each plan)

- **Arg-key / action-string fidelity:** confirm each against the leaf's `.zc` during
  planning (a wrong key silently no-ops). The B5b lesson holds.
- **`std/json` `hasKey` aborts on a non-object payload** — use the nil-safe `{}` accessor
  (`let v = a{"k"}; if not v.isNil`), the idiom `routeClipboard`/`routeApp`/the B5b arms
  use. (B5b reusable gotcha.)
- **Icon resolution (menu/tray):** `zapp_resolve_icon` is in the `.m` (compiled) — `importc`
  it; don't re-port the icon pipeline. Preserve `template` true/false faithfully.
- **fs allowlist correctness:** fail-open only on a malformed/inactive manifest (mirror
  permissions' `gActive`); a present-but-empty allowlist denies. `trashItem` MUST be
  allowlist-gated (security — router.zc:576-593).
- **Registries (tray):** the `.zc` keeps a tray-item registry; port as a Nim `Table`/`seq`,
  main-thread (no worker concern).
- **No standalone router unit test** (heavy import chain) — leaves are build + runtime +
  human-smoke gated; the pure helpers (fs expansion/allowlist, menu JSON build) get unit
  tests in `native/nim/tests/`.

## Success criteria (per leaf, at its gate)

- The leaf's surface visibly works on the Nim build (e.g. `Dialog.open()` returns a path;
  `Notification.show()` posts; `Shortcuts.register()` fires; `Screen.getAll()` returns
  displays; `Menu`/`Tray`/`Dock` render + act; the embedded panel mounts; `trashItem`
  trashes an allowlisted path and refuses a non-allowlisted one).
- Build ends `[zapp] build complete:`; all Nim unit tests pass; `.m`/engines untouched;
  no `{.emit.}`; only the leaf's `.nim` + `router.nim` (+ CLI emitter for fs) staged.

## References

- Leaf `.zc`: `native/{fs,dialog,notification,shortcuts,screen,menu,tray,dock,panel}/*.zc`.
- Leaf `.m` (compiled, untouched): `native/platform/darwin/{fs,dialog,notification,
  shortcuts,screen,menu,tray,dock,panel}.m` (+ `fs.h`).
- Router reference: `native/app/router.zc` (t:1 leaf blocks ~1435-1751; t:4 leaf arms
  dock ~735, tray ~966, menu ~1072; shell-path ~576-593; `screen_route` call ~126;
  `panel_route` call ~732; `permission_id_for_*` ~30-54).
- Recipe precedents: `native/nim/clipboard.nim` (t:1 leaf), `native/nim/router.nim`
  (`routeClipboard`/`routeWindowAction`), `native/nim/permissions.nim` (config-codegen +
  allowlist), the type-modeling convention
  (`docs/superpowers/specs/2026-06-15-nim-type-modeling-convention-design.md`).
