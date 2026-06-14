# Inspector Pane (macOS) — Design

**Date:** 2026-06-14
**Branch:** `feat/inspector-pane` (to be cut from main)
**Status:** Approved

## Goal

Add a trailing utility pane — the right-hand "inspector" in Mail/Xcode/Notes —
completing the `sidebar | content | inspector` three-column native shell. The
inspector is a web-content pane (loads an app route, exactly like the sidebar)
that mirrors the existing `SidebarHandle`: declared at `Window.create`, toggled
/ collapsed / resized at runtime. It is the symmetric partner of the sidebar:
the sidebar is the leading `NSSplitViewItem`, the inspector is the trailing
`inspectorWithViewController:` item on the same `NSSplitViewController`.

## Decisions (user-confirmed)

1. **Lifecycle: declare + runtime show/hide.** Declared in `Window.create`
   (may start collapsed); `toggle()/collapse()/expand()/setWidth()` at runtime,
   exactly like `SidebarHandle`. Matches how native inspectors behave —
   structurally always present, toggled visible. No WKWebView re-parenting
   (the constraint that makes the sidebar create-time-rooted): a window must
   root on the split controller at creation to host any pane. *Fully dynamic
   attach-to-a-plain-window is OUT* (would re-root + re-parent the main webview
   → breaks its bridge).
2. **Toolbar integration ships in v1.** A `toggleInspector` toolbar item +
   an inspector-aware `trackingSeparator` (so the 3-column shell is complete
   out of the box while the toolbar code is fresh).
3. **Implementation: Approach A** — a parallel `inspector.m` mirroring
   `sidebar.m`'s controller + registry, with the window.m split *construction*
   unified into one builder that assembles 1–3 panes. The shipped, smoke-passed
   sidebar runtime path stays byte-identical (lowest regression risk). The one
   shared piece (Approach C): the collapse/resize event-emit helper is factored
   out and used by both `sidebar.m` and `inspector.m`. Generalizing both panes
   into one module (Approach B) is deferred to whenever a third pane type
   appears.

## Architecture

A window with an inspector roots on an `NSSplitViewController` whose items are,
in order: `[sidebar?]`, content, `[inspector?]`. The content webview (main) is
born in the content split item; the sidebar webview (if any) in the leading
`.sidebar` item; the inspector webview in the trailing `.inspector` item. None
are ever re-parented. Each pane gets its own dispatch slot, pre-allocated by
`WindowManager.create`. All panes identify in JS as the host window
(`win-<host>`).

```
NSSplitViewController (window.contentViewController)
├─ NSSplitViewItem  .sidebar     → sidebar webview   (pane_role 1)   [optional]
├─ NSSplitViewItem  (content)    → main webview      (pane_role 0)
└─ NSSplitViewItem  .inspector   → inspector webview (pane_role 3)   [optional]
```

Divider indices (stable for the window's life — the item set is fixed at
create): with a sidebar present, divider 0 = sidebar|content, divider 1 =
content|inspector. Without a sidebar, divider 0 = content|inspector.

## Runtime API (`runtime/window.ts`)

```ts
/** Options for a native inspector (trailing NSSplitViewItem) attached to a window. */
export interface InspectorOptions {
  /** Entry URL/route for the inspector webview (resolved like sidebar.url). Required. */
  url: string;
  /** Initial width in points. Default 280. */
  width?: number;
  /** Divider drag limits. Defaults 180 / 400. */
  minWidth?: number;
  maxWidth?: number;
  /** User can collapse via system behaviors. Default true. */
  collapsible?: boolean;
  /** Start collapsed (the common "hidden until summoned" inspector). Default false. */
  collapsed?: boolean;
  /** Background material. Default matches the sidebar pane default. */
  material?: Material;
}

/** A handle to the inspector attached to a window. Mirrors SidebarHandle. */
export interface InspectorHandle {
  toggle(): void;
  collapse(): void;
  expand(): void;
  setWidth(px: number): void;
  /** Tracked from INSPECTOR_COLLAPSED/EXPANDED, seeded by the create option. */
  readonly collapsed: boolean;
  /** Last width from INSPECTOR_RESIZED (the create option until the first event). */
  readonly width: number;
}

// WindowOptions gains:  inspector?: InspectorOptions
// WindowHandle gains:   readonly inspector?: InspectorHandle  // present only when the window has one
```

- `createInspectorHandle(windowId, initialCollapsed, initialWidth)` mirrors
  `createSidebarHandle`: a per-window state record (shared across repeated
  `Window.current()` calls), event listeners registered once per window,
  getters reading the record, methods firing `inspector:*` windowActions
  with `{ windowId, … }`.
- `Window.current()` attaches `.inspector` when the pane belongs to an
  inspector window — either the inspector pane itself (`zapp.isInspector`) or
  any pane of a window that has one (`zapp.hasInspector`, injected into every
  pane at construction — mirror of `zapp.hasSidebar`).
