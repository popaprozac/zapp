# CEF sub-cycle C1 — sidebar on CEF windows (macOS) — design

**Date:** 2026-07-06
**Branch:** `feat/cef-native-chrome` (off `feat/nim-native @ 389e9b6`; NO merge to `nim-native` without ask — Windows handoff target)
**Type:** Feature — host CEF browsers in an `NSSplitViewController` sidebar pane (the first native-chrome element on CEF). Opt-in + gated. macOS-only.
**Status:** design approved; pending spec review → writing-plans → SDD

## Goal

A chromium (`webEngine:"chromium"`) app's window **with a sidebar** renders **both** the host pane and the sidebar pane on CEF, with collapse/expand/resize events reaching both CEF panes and clean per-pane teardown. Reuses sub-cycle B's registry/create/teardown + the engine-agnostic split machinery. `webEngine:"system"` (WKWebView) windows stay byte-identical. Inspector + toolbar are follow-on cycles (C2/C3).

**North star.** The CEF native-chrome series (C1 sidebar → C2 inspector → C3 toolbar → …) exists to reach one integration target: running the full **`kitchen-sink`** app — Zapp's showcase of every native surface (sidebar, inspector, toolbar, tray, menus, popover, workers …) — with `webEngine:"chromium"`. Each cycle removes one blocker; once enough land, `kitchen-sink` on CEF is the comprehensive "every native surface on Chromium" gate. C1's `cef-hello` sidebar fixture is the *focused* gate for this cycle (kitchen-sink can't run on CEF until its other surfaces land); kitchen-sink-on-CEF is the eventual whole-app gate.

## Context

Today the CEF window branch (`window.m:1156`) is **fullbleed-only** — it hosts a CEF browser in `[window contentView]` and NEVER builds the sidebar/inspector split. The split-building itself (`window.m:927-1064`) is **engine-agnostic** AppKit: an `NSSplitViewController` + `[NSSplitViewItem sidebarWithViewController:]` + a content item, with pane **container views** (`sidebarContainer` = the sidebar VC's `.view`; `contentVC.view` = the host pane). The WKWebView path mounts a `WKWebView` into each pane container via `darwin_webview_create_ext(container_view, …)` then registers it: `zapp_register_webview(sidebar_slot, wv, hostWindowId)` — the sidebar's JS identity is the **host** id (`win-<host>`), transport routes by the slot index.

Sub-cycle B shipped: the slot↔browser registry `zapp_cef_browsers[]`; `zapp_cef_create_browser_in_view(parent_view, url, window_slot, window_id, owner_id)` — hosts a CEF browser in **any** NSView, registering it in the table by slot; and the Electrobun `removeFromSuperview` teardown `zapp_cef_teardown_browser_for_slot(slot)`. The sidebar event registry `zapp_sidebar_register(splitVC, sidebarItem, host_id, sidebar_slot)` (sidebar.m) — KVO + resize observers emitting `sidebar-collapsed`/`expanded`/`resized` into both panes — is engine-agnostic.

So C1's only new work is **routing the CEF window path through the split** and mounting a CEF browser into each pane container instead of a WKWebView. Everything else (the split builder, B's create/teardown/registry, the sidebar event registry) is reused unchanged.

## Design

### 1. Route the CEF window path through the split

When a chromium window has a sidebar (`useSidebar`, from `sidebarUrl`), build the split by reusing the existing engine-agnostic block (`window.m:927-1064`) — same `NSSplitViewController` + `sideItem` + `contentItem` + container views. Then, instead of the fullbleed `[window contentView]` CEF branch, mount a CEF browser into **each** pane container. This is a restructure of `window.m`'s create path so the `ZAPP_HAS_CEF` branch reaches the split path (today it's a separate fullbleed-only branch) — the highest-risk part of C1 (careful interleaving; see Scope).

### 2. Per-pane CEF browsers (reuse B's create)

- **Host pane:** `zapp_cef_create_browser_in_view(contentVC.view, host_url, host_slot, hostWindowId, ownerId)`.
- **Sidebar pane:** `zapp_cef_create_browser_in_view(sidebarContainer, sidebar_url, sidebar_slot, hostWindowId, ownerId)`.

