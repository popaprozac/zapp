# Dynamic Toolbar Updates — Design

**Date:** 2026-06-12
**Branch:** `feat/toolbar-dynamic`
**Status:** Approved

## Goal

Toolbar v2 lifecycle: update and destroy after window creation. Driving
case (user, from the Messages-app filter button): a `menu:` toolbar item
whose checkmark must move when the selection changes — impossible in v1
because the toolbar is baked into `toolbarJson` at create. Also: destroy
("is there a way to destroy it too?"), late attach, enabled/disabled
buttons, and the chevron-less menu-button look.

## Decisions (user-confirmed)

1. **API shape: always-present `win.toolbar` handle** on every
   WindowHandle (creator and panes alike — no hasToolbar marker
   plumbing). `setItems` attaches when no toolbar exists (late-attach
   for free); `updateItem`/`remove` no-op gracefully without one.
   The create-time `toolbar:` option stays as sugar.
2. **Item extras in this cycle:** `enabled?: boolean` (buttons) and
   `indicator?: boolean` (menu buttons; default true — `false` is the
   Messages no-chevron look). Badges and runtime style switching are
   OUT (badge = custom-view follow-up; style flip = YAGNI).
3. **Reconcile strategy:** `setItems` mutates the SAME NSToolbar
   instance (remove-all + insert by identifier); `updateItem` patches
   the live NSToolbarItem in place (label/image/menu/enabled are
   mutable) — flicker-free for the checkmark case.

## API surface (runtime/window.ts)

```ts
/** Patch for one toolbar item. Omitted keys are left unchanged. */
export interface ToolbarItemPatch {
  label?: string;
  icon?: string;              // sf:/path/data-URL (same resolver)
  enabled?: boolean;
  menu?: MenuItemDef[];       // REPLACES the pull-down (checkmark refresh);
                              // actions stripped + re-registered like setItems
  action?: () => void;        // replaces the creator callback
}

export interface ToolbarHandle {
  /** Replace the full item set; ATTACHES a toolbar when none exists.
   *  style applies only on fresh attach (warn + ignore otherwise). */
  setItems(items: ToolbarItemDef[], opts?: { style?: "unified" | "unifiedCompact" | "expanded" }): void;
  /** In-place patch of one item by id. Unknown id → native no-op + warn. */
  updateItem(id: string, patch: ToolbarItemPatch): void;
  /** Destroy the toolbar. Chrome metrics re-inject (titlebar height
   *  shrinks back; --zapp-toolbar-height → 0px). No-op when none. */
  remove(): void;
}

// WindowHandle gains (ALWAYS present):
toolbar: ToolbarHandle;

// ToolbarItemDef gains:
enabled?: boolean;     // buttons; default true; honored at create too
indicator?: boolean;   // menu buttons; default true (showsIndicator)
```

- All ops are windowActions with payload-`windowId` resolution
  (attachModal/sidebar pattern) — handles work from the creator, either
  pane, anywhere.
- `setItems` runs the existing `normalizeToolbar` (same validation:
  ids, charset, reserved prefixes, menu-on-button-only, action+menu
  exclusivity). `updateItem` runs a new pure `normalizeToolbarPatch`
  (TDD): validates patch keys, strips/collects `action` and nested
  `menu` actions, rejects unknown keys; `{}` patch → no-op throw
  ("empty patch").
- `ToolbarOptions.style` on `setItems`: honored only when attaching
  fresh; `console.warn` + ignored when a toolbar already exists
  (runtime can't know attach-state — the WARN comes from native via
  NSLog; runtime just passes style through).

### Action-map hygiene (shrinks the documented v1 leak)

The runtime keeps per-window registries of which button-action ids
(`<windowId>:<itemId>` keys in `toolbarActions`) and menu-action ids
(app-global keys in `toolbarMenuActions`) each window registered:

- `setItems`: purge that window's previous entries from BOTH maps,
  then register the new set.
- `updateItem` with `action`: replace that one button entry; with
  `menu`: purge the ids previously registered FOR THAT ITEM, register
  the new menu's ids (per-item id tracking nests under the per-window
  registry).
- `remove`: purge the window's entries.

v1's "entries persist for app lifetime" comment gets updated: now only
windows that never touch their toolbar again leak (create-time-only
apps), same as before; any dynamic use self-cleans.

## Wire + routes (router.zc, Apple-gated)

- `toolbar:setItems  { windowId, toolbarJson }` — toolbarJson is the
  same pre-stringified `{style, items}` shape as create.
- `toolbar:updateItem { windowId, itemJson }` — itemJson is one
  normalized item object `{ id, label?, icon?, enabled?, indicator?,
  menu? }` (only patched keys present besides id).
