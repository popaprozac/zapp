# CEF sub-cycle D — DevTools on CEF windows (macOS) — design

**Date:** 2026-07-08
**Branch:** `feat/cef-devtools` (off `feat/nim-native @ f190d8e`; NO merge to `nim-native` without ask)
**Type:** Feature — open Chromium DevTools to inspect a CEF webview (html/css/console/network). Opt-in path is CEF; dev-gated. macOS-only.
**Status:** design approved (API + Cmd-Opt-I, devtools-only); pending spec review → writing-plans → SDD

## Goal

Let a developer open **Chromium DevTools** for a CEF (`webEngine:"chromium"`) webview — parity with the WKWebView web inspector that `kitchen-sink`/`cef-hello` already get from `inspectable: Inspectable.Auto` (via macOS's system Develop menu / right-click Inspect). This is the debugging tool for the three kitchen-sink-on-CEF breakages (popover, contextmenu, embedded-webview) and for CEF app development generally. Dev-gated (only when `inspectable`), like the WK inspector.

## Context

- **CEF C-API** (`cef_browser_host_t`, confirmed in `spikes/cef-macos/cef_binary/include/capi/cef_browser_capi.h`): `show_dev_tools(windowInfo, client, settings, inspect_element_at)`, `close_dev_tools()`, `has_dev_tools()`. Passing a standalone `window_info` (+ NULL client/settings/point) opens DevTools in its **own window** with default handling.
- **WK today:** `inspectable` (per-window, from `Inspectable.Auto` = on-in-dev, off-in-prod; `app_get_bootstrap_web_content_inspectable()`) gates `setInspectable:` on the WKWebView; the inspector is reached via macOS's **system** Develop menu / right-click "Inspect Element" — there is no public Zapp/Apple *API* to open it programmatically.
- **The gap on CEF is purely the trigger.** CEF has no system Develop-menu integration, and its right-click "Inspect" rides the context menu — which the kitchen-sink catalog found **broken**. So CEF needs an explicit Zapp trigger to call `show_dev_tools`.
- **CEF client** already exposes `get_life_span_handler`; it also exposes **`get_keyboard_handler`** (`cef_client_capi.h:165`) + `cef_keyboard_handler_capi.h` — the clean path for the Cmd-Opt-I shortcut.

## Design

### 1. Native CEF show/close (gated)

In `native/platform/darwin/cef/zapp_cef_host.m`, mirroring the existing `zapp_cef_window_for_slot`/`_teardown_*` refcount idiom (borrowed browser, owned host released once):
- `void zapp_cef_show_dev_tools(int32_t slot)` → `zapp_cef_browser_for_slot(slot)` → `get_host` → `show_dev_tools(host, <standalone window_info>, NULL, NULL, NULL)` → release host. The `window_info` opens DevTools as its own top-level window (mirror the standalone-window setup already used by `zapp_cef_make_host_window`, minus SetAsChild).
- `void zapp_cef_close_dev_tools(int32_t slot)` → `get_host` → `close_dev_tools` → release host.
- Declared in `zapp_cef.h`.

### 2. Router entry (engine-aware, dev-gated)

`darwin_devtools_open(int32_t slot)` / `darwin_devtools_close(int32_t slot)` (a new `native/platform/darwin/devtools.m`, or folded into an existing router-surface file):
- **Dev gate:** if `!app_get_bootstrap_web_content_inspectable()` → no-op (parity with WK — no inspector in prod).
- **CEF slot** (`zapp_cef_browser_for_slot(slot)` non-NULL under `#ifdef ZAPP_HAS_CEF`) → `zapp_cef_show_dev_tools(slot)` / `close`.
- **WK slot** → no-op + a one-line stderr hint ("DevTools on WKWebView: use the system Develop menu / right-click Inspect"). No private-API attempt.
- Wired to router actions `devtools:open` / `devtools:close` (the shared router's action table, alongside `sidebar:toggle` etc.).

### 3. Runtime API

`Window.current().openDevTools()` / `closeDevTools()` in `runtime/window.ts` (on the `WindowHandle`, mirroring the sidebar/inspector handle methods): `windowAction("devtools:open"/"devtools:close", { windowId })`. Available on all windows; on WK it reaches the no-op path (documented), on CEF it opens DevTools.

### 4. Cmd-Opt-I keyboard shortcut (CEF, dev-gated)

Add a `cef_keyboard_handler_t` to the CEF client (`zapp_cef_client.c`, via `get_keyboard_handler`, same pattern as `get_life_span_handler`). Its `on_key_event` catches **Cmd-Opt-I** (macOS: `command` + `alt` modifiers + the `I` key) on the focused CEF browser and calls `zapp_cef_show_dev_tools(this browser's slot)` (dev-gated). Because the handler fires on the focused browser, it naturally targets the pane the developer is looking at — no app-menu dependency. (Alternative considered: a native menu item with the key-equivalent; the keyboard handler was chosen for its focused-browser targeting and CEF-scoping.)

### 5. Fixture + gate

`examples/cef-hello/` gets an **"Open DevTools"** button (→ `Window.current().openDevTools()`) in the host pane, and a note that `Cmd-Opt-I` works too. (`cef-hello` is built with `inspectable: Inspectable.Auto`, so dev-gated is satisfied in a dev build.)

## Testing (human R0 gates)

- **API:** click "Open DevTools" in window 1's host pane → a **Chromium DevTools window opens**, showing that pane's live html/css/console/network. `closeDevTools()` (or the DevTools window's own close) closes it.
- **Shortcut:** with the CEF page focused, `Cmd-Opt-I` opens DevTools for the focused pane (open the sidebar pane's DevTools by focusing it → confirms per-focused-browser targeting).
- **Dev gate:** (spot-check) in a prod-style build (`inspectable` off) the API + shortcut no-op.
- **WK unaffected:** a `webEngine:"system"` build is byte-identical for the CEF parts (all CEF code `#ifdef`-gated); the WK path of `darwin_devtools_open` no-ops cleanly. `Window.current().openDevTools()` on WK doesn't crash.

## Error handling

- Slot with no CEF browser / no host → the helpers no-op (NULL guards, like the other `*_for_slot` helpers).
- Dev gate short-circuits before any native call in prod.
- Double-open: CEF's `show_dev_tools` re-focuses an existing DevTools window (or use `has_dev_tools` to toggle — a small nicety, optional).

## Non-goals

- **WK programmatic DevTools open** — no clean public API; WK keeps the system Develop-menu / right-click inspector. The API/shortcut no-op on WK.
- **Navigation** (back/forward/reload for CEF) — separate cycle (was bundled as "D devtools/nav"; split out per the scope decision).
- **Docked/embedded DevTools** — own-window this cycle (SetAsChild-docked DevTools is a later refinement).
- Fixing popover/contextmenu/embedded-webview — those are their own cycles; DevTools is the *tool* for them.

## Scope

`zapp_cef_host.m` + `zapp_cef.h` (show/close) + `zapp_cef_client.c` (keyboard handler) + a router-surface file (`darwin_devtools_open/close` + action wiring) + `runtime/window.ts` (the API) + `cef-hello` fixture + FINDINGS/SMOKE. Likely **~3 tasks**: (1) native CEF show/close + router entry + the `devtools:open/close` actions + the runtime API; (2) the Cmd-Opt-I `CefKeyboardHandler`; (3) fixture + docs. All CEF-native code `#ifdef ZAPP_HAS_CEF`-gated → `system` build byte-identical.
