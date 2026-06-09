# Permissions System (v1) — Design

**Date:** 2026-06-09
**Status:** Approved (brainstorm) → ready for implementation plan
**Branch:** `feat/permissions-system`

## Context

Zapp's trust model today: the app's own JS (webview + workers) is fully trusted —
any context with a bridge can invoke any built-in native capability. The only
existing gates are special-purpose: the **fs path allowlist** (`native/fs/fs.zc`,
enforced native-side before every syscall), the **navigation allowlist**
(default-deny, `darwin/webview.m:547`), and **panel sandboxing** (`<zapp-webview>`
embeds get no bridge at all). The 2026-06-09 security audit confirmed those
boundaries are sound and found no escalation path — but there is no way for an
app to *narrow* what its own web layer can do.

Competitors make this a headline feature: Tauri v1's allowlist / v2's
capabilities, zero-native's `app.zon` manifest. Zapp's positioning ("Security"
feature bullet) should be backed by a real, declarative allow/deny mechanism.

This cycle adds **v1: an app-global permissions manifest** in `zapp.config.ts`,
enforced natively at the dispatch choke points, plus a **`Permissions.query()`**
runtime API that also answers platform support (the capability-detection gap:
iOS no-op stubs are currently indistinguishable from success).

## Decisions (locked in brainstorm)

1. **Granularity: app-global.** One manifest for the whole app. Per-context
   (per-window / per-worker / per-panel) grants are the planned v2; the config
   shape is chosen so v2 extends rather than breaks it.
