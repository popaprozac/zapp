# Unified Menu/Toolbar Action Context + Toolbar Type Refinement — Design

**Status:** approved (brainstorm), pending plan
**Branch:** `feat/nim-native` (UNMERGED)
**Tasks:** #700 (unify menu-like callback surface) + the toolbar typing/label nits
**Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

## Goal

Give every menu-like action callback a consistent **context argument** so a
handler can update its own item in place (no `Window.current().toolbar.updateItem(id, …)`
boilerplate), and tighten the toolbar item types. Four coherent parts on the
shared menu/toolbar surface:

- **A. Unified `ActionContext`** — `action: (ctx) => void` across app menus,
  context menus, tray menus, toolbar pull-downs, toolbar buttons, and segments.
- **A+. Live per-item updates for app & tray menus** — so `ctx.update()` works
  on those surfaces too (today they are rebuild-only).
- **B. Discriminated-union `ToolbarItemDef`** — per-`type` field narrowing.
- **C. `type: "label"`** text toolbar item.

macOS-only (menus + toolbar are macOS chrome). Branch UNMERGED.

## Background (verified 2026-06-25)

- `MenuItemDef.action` (`runtime/menu.ts:33`) is `() => void` and is the SHARED
  item type used by `Menu` (app menu, `setMenu`), context menus, `Tray`
  (`setMenu`), and toolbar pull-downs (`ToolbarItemDef.menu`).
- App/tray menus are **rebuild-only**: `Menu.setMenu(items)` (`menu.ts:93`) and
  `Tray.setMenu(items)` (`tray.ts:245`) replace the whole menu; there is no
  per-item native update. The toolbar alone has `win.toolbar.updateItem(id, patch)`.
- Action dispatch: menu items ride `__menu:click` (`{id}`), toolbar buttons ride
  `TOOLBAR_CLICKED` (`{windowId,id}`), segments ride `TOOLBAR_GROUP_SELECTED`
  (`{windowId,id,index,selected}`). The runtime looks up the registered closure
  by id and currently calls it as `fn()` (`window.ts` `wireToolbarClicks` /
  `wireToolbarMenuClicks` / `wireToolbarGroupSelect`; `menu.ts`/`tray.ts` action
  maps). Adding an argument → `fn(ctx)` is **non-breaking** (existing `() => {}`
  ignores it).
- `ToolbarItemDef` (`runtime/window.ts:331`) is one flat interface; every field
  optional; `type` is a string union. `normalizeToolbar` (~665) reads fields
  loosely. Nim `ToolbarItemOpt` is a flat wire struct (unchanged by the TS union).

## Decisions (from brainstorm)

1. **Context arg** (not `this`-binding, not return-a-patch): `action: (ctx) => …`.
2. **Collapsed `ctx.update` semantic:** `ctx.update(patch)` always patches **the
   item the action is on**, on every surface. No `ctx.parent` (the only reason it
   existed was the radio whole-menu rebuild, which auto-radio removes). The rare
   "update my owning toolbar button from a pull-down action" → `ctx.window.toolbar.updateItem(buttonId, patch)`;
   a `ctx.parent` convenience can be added later, purely additively.
3. **Unify across all menu-like surfaces** (app/context/tray/toolbar/segments).
4. **Live per-item update for app + tray menus too** — implemented in the runtime
   (hold the menu tree, patch, re-`setMenu`); no new native API. Context menus are
   ephemeral → `ctx.update` is a documented no-op there.
5. **Auto-radio IN SCOPE:** `MenuItemDef.radioGroup?: string`. Same-group items in
   a menu are single-select; selecting one auto-moves the checkmark (the runtime
   sets the clicked item `checked` + unchecks same-group siblings in the held tree
   + rebuilds) — **no `update` call needed** for the moving-checkmark case. Runtime
   only (reuses the Part A+ held-tree rebuild); native menus just re-render.

## Part A — `ActionContext`

### Type (uniform shape everywhere)

```ts
export interface ActionContext {
  /** This item's id. */
  id: string;
  /** The window the action fired in (Window.current()). */
  window: WindowHandle;
  /** Live per-item update — patches THE ITEM THE ACTION IS ON, on every surface:
   *  toolbar item → updateItem; toolbar pull-down item → patch this menu item
   *  (rebuild parent menu); app/tray menu item → patch held tree + re-setMenu.
   *  Context menus are dismissed on click → no-op (documented). */
  update(patch: MenuItemPatch | ToolbarItemPatch): void;
  /** Checkable menu items: the item's `checked` state as last set (for non-radio
   *  toggles; radio checkmarks are auto-managed — see Auto-radio). */
  checked?: boolean;
  /** Segments: the activated segment index + its (transient) selected state. */
  index?: number;
  selected?: boolean;
}
```