- `Window.isInspector()` returns true inside the inspector webview
  (`globalThis[Symbol.for('zapp.isInspector')] === true`), mirror of
  `Window.isSidebar()`.
- `Window.create` pre-stringifies / passes `inspector` options through the
  same path the sidebar uses (the native side reads them via `wopts_inspector_*`
  accessors). The handle returned by `createWindowHandle(windowId, sidebarOpts,
  inspectorOpts)` wires `.inspector` when `inspectorOpts` is present.

### Window actions + routes

`inspector:toggle | inspector:collapse | inspector:expand | inspector:setWidth`,
each `{ windowId, … }`. The router `inspector:*` block is a verbatim clone of
the `sidebar:*` block (payload-`windowId` resolution via
`darwin_window_numeric_id_for_string` with sender fallback; Apple-gated; ungated
by design, same class as `sidebar:*`). It calls
`darwin_inspector_toggle/collapse/expand/set_width(window_id[, width])`.

## Events (`runtime/events.ts`)

```
INSPECTOR_COLLAPSED = 17  → "window:inspector-collapsed"
INSPECTOR_EXPANDED  = 18  → "window:inspector-expanded"
INSPECTOR_RESIZED   = 19  → "window:inspector-resized"
```

(Following `POPOVER_CLOSED = 16`.) Resized payload carries `{ windowId, width }`,
mirror of the sidebar.

## Native construction (`window.m`) — unified split builder

The current `useSidebar` branch generalizes to `useSidebar || useInspector`:

1. **Slots:** `host_slot` (main, pre-existing), `sidebar_slot` (if sidebar),
   `inspector_slot` (if inspector) — each pre-allocated from `WindowManager`'s
   id-space (`window.zc` gains `inspector_numeric_id` accessor + pre-alloc,
   mirror of `sidebar_numeric_id`). `wopts_inspector_*` accessors added
   (url/width/min/max/collapsible/collapsed/material/numeric_id).
2. **Chrome default:** unchanged — a pane window (sidebar and/or inspector)
   defaults to full-size content + hidden/transparent titlebar unless
   `titleBarStyle` was set.
3. **Items:** build `sideItem` (`sidebarWithViewController:`) if sidebar;
   `contentItem` (`splitViewItemWithViewController:`); `inspItem`
   (`inspectorWithViewController:`, macOS 11+) if inspector — set
   `minimumThickness`/`maximumThickness`/`canCollapse` from options. Add in
   order `[side], content, [insp]`; `window.contentViewController = splitVC`.
4. **Initial geometry:** after the controller is the root, position the sidebar
   divider (existing) and the inspector divider:
   `setPosition:(splitView.width − inspectorWidth) ofDividerAtIndex:inspectorDivider`;
   apply `collapsed` last.
