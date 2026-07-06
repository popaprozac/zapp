# CEF sub-cycle B — multi-window (macOS) — design

**Date:** 2026-07-06
**Branch:** `feat/cef-multi-window` (off `feat/nim-native @ 1eb563f`; NO merge to `nim-native` without ask — Windows handoff target)
**Type:** Feature — build out the CEF **per-window lifecycle**: a slot↔browser registry, targeted + broadcast delivery to N windows, popup parity, and a per-window close handshake with close-guard + quit parity. Opt-in + gated. macOS-only.
**Status:** design approved; pending spec review → writing-plans → SDD

## Goal

Make **N app-created CEF windows** (`window.create` on a `webEngine:"chromium"` app) each work correctly: render, bridge, and receive events independently; targeted native→JS eval routes to the right window; broadcasts (worker events, notifications, etc.) fan to **all** CEF windows; `window.open`/`target=_blank` route to the system browser (WKWebView parity); and per-window close honors the **close guard** and the **last-window quit** rule exactly as WKWebView does. `system`/WKWebView builds stay byte-identical.

## Context — the single-window model and what's missing

The prod slice + sub-cycle A wired a **single** CEF browser:

- Two globals in `zapp_cef_client.c`: `g_active_browser` (client.c:86) and `g_zapp_cef_window_slot` (client.c:101), with `zapp_cef_set_window_slot` / `zapp_cef_get_window_slot` (client.c:103-104).
- `on_after_created` (client.c:160) sets `g_active_browser`; `zapp_cef_eval_in_window(slot, js)` (client.c:131) only works for that one global slot.
- The client is **already created per-browser** (`zapp_cef_client_create()`, host.m:272) — but `zapp_cef_create_browser_in_view` (host.m:243) stashes the slot in the global via `zapp_cef_set_window_slot(window_slot)` (host.m:256). The per-window slot is threaded to create; it just isn't kept per-window.
- Sub-cycle A's broadcast branch in `zapp_registered_webviews_eval` (window.m:154-164) delivers to the one active browser via `get_window_slot()`.

**The close path does not exist yet.** `close_browser` is called **nowhere** in `native/platform/darwin/`, and the window close/destroy handlers (`windowShouldClose:` window.m:445, `windowWillClose:` window.m:454) have **no CEF branch**. The CEF browser is never explicitly torn down on window close; it only dies at app shutdown via `cef_shutdown` → `on_before_close` (client.c:178), which calls `zapp_cef_quit_main_loop()` **unconditionally**. Single-window "works" only because `terminateAfterLastWindowClosed` quits the whole app when that one window closes.

A second `window.create` today would clobber the global slot and orphan the first browser (still registered, still receiving broadcasts, never torn down). B fixes this by building the real per-window lifecycle.

## Design

### 1. The registry — slot-indexed browser table

Replace `g_active_browser` + `g_zapp_cef_window_slot` with a slot-indexed table, the exact mirror of the WKWebView side's `zapp_webviews[]`:

```c
static cef_browser_t* zapp_cef_browsers[ZAPP_MAX_WINDOW_CALLBACKS] = {0};
```

- `zapp_cef_client_create(int32_t slot)` gains a slot argument and bakes it into the client struct (and thus its life-span + message handlers). The client is already per-browser, so this is per-window state with zero correlation race.
- `on_after_created` registers `zapp_cef_browsers[client->slot] = browser` (keeping the extra owned ref, as today).
- `on_before_close` clears `zapp_cef_browsers[client->slot] = NULL` and releases the extra ref.
- Remove/repurpose `zapp_cef_set_window_slot` / `zapp_cef_get_window_slot` and `g_active_browser`/`g_active` accessor. Provide slot-bounds-checked helpers for the eval + broadcast paths.

### 2. Targeted eval — route by slot

`zapp_cef_eval_in_window(slot, js)` looks up `zapp_cef_browsers[slot]` (bounds-checked) and evals in that browser, instead of comparing to the one global slot. `darwin_window_eval_js`'s CEF branch (window.m:650-657) already passes `window_id` as the slot, so a `Services.invoke` result routes to the window that requested it.

