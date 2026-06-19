# Sidebar presentation mode + iOS drag-region hiding — Design

**Date:** 2026-06-19
**Branch:** `feat/nim-native`
**Status:** Design (awaiting user review)

## Summary

Two related "make each platform feel native" changes for sidebar windows:

1. **`SidebarOptions.presentation`** — a new create-time option (`"tile"` default,
   `"overlay"`) exposing Apple's `UISplitViewController` *split behavior*. Its real
   payoff is the **iPad-regular overlay flyout** (sidebar floats over content,
   dims it, tap-out dismisses). On macOS it is a documented **no-op**
   (`NSSplitViewController` tiles only); on iPhone it is a no-op (the split
   collapses to a navigation stack regardless).

2. **Hide drag regions on iOS** — iOS windows aren't user-draggable, so
   `data-zapp-drag-region` strips are dead weight. Disable drag-region tracking
   framework-side when the platform is iOS, and stop rendering the kitchen-sink's
   visual drag strips on iOS.

This is the convention-correct shape established in brainstorming:

| Platform / size | Sidebar behavior |
|---|---|
| **macOS** | Tiled, collapsible (always). `presentation` ignored. Drag strips kept. |
| **iPad (regular)** | `tile` → both columns side-by-side (default). `overlay` → sidebar floats over content as a flyout. Drag strips hidden. |
| **iPhone (compact)** | Collapses to master-detail (land on primary/sidebar, push secondary/content). `presentation` ignored. Drag strips hidden. |

The iPhone master-detail behavior already ships and is unchanged. The "true
custom hamburger drawer on iPhone" idea is **explicitly out of scope** — it's not
an Apple convention on iPhone, and we choose not to fake it.

## Terminology (Apple)

- **Split view** = the container (`UISplitViewController` / `NSSplitViewController`).
- **primary / secondary** = the columns (sidebar / content).
- **master-detail** = the list-drives-detail *interaction* built on those columns.
- **split behavior** (`preferredSplitBehavior`) = `.tile` | `.overlay` | `.displace`.
  We expose `tile` and `overlay`; `.displace` is intentionally omitted (YAGNI —
  trivial to add later as a third enum value if asked).

We use Apple's terminology (`presentation: "overlay"`), **not** "drawer".

## Component design

### 1. TS surface — `runtime/window.ts`

Add to `SidebarOptions` (and document the platform matrix inline):

```ts
/**
 * How the sidebar is presented when there's room for both columns.
 * Maps to UISplitViewController's split behavior.
 *
 * - "tile" (default): sidebar sits beside content (the classic split).
 * - "overlay": sidebar floats OVER content as a flyout; dims content
 *   behind it; tapping outside dismisses it.
 *
 * Platform behavior:
 * - iPad (regular width): fully honored — "overlay" is the native flyout.
 * - macOS: NO-OP. NSSplitViewController tiles only (slide-in collapse,
 *   never floats over content). Sidebar is always tiled-collapsible.
 * - iPhone (compact width): NO-OP. The split always collapses to a
 *   master-detail navigation stack regardless of this value.
 *
 * Create-time only. Default "tile".
 */
presentation?: "tile" | "overlay";
```

No serialization change needed for runtime `createWindow`: it spreads `{...opts}`
so `sidebar` (now carrying `presentation`) reaches native as-is. For apps that
configure the first window via `zapp.config.ts` (the CLI initial-window render
path → `zapp_window_config_json` → `windowOptsApplyJson`), verify the emitted
sidebar block forwards `presentation`; add it if the renderer enumerates keys.
(The kitchen-sink itself creates its first window in Nim — see §6 — so the
config path isn't what we smoke, but it must stay correct for config-driven apps.)

The `SidebarHandle.showContent/showSidebar/toggle/collapse/expand` doc comments
currently say "no-op on iPad-regular" — that's now wrong (and was the user's
"sidebar not collapsible on iPad" report). Update them: these act on **every**
platform with a sidebar — push/pop the nav stack on iPhone, and **collapse/reveal
on iPad-regular** (`tile` slides the sidebar beside content; `overlay` floats it
over). They only truly no-op when the window has no sidebar.

