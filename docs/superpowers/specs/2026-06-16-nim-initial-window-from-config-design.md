# Nim Initial-Window-From-Config — Design (overnight, autonomous)

**Date:** 2026-06-16 (autonomous overnight work — [[project_nim_kitchensink_parity_overnight]])
**Branch:** `feat/nim-native`
**Status:** Self-designed under the user's overnight delegation; **documented for morning review + cheap redirect** (this touches the open config-surface reconciliation — see Caveat).

## Goal

Make the **Nim build's initial window** be the app's real window (chrome shell), so `kitchen-sink` under `ZAPP_NATIVE_LANG=nim` shows its native sidebar/inspector shell on launch instead of the hardcoded skeleton window. This is THE blocker for Nim kitchen-sink parity: today the Nim entry (`native/nim/zapp.nim`) hardcodes a plain 900×650 "Zapp v2 (Nim)" window, and the app's `app.zc` is not run on the Nim build — so kitchen-sink's native-sidebar nav is absent on Nim and none of its sections are reachable there.

## Scope

- **IN:** the Nim build creates its initial window from an optional `window` block in `zapp.config.ts` (width/height/title/sidebar/inspector/toolbar). Falls back to the current skeleton defaults when the block is absent. The **zc build is untouched** (still driven by the hand-written `app.zc run_app`).
- **OUT (cosmetic / deeper):** app **services** on Nim. App services are Zen-C handlers in `app.zc` the Nim build cannot execute; only the skeleton `greet` is registered on Nim (returns `{"greeting":...}` → kitchen-sink's `greet → [object Object]` landing line on Nim stays cosmetic). Service parity is a separate, deeper milestone. The window (pure data) is the achievable, high-value parity win.
- **OUT:** the app **name** in the menu bar (`newApp("Zapp Nim Skeleton")`) — minor; can fold in later.

## Approach (additive, reversible)

1. **`ZappConfig.window?`** (optional) in `cli/src/config.ts` — `{ title?, width?, height?, sidebar?: {url?,width?,material?,collapsible?,collapsed?,minWidth?,maxWidth?}, inspector?: {…}, toolbarJson? }`. Shape **mirrors the JSON `windowOptsApplyJson` already parses** (WM1, `native/nim/window.nim`).
2. **CLI codegen** — `renderInitialWindowNim(window)` in `cli/src/build-config.ts` emits `.zapp/zapp_initial_window.nim` with a single getter:
   ```nim
   proc zapp_window_config_json*(): cstring {.exportc, cdecl.} = "<json or empty>".cstring
   ```
   `<json>` = the `window` block serialized to the `windowOptsApplyJson` arg shape; `""` when no `window` block. (Matches the existing `zapp_build_*` cstring-getter codegen pattern — no Nim-type coupling.) Wired into `buildNativeNim` (`cli/src/native.ts`) alongside the other `.zapp/*.nim` writes. **bun-tested** like the other renderers.
3. **Nim consume** — `native/nim/zapp.nim` boot: importc `zapp_window_config_json`; if non-empty, `newWindowOptions("Zapp") + windowOptsApplyJson(opts, parseJson(json))`; else the current skeleton defaults (900×650, "Zapp v2 (Nim)"). Then the existing dev-gated `inspectable` set + `createWindow(opts)`. Reuses WM1's tested `windowOptsApplyJson`.
4. **kitchen-sink** — add the `window` block to `kitchen-sink/zapp.config.ts` mirroring its `app.zc` opts: `{ title:"Kitchen Sink", width:1100, height:700, sidebar:{url:"#sidebar-pane",width:240}, inspector:{url:"#inspector-pane",width:300,collapsed:true} }`. → the Nim initial window becomes the chrome shell.

## Decomposition (3 slices, each a smoke-testable commit)

- **S1 — CLI:** `ZappConfig.window` + `renderInitialWindowNim` + wire into `buildNativeNim` + bun test for the renderer (empty + populated). Verify the Nim build still builds (no `window` block yet → empty getter → skeleton fallback unchanged).
- **S2 — Nim consume:** `zapp.nim` reads `zapp_window_config_json()` → `windowOptsApplyJson` (fallback to skeleton). Build-verify (still skeleton, since no app sets `window` yet).
- **S3 — kitchen-sink:** add the `window` block to `kitchen-sink/zapp.config.ts`. Nim build → **AM smoke: kitchen-sink on Nim shows the sidebar/inspector chrome shell + all sections reachable.** (zc build unaffected.)

## Verification
- bun test for the renderer (S1). Build success = `[zapp] build complete:` (each slice, Nim + a zc sanity). Nim unit suite stays green.
- AM human smoke (S3): `ZAPP_NATIVE_LANG=nim bun run dev` in kitchen-sink → chrome shell on the initial window; click Sidebar/Inspector/Toolbar/Popover/Multi-window — all reachable (and, with the WM port + t:3 EMIT already landed, interactive).

## Caveat — config-surface decision made under delegation
Adding `window` to `zapp.config.ts` is a **config-surface decision** that intersects the open reconciliation ([[project_app_config_surface_reconcile]] — app options split between `zapp.config.ts` and `app.zc` AppConfig; lean is "config injects/overrides"). This is **directionally aligned** (config as source) and **additive + reversible** (optional field; absent → skeleton; zc untouched; clean revert = remove the field + codegen + the zapp.nim hook). For kitchen-sink it creates **temporary duplication** (window opts in both `app.zc` and `zapp.config.ts`) — acceptable migration-era bridge, to be resolved when the reconciliation lands (eventually `zapp.config.ts` drives both builds, or app.zc is generated). **If the morning review wants a different config shape / source, the revert is cheap.**