### 3. Broadcast — fan to all CEF windows

The `ZAPP_HAS_CEF` branch in `zapp_registered_webviews_eval` (window.m:154-164) iterates `zapp_cef_browsers[]` and evals each **live** (non-NULL) browser, instead of the single `get_window_slot()`. A worker's `Events.emit("tick")` and every native broadcast now reach every CEF window. Uses `[script UTF8String]` (block-retained), same as today.

### 4. Message tagging — per-window `window_id`

`on_process_message_received` (client.c) tags the router `window_id` from `client->slot` (the per-window slot baked into the client) instead of the global `zapp_cef_get_window_slot()`. A bridge message from window 2 is delivered to the router as window 2, so its invoke-result eval routes back to window 2 (§2).

### 5. Popup parity — `on_before_popup` → system browser

Add `on_before_popup` to the life-span handler: **cancel** the popup (return 1) and open the target URL in the system browser (`NSWorkspace openURL`), mirroring WKWebView's `createWebViewWithConfiguration` (webview.m:668-677). Without this, CEF's default spawns a raw chrome-less popup window (no Zapp bridge/allowlist) — worse than WKWebView. This is parity, not a new feature. In-app popups are a non-goal (see below).

### 6. Close handshake — close-guard + quit parity (highest-risk)

Build the per-window close path so CEF teardown routes **through** the window-close handlers, giving close-guard parity:

- **User close:** `windowShouldClose:` (window.m:445) runs its existing guard check first — it dispatches `ZAPP_EVENT_WINDOW_CLOSE`; a set close guard (`gCloseGuard[id]`) returns `ZAPP_EVENT_RESULT_CANCEL` → `NO` → nothing tears down (browser + window stay). Parity ✓. If allowed (`YES`) → a CEF branch in the close path calls `browser->host->close_browser(force)` for that window's browser → `do_close` → `on_before_close` → **deregister** `zapp_cef_browsers[slot]`.
- **`on_before_close` no longer calls `zapp_cef_quit_main_loop()`** — it only deregisters + releases. The last-window `[NSApp stop]` becomes Zapp's existing `terminateAfterLastWindowClosed` path (the same one WKWebView windows use), so quit semantics are identical across engines.
- **Programmatic close** (`Window.close()` / force-close, which clears the guard first — router.zc:658) routes through the same handshake.
- Wire a `ZAPP_HAS_CEF` branch into the appropriate window close/destroy handler (`windowWillClose:` and/or `darwin_window_destroy`) to trigger `close_browser` for the window's browser and clear its table slot, mirroring how `windowWillClose:` clears `zapp_webviews[]` today. Preserve Zapp's reversible-close contract (a hidden-then-reshown window must not leave a dead browser) — evaluate whether CEF supports reversible close or whether a CEF window's close is terminal (documented in the plan; if terminal, gate it).

**Risk:** the AppKit↔CEF close handshake (`do_close` deferral, teardown ordering, refcount-release convention) is the notoriously fiddly part of CEF-on-macOS. It gets its own human gate and may warrant a small spike if the ordering fights us.

### 7. Fixture + gates

Extend `examples/cef-hello` to open a **second** CEF window (a second `window.create`), reusing the existing `ticker` worker + `greet` service.

**Human gates (R0):**
- Both windows render on Chromium; **both** show the worker's ticking counter (broadcast fan-out, §3).
- `greet` round-trips per-window (targeted eval routes to the clicking window, §2/§4).
- **Close guard:** set a close guard on a CEF window → clicking close is vetoed and JS receives the `window:close` event → force-close then actually closes it (§6).
- Closing a **non-last** window leaves the other(s) alive and still ticking; closing the **last** window quits (`terminateAfterLastWindowClosed`).
- A `target=_blank` / `window.open` link opens in the **system browser** (§5).

## Components / files

