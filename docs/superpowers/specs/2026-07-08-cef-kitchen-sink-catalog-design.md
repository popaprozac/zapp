# Kitchen-sink-on-CEF — integration catalog (macOS) — design

**Date:** 2026-07-08
**Branch:** `feat/cef-kitchen-sink-catalog` (off `feat/nim-native @ 2bf6bd9`; NO merge to `nim-native` without ask)
**Type:** Spike / integration catalog — run the full `kitchen-sink` app on `webEngine:"chromium"` and catalog every native surface's CEF status. macOS-only.
**Status:** design approved (catalog-only, temp-flip + revert); pending spec review → execute

## Goal

Produce a **per-surface CEF-status catalog** for the full `kitchen-sink` app — Zapp's showcase of every native surface — now that the four CEF chrome/event blockers (C1 sidebar, C2 inspector, C3 toolbar, host-event fan-out) are merged. This is the north-star integration checkpoint: learn *exactly* what works on CEF and what doesn't. The catalog is the **deliverable** and the roadmap; **fixing** the breakages is out of scope (each becomes its own scoped follow-up cycle).

## Approach — spike-first, human-driven walkthrough

1. **Temp flip.** Set `kitchen-sink/zapp.config.ts` `webEngine: "chromium"` (one line, mirroring `cef-hello`). This is temporary — reverted at the end; the committed catalog (FINDINGS) is the artifact.
2. **Build gate (finding #0).** `cd kitchen-sink && rm -rf ~/.cache/nim/app_r && bun run build`. Does the full app compile + link with CEF? Most native surfaces are engine-agnostic AppKit and should; any WK-specific dep that fails to compile/link is the first catalog entry (a build-level breakage).
3. **Structured walkthrough.** Launch and exercise each of the 21 surfaces, recording **PASS / PARTIAL / BROKEN** + a one-line note. Human-driven: the controller builds and hands the user a risk-tiered checklist; the user drives, the controller compiles. Console/native logs captured alongside for crashes/errors.
4. **Catalog → roadmap.** Write a per-surface CEF-status table into `spikes/cef-macos/FINDINGS.md` (a "kitchen-sink-on-CEF catalog" section). This is the backlog for follow-up cycles (and helps prioritize sub-cycle D).
5. **Revert the flip.** Restore `kitchen-sink/zapp.config.ts` to `system` default. Kitchen-sink stays WK-by-default; the catalog is the only lasting artifact.

## The 21 surfaces (walkthrough checklist)

**Tier 1 — likely-works (built on CEF-covered primitives; confirm quickly):**
- `sidebar`, `inspector`, `toolbar` — native chrome (C1-C3).
- `workers`, `events`, `sync` — worker/event bridge (A/B).
- `window-log`, `home` — plain bridge/render.
- `multiwindow` — multi-window registry (B).

**Tier 2 — higher-risk / never CEF-tested (the real findings live here):**
- `embedded-webview` — a `<zapp-webview>` nested inside a CEF page (WKWebView-in-CEF? the sandboxed embed path is WK-specific — HIGH risk).
- `clipboard` — read/write text/html/image/files.
- `filedrop` — drag-drop onto the webview (CEF drop handling differs).
- `dialogs` — native open/save/alert panels.
- `tray` — status-bar item + attached window.
- `notifications` — UNUserNotificationCenter.
- `popover` — NSPopover with a webview.
- `contextmenu` — right-click menu (CEF has its OWN context menu — likely collides/overrides).
- `dock` — dock menu / badge / bounce.
- `screen` — displays API.
- `shortcuts` — global shortcuts (Carbon).
- `app-events` — notif-click / reopen / deep-link.

## What "PASS / PARTIAL / BROKEN" means

- **PASS** — the surface behaves as on WKWebView.
- **PARTIAL** — works but with a visible/behavioral difference (note it).
- **BROKEN** — doesn't work / crashes / no-ops.

For each, capture: what was exercised, the result, and (if broken) the likely layer (build, native primitive, WK-specific path, CEF-intrinsic difference).

## Output

`spikes/cef-macos/FINDINGS.md` gains a "**Kitchen-sink-on-CEF catalog (2026-07-08)**" section: a table of all 21 surfaces × status × note, plus a short "roadmap" summary (which broken surfaces are quick `#ifdef` gates vs which need real cycles vs which are CEF-intrinsic/won't-fix).

## Non-goals

- **Fixing the breakages** — every fix is a separate scoped cycle (user-decided: catalog only). The controller may fix ONLY a truly-trivial 1-line gate opportunistically if it blocks cataloging the rest, and will flag it.
- **Lasting engine config** — the flip is temporary; kitchen-sink stays `system` by default (no `ZAPP_ENGINE` toggle this pass).
- **Non-macOS** — macOS only.

## Testing

The "test" is the walkthrough itself (human R0 per surface). The build gate (#0) is automated. No unit tests. Success = a complete, honest catalog (all 21 surfaces have a status), committed to FINDINGS, with the flip reverted.

## Scope

`kitchen-sink/zapp.config.ts` (temp flip, reverted) + `spikes/cef-macos/FINDINGS.md` (the catalog). Executed as a direct spike (build + human walkthrough + doc), not subagent-decomposed — the walkthrough is human-driven and the deliverable is a single catalog, so the SDD task/review machinery doesn't fit; the controller runs it inline and the catalog stands as the reviewable artifact.
