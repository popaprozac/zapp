# Security model

## Trust boundaries

Zapp has three trust zones:

1. **Your native code (Zen-C / ObjC / C)** — fully privileged.
2. **Your app's JS** (the main webview, sidebar webviews, + workers, loaded from `zapp://` or
   your dev server) — trusted by default. It talks to native over the
   bridge; the `security.permissions` manifest (below) lets you narrow what it can
   reach.
3. **External web content** — untrusted. Put it in an embedded webview
   (`<zapp-webview>`): embeds get **no bridge** — no `Services`, no FS, no
   native APIs; host↔embed communication is only
   `postMessage`/`execJS` ↔ `window.zappHost.postMessage`. **Never load
   third-party content into the main webview.**

Additional standing boundaries:
- **Navigation allowlist** — top-level navigation in the main webview is
  default-deny (built-in schemes + dev localhost only); allow specific
  origins natively via the security manager. `target="_blank"` opens in the
  system browser, never in-app.
- **FS path allowlist** — `security.filesystem.allow` in zapp.config.ts; every FS call is
  prefix-checked natively before the syscall (plus session grants from
  user-picked dialog paths). Composes with the `fs` permission below.
  (Note: the `fs` permission gates the framework FS API. The `bare-fs`
  worker module — `@zappdev/runtime/bare/fs` — is governed by the path
  allowlist only, not the `fs` permission.)
- DevTools are disabled in production builds.

## Permissions manifest

Declare which built-in native capabilities your app may use:

```ts
// zapp.config.ts
security: {
  permissions: ["clipboard:read", "fs", "dialog", "notifications", "window:create"],
},
```

- **Absent** → everything allowed (legacy behavior).
- **Present** → exhaustive: anything not listed is **denied, enforced
  natively** (webview AND workers). A bare module name grants all its
  verbs (`"clipboard"` ⊇ `clipboard:read` + `clipboard:write`).
- Unknown ids fail the build (typed `ZappPermission` union gives editor
  autocomplete).

| Permission | Verbs | Covers |
|---|---|---|
| `clipboard` | `:read`, `:write` | Clipboard reads / writes+clear |
| `fs` | `:read`, `:write` | FS API (additionally path-allowlisted) |
| `dialog` | — | file open/save + message dialogs |
| `notifications` | — | show/schedule/categories |
| `shortcuts` | — | global hotkeys |
| `tray` | — | status items |
| `dock` | — | badge/bounce/icon |
| `menu` | — | app menu + context menus |
| `screen` | — | display enumeration / cursor |
| `embed` | — | `<zapp-webview>` panels |
| `window:create` | — | creating new windows (ops on existing windows are never gated) |
| `shell` | `:open`, `:reveal`, `:trash` | openExternal/openPath · showItemInFolder · trashItem |

Not gated in v1 (by design): window ops on existing windows (including sidebar toggle/resize), app lifecycle,
`Events`, `Sync`, user `Services` (you wrote both sides; per-service gating
arrives with per-context grants in v2), `webview.protocols`/
`application.deepLinks`
(their config declaration is the grant).

## Denied calls

- Invoke-style APIs (Clipboard, Dialog, Notification, Shortcuts, Screen,
  `Window.create`) **reject** with an error where
  `error.code === "PERMISSION_DENIED"` and `error.permission` names the id.
- Fire-and-forget APIs (Tray, Dock, Menu, ContextMenu, shell helpers,
  `Webview.create`) **throw `PermissionDeniedError` synchronously** in the
  webview; in workers the native layer logs
  `[zapp] permission denied: <id> (<method>)` (once per id) and drops the call.

The Z-native path compiles the resolved manifest into immutable application
policy. Its focused frontend `createWindow()` performs the mirrored JavaScript
check for an immediate, descriptive `PermissionDeniedError`, while the Z
router independently enforces `window:create`. Sending `__window:create`
directly cannot bypass that native check. Native failures cross the WebView
boundary as a structured `{ code, message, permission }` envelope and are
reconstructed as `ZappError` subclasses when the runtime is loaded.

Errors live at the broadest package boundary that can produce them:

```ts
import {
  PermissionDeniedError,
  ZappError,
  ZappInvocationError,
} from "@zappdev/runtime";
import { WindowError } from "@zappdev/runtime/window";
```

`PermissionDeniedError` is runtime-wide because any capability can be denied.
Feature entry points own their narrower failures; for example, a native window
failure becomes `WindowError` with `operation` metadata such as `"create"`.
Unknown or service-generic native failures remain `ZappInvocationError` and
always retain their stable `code` for programmatic handling.

## Detection

```ts
import { Permissions } from "@zappdev/runtime";
await Permissions.query("tray");   // "granted" | "denied" | "unsupported"
await Permissions.list();          // the active allowlist
```

`"unsupported"` answers the *platform* axis (e.g. `tray` on iOS) before the
manifest is consulted — unsupported APIs still silently no-op when called
(v1 keeps legacy call behavior); `query()` is how you detect them.

## Roadmap (v2)

Per-context grants (per window / per worker / per panel), per-service
gating (`service:<name>`), runtime permission prompts.