- `toolbar:remove    { windowId }`.

Each resolves the payload windowId via
`darwin_window_numeric_id_for_string` with sender fallback, then calls
the native entry point with `(window_ptr, ..., host_slot)`.

## Native (toolbar.m)

Three entry points beside the existing `darwin_toolbar_attach`:

- **`darwin_toolbar_set_items(window_ptr, toolbar_json, host_slot)`**
  - Registry hit: parse json; rebuild the controller's `identifiers` +
    `buttonsById`; reconcile the SAME NSToolbar instance:
    `while (toolbar.items.count) removeItemAtIndex:0;` then
    `insertItemWithItemIdentifier:atIndex:` in declared order (the
    delegate serves the new defs). `style` in the json: NSLog warn +
    ignore. One `zapp_toolbar_inject_metrics(window, host_slot, false)`
    after reconcile (the contentLayoutRect KVO also catches height
    changes; the explicit call covers same-height cases cheaply).
  - Registry miss: delegate to `darwin_toolbar_attach` (style honored)
    — late-attach. window.m's construction-time injection stays as-is
    (unchanged, proven); the set_items late-attach path schedules its
    OWN injection (same one-tick dispatch + `inject_metrics(window,
    host_slot, true)` so the user script persists across reloads).
- **`darwin_toolbar_update_item(window_ptr, item_json)`**
  - Merge patch keys into the stored def in `buttonsById` (future
    delegate rebuilds must agree).
  - Find the live item by identifier in `toolbar.items`; mutate in
    place: `label`/`paletteLabel`/`toolTip`; `image` via
    `zapp_resolve_icon`; `enabled` (see below); for NSMenuToolbarItem:
    fresh NSMenu via `darwin_menu_build_from_items_json` +
    `showsIndicator` from `indicator`.
  - Unknown id or no toolbar: NSLog warn, no-op.
- **`darwin_toolbar_remove(window_ptr)`** — ORDER IS LOAD-BEARING:
  1. remove the contentLayoutRect KVO observer (the controller is
     about to lose its only strong ref; the coalesced KVO block holds
     it weakly and would silently skip the final inject),
  2. `window.toolbar = nil`,
  3. `dispatch_async` one tick → `zapp_toolbar_inject_metrics(window,
     host_slot, false)` capturing the WINDOW + SLOT (not the
     controller) — titlebar height shrinks back, toolbar-height → 0px,
  4. drop the registry entry.
  No-op when not registered.

### enabled (the AppKit validation dance)

- Action buttons: implement `validateToolbarItem:` on
  ZappToolbarController returning the stored def's enabled flag
  (default YES). This is the canonical mechanism — AppKit revalidates
  on its own schedule and would re-enable items behind a bare
  `.enabled` set.
- Menu items (NSMenuToolbarItem, no action): `autovalidates = NO` +
  set `.enabled` directly at build/update time.
- `darwin_toolbar_attach`'s item construction honors `enabled` and
  `indicator` at create too.

### iOS / Windows

- ios/toolbar.m: 3 new no-op stubs (router references the symbols
  under `#ifdef __APPLE__`, true on iOS — the parity-gate class).
- Windows: untouched (toolbar routes are Apple-gated; toolbar remains
  documented macOS-only chrome).

## Testing

- bun (TDD): `normalizeToolbarPatch` (key validation, empty-patch
  throw, action/menu stripping + collected maps, charset on new menu
  ids); per-window action-registry purge logic (extracted pure enough
  to test: registered-id bookkeeping in/out); `enabled`/`indicator`
  wire shape through `normalizeToolbar`.
- Gates: `bun run test:all`, hello-world macOS build (`[zapp] build
  complete:`), ios-simulator build, headless runtime smoke.
- Demo (hello-world, user-WIP, never committed): the filter `menu:`
  gets a MOVING CHECKMARK (action → `updateItem("filter", { menu:
  rebuiltWithChecked })`); an enable/disable toggle for the compose
  button; "Remove toolbar" / "Attach toolbar" buttons proving destroy +
  late-attach + metrics shrinking/growing (`--zapp-titlebar-height`
  visibly changes — the pane padding uses the var).
- Visual gate (user): checkmark moves on selection; disabled button
  greys; chevron hidden with `indicator: false`; remove/attach animates
  sanely and content padding tracks.

## Out of scope (follow-ups)

Badges/counts on buttons (custom-view), runtime style switching,
NSSearchToolbarItem, user customization, Windows/iOS toolbars,
menuNeedsUpdate-style lazy pull (push-model updateItem covers the known
cases; revisit if apps want open-time freshness).
