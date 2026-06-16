# Nim Migration — Phase 2 Breadth, Batch 5b: t:4 Window/App Action Surface — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration breadth phase; applies the type-modeling convention.
B1-B5a done. **This is Batch 5b** — the second router slice: the t:4 action arms whose
targets are already compiled.

## Goal

Fill `routeWindowAction`'s B5b seam (`native/nim/router.nim`) with the t:4 **window ops**,
**app ops**, and **openExternal** action arms — the body of `router_handle_window_action`
(`router.zc:535-729`) for the arms whose `darwin_*` targets are in the compiled `.m` —
making the demo's `Window.*` / `App.quit`/`activate` / "open external URL" controls work on
the Nim build. B5a already put the permission gate + subscribe/unsubscribe/ready at the head;
this adds the dispatch arms below the seam.

## Scope refinement (from the exploration)

Two arm groups I'd originally lumped into B5b depend on not-yet-ported `.zc` and move to **B6**:
- **Shell path ops** (openPath/showItemInFolder/trashItem) — the `darwin_*` are compiled, but
  they call `fs_expand_path` + `fs_is_allowed` (`fs.zc`, not ported; trashItem is FS-allowlist-
  gated). → **B6 (with fs.zc).**
- **Panel ops** — delegate to `panel_route` (`panel.zc`, not ported). → **B6 (panel leaf).**

So **B5b = window ops + app ops + openExternal** (all targets compiled).

## Scope

**In** (all added to `routeWindowAction` below the B5a seam, each ungated unless noted):

- **Window ops.** Resolve the handle once: `darwin_window_get_by_numeric_id(windowId.int32) ->
  void*`; if nil (window gone), return. Then dispatch (window.h signatures):
  - handle-based: `show`→`darwin_window_show(h)`; `hide`→`darwin_window_hide(h)`;
    `minimize`→`darwin_window_minimize(h)`; `maximize`→`darwin_window_maximize(h)`;
    `setFocus`→`darwin_window_focus(h)`; `close`→`darwin_window_force_close(h)`;
    `setTitle`→`darwin_window_set_title(h, title)`; `setSize`→`darwin_window_set_size(h, w, h2)`;
    `setPosition`→`darwin_window_set_position(h, x, y)`;
    `setFullscreen`→`darwin_window_set_fullscreen(h, on)`;
    `setAlwaysOnTop`→`darwin_window_set_always_on_top(h, on)`.
  - id-based (NO handle needed): `loadUrl`→`darwin_window_load_url(windowId.int32, url)`;
    `setDragRegion`→`darwin_webview_set_drag_region(windowId.int32, drag)`;
    `setCloseGuard`→`zapp_window_set_close_guard(windowId, on)` (already exportc in
    callbacks.nim — call it).
  - Arg keys (confirm against `router.zc:535-768` during planning): `setTitle`→`title`;
    `setSize`→`width`/`height`; `setPosition`→`x`/`y`; `setFullscreen`/`setAlwaysOnTop`→`on`;
    `loadUrl`→`url`; `setDragRegion`→`drag`; `setCloseGuard`→`on`. Missing/typed-wrong args
    no-op (match the zc's `is_some()` guards — only dispatch when the arg parses).
- **App ops** (platform.m): `quit`→`darwin_app_quit(force)` (arg `force`, default false);
  `activate`→`darwin_app_activate()`; `setQuitGuard`→`darwin_set_quit_guard(on)` (arg
  `enabled`). All ungated (`permission_id_for_action` returns `""`).
- **openExternal** (`shell:open`-gated — the gate already runs at the head): `darwin_open_external(url)`
  (arg `url`). webview.h.

**Out (deferred):**
- **Shell path ops** (openPath/showItemInFolder/trashItem) → **B6** (need fs.zc:
  `fs_expand_path` + `fs_is_allowed`).
- **Panel ops** → **B6** (need `panel_route` from panel.zc).
- **attachModal/detachModal** → confirm in planning; they use the zc `App.window` registry's
  `attach_modal`/`detach_modal` (a Window method that wraps darwin calls). If a simple
  `darwin_window_attach_modal(parent, modal)`-style target exists in compiled window.m, include
  it; otherwise **defer to B8** (sheet attachment is a less-common control). The plan decides
  after reading window.m.
- **dock/sidebar/inspector/popover/toolbar** t:4 → **B8**.
- **Accessory-pane sender-slot/host resolution** (`router.zc:500-534`) → **B8**. The Nim build
  has no sidebar/inspector panes yet, so the sending `windowId` IS the target host; B5b uses
  `windowId` directly. (When B8 adds accessory panes, the host-resolution lands with them.)

## Architecture / convention

- All arms live in `routeWindowAction` (`native/nim/router.nim`), below the B5a gate +
  subscribe/unsubscribe/ready, as a `case action` / `if` chain mirroring `router.zc`'s order.
  The `darwin_*` targets are `importc`'d at the top of router.nim (alongside the B5a
  `darwin_set_login_item` etc.).
- `routeWindowAction` runs on the main thread (webview→native) — Nim-string arg extraction
  (`a{"title"}.getStr`) is fine.
- No `{.emit.}`; `.m`/engines untouched. No new enums needed (these are action-name strings +
  darwin calls). Idiomatic Nim `case`/`if` dispatch.

## Success criteria (the gate)

- The demo's window controls visibly act on the Nim build: `Window.minimize()`,
  `Window.setTitle(s)`, `Window.setSize(w,h)`, `Window.setPosition(x,y)`,
  `Window.setFullscreen(true/false)`, `Window.setAlwaysOnTop(true)`, `Window.hide()/show()`,
  `Window.close()`, `Window.loadUrl(url)`.
- `App.quit()` quits; `App.activate()` brings the app forward; `App.setQuitGuard(true)` is wired.
- An "open external URL" action opens the system browser.
- Build ends `[zapp] build complete:`; all Nim unit tests pass; `.m`/engines untouched; no `{.emit.}`.

## Risks (into the plan)

- **Arg keys:** confirm each arm's payload key against `router.zc:535-768` (the plan supplies
  best-guess defaults — `width`/`height`/`x`/`y`/`on`/`title`/`url`/`drag`/`force`/`enabled` —
  but the zc is the source of truth; a wrong key silently no-ops).
- **`window_*` vs `darwin_window_*`:** the zc calls `window_show(win.handle)` etc.; these resolve
  to the compiled `darwin_window_*` (window.h). The Nim port calls `darwin_window_*` directly
  via the `darwin_window_get_by_numeric_id` handle.
- **nil handle:** `darwin_window_get_by_numeric_id` returns nil if the window is gone — guard
  (return) before the handle-based calls. The id-based calls (loadUrl/dragRegion/closeGuard)
  take the id and self-guard in the `.m`.
- **attachModal target:** decide include-or-defer in the plan after reading window.m for a
  compiled `darwin_*` modal-attach target.
- **No standalone router unit test** (heavy import chain) — the arms are build + runtime-gated,
  consistent with B5a T2/T3.

## References

- `native/app/router.zc:535-729` (the window-op + openExternal arms), `:734-768` (dock/sidebar
  — B8, for the dispatch-order reference only).
- `native/platform/darwin/window.h:47-58,97` (window-op + handle-by-id sigs),
  `webview.h:58,61` (openExternal, drag region), `platform.m:46,50,55` (quit-guard, quit,
  activate).
- `native/nim/router.nim:routeWindowAction` (the B5a seam to fill), `native/nim/callbacks.nim`
  (`zapp_window_set_close_guard` exportc).