No `ctx.parent` (collapsed semantic, Decision 2). To update a pull-down's owning
toolbar button from a menu item's action, use
`ctx.window.toolbar.updateItem(buttonId, patch)`.

`MenuItemPatch` (new, small): `{ label?; checked?; enabled?; icon? }` — the live-
patchable subset of a `MenuItemDef`. `ToolbarItemPatch` already exists.

### Per-surface `update()` wiring

| Surface | `ctx.update(patch)` patches THIS item by |
|---|---|
| Toolbar button | `win.toolbar.updateItem(id, patch)` |
| Toolbar pull-down item | patch this item in the parent's held menu tree → `win.toolbar.updateItem(parentId, { menu: rebuilt })` |
| App menu item | patch the held app-menu tree → re-`Menu.setMenu(rebuilt)` |
| Tray menu item | patch the held tray-menu tree → re-`tray.setMenu(rebuilt)` |
| Context menu item | no-op (menu dismissed) |
| Segment | `win.toolbar.updateItem(groupId, { selected })`-style group update |

The action callback signature changes to `(ctx?: ActionContext) => void` on
`MenuItemDef`, `ToolbarItemDef`, and `ToolbarSegmentDef`. The runtime constructs
the appropriate `ctx` at dispatch time (it knows the surface, the id, and the
window) and calls `fn(ctx)`.

## Part A+ — App/Tray menu-tree retention + live update

Today the runtime strips actions and forwards the clean items to native, keeping
only an id→action map. To support `ctx.update`, it must additionally **retain the
menu tree** (the clean `MenuItemDef[]` last set) per surface:

- **App menu:** `Menu.setMenu(items)` retains the tree (module state). `ctx.update`
  on a menu item walks the tree by id, applies the patch (label/checked/enabled/
  icon), and re-runs `setMenu` with the patched tree (re-stripping actions).
- **Tray:** `Tray.setMenu` already keeps `menuActionsByTray`; extend it to retain
  the tree per tray id. `ctx.update` patches + re-sends `tray:setMenu`.
- Re-`setMenu` is the existing native path (full rebuild) — no new native API.
  Menus are small; rebuild cost is negligible.

The patch-by-id walk + tree retention is pure runtime + unit-testable.

## Part A++ — Auto-radio menus

`MenuItemDef` gains `radioGroup?: string`. Items sharing a `radioGroup` value
within a menu are a single-select group: exactly one is `checked`. When the user
clicks a `radioGroup` item, **before/around firing its action** the runtime
auto-moves the checkmark — in the held menu tree it sets the clicked item
`checked: true` and the same-group siblings `checked: false`, then rebuilds the
surface (the Part A+ patch-held-tree-and-rebuild). The app's action just runs its
logic; no `update` call is needed for the checkmark.

- Pure **runtime** (reuses Part A+ tree retention + rebuild); native menus only
  re-render the rebuilt tree. No native menu-state API.
- Initial selection = whichever item the app set `checked: true` on.
- Works on every menu surface that retains its tree (app menu, tray, toolbar
  pull-down). Context menus are ephemeral — `radioGroup` is honored for the
  initial checkmark but there is nothing to re-render after dismissal.
- Unit-testable: clicking a group item updates the held tree's checked states
  correctly (one on, siblings off) and triggers exactly one rebuild.

This makes the filter the cleanest case: `{ id, label, radioGroup: "filter",
checked: filter === "unread", action: (ctx) => setFilter("unread") }` — the
checkmark moves itself.

## Part B — Discriminated-union `ToolbarItemDef`

Convert the flat interface into a union on `type` (TS author-side only; the Nim
wire struct is unchanged):