2. **Default: presence-activated.** No `permissions` field → everything allowed
   (today's behavior; zero breakage). Field present → it is exhaustive: anything
   not listed is denied.
3. **Taxonomy: module + optional verb.** Ids like `"clipboard"`, `"fs:read"`.
   A bare module name grants all of its verbs (`"clipboard"` ⊇ `clipboard:read`
   + `clipboard:write`). New verbs can be added later without breaking bare grants.
4. **Surface: built-ins only.** User-defined services stay ungated in v1 (the
   app wrote both the service and the caller; gating them pays off only with
   per-context grants). `protocols` / `deepLinkSchemes` are already declared in
   config — that declaration *is* their grant; no double-gating.

**Refinement since the brainstorm summary (flagged for review):** the presented
catalog had `open-external`. This spec generalizes it to **`shell`** with verbs,
because `openPath` / `showItemInFolder` / `trashItem` are the same "hand
something to the OS shell" risk class as `openExternal` and shouldn't be left
ungated: `shell:open` (openExternal + openPath), `shell:reveal`
(showItemInFolder), `shell:trash` (trashItem). Bare `shell` grants all three.

## Config surface (CLI)

```ts
// zapp.config.ts
const config: ZappConfig = {
  // ...
  // Absent → allow-all (unchanged). Present → exhaustive allowlist.
  permissions: [
    "clipboard:read",
    "fs:read",
    "dialog",
    "notifications",
    "window:create",
  ],
};
```

- New exported union type `ZappPermission` in `cli/src/config.ts` — editors
  autocomplete ids and typos are **type errors** at config time.
- CLI validation (same place `validateNative` lives): unknown id, duplicate id,
  or a verb id alongside its bare module (redundant; warn, not error) — unknown
  ids are a **build error** with a did-you-mean suggestion.
- `resolvePermissions(config)` (bun-tested, pure): normalizes to a flat string
  set + an `active: boolean` flag (false when the field is absent).

## Permission catalog (v1)

| Permission id | Verbs | Gates (dispatch surface) |
|---|---|---|
| `clipboard` | `:read`, `:write` | `__clipboard:*` invoke methods (read* → `:read`; write*/clear → `:write`) |
| `fs` | `:read`, `:write` | `fs_*` entry points in `native/fs/fs.zc` (read/list/stat/exists → `:read`; write/mkdir/remove/rename/copy → `:write`). **Composes with** the existing path allowlist — both must pass. |
| `dialog` | — | `__dialog:*` (openFile / saveFile / message) |
| `notifications` | — | `__notif:*` (show / schedule / categories / permission) |
| `shortcuts` | — | `__shortcuts:*` (register / unregister / isRegistered) |
| `tray` | — | t:4 actions `tray:*` |
| `dock` | — | t:4 actions `dock:*` + dock badge/bounce/icon ops |
| `menu` | — | all menu-mutation router actions (app menu set, context-menu show; exact action-name list enumerated in the plan from `router.zc`) |
| `screen` | — | `__screen:*` (getAll / getPrimary / getById / getCursorPoint) |
| `embed` | — | all `panel*` actions routed via `panel_route` (`<zapp-webview>` create/control) |
| `window:create` | (verb-only id) | `__window:create`. Other window ops on existing windows stay ungated (core surface; the main window must always work). |
| `shell` | `:open`, `:reveal`, `:trash` | t:4 `openExternal` + `openPath` → `:open`; `showItemInFolder` → `:reveal`; `trashItem` → `:trash` |

**Never gated (v1):** window ops on existing windows (show/hide/resize/title/
fullscreen/close/modal/loadUrl/drag regions/subscribe), app lifecycle
(quit/activate/quit-guard/theme/power/getConfig), `Events`, `Sync`, `Services`
(user services), `Workers` creation, protocols/deep links (config-declared).

## Enforcement (native, authoritative)

The pattern is the same build-time codegen → parse-once → check-per-dispatch
chain the fs allowlist and navigation allowlist already use:

1. **Codegen:** CLI emits `zapp_build_permissions_json()` (build-config.ts,
   next to `zapp_build_fs_allowlist_json`) — `{"active":bool,"allow":["..."]}`.
2. **`native/app/permissions.zc` (new):**
   - `permissions_init()` — parse once at startup (heap-safe `zapp_json_parse`)
     into a flat set; `active=false` short-circuits everything to allowed.
   - `permissions_is_allowed(id: string) -> bool` — verb semantics: exact match
     OR bare-module match (`"clipboard:read"` passes if set contains
     `"clipboard:read"` or `"clipboard"`).
   - `permissions_check(id, method) -> bool` — wrapper that logs
     `[zapp] permission denied: <id> (<method>)` once per id (anti-spam) and
     returns the verdict.
3. **Router checkpoint (`native/app/router.zc`):** a single mapping function
   `permission_id_for(method/action) -> string?` consulted at the top of the
   two dispatch paths (t:1 invoke prefixes; t:4 window-action names). Unmapped
   methods (services, window ops, plumbing) → no check.
   - **Denied t:1 invoke** → respond on the existing reply channel with
     `{ error: { code: "PERMISSION_DENIED", permission: "<id>" } }` so the JS
     promise rejects.
   - **Denied t:4 fire-and-forget** → log + drop (no reply channel exists; the
     runtime mirror below gives the developer-visible error).
4. **fs:** the check lives inside `fs.zc` next to `fs_is_allowed` (those entry
   points are reachable from services and worker host objects, not only the
   router — gating at the entry point covers every caller).
5. **Workers:** zjs / bare host-object dispatch for the gated namespaces calls
   the same `permissions_is_allowed()` — app-global means no context identity
   is needed (that's what keeps this cycle small).
6. **Panels:** nothing to do — embeds have no bridge (audit-verified).

## Runtime mirror + capability detection

The manifest rides the existing bootstrap config (same carrier as window id /
config) so the runtime can fail fast and friendly; **native remains the
authority** — a handcrafted bridge message still hits the router gate.

```ts
import { Permissions, PermissionDeniedError } from "@zappdev/runtime";

await Permissions.query("clipboard:write");
// → "granted" | "denied" | "unsupported"
Permissions.list(); // → string[] (the active allowlist; [] + active:false when manifest absent)
```

- **`"unsupported"`** answers the platform axis: a small static per-platform
  support table in the runtime (platform id already in bootstrap config) marks
  e.g. `tray`/`shortcuts`/`menu`/`dock` (minus badge) as unsupported on iOS.
  `query` returns `"unsupported"` **before** consulting the manifest. Call
  behavior of unsupported APIs does NOT change in v1 (still silent no-op — no
  breakage); the table finally makes it detectable. Table is bun-tested and
  documented; the native parity audit keeps it honest.
- **Denied behavior in the runtime:** gated fire-and-forget calls (`Tray.create`,
  `Dock.*`, `Window.create`, `Webview.create`, `App.openExternal`, menu set)
  check the mirrored manifest and **throw `PermissionDeniedError` synchronously**
  (carries `.permission`); invoke-style calls reject async with the same error
  type built from the native `PERMISSION_DENIED` response. Workers get the same
  mirror via their bootstrap.

## Docs

- **New `docs/security.md`:** the trust model (main webview + workers trusted;
  panels sandboxed; "untrusted content goes in `<zapp-webview>`, never the main
  webview"), the permissions manifest (catalog table), fs path allowlist,
  navigation allowlist, what is intentionally not gated in v1, v2 roadmap.
- `docs/api-reference.md`: new `Permissions` section + a permission column note
  in each gated module's section.
- README: Security bullet gains "declarative permissions manifest
  (`permissions` in zapp.config.ts)"; link `docs/security.md` from docs index.
- hello-world: add a `permissions` block listing what the demo actually uses —
  it doubles as the smoke vehicle.

## Verification

- **bun tests:** `resolvePermissions` + validation (unknown id error,
  redundancy warning), verb-semantics unit (`"clipboard"` grants
  `clipboard:read`), support-table lookup, `Permissions.query` tri-state.
- **native test:** `permissions.zc` parser + `permissions_is_allowed` verb
  semantics (`native/tests/`, runs under `bun run test:native`).
- **Smoke (manual + headless):** hello-world with a restrictive manifest —
  denied `Clipboard.readText()` rejects with `PERMISSION_DENIED`; denied
  `Tray.create` throws synchronously; granted calls work; **no-manifest app
  behaves exactly as today** (regression guard). Worker path: a zjs worker
  calling a denied namespace is refused.
- Gates: `bun run test:all` (tests + native + tsc), macOS + ios-sim builds
  ending `[zapp] build complete:`, #281 parity lint (new `.zc` references need
  iOS-visible symbols — `permissions.zc` is platform-neutral, no `darwin_*`).

## Non-goals (v1) / v2 roadmap

- **Per-context grants** — v2: `permissions` accepts an object form
  (`{ app: [...], "worker:<name>": [...], window: [...] }`); the v1 string-array
  stays valid as the app-global shorthand. Requires context identity on every
  dispatch path.
- **Per-service gating** (`service:<name>` ids) — lands with per-context.
- **Runtime permission prompts** (ask-the-user) — explicitly out; this is a
  developer-declared manifest, not a consent UI.
- **Changing unsupported-platform call behavior** (e.g. making `Tray.create`
  throw on iOS) — detection only in v1.
- Windows enforcement beyond what its partial router already dispatches (the
  gate sits in shared `.zc`, so Windows inherits it as its surfaces land).

## File inventory

| File | Change |
|---|---|
| `cli/src/config.ts` | `ZappPermission` union + `permissions?: ZappPermission[]` on `ZappConfig` |
| `cli/src/permissions.ts` (new) | catalog, `resolvePermissions`, validation (bun-tested) |
| `cli/src/build-config.ts` | emit `zapp_build_permissions_json()` |
| `native/app/permissions.zc` (new) | parse + `permissions_is_allowed` / `permissions_check` |
| `native/app/router.zc` | `permission_id_for` mapping + checkpoint at both dispatch paths + denied invoke reply |
| `native/fs/fs.zc` | `fs:read` / `fs:write` check beside `fs_is_allowed` |
| worker engine bridges (zjs.c / bare.c host objects) | consult `permissions_is_allowed` on gated namespaces |
| `runtime/permissions.ts` (new) | `Permissions.query/list`, `PermissionDeniedError`, support table |
| runtime gated modules | synchronous mirror checks on fire-and-forget calls; map native `PERMISSION_DENIED` |
| `bootstrap/*` | carry manifest + platform id (extends existing bootstrap config) |
| `docs/security.md` (new), `docs/api-reference.md`, `README.md`, `docs/README.md` | docs per above |
| `hello-world/zapp.config.ts` | demo `permissions` block (smoke vehicle). **Caution:** this file carries uncommitted user WIP — the block is added in place but left for the user to commit with their WIP (never staged by the implementer); the automated smoke uses cp-backup/restore if a more restrictive temporary manifest is needed. |