5. **Webviews:** main → host slot, self identity, `pane_role 0`; sidebar →
   sidebar slot, host identity, `pane_role 1`; inspector → inspector slot, host
   identity, always-transparent, **`pane_role 3`** (2 = popover). Each is
   explicitly registered in the dispatch table from its container (the
   contentView is the split, so the auto-registration walk can't find them).
6. **Markers:** `zapp.isInspector` document-start user script on the inspector
   pane (mirror `zapp.isSidebar` at `pane_role 1`); `zapp.hasInspector` injected
   into every pane of an inspector window (mirror `zapp.hasSidebar`). The
   inspector pane (`pane_role 3`) is a first-class pane — it participates in the
   `hasSidebar`/`hasInspector` marker injection like the main/sidebar panes;
   only the popover pane (`pane_role 2`) remains excluded.
7. **Fan-out + metrics:** `zapp_set_inspector_slot(host, inspector)` +
   `zapp_inspector_slot_lookup(host)`. `zapp_dispatch_event_to_js` fans window
   events into the inspector slot (second block beside the sidebar fan-out).
   `zapp_toolbar_inject_metrics`'s slot list extends to include the inspector
   slot, so the inspector pane receives `--zapp-titlebar-height` /
   `--zapp-toolbar-height`.
8. **Register controller:** `zapp_inspector_register(window, splitVC, inspItem,
   host, inspector_slot)`.

## Native control + registry (`inspector.m`)

```objc
@interface ZappInspectorController : NSObject
@property NSSplitViewController* splitVC;
@property NSSplitViewItem* inspectorItem;
@property int32_t hostWindowId;
@property int32_t inspectorSlotId;
@property NSInteger inspectorDividerIndex;   // 1 if sidebar present, else 0 (fixed at register)
@property BOOL lastCollapsed;
@property int lastWidth;
@end
```

- `zapp_inspector_register` mirrors `zapp_sidebar_register`: KVO on
  `inspectorItem.collapsed` + `NSSplitViewDidResizeSubviewsNotification` →
  emit `inspector-collapsed`/`inspector-expanded`/`inspector-resized` into the
  panes. Stores `inspectorDividerIndex` from the current item layout.
- `darwin_inspector_toggle/collapse/expand` → `[[inspectorItem animator]
  setCollapsed:…]` (idempotent guards as in sidebar).
- `darwin_inspector_set_width(window_id, w)` → clamp to min/max thickness,
  `setPosition:(splitView.width − w) ofDividerAtIndex:inspectorDividerIndex`.
- Current width read from `inspectorItem.viewController.view.frame.size.width`.
- `zapp_inspector_unregister` removes the KVO + notification observers.
- **Shared with sidebar.m:** the collapse/resize event-emit helper (fans an
  event name + JSON into the host + accessory panes) is extracted and called by
  both controllers (Approach C's one shared piece). `inspector.m` reuses the
  same `zapp_*_on_main` main-thread guard idiom.

## Toolbar integration (`toolbar.m`, `runtime/window.ts`)

- **`type: "toggleInspector"`** — a custom `NSToolbarItem` (no AppKit standard
  exists) with default SF symbol `sidebar.right`, target/action toggling the
  window's inspector (`darwin_inspector_toggle(windowNumericId)`). Requires the
  window to have an inspector. `normalizeToolbar` grows a `hasInspector`
  parameter (passed `opts.inspector !== undefined`); `toggleInspector` is
  warned + dropped when `!hasInspector` (mirror `toggleSidebar`'s `hasSidebar`
  check). `normalizeToolbar(toolbar, hasSidebar, hasInspector)`.
- **`trackingSeparator` gains `pane?: "sidebar" | "inspector"`** (default
  `"sidebar"`, backward-compatible — existing usage unchanged). The wire item
  carries `pane`; toolbar.m's tracking-separator branch resolves the divider
  index: `sidebar` → the sidebar divider (0), `inspector` → the inspector
  divider (from the inspector registry, `zapp_inspector_divider_index(window)`).
  An inspector `trackingSeparator` requires the window to have an inspector
  (warn + drop otherwise).

## iOS / Windows

- **iOS:** no-op stubs for `darwin_inspector_toggle/collapse/expand/set_width`,
  `zapp_inspector_register`, `zapp_inspector_unregister`,
  `zapp_inspector_slot_lookup`, `zapp_inspector_divider_index` (the iOS parity
  test requires every `.zc`-referenced `darwin_*`/`zapp_*` symbol to be defined
  in both platform dirs). `wopts_inspector_*` accessors compile on both.
- **Windows:** untouched. Inspector routes are Apple-gated; the inspector is
  documented macOS-only chrome for now.

## Error handling

- Empty / missing `inspector.url` → no inspector built (mirror `useSidebar`).
- `inspector:*` op on a window without an inspector → no-op (registry miss).
- `toggleInspector` / inspector `trackingSeparator` on a window without an
  inspector → warn + drop in `normalizeToolbar`.

## Testing

- **bun (TDD/unit):** `normalizeToolbar` gains `hasInspector`; tests for
  `toggleInspector` (kept when hasInspector, dropped+warned otherwise),
  `trackingSeparator { pane: "inspector" }` wire shape + drop-when-no-inspector,
  and `pane` defaulting to `"sidebar"`; `events.ts` INSPECTOR_* name mapping;
  `createInspectorHandle` state tracking (collapsed/width seed + event updates),
  mirroring any existing sidebar-handle tests.
- **native:** macOS hello-world build ends `[zapp] build complete:`;
  ios-simulator build ends `[zapp] build complete:`; `bun test
  ./cli/src/ios-platform-parity.test.ts` passes (new inspector symbols defined
  in both platform dirs).
- **smoke (user, hello-world demo — never committed):** a `sidebar | content |
  inspector` window. Toggle the inspector via the `toggleInspector` toolbar
  button AND `win.inspector.toggle()`; drag-resize fires `INSPECTOR_RESIZED`;
  collapse/expand fire events; both tracking separators (sidebar + inspector)
  align toolbar controls to their dividers; the inspector pane's content pads by
  `--zapp-titlebar-height`.

## Defaults chosen

- `width` 280, `minWidth` 180, `maxWidth` 400, `collapsible` true,
  `collapsed` false.
- `toggleInspector` glyph: SF Symbol `sidebar.right`.
- `trackingSeparator` carries a `pane` field (vs. a separate
  `inspectorTrackingSeparator` type) — backward-compatible, one type.

## Out of scope

Multiple inspectors per window; a bottom/dock pane; dynamic attach to a window
created without a split root; native-rendered (non-web) inspector content;
Windows/iOS inspector chrome.