```ts
type ToolbarItemDef =
  | ToolbarButtonDef        // type?: "button"; id: string; label?; icon?; action?; menu?; enabled?; indicator?; style?; tintColor?; badge?; bordered?
  | ToolbarLabelDef         // type: "label"; id?: string; text: string   (Part C)
  | ToolbarSegmentedDef     // type: "segmented"; id: string; segments; selectionMode?; selected?; controlRepresentation?
  | ToolbarGroupDef         // type: "group"; id: string; items; controlRepresentation?
  | ToolbarTrackingSepDef   // type: "trackingSeparator"; pane?: "sidebar" | "inspector"
  | ToolbarSystemDef;       // type: "toggleSidebar" | "toggleInspector" | "space" | "flexibleSpace"
```

- `id` becomes **required** on button/segmented/group (matches the runtime
  validation that already throws without it) and on label is optional.
- System items (`space`/`flexibleSpace`/`toggleSidebar`/`toggleInspector`/
  `trackingSeparator`) accept **only** their valid fields — no `action`, `badge`,
  `menu`, `style`, etc.
- `normalizeToolbar` narrows by `type` (or casts at the branch it already
  switches on) where it reads type-specific fields. `ToolbarItemPatch` (updateItem)
  stays a permissive patch type (patches are intentionally cross-cutting).
- This is the one mild migration risk: existing call sites that omit `id` on a
  button, or set a stray field on a system item, become type errors — but those
  were already runtime-invalid. The kitchen-sink + tests get a pass.

## Part C — `type: "label"` text item

`{ type: "label"; id?: string; text: string }` → a non-interactive
`NSToolbarItem` whose `view` is a centered `NSTextField` (label style) showing
`text`. Live-updatable via `updateItem(id, { text })` (add `text` to
`ToolbarItemPatch`). Full stack: TS union variant → Nim `ToolbarItemOpt.text`
field + serialize/parse → `toolbar.m` builder arm (NSTextField view) →
kitchen-sink showcase + api-reference.

## Migration / compatibility

- All callback changes are **additive** (`() => void` still satisfies
  `(ctx?) => void`). Existing apps compile unchanged; the kitchen-sink migrates
  its filter to `ctx.parent.update`.
- The discriminated union (B) is the only source of new TS errors, and only for
  already-invalid item shapes.

## Testing

- TS unit (bun): `ActionContext` construction per surface (id/window/payload);
  the menu-tree patch-by-id walk (app/tray) round-trips a patch; the discriminated
  union accepts valid shapes + rejects invalid (type-level `// @ts-expect-error`);
  `normalizeToolbar` still emits correct wire for each variant.
- Nim unit: `ToolbarItemOpt.text` serialize/parse round-trip (Part C).
- Builds: macOS `[zapp] build complete:` + iOS-sim cross-compile.
- Human visual smoke: filter checkmark moves via `ctx.parent.update`; an app-menu
  and tray-menu checkmark toggles via `ctx.update`; a `type:"label"` toolbar item
  renders its text + updates live.

## Plan shape (proposed — decomposed)

1. **T1** — `ActionContext` type + `MenuItemPatch` + the dispatch wiring for
   TOOLBAR surfaces (button + pull-down item `ctx.update`), TDD. Migrate the
   kitchen-sink filter button to receive `ctx` (interim: `ctx.update`).
2. **T2** — App/Tray menu-tree retention + `ctx.update` (patch held tree +
   re-setMenu) + pass `ctx` to menu/tray actions, TDD.
3. **T3** — Auto-radio: `MenuItemDef.radioGroup` + the runtime auto-checkmark
   (patch held tree on group-item click + rebuild), TDD. Migrate the filter to
   `radioGroup` (drop the manual refresh).
4. **T4** — Discriminated-union `ToolbarItemDef` + `normalizeToolbar` narrowing +
   type tests; fix any kitchen-sink fallout.
5. **T5** — `type:"label"` text item full stack (TS variant + Nim + toolbar.m +
   patch `text`).
6. **T6** — kitchen-sink showcase (ctx-update + auto-radio across toolbar
   pull-down / app-menu / tray + a label item) + api-reference docs + full gates
   + human visual smoke.

## Non-goals / follow-ups

- **`ctx.parent`** (a pull-down item reaching its owning toolbar button) — dropped
  in favor of the collapsed `ctx.update` semantic; can be added later, purely
  additively, if the "button reflects selection" pattern proves common.
- Context-menu live update (ephemeral; `ctx.update` is a no-op; `radioGroup` only
  sets the initial checkmark).
- Per-segment `ctx.update` beyond the group `selected` (segments are create-time
  shaped; v1 exposes index/selected payload + group update).
- iOS (menus/toolbar are macOS chrome).
