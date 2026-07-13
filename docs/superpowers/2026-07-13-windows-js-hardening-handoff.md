# Windows handoff — safe native→JS transport (review finding #2)

**Date:** 2026-07-13 · **Branch merged to `main`:** `feat/safe-js-transport` · **Owner of this follow-up:** Windows team

This is the Windows-side handoff for the P0 injection fix (external event data becoming executable JavaScript). The cross-platform + macOS/worker sides are **done and merged**; two Windows items remain that the Windows team owns because they involve the Windows platform build (`windows/*.c`) which does not compile on macOS.

## What landed (all platforms)

- **One safe encoder:** `native/shared/jslit.c` — `char* zapp_js_lit_dup(const char* utf8)` returns a malloc'd **complete double-quoted JS/JSON string literal** (JSON escaping + `U+2028`/`U+2029`; caller `free()`s; NULL only on malloc failure). Dependency-free C, already compiled into every platform's link. Declared in `native/shared/jslit.h`.
- **All migrated to it:** the 7 Nim call sites (`jsLit` wrapper), `zjs.c` (worker-crash payload), and the 5 Windows files below. **`zapp_escape_dup` is deleted** (it escaped only `\ ' \n \r` — missed `"`, `U+2028`, `U+2029`).
- **Guards:** an adversarial `bun:ffi` test (`cli/src/jslit-transport.test.ts`, 17 cases, evals real IIFEs vs a stub bridge — ASan/mutation-verified) and a Nim lint (`cli/src/js-transport-lint.test.ts`) that fails on any re-introduced raw `_onEvent`/etc. interpolation.

## ⚠️ Item 1 — compile-verify the 5 migrated Windows files [REQUIRED]

These were migrated onto `zapp_js_lit_dup` and reviewed by reading (pattern + `grep`-zero + free-audit), but **could not be compiled on macOS** — the Windows build is their real gate:

- `native/platform/windows/deeplink.c` (deep-link URL — two-layer: url JSON-encoded into `{"url":…}`, that payload JS-encoded, shared by the app-event + `_onEvent` layers)
- `native/platform/windows/filedrop.c` (dropped file paths)
- `native/platform/windows/notification.c` (notification text; note the empty-guard uses `user_text[0]`, not the encoded result)
- `native/platform/windows/panel.c` (`panel_emit` now `zapp_js_lit_dup`s the payload)
- `native/platform/windows/sidebar.c`

**Action:** build Windows, run the WebView2 bridge smoke, and confirm a deep link / dropped file / notification with an apostrophe **and** a `"` delivers intact (no `JSON.parse` error, no execution). If any file fails to compile or misbehaves, the pattern is: call `zapp_js_lit_dup(x)`, use its result directly (it includes its own quotes), drop any manual `'…'`/`\"…\"`, and `free()` it.

## Item 2 — the lower-risk Windows tail [FOLLOW-UP, Windows-JS-hardening]

The finding's *class* (hand-built JS/JSON with weak or no escaping) has a longer tail on Windows that never used `zapp_escape_dup`, so it was correctly untouched by the P0 fix. It is **lower risk** (app-controlled data, or post-`jsLit` robustness rather than injection), but should be swept for completeness:

**2a — raw `'%s'` interpolation into `_onEvent`/dispatch calls** (mostly app-controlled data — menu labels, accelerators, ids — so cleanliness/defense-in-depth, not a live external hole):
- `native/platform/windows/menu.c:70`
- `native/platform/windows/shortcuts.c:206` (`_onEvent('app:shortcut-triggered','%s')` — the accelerator; verify it's never externally sourced)
- `native/platform/windows/tray.c:222`
- `native/platform/windows/window.c:183`
- `native/platform/windows/popover.c:88`
- `panel.c`'s `panel_emit` also single-quotes `panel_id`/`event` raw (both internal/controlled)

**2b — weak local JSON escapers** (their output is `jsLit`-encoded at the transport, so **not an injection** — but they miss control chars / `\t` / `U+2028`/`U+2029`, so an edge-case value produces malformed inner JSON that fails `JSON.parse`, silently dropping that event's data):
- `p_json_escape` (`native/platform/windows/panel.c:56`)
- `json_escape_path` (`native/platform/windows/dialog.c:99`)

**Recommended approach:** route every external value through `zapp_js_lit_dup` (for a JS-string arg) or use it to produce a valid JSON string value (`{"k":<zapp_js_lit_dup(v)>}`) — the same pattern the P0 fix applied. Then **add a C-side lint** mirroring `cli/src/js-transport-lint.test.ts` (scan `native/**/*.c` for `_onEvent`/`dispatch*`/JSON-template building whose args aren't `zapp_js_lit_dup`-encoded), so the C paths get the same regression guard the Nim paths now have. Retire `p_json_escape`/`json_escape_path` in favor of the one encoder.

## Reference

- Spec: `docs/superpowers/specs/2026-07-13-safe-js-transport-design.md`
- Plan: `docs/superpowers/plans/2026-07-13-safe-js-transport.md`
- Encoder: `native/shared/jslit.{c,h}`; adversarial gate: `cli/src/jslit-transport.test.ts`; Nim lint: `cli/src/js-transport-lint.test.ts`