### 2. Native option parsing — `window.zc` + `window.nim` (parity)

Both layers parse the `sidebar` JSON object in `windowOptsApplyJson`. Add a
`sidebarPresentation` field to `WindowOptions` (default `"tile"` / empty = tile),
parse `sb.presentation` (string), and add an accessor
`wopts_sidebar_presentation(opts) -> cstring` consumed by the .m layer.

- `native/window/window.zc`: field + default + parse (`sb.get_str("presentation")`)
  + `fn wopts_sidebar_presentation(...)`.
- `native/nim/window.nim`: `sidebarPresentation*: string` (default `""`/`"tile"`)
  + parse (`jStr(sb, "presentation")`) + `proc wopts_sidebar_presentation`.

Per the strict Nim↔zc parity rule, both get the same field/accessor even though
the iOS build is Nim-only. Document if any divergence is unavoidable.

### 3. iOS apply — `native/platform/ios/window.m` + `native/platform/ios/sidebar.m`

**window.m (materialize):** read `wopts_sidebar_presentation(opts)` into the
`ZappIOSDeferred` record (strdup, freed in destroy). When building the split, if
presentation is `"overlay"`:

```objc
split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
// Start hidden so the sidebar reads as a summon-able flyout; the system
// provides a toggle button + edge-swipe (presentsWithGesture defaults YES).
split.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
```

Otherwise leave the defaults (tile). No new `zapp_ios_sidebar_register` param is
needed — the control ops below use `showColumn:`/`hideColumn:`, which adapt to the
split's configured behavior.

