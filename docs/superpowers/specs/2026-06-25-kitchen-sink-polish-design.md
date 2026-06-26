# Kitchen-Sink Polish Pass — Design

**Status:** approved (brainstorm), pending plan
**Branch:** `feat/nim-native` (UNMERGED)
**Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
**Scope:** demo-app only (`kitchen-sink/src`). No framework/runtime API changes expected.

## Goal

Seven loose-end fixes + additions to the kitchen-sink demo so each native feature reads clearly and the multi-window demos are focused rather than spilling the full shell.

## Background (verified)

- Sections implement `Section { render(host), inspector?(host) }` (`kitchen-sink/src/sections/types.ts:7`). Registry has 17 sections (`sections/registry.ts`).
- Cross-pane state rides the `Events` bus: `ks:nav` (windowId-scoped), `ks:filter`, `ks:tray`. Panes are separate webviews of one window.
- The hash router (`kitchen-sink/src/shell/router.ts`) is the single dispatch point:
  ```ts
  if (hash.startsWith("#titlebar-showcase")) { renderTitlebarShowcasePane(app); return; }
  if (hash.startsWith("#bg-demo"))           { renderBgDemoPane(app); return; }
  switch (hash) {
    case "#sidebar-pane":   renderSidebarPane(app); break;
    case "#inspector-pane": renderInspectorPane(app); break;
    case "#popover-pane":   renderPopoverPane(app); break;
    default:                void renderMainPane(app); break;
  }
  ```
- `main-pane.ts:66` windowId-scopes its `ks:nav` listener; `inspector-pane.ts:36` does NOT (latent multi-window bug).
- `Window.create` demos live in `sections/multiwindow.ts`; sheets (`asSheetOf`) and the color window set no main `url` → fall to `renderMainPane` (full shell).

## Items

### 1. Inspector staleness (bug fix)
**Root cause:** the **Sidebar** (`sections/sidebar.ts:57`) and **Inspector** (`sections/inspector.ts:39`) section inspectors render a static "observing…" line and only update on a *future* `SIDEBAR_*`/`INSPECTOR_*` event; they never read initial state on mount (Toolbar/Tray seed from module state, so they look live).
**Fix:** on mount, seed the displayed state from the live handle's current values if a getter exists (e.g. collapsed/width); if no getter is available, replace "observing…" with an honest live-label (e.g. "Live — collapse / expand / resize the sidebar to see updates") so it doesn't imply it's already reflecting state. Keep the event subscription for live updates.
**Also (latent multi-window bug):** windowId-scope `inspector-pane.ts`'s `ks:nav` listener to match `main-pane.ts`, so the bg/color/shell-2 windows don't cross-drive each other's inspector.

### 2. Window log (new section `window-log`)
New section (registry + `sections/window-log.ts`): `render()` shows a capped (~50-entry), timestamped, scrolling log subscribing to the window geometry/lifecycle events exposed by `WindowEvent` (resize, move, focus/blur, miniaturize/zoom, screen-change — whichever the enum provides; the implementer enumerates and subscribes to the available geometry/lifecycle members, NOT toolbar/sidebar/inspector). A "Clear" button. Returns a teardown that unsubscribes all. Distinct from the existing `events` section (that demos the `Events.emit/on` bus).

### 3. Popover (keep one, label it)
Decision: **keep the single re-anchored popover** (`sections/popover.ts:11` `pop` singleton, shown from the button and from `{ toolbarItem: "compose" }`). Add a clear label/comment in the section card intro and the popover-pane content noting "same popover, re-anchored — shown from the button and the Compose toolbar item." No behavioral change; labeling only.

### 4. Context menu (new section `contextmenu`)
New section (registry + `sections/contextmenu.ts`): a right-click target area + a button → `ContextMenu.show(items, { event })` (`ContextMenu` from `@zappdev/runtime`). The menu is **rebuilt on each show** from current app state and includes: a couple of plain actions (update a result line), a `submenu`, a `radioGroup` (e.g. "Sort by: Name / Date / Size"), and a `checkbox`. Because context menus are ephemeral, `ctx.update` is a no-op there — the radio/checkbox state is held in module vars and reflected by rebuilding the menu on the next show (the documented pattern). The section notes this explicitly.

