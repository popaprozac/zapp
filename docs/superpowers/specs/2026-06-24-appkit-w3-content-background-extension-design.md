# AppKit New-Design Adoption — W3: Content Background Extension (macOS) — Design

**Status:** Approved (design) — pending spec review
**Branch:** `feat/nim-native` (keep UNMERGED)
**Date:** 2026-06-24
**Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
**Parent effort:** AppKit new-design adoption (WWDC26 "Build an AppKit app with the new design"). Sub-cycle W3 of the W1/W2/W3 decomposition. iOS untouched.

---

## Background

After removing the macOS SwiftUI pane path (2026-06-23), macOS chrome is AppKit
(`NSSplitViewController` + `NSToolbar`). The WWDC26 talk shows AppKit already
delivers the new Liquid Glass design natively on macOS 26 (Tahoe).

**W1 finding (no work needed): the glass is already lit up.** `window.m` builds the
sidebar via `[NSSplitViewItem sidebarWithViewController:]` (`:879`) and the inspector
via `[NSSplitViewItem inspectorWithViewController:]` (`:919`) — the glass-capable
behaviors. The `NSVisualEffectView` is only inserted for an explicit **non-`sidebar`**
`material` override (`:857-859`, `:899-900`); unspecified/`sidebar` → native glass;
`< 26` vibrancy is automatic via the split-item behaviors. So default windows already
show real floating glass. (W1 collapses to documentation, folded into this cycle's docs.)

**What's genuinely missing — this cycle.** The talk's *content-under-glass* depth
effect: letting content flow under the floating sidebar, and `NSBackgroundExtensionView`
to mirror/blur content edge-to-edge behind the glass (the App Store-poster effect). Our
content pane is a `WKWebView`; the native APIs target static content views, so this needs
a risk gate and a CSS-injection companion.

**Inspector is out of scope by design.** The talk: *"sidebars … float **above** the
window's content, whereas inspectors … sit **alongside** the content."* Both
`automaticallyAdjustsSafeAreaInsets` and `NSBackgroundExtensionView` exist because the
floating sidebar overlaps content. The inspector doesn't overlap content, so it imposes
no content safe-area inset and carries no extension. Sidebar-edge is the complete scope.

## Decision

Add a create-time, sidebar-edge `contentBackground` window option with three modes,
macOS-26-gated with graceful fallback, plus a safe-area CSS-injection companion so
webview content can lay out correctly while flowing under the floating glass.

### Config surface
`WindowOptions.contentBackground?: ContentBackground` (default `Standard`), mirroring the
existing `Material` const-enum pattern (autocompletes; plain string literals still
type-check):
- **`Standard`** (`"standard"`) — content sits in its column beside the sidebar; no
  extension. Today's behavior; the `< 26` fallback for the other modes.
- **`Extend`** (`"extend"`) — content frame extends under the floating sidebar via
  `automaticallyAdjustsSafeAreaInsets`; the app lays out using injected safe-area CSS
  vars; no mirror. (Talk's "I'll position content myself" path.)
- **`Mirror`** (`"mirror"`) — `NSBackgroundExtensionView`: content positioned in the safe
  area, edges mirrored/blurred behind the sidebar glass (the poster effect). Degrades to
  `Extend` if T1 finds `NSBackgroundExtensionView` + `WKWebView` incompatible.

Create-time only (no runtime toggle — structural). Sidebar edge only.

### Version gating + fallback
| Mode | macOS 26+ | < 26 |
|---|---|---|
| `Standard` | content beside sidebar (native glass) | same |
| `Extend` | content under floating sidebar + safe-area CSS | falls back to `Standard` |
| `Mirror` | `NSBackgroundExtensionView` mirror + safe-area CSS | falls back to `Standard` |

Gated with `if (@available(macOS 26, *))` (the codebase idiom). The runtime/Nim layers
pass the mode through unconditionally; the native layer decides based on availability and
logs the resolved behavior.

### Material semantics (W1 docs, folded in)
Keep the current contract and document it: `material` unspecified or `Material.Sidebar` →
native glass (no `NSVisualEffectView`); any other `material` → forced
`NSVisualEffectView` override (all macOS versions). (We do NOT implement strict
"naming Sidebar forces the static material" — on macOS 26 that would suppress the
floating glass, a footgun.)

## Goals
- Apps can opt the content pane into the floating-glass depth effect via one config value,
  with full-bleed media mirroring behind the sidebar on macOS 26.
- Web content lays out correctly (no content hidden under the sidebar) via injected
  safe-area + corner CSS vars that update as the sidebar collapses/resizes.
- Graceful, documented fallback on `< 26` and on the `Mirror`-NO-GO path.
- Default windows unchanged (`Standard`).

## Non-goals
- Inspector-edge extension (out of scope by design, see Background).
- Runtime toggling of `contentBackground`.
- A general "all content flows under all chrome" model beyond what `Extend`/`Mirror`
  need (the safe-area vars are the reusable primitive; broader use is app-driven).
- iOS changes.

## The risk gate (T1)

`NSBackgroundExtensionView` ships in Apple's examples wrapping *static* content views.
Ours is a live, interactive `WKWebView`. T1 is a go/no-go human visual spike:

Wrap the content `WKWebView` (i.e. `contentVC.view`/`mainContainer`, `window.m:828-838`,
webview mounted `:964`) in `NSBackgroundExtensionView(contentView:)` and set
`automaticallyAdjustsSafeAreaInsets = true` on the content split item, behind
`if (@available(macOS 26, *))`. Confirm:
1. The mirror/blur appears behind the floating sidebar.
2. The webview still renders, scrolls, and takes input (the replica is visual-only).
3. Collapsing/resizing the sidebar updates the content's `safeAreaInsets` (drives T4).

- **GO** → ship all three modes.
- **NO-GO** (webview interaction breaks, or no mirror) → drop `Mirror` from the enum for
  now (keep `Standard`/`Extend`), document the limitation + a follow-up, and ship the
  `Extend` depth effect (content under glass + safe-area CSS), which is still a real win.

## Safe-area → CSS companion

When `Extend`/`Mirror` is active, the content webview is inset to the unobscured region,
so the page must know that inset or content hides under the sidebar. Extend the existing
chrome-metrics injection (`toolbar.m` `zapp_toolbar_inject_metrics`, the
`documentElement.style.setProperty('--zapp-titlebar-height',…)` JS at `:606`) with:
- `--zapp-safe-area-left` (sidebar overlap; 0 when collapsed/`Standard`),
- `--zapp-safe-area-{top,right,bottom}` (top from chrome; right/bottom typically 0),
- `--zapp-corner-inset` (the rounder Tahoe window corners, so content near corners isn't
  clipped — the CSS analog of `NSView.LayoutRegion`).

Source of truth = the content view's `safeAreaInsets`. It must re-inject when the sidebar
collapses/expands/resizes — reuse the existing sidebar KVO/`didResizeSubviews`
observers (sidebar.m) to trigger a re-inject, same machinery as the toolbar metrics.

## Files (anticipated)
- `runtime/window.ts` — `ContentBackground` const enum + `WindowOptions.contentBackground` + docs.
- `native/nim/window.nim` — parse `contentBackground` from window config JSON; pass to native.
- `native/platform/darwin/window.m` — content-pane wiring (`Extend` safe-area / `Mirror`
  `NSBackgroundExtensionView`), `@available(macOS 26)` + fallback + resolved-behavior log.
- `native/platform/darwin/toolbar.m` (or a small new metrics helper) — safe-area + corner
  CSS vars injection + dynamic re-inject.
- `native/platform/darwin/sidebar.m` — trigger safe-area re-inject on sidebar collapse/resize.
- `kitchen-sink/src/sections/sidebar.ts` — full-bleed media showcase.
- `docs/api-reference.md`, `docs/native-ui-strategy.md` — `contentBackground` + W1 material/version docs.
- Tests: `runtime`/CLI unit coverage for the enum parse where applicable (bun:test).

## Task breakdown (for the plan)
- **T1 — RISK GATE (human visual).** `NSBackgroundExtensionView` + `WKWebView` viability
  (mirror appears, webview interactive, safe-area updates). GO → 3 modes; NO-GO → drop
  `Mirror`, ship `Extend`. Pause for human.
- **T2 — Config surface.** `ContentBackground` enum + `WindowOptions.contentBackground`
  (runtime/window.ts) + `window.nim` parse + unit coverage. Pass-through only.
- **T3 — Native wiring.** `window.m` content pane: `Extend` (`automaticallyAdjustsSafeAreaInsets`)
  + `Mirror` (`NSBackgroundExtensionView`), `@available(macOS 26)` + `Standard` fallback +
  log. Build gate.
- **T4 — Safe-area CSS.** Inject `--zapp-safe-area-*` + `--zapp-corner-inset`; dynamic
  re-inject on sidebar collapse/resize. Build gate.
- **T5 — Showcase + docs + gates.** `sidebar.ts` full-bleed demo; `api-reference` +
  `native-ui-strategy` (incl. W1 material/version docs); full build matrix (macOS
  `[zapp] build complete:` + iOS-sim + `bun test`); human visual smoke (all three modes +
  `< 26` reasoning); final review.

## Verification / gates
- `bun test` (runtime/CLI) green.
- macOS build `[zapp] build complete:` + fresh binary; iOS-sim build green (shared Nim
  unaffected; `contentBackground` is darwin-only behavior with an iOS no-op).
- Human visual smoke: `Standard` unchanged; `Extend` flows content under the sidebar with
  correct safe-area layout; `Mirror` shows the poster effect (if GO); sidebar
  collapse/resize updates the safe-area live.
- Final cross-impl review; branch stays UNMERGED.

## Risks
- **`NSBackgroundExtensionView` + `WKWebView`** — the T1 gate; NO-GO path defined.
- **Dynamic safe-area churn** — re-injecting on every resize tick; coalesce like the
  existing metrics KVO (one re-measure per runloop tick) to avoid thrash.
- **iOS link parity** — any new `darwin_*` symbol referenced from shared Nim needs an iOS
  no-op; covered by the iOS-sim build + parity lint.

## Self-review
- Spec coverage: enum (T2) · native modes + gating/fallback (T3) · safe-area CSS (T4) ·
  risk gate (T1) · showcase/docs/W1-docs (T5). Inspector explicitly out (Background).
- No placeholders; version-fallback table explicit; NO-GO path concrete.
- Naming (`ContentBackground` / `Standard`/`Extend`/`Mirror`) is final-tweakable in T2 but
  consistent throughout.