**sidebar.m (control ops) — make them work on iPad-regular (fixes "not
collapsible"):** today the reveal/hide ops early-return unless
`c.splitVC.isCollapsed` (compact/iPhone), so the sidebar can't be collapsed on
iPad. Drop that guard and drive the split with `showColumn:`/`hideColumn:`
(iOS 16+) uniformly — the same calls adapt to the split's state:

- **compact (iPhone):** push/pop the collapsed nav stack (existing behavior).
- **tile (iPad regular):** `hideColumn:Primary` collapses the sidebar (gives
  content the full width); `showColumn:Primary` brings it back — matching macOS's
  collapsible tiled sidebar.
- **overlay (iPad regular):** `showColumn:Primary` floats the flyout in;
  `hideColumn:Primary` dismisses it.

Mapping: `collapse`/`showContent` → hide primary; `expand`/`showSidebar` → show
primary; `toggle` flips on the tracked `lastCollapsedEmit`. The pre-iOS-16
fallback keeps the compact nav push/pop and nudges `preferredDisplayMode` on
regular. `setWidth` → `preferredPrimaryColumnWidth` (already wired). The
construction-time `preferredSplitBehavior` (tile vs overlay) decides the visual;
the control-op code is identical for both.

The only true no-op stays `tile` when the window is genuinely showing both
columns and the caller is content with that — but `collapse()`/`toggle()` now
have an effect there too (collapsing the tiled sidebar), so the kitchen-sink's
"‹ Menu" button becomes functional on iPad instead of inert.

### 4. macOS — `native/platform/darwin/window.m`

Read the field for parity but **no-op** it with a clear comment: AppKit's
`NSSplitViewController` sidebar tiles/collapses; it has no overlay-over-content
mode. The sidebar stays tiled-collapsible regardless of `presentation`.

### 5. Drag-region hiding on iOS

**Framework — `bootstrap/webview.ts`:** gate the `mousemove` drag-region tracker
so it never installs on iOS. Read the platform from the bootstrap config carrier:

```ts
const cfg = (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
const isIOS = cfg?.permissions?.platform === "ios";
// ... only addEventListener("mousemove", ...) when !isIOS
```

Risk: the bootstrap-config WKUserScript must be injected **before** the bridge
script for the symbol to exist at IIFE time. If injection order can't be
guaranteed, fall back to reading the platform lazily inside the handler on first
event (compute `isIOS` once, then early-return). The plan's first iOS task
verifies ordering and picks the robust form.

**Kitchen-sink — shell panes:** stop rendering the visual `data-zapp-drag-region`
strips when `Platform.isIOS` (the titlebar-height strip + sidebar/inspector drag
strips added in #510/#513). `Platform.isIOS` is true on iPad too — this removes
the spurious drag-to-move strip the user saw on iPad. macOS keeps them (window
dragging is real there).

### 6. Kitchen-sink showcase + docs

- Set `sidebarPresentation: "overlay"` in the kitchen-sink's first-window
  `WindowOptions(...)` in `kitchen-sink/zapp/app.nim` so the feature is smoke-able
  on an iPad simulator (harmless no-op on macOS/iPhone).
- Update `docs/api-reference.md` (Sidebar section) with the `presentation`
  option and the platform matrix, and a one-line note that drag regions are
  inert on iOS.

## Data flow

```
zapp.config.ts / app code: sidebar: { url, width, presentation: "overlay" }
  → runtime createWindow {...opts}  →  __window:create JSON  (or CLI initial-window render)
    → router → windowOptsApplyJson (nim/zc): WindowOptions.sidebarPresentation
      → window.m materialize: wopts_sidebar_presentation → UISplitViewController.preferredSplitBehavior
        → zapp_ios_sidebar_register(overlay) → control ops act on overlay-regular
```

## Testing

- **Unit (bun):** `windowmanager_test.nim` — assert `windowOptsApplyJson` parses
  `presentation` into `sidebarPresentation` (and defaults to tile when absent).
  (TS passthrough needs no new test — it's a spread.)
- **Build gates:** macOS Nim build + iOS-sim Nim build both link; `bun test
  cli/src` ios-platform-parity lint stays green (no new `darwin_*` symbol unless
  stubbed both platforms).
- **Human smoke:**
  - **iPad simulator:** kitchen-sink (overlay) → sidebar floats over content as a
    flyout; the "‹ Menu" button + edge-swipe reveal it, tap-out dismisses; **no
    drag strip**. Sanity-check `tile` too (temporarily): the sidebar starts
    beside content and `toggle()`/"‹ Menu" collapses + restores it (the
    "collapsible on iPad" fix).
  - **iPhone simulator:** unchanged master-detail (land on sidebar, tap → content,
    back); **no drag strips** visible.
  - **macOS:** unchanged tiled sidebar; **drag strips still present** and working.

## Out of scope

- **Inspector pane on iOS** (the trailing pane). Currently fully stubbed
  (`native/platform/ios/inspector.m` is all no-ops; `window.m` builds only
  `.doubleColumn` and explicitly defers it). Real support needs
  `UISplitViewController` `.tripleColumn` (sidebar + content + inspector) plus a
  third webview slot and inspector control ops — a meatier, separate cycle.
  Surfaced by the user's iPad test ("inspector not compat?"); recommended as a
  dedicated follow-up.
- Custom hamburger/overlay drawer on iPhone (non-conventional; not faked).
- `.displace` split behavior (trivial future enum addition).
- Runtime `setPresentation()` (create-time only for v1).
- Windows split-view presentation (tracked separately under the Windows gap).

## Files touched

- `runtime/window.ts` — `SidebarOptions.presentation` + handle doc comments.
- `native/window/window.zc` — field + default + parse + accessor (parity).
- `native/nim/window.nim` — field + default + parse + accessor.
- `native/nim/tests/windowmanager_test.nim` — parse test.
- `native/platform/ios/window.m` — read + apply split behavior + thread overlay flag.
- `native/platform/ios/sidebar.m` — presentation-aware control ops.
- `native/platform/darwin/window.m` — documented no-op read.
- `bootstrap/webview.ts` — iOS drag-tracking gate.
- `kitchen-sink/src/shell/*.ts` — hide drag strips on iOS.
- `kitchen-sink/zapp/app.nim` — `sidebarPresentation: "overlay"` on the first window.
- `cli/src/build-config.ts` — verify config-driven initial-window sidebar render forwards `presentation`.
- `docs/api-reference.md` — Sidebar `presentation` + platform matrix + iOS drag note.