Each registers in `zapp_cef_browsers[pane_slot]` (B's table). The two slots are the pre-allocated `host_slot` + `sidebar_slot` (`wopts_sidebar_numeric_id`) the WK path already uses. Both panes carry the **host** JS identity string (`hostWindowId`), mirroring `zapp_register_webview(sidebar_slot, wv, hostWindowId)` — transport routes by slot, identity by the host id.

### 3. Events — via B's registry + the (engine-agnostic) sidebar registry

`zapp_sidebar_register` wires KVO + resize and emits `sidebar-collapsed`/`expanded`/`resized` to the pane slots. With the CEF pane browsers in B's table, targeted eval (by slot) and broadcast (fan to all live slots) reach them — the sidebar events route to the right pane slots, and worker/global events fan to both panes. No change to the sidebar registry.

### 4. Teardown — per pane (extend B's)

B's `windowWillClose:` CEF teardown currently tears down one slot (the host). For a sidebar window it must tear down **each** pane's CEF browser — call `zapp_cef_teardown_browser_for_slot` for the host slot AND the sidebar slot (and inspector slot in C2). Extend the `windowWillClose:` CEF branch to iterate the window's actual pane slots.

### 5. Toggle

C1 has no toolbar (C3). The sidebar collapses via the divider drag (`NSSplitViewItem.canCollapse`, already wired) or any existing programmatic collapse API — reuse whatever exists; do NOT add a new toggle API just for the gate. The gate proves render + collapse/expand event delivery, not the toolbar button.

## Components / files

- `native/platform/darwin/window.m` — route the CEF branch through the split when `useSidebar`; mount CEF browsers into the pane containers (host + sidebar); extend the `windowWillClose:` CEF teardown to per-pane slots. All CEF changes `#ifdef ZAPP_HAS_CEF`-gated.
- **Reused unchanged:** B's `zapp_cef_create_browser_in_view` / `zapp_cef_teardown_browser_for_slot` / the registry; the split builder (`window.m:927-1064`); `zapp_sidebar_register` (sidebar.m).
- `examples/cef-hello/` — window 1 gets a sidebar (host + sidebar panes; a simple sidebar page/route); window 2 stays plain (multi-window regression). `zapp/app.nim` window 1 `WindowOptions` gains sidebar opts.
- `spikes/cef-macos/FINDINGS.md` — sidebar-on-CEF closed.

## Testing (human R0 gates)

- **Both panes render:** window 1 shows the host pane AND the sidebar pane on Chromium; window 2 (plain) still renders.
- **Broadcast to both panes:** a worker tick / event reaches BOTH panes (the worker's `Events.emit` fans to the host + sidebar CEF browsers via B's broadcast).
- **Collapse/expand:** collapsing/expanding the sidebar (divider drag) delivers the `sidebar-collapsed`/`expanded` event to both CEF panes.
- **Targeted still works:** per-window greet routes to the host pane (`win=<host>`); the multi-window gates from B still pass.
- **Per-pane teardown:** closing window 1 tears down BOTH pane browsers cleanly — `browser closed (slot <host>)` AND `browser closed (slot <sidebar>)` in the console, no leak (B's teardown per pane).
- **Byte-identical:** a `webEngine:"system"` build is unaffected (all CEF changes `#ifdef`-gated; the WK sidebar path unchanged).

## Error handling

- Pane slot bounds-checks via B's `zapp_cef_slot_ok`.
- Teardown iterates only the window's actual pane slots (host + sidebar when present).
- `sidebar_url` absent → no sidebar; the CEF path stays fullbleed (B unchanged).
- Refcount: each pane's CEF browser follows B's proven create/teardown lifecycle independently.

## Non-goals (deferred)

- **Inspector on CEF** — mirrors the sidebar; sub-cycle **C2**.
- **Toolbar + sidebar-toggle button on CEF** — sub-cycle **C3**.
- **Vibrancy / material behind a CEF pane** — a CEF (non-OSR Alloy) browser is opaque and renders its own background, so the WK sidebar's vibrancy `svfx` wrapper won't show through a CEF pane. CEF panes are opaque this cycle (vibrancy-on-CEF = OSR territory, a separate concern). Document it.
- Popover on CEF; per-pane distinct engines.
- The B **terminal-close** limitation (a closed CEF window reshows blank) applies per-pane — already documented.

## Scope

`window.m` CEF-branch-through-split + per-pane CEF mounting + per-pane teardown + a sidebar fixture + FINDINGS. Likely **~3 tasks**: (1) route the CEF path through the split + mount CEF host + sidebar panes + fixture + the both-panes-render gate; (2) per-pane teardown + collapse/expand event delivery gate; (3) docs. **Highest risk:** the `window.m` create-path restructure (making the `ZAPP_HAS_CEF` branch use the engine-agnostic split instead of its separate fullbleed branch) — the plan should map the exact current branching before editing, and may spike the split-interleaving.