- `native/platform/darwin/cef/zapp_cef_client.c` — the `zapp_cef_browsers[]` table; `zapp_cef_client_create(slot)` + per-client slot; `on_after_created` / `do_close` / `on_before_close` (deregister, no quit); new `on_before_popup`; message tagging from `client->slot`. Remove the two globals.
- `native/platform/darwin/cef/zapp_cef_host.m` — `zapp_cef_create_browser_in_view` passes `window_slot` to `zapp_cef_client_create(slot)`; drop `zapp_cef_set_window_slot`.
- `native/platform/darwin/cef/zapp_cef.h` — updated decls (`zapp_cef_client_create(int32_t)`, table accessors for eval/broadcast; remove `get/set_window_slot`).
- `native/platform/darwin/window.m` — broadcast branch (window.m:154-164) iterates the table; new `ZAPP_HAS_CEF` branch in the close/destroy path to call `close_browser` + clear the slot; targeted branch (650-657) unchanged.
- `examples/cef-hello/` — second window + the close-guard / multi-window gate wiring.
- `spikes/cef-macos/FINDINGS.md` — mark multi-window closed + which coupled Minors cleared (the `on_before_close`→`[NSApp stop]` quit-guard).

## Testing

- **Human R0:** the §7 gate list (two-window render + broadcast fan-out, per-window targeted greet, close-guard veto + force-close, non-last vs last close, popup→system browser).
- **Byte-identical:** a `webEngine:"system"` build is unaffected — all `cef/*` TUs compile only under `ZAPP_HAS_CEF`, and the `window.m` CEF branches are `#ifdef`-gated; `clang -E`/`unifdef -UZAPP_HAS_CEF` on `window.m` shows the CEF-specific lines are the only delta.
- **Build regression:** chromium build green; single-window `cef-hello` (before the 2nd window) still renders + bridges + ticks.
- **CLI gate:** canonical `bun run check` + `bun run test` unchanged (no CLI logic change; fixture config is data). NOT per-example `bunx tsc` (pre-existingly fails on runtime enums — see `reference_example_app_tsc_gate`).

## Error handling

- **Slot bounds:** every table access bounds-checks `slot` (`< 0 || >= ZAPP_MAX_WINDOW_CALLBACKS` → no-op), mirroring `zapp_webview_for_slot`.
- **Broadcast:** NULL-guard each table entry before eval (windows come and go).
- **Refcount discipline:** `close_browser` + `do_close`/`on_before_close` follow the CEF C-API owned-ref convention exactly (each callback gets a fresh owned ref to release; the extra `on_after_created` ref released once on deregister). This is the main correctness hazard — verified per the refcount comments already in `zapp_cef_client.c`.
- **Popup:** NULL-guard the target URL before `openURL`.
- **Close guard veto:** because the veto happens at `windowShouldClose:` before any `close_browser`, a vetoed close leaves the browser fully intact — no half-torn-down state.

## Non-goals (deferred to their cycles)

- **In-app popups** — `window.open`/`target=_blank` route to the system browser (§5), never spawn an in-app CEF window (would diverge from WKWebView). The "in-app OAuth feel" future is a wrapped **`ASWebAuthenticationSession`** primitive (Safari-backed, SSO-sharing, app-isolated, auto callback capture) — not raw popups. Not part of B.
- **Mixed-engine / per-window engine** — `webEngine` resolves app-wide per platform; a chromium app's windows are all CEF.
- **Native-chrome CEF windows** (sidebar / inspector / toolbar on a CEF window) — sub-cycle **C**. B covers plain (fullbleed) CEF windows only, same as the prod slice.
- **DevTools / navigation** — sub-cycle **D**. **Helper signing / notarization** — sub-cycle **E**.

## Scope

Build the CEF per-window lifecycle: registry + targeted/broadcast delivery + message tagging (`client.c`, `host.m`, `zapp_cef.h`, `window.m` broadcast branch) + the close handshake with close-guard/quit parity (`client.c` handlers + `window.m` close branch) + popup parity (`on_before_popup`) + a two-window fixture + FINDINGS. Likely **~4 tasks**: (1) registry + per-window client slot + targeted eval + broadcast fan-out; (2) close handshake + close-guard parity + last-window quit; (3) popup parity; (4) fixture second window + gates + docs. Task 2 is the highest-risk and may spike the AppKit↔CEF close ordering first.