### 5. Sheets → single pages
Add a prefix route `#sheet=` → `renderSheetPane(app)` (new `shell/sheet-pane.ts`) that reads the variant from the hash (`settings` | `quickadd` | `drawer`) and renders a focused single page (a small settings form, a compact quick-add form, a drawer content list). Point the three sheet `Window.create` calls (`multiwindow.ts:61/63/65`) at `url: "#sheet=settings"` / `"#sheet=quickadd"` / `"#sheet=drawer"`. Sheets no longer load the full shell.

### 6. Background windows → small sidebar
Add `#bg-sidebar` route → `renderBgSidebarPane(app)` (in/with the bg-demo pane code): a 2-item sidebar ("Aurora" / "Mesh") that emits a windowId-scoped `ks:bg-nav` `{ variant, windowId }`. `renderBgDemoPane` gains two full-bleed background variants and a windowId-matched `ks:bg-nav` listener that swaps the visible variant (so the glass / background-extension effect re-adapts). Change `bg-mirror`/`bg-extend` `Window.create` `sidebar.url` from `#sidebar-pane` → `#bg-sidebar` (`multiwindow.ts:82/91`). The mirror/extend mode + the variant both come through the existing `#bg-demo=` content hash + the new nav event.

### 7. Color window → descriptive sidebar + focused content
Add `#color-sidebar` route → `renderColorSidebarPane(app)`: **static descriptive text, no nav items**, explaining what to observe (opaque teal window color; translucent-purple sidebar letting the teal show through). Add `#color-content` route → `renderColorContentPane(app)`: a focused info page (over the teal window) describing the color API (names / hex / rgb() / rgba()). Update the color-demo `Window.create` (`multiwindow.ts:103`) to set `sidebar.url: "#color-sidebar"` and main `url: "#color-content"` so the window is a coherent color demo rather than a half-navigable shell.

## Router changes (summary)
`shell/router.ts` gains: a `hash.startsWith("#sheet=")` prefix guard → `renderSheetPane`; switch cases `#bg-sidebar` → `renderBgSidebarPane`, `#color-sidebar` → `renderColorSidebarPane`, `#color-content` → `renderColorContentPane`. (`#bg-sidebar`/`#color-*` are exact-match cases; `#sheet=` is a prefix like `#bg-demo`.)

## New/changed files
- New: `sections/window-log.ts`, `sections/contextmenu.ts`, `shell/sheet-pane.ts`, `shell/color-panes.ts` (color sidebar + content), `shell/bg-sidebar` (may live in the existing bg-demo pane file).
- Changed: `sections/registry.ts` (+window-log, +contextmenu), `shell/router.ts` (new routes), `shell/inspector-pane.ts` (windowId scope), `sections/sidebar.ts` + `sections/inspector.ts` (seed initial state), `sections/popover.ts` + `shell/popover-pane.ts` (label), `sections/multiwindow.ts` (sheet/bg/color window urls), the bg-demo pane (variants + nav).

## Testing
- `bun run check` clean; `bun test` (existing suite) green. No new runtime unit tests expected (demo-side); any small pure helper added gets a focused test.
- macOS build: `cd kitchen-sink && bun run build` → `[zapp] build complete:`.
- Human visual smoke (final): inspector seeds initial state + updates live; window-log scrolls on resize/move/focus; popover label reads clearly from both anchors; context-menu shows submenu/radio/checkbox + radio reflects state on re-open; each sheet is a focused page; bg windows show a 2-item sidebar swapping variants; color window shows the text sidebar + focused content over teal.

## Non-goals
- No framework/runtime API changes (demo-only). If a needed state getter (sidebar/inspector collapsed/width) is genuinely missing from the public API, fall back to the honest live-label (do NOT add a framework API in this cycle — file a follow-up).
- iOS (these are macOS multi-window / chrome demos).
- The deeper inspector-pane multi-window correctness beyond the `ks:nav` windowId scope.
