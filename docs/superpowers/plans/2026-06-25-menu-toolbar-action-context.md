# Unified Menu/Toolbar Action Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every menu-like action callback a consistent `ctx` argument (`action: (ctx) => …`) with `ctx.id`, `ctx.window`, payload, and a uniform `ctx.update(patch)` that patches the item it fired on — across app menus, context menus, tray menus, toolbar buttons, toolbar pull-downs, and segments — plus auto-radio menus, a discriminated-union `ToolbarItemDef`, and a `type:"label"` text item.

**Architecture:** The callback signature widens from `() => void` to `(ctx?: ActionContext) => void` (non-breaking: a zero-arg closure still satisfies it). Each of the four `__menu:click`/toolbar dispatch sites already knows its surface, so each constructs its own surface-appropriate `ctx` at dispatch time. App/tray/pull-down menus retain their original `MenuItemDef[]` tree so `ctx.update` can patch one item and re-send the whole menu (toolbar items keep their existing per-item `updateItem`). A pure `patchMenuTree` helper does the patch; a pure `applyRadioSelection` helper does auto-radio. Context menus get `ctx` + payload only (ephemeral — `update` is a no-op).

**Tech Stack:** TypeScript runtime (`runtime/*.ts`, `bun test`, `bun run check` = tsc), Nim native (`native/nim/window.nim`), Objective-C (`native/platform/darwin/toolbar.m`), kitchen-sink demo app.

## Global Constraints

- Branch `feat/nim-native`, kept **UNMERGED** — do NOT merge to main.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Staging discipline:** explicit per-file `git add <path>` only. NEVER `git add -A` / `git add .` — the working tree has unrelated pre-existing WIP under `assets/`, `benchmarks/`, `vendor/`, `spikes/`, plus untracked files that must not be swept into commits.
- **Always use Bun, never Node.** Tests: `bun test`. Type-check: `bun run check`. macOS build: `cd kitchen-sink && bun run build` (success = a line `[zapp] build complete:` + fresh binary, NOT just Vite `✓ built`).
- **Non-breaking:** existing `action: () => void` call sites must still compile and run unchanged.
- **macOS-only feature surface** (menus + toolbar are macOS chrome). The Nim `text` field added in T5 must still cross-compile for iOS-sim (the existing iOS-sim build gate must stay green) — it is a plain field, no iOS native arm.
- Context menus receive `ctx` + payload but `ctx.update` is a **no-op** (the menu is dismissed on click).

---

### Task 1: ActionContext core + toolbar dispatch wiring (RISK GATE)

**Files:**
- Create: `runtime/action-context.ts` — `ActionContext`, `MenuItemPatch`, pure `patchMenuTree`
- Create: `runtime/action-context.test.ts` — `patchMenuTree` + type tests
- Modify: `runtime/menu.ts:33` — widen `MenuItemDef.action` type
- Modify: `runtime/window.ts` — widen `ToolbarItemDef.action`, `ToolbarSegmentDef.action`, `ToolbarItemPatch.action` types; widen the action `Map` types; rewrite `wireToolbarClicks` (507), `wireToolbarGroupSelect` (517), `wireToolbarMenuClicks` (533) to call `fn(ctx)`; retain pull-down menu trees in `setItems` (1118) / `updateItem` (1142)
- Modify: `kitchen-sink/src/shell/toolbar-def.ts` — migrate filter `pickFilter` to take `ctx`

**Interfaces:**
- Produces:
  - `interface MenuItemPatch { label?: string; checked?: boolean; enabled?: boolean; icon?: string; }`
  - `interface ActionContext { id: string; window: WindowHandle; update(patch: MenuItemPatch): void; checked?: boolean; index?: number; selected?: boolean; }`
  - `function patchMenuTree(tree: MenuItemDef[], id: string, patch: MenuItemPatch): MenuItemDef[]` — returns a new tree (deep-copied items) with the item whose `id === id` shallow-merged with `patch`; recurses into `submenu`.
- Consumes: `MenuItemDef` (`runtime/menu.ts`), `WindowHandle` (`runtime/window.ts:880`), `Window.current()` (`runtime/window.ts:1208`), `ToolbarHandle.updateItem` (`runtime/window.ts:426`).

- [ ] **Step 1: Write the failing test for `patchMenuTree`**

Create `runtime/action-context.test.ts`:

```ts
import { test, expect } from "bun:test";
import { patchMenuTree } from "./action-context";
import type { MenuItemDef } from "./menu";

test("patchMenuTree merges patch into the matching item, leaves others, deep-copies", () => {
  const tree: MenuItemDef[] = [
    { id: "all", label: "All", checked: true, action: () => {} },
    { id: "unread", label: "Unread", checked: false, action: () => {} },
  ];
  const next = patchMenuTree(tree, "unread", { checked: true });
  expect(next).not.toBe(tree); // new array
  expect(next[1].checked).toBe(true);
  expect(next[0].checked).toBe(true); // untouched
  expect(tree[1].checked).toBe(false); // original not mutated
  expect(next[1].action).toBe(tree[1].action); // action preserved by reference
});

test("patchMenuTree recurses into submenu", () => {
  const tree: MenuItemDef[] = [
    { label: "View", submenu: [{ id: "wrap", label: "Wrap", checked: false }] },
  ];
  const next = patchMenuTree(tree, "wrap", { checked: true });
  expect(next[0].submenu![0].checked).toBe(true);
  expect(tree[0].submenu![0].checked).toBe(false);
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bun test runtime/action-context.test.ts`
Expected: FAIL — `Cannot find module './action-context'`.

- [ ] **Step 3: Create `runtime/action-context.ts`**

```ts
import type { MenuItemDef } from "./menu";
import type { WindowHandle } from "./window";

/** The live-patchable subset of a MenuItemDef (ctx.update on a menu item). */
export interface MenuItemPatch {
  label?: string;
  checked?: boolean;
  enabled?: boolean;
  icon?: string;
}

/** Context passed to every menu-like action callback. The same shape across app
 *  menus, context menus, tray menus, toolbar buttons, toolbar pull-downs and
 *  segments. `update` patches THE ITEM THE ACTION IS ON (no-op for context
 *  menus — they are dismissed on click). */
export interface ActionContext {
  /** This item's id. */
  id: string;
  /** The window the action fired in (Window.current()). */
  window: WindowHandle;
  /** Live per-item update. Toolbar item → updateItem; toolbar pull-down item →
   *  patch this menu item (rebuild the owning toolbar item's menu); app/tray
   *  menu item → patch held tree + re-setMenu; context menu → no-op. */
  update(patch: MenuItemPatch): void;
  /** Checkable menu items: the item's `checked` state as last set. */
  checked?: boolean;
  /** Segments: the activated segment index + its (transient) selected state. */
  index?: number;
  selected?: boolean;
}

/** Pure: return a new tree (items deep-copied) with the item whose id matches
 *  shallow-merged with `patch`. Recurses into submenu. Actions are preserved by
 *  reference so re-stripping/re-registering keeps them live. */
export function patchMenuTree(
  tree: MenuItemDef[],
  id: string,
  patch: MenuItemPatch,
): MenuItemDef[] {
  return tree.map((item) => {
    const next: MenuItemDef = item.submenu
      ? { ...item, submenu: patchMenuTree(item.submenu, id, patch) }
      : { ...item };
    if (next.id === id) Object.assign(next, patch);
    return next;
  });
}
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `bun test runtime/action-context.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Add type-level tests (compile-time, validated by tsc)**

Append to `runtime/action-context.test.ts`:

```ts
import type { ActionContext } from "./action-context";

// Type-level: a zero-arg closure must satisfy (ctx?) => void (non-breaking).
test("ActionContext callback accepts zero-arg closures", () => {
  const widened: (ctx?: ActionContext) => void = () => {};
  const ctxAware: (ctx?: ActionContext) => void = (ctx) => {
    ctx?.update({ checked: true });
  };
  expect(typeof widened).toBe("function");
  expect(typeof ctxAware).toBe("function");
});
```

- [ ] **Step 6: Widen the action callback types**

In `runtime/menu.ts:33`, change `action?: () => void;` to:
```ts
  action?: (ctx?: import("./action-context").ActionContext) => void;
```

In `runtime/window.ts`, change the three `action?: () => void;` declarations (on `ToolbarItemDef` ~331, the segment def `ToolbarSegmentDef`, and `ToolbarItemPatch:407`) to the same `(ctx?: ActionContext) => void` — add `import type { ActionContext, MenuItemPatch } from "./action-context";` at the top and use `action?: (ctx?: ActionContext) => void;`.

Widen the action map types: `runtime/window.ts:504` `toolbarActions` and `:530` `toolbarMenuActions` from `Map<string, () => void>` to `Map<string, (ctx?: ActionContext) => void>`. In `runtime/menu.ts` `collectActions` return type and in `tray.ts` `menuActionsByTray`/`collectActions`, and the `normalizeToolbar` `actions`/`menuActions` maps (`runtime/window.ts:665+`), widen the same way.

- [ ] **Step 7: Run tsc; verify clean**

Run: `bun run check`
Expected: no errors (existing `() => {}` call sites still satisfy `(ctx?) => void`).

- [ ] **Step 8: Retain pull-down menu trees + reverse owner map**

In `runtime/window.ts`, near the toolbar action maps (~504), add:
```ts
// Retained ORIGINAL pull-down menu trees (with actions) so a pull-down item's
// ctx.update can patch the item + re-send the owning toolbar item's whole menu.
// Keyed "windowId:itemId" (the owning toolbar item).
const toolbarMenuTrees = new Map<string, MenuItemDef[]>();
// Reverse: a pull-down menu item id → the "windowId:itemId" that owns it.
const toolbarMenuItemOwner = new Map<string, string>();
```

In `setItems` (1118) where it registers menu actions (~1137), and in `updateItem` (1142) where `patch.menu` is handled (~1156), after the existing `toolbarMenuActions` population, also record the tree. Add a helper near the maps:
```ts
function recordToolbarMenuTree(windowId: string, itemId: string, menu: MenuItemDef[]): void {
  const ownerKey = `${windowId}:${itemId}`;
  toolbarMenuTrees.set(ownerKey, menu);
  const walk = (items: MenuItemDef[]) => {
    for (const m of items) {
      if (m.id) toolbarMenuItemOwner.set(m.id, ownerKey);
      if (m.submenu) walk(m.submenu);
    }
  };
  walk(menu);
}
```
Call `recordToolbarMenuTree(windowId, item.id, item.menu)` for each toolbar item that has a `menu` in `setItems` (iterate the original `items` arg for those with `.menu`), and in `updateItem` call `recordToolbarMenuTree(windowId, id, patch.menu)` when `patch.menu !== undefined`. NOTE: the menu ids are auto-assigned by `normalizeToolbar`/`stripMenuActions` — pass the SAME tree object that was normalized so ids line up (the normalizer mutates ids onto the items in place; if it does not, capture the id-assigned tree it returns). Verify by reading `normalizeToolbar`/`stripMenuActions` (runtime/window.ts ~546) which assigns `__tbmenu_N` ids.

- [ ] **Step 9: Rewrite the three toolbar dispatch sites to build + pass `ctx`**

`wireToolbarClicks` (507) — toolbar button:
```ts
getBridge().on(eventName(WindowEvent.TOOLBAR_CLICKED), (payload: any) => {
  const windowId = payload?.windowId;
  const id = payload?.id;
  const fn = toolbarActions.get(`${windowId}:${id}`);
  if (!fn) return;
  const win = Window.current();
  fn({ id, window: win, update: (patch) => win.toolbar.updateItem(id, patch as any) });
});
```

`wireToolbarGroupSelect` (517) — segment:
```ts
getBridge().on(eventName(WindowEvent.TOOLBAR_GROUP_SELECTED), (payload: any) => {
  const windowId = payload?.windowId;
  const id = payload?.id;
  const index = payload?.index;
  const fn = toolbarActions.get(`${windowId}:${id}:${index}`);
  if (!fn) return;
  const win = Window.current();
  fn({ id, window: win, index, selected: payload?.selected,
       update: (patch) => win.toolbar.updateItem(id, patch as any) });
});
```

`wireToolbarMenuClicks` (533) — pull-down menu item (patches THIS item, rebuilds the owning toolbar item's menu):
```ts
getBridge().on("__menu:click", (payload: any) => {
  const id = typeof payload === "string" ? JSON.parse(payload).id : payload?.id;
  const fn = toolbarMenuActions.get(id);
  if (!fn) return; // not a toolbar pull-down item — app menu / tray handles it
  const win = Window.current();
  const ownerKey = toolbarMenuItemOwner.get(id); // "windowId:itemId"
  const update = (patch: MenuItemPatch) => {
    if (!ownerKey) return;
    const tree = toolbarMenuTrees.get(ownerKey);
    if (!tree) return;
    const itemId = ownerKey.slice(ownerKey.indexOf(":") + 1);
    const patched = patchMenuTree(tree, id, patch);
    toolbarMenuTrees.set(ownerKey, patched);
    win.toolbar.updateItem(itemId, { menu: patched } as any);
  };
  fn({ id, window: win, update });
});
```
Add `import { patchMenuTree } from "./action-context";` (value import) at the top of `window.ts`.

- [ ] **Step 10: Migrate the kitchen-sink filter to receive `ctx`**

In `kitchen-sink/src/shell/toolbar-def.ts`, change `pickFilter` and the menu actions to take `ctx` (interim — radioGroup lands in T3):
```ts
import { Events, Window, type MenuItemDef, type ToolbarItemDef } from "@zappdev/runtime";
// ...
export function filterMenu(): MenuItemDef[] {
  return [
    { id: "kf-all", label: "All", checked: filter === "all",
      action: (ctx) => { setFilter("all"); ctx?.update({ checked: true }); } },
    { id: "kf-unread", label: "Unread", checked: filter === "unread",
      action: (ctx) => { setFilter("unread"); ctx?.update({ checked: true }); } },
    { id: "kf-flagged", label: "Flagged", checked: filter === "flagged",
      action: (ctx) => { setFilter("flagged"); ctx?.update({ checked: true }); } },
  ];
}
```
Delete the old `pickFilter` and its `Window.current().toolbar.updateItem(...)` body. (Note: `ctx.update({checked:true})` only checks the clicked item; siblings still show their old checkmark until T3's radioGroup. This interim state is acceptable — the gate verifies the action fires + the clicked item checks.)

- [ ] **Step 11: tsc + build + commit**

Run: `bun run check` (expect clean) then `bun test runtime/action-context.test.ts` (expect PASS) then `cd kitchen-sink && bun run build` (expect `[zapp] build complete:`).
```bash
cd /Users/zach/code/zapp
git add runtime/action-context.ts runtime/action-context.test.ts runtime/menu.ts runtime/window.ts kitchen-sink/src/shell/toolbar-def.ts
git commit -m "feat(actions): ActionContext + toolbar ctx dispatch (button/segment/pull-down)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 12: RISK GATE — human visual smoke**

STOP and ask the human to run the kitchen-sink app and confirm: (a) clicking the toolbar **Filter** pull-down and choosing an item still fires (the filter state changes); (b) the chosen item shows a checkmark; (c) toolbar buttons (Compose/Inbox) and the segmented controls still fire. Do not proceed to Task 2 until confirmed. This gate exists because Steps 8–9 refactor every toolbar dispatch site — a regression here is invisible to the unit tests.

---

### Task 2: App + Tray menu-tree retention + `ctx.update`

**Files:**
- Modify: `runtime/menu.ts` — retain the app-menu tree; build `ctx` in the `__menu:click` handler (85); `ctx.update` patches tree + re-`Menu.build`
- Modify: `runtime/tray.ts` — retain per-tray tree; build `ctx` in the `__menu:click` handler (162); `ctx.update` patches tree + re-`tray:setMenu`
- Modify: `runtime/action-context.test.ts` — add a retained-tree round-trip test

**Interfaces:**
- Consumes: `patchMenuTree`, `ActionContext`, `MenuItemPatch` (Task 1), `Window.current()`.
- Produces: app-menu and tray-menu actions now receive `ctx`; `ctx.update` works on both surfaces.

- [ ] **Step 1: Write the failing test (app-menu tree retention round-trip)**

The rebuild logic itself needs the bridge, but the patch step is pure. Add a focused test that the retained tree + a patch produces the expected re-send tree. In `runtime/action-context.test.ts`:

```ts
test("patchMenuTree round-trips a checkbox toggle for app/tray re-setMenu", () => {
  const held: MenuItemDef[] = [
    { id: "wrap", label: "Word Wrap", type: "checkbox", checked: false, action: () => {} },
  ];
  const next = patchMenuTree(held, "wrap", { checked: true });
  expect(next[0].checked).toBe(true);
  expect(next[0].action).toBe(held[0].action); // action survives → re-strip re-registers it
});
```

- [ ] **Step 2: Run it; verify it passes** (patchMenuTree already exists)

Run: `bun test runtime/action-context.test.ts`
Expected: PASS (the new test + prior tests).

This test guards the invariant Task 2 relies on (actions survive the patch so re-`setMenu` re-registers them).

- [ ] **Step 3: Retain the app-menu tree + pass `ctx`**

In `runtime/menu.ts`, refactor `Menu.build` (78) so the action map and the original `items` are module-level (replacing the per-call closure that leaks listeners). Add near the top:
```ts
let appMenuTree: MenuItemDef[] = [];
let appMenuActions = new Map<string, (ctx?: ActionContext) => void>();
let appMenuWired = false;
```
(Add `import type { ActionContext, MenuItemPatch } from "./action-context";` and `import { patchMenuTree } from "./action-context";`.)

In `Menu.build(items)`: set `appMenuTree = items;` `appMenuActions = collectActions(items);` post `setMenu` with `stripActions(items)`; wire the listener once:
```ts
if (!appMenuWired) {
  appMenuWired = true;
  Events.on("__menu:click", (payload: any) => {
    const id = typeof payload === "string" ? JSON.parse(payload).id : payload?.id;
    const fn = appMenuActions.get(id);
    if (!fn) return;
    const win = Window.current();
    const update = (patch: MenuItemPatch) => {
      appMenuTree = patchMenuTree(appMenuTree, id, patch);
      (getBridge() as any).post(JSON.stringify({ t: 4, m: "setMenu", a: { items: stripActions(appMenuTree) } }));
    };
    fn({ id, window: win, update });
  });
}
```
This also fixes the pre-existing listener-accumulation bug (one listener, module state). Import `Window` if not already imported.

- [ ] **Step 4: Retain per-tray trees + pass `ctx`**

In `runtime/tray.ts`, add a module map beside `menuActionsByTray` (145):
```ts
const menuTreesByTray = new Map<number, MenuItemDef[]>();
```
In `Tray.create` (213) and `setMenu` (245), after setting `menuActionsByTray`, also `menuTreesByTray.set(id, opts.menu /* or items */);`.

In the tray `__menu:click` handler (162), thread `ctx`. Replace the `handler()` loop so it knows which tray id matched:
```ts
Events.on("__menu:click", (payload: any) => {
  const data = typeof payload === "string" ? JSON.parse(payload) : payload;
  const itemId = data?.id;
  if (!itemId) return;
  for (const [trayId, actions] of menuActionsByTray) {
    const handler = actions.get(itemId);
    if (!handler) continue;
    const win = Window.current();
    const update = (patch: MenuItemPatch) => {
      const tree = menuTreesByTray.get(trayId);
      if (!tree) return;
      const patched = patchMenuTree(tree, itemId, patch);
      menuTreesByTray.set(trayId, patched);
      postAction("tray:setMenu", { id: trayId, items: stripActions(patched) });
    };
    handler({ id: itemId, window: win, update });
    return;
  }
});
```
Add the `ActionContext`/`MenuItemPatch`/`patchMenuTree`/`Window` imports. Clean up the tray tree on destroy (where `menuActionsByTray.delete(id)` is called ~286, also `menuTreesByTray.delete(id)`).

- [ ] **Step 5: tsc + build + commit**

Run: `bun run check` (clean), `bun test` (all pass), `cd kitchen-sink && bun run build` (`[zapp] build complete:`).
```bash
cd /Users/zach/code/zapp
git add runtime/menu.ts runtime/tray.ts runtime/action-context.test.ts
git commit -m "feat(actions): app + tray menu ctx.update via retained tree + re-setMenu

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Auto-radio menus (`MenuItemDef.radioGroup`)

**Files:**
- Modify: `runtime/menu.ts` — add `radioGroup?: string` to `MenuItemDef`; export a pure `applyRadioSelection`
- Modify: `runtime/action-context.ts` OR `runtime/menu.ts` — `applyRadioSelection` (place beside `patchMenuTree` in `action-context.ts` for reuse)
- Modify: `runtime/window.ts`, `runtime/menu.ts`, `runtime/tray.ts` — at each `__menu:click` dispatch, BEFORE firing the action, if the clicked item has a `radioGroup`, auto-move the checkmark (patch held tree: clicked → checked, same-group siblings → unchecked) and re-send the surface
- Modify: `runtime/action-context.test.ts` — `applyRadioSelection` tests
- Modify: `kitchen-sink/src/shell/toolbar-def.ts` — filter → `radioGroup`, drop manual `ctx.update`

**Interfaces:**
- Produces: `function applyRadioSelection(tree: MenuItemDef[], selectedId: string, group: string): MenuItemDef[]` — returns a new tree where every item with `radioGroup === group` gets `checked = (item.id === selectedId)`; recurses into submenu.
- Consumes: `patchMenuTree` infrastructure, the retained trees from Tasks 1–2.

- [ ] **Step 1: Write the failing test for `applyRadioSelection`**

In `runtime/action-context.test.ts`:
```ts
import { applyRadioSelection } from "./action-context";

test("applyRadioSelection checks the selected item, unchecks same-group siblings", () => {
  const tree: MenuItemDef[] = [
    { id: "all", label: "All", radioGroup: "filter", checked: true },
    { id: "unread", label: "Unread", radioGroup: "filter", checked: false },
    { id: "other", label: "Other", checked: true }, // no group — untouched
  ];
  const next = applyRadioSelection(tree, "unread", "filter");
  expect(next[0].checked).toBe(false);
  expect(next[1].checked).toBe(true);
  expect(next[2].checked).toBe(true); // not in group
  expect(tree[1].checked).toBe(false); // original not mutated
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bun test runtime/action-context.test.ts`
Expected: FAIL — `applyRadioSelection` not exported (and `radioGroup` not yet on the type).

- [ ] **Step 3: Add `radioGroup` to `MenuItemDef` and implement `applyRadioSelection`**

In `runtime/menu.ts` `MenuItemDef` (25–41), add after `checked`:
```ts
  /** Single-select group key. Same-group items are radio-exclusive: selecting
   *  one auto-moves the checkmark (the runtime checks it + unchecks siblings).
   *  Set initial `checked: true` on the starting selection. */
  radioGroup?: string;
```
In `runtime/action-context.ts`, add:
```ts
export function applyRadioSelection(
  tree: MenuItemDef[],
  selectedId: string,
  group: string,
): MenuItemDef[] {
  return tree.map((item) => {
    const next: MenuItemDef = item.submenu
      ? { ...item, submenu: applyRadioSelection(item.submenu, selectedId, group) }
      : { ...item };
    if (next.radioGroup === group) next.checked = next.id === selectedId;
    return next;
  });
}
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `bun test runtime/action-context.test.ts`
Expected: PASS.

- [ ] **Step 5: Auto-move the checkmark at each dispatch site (before firing the action)**

In each of the three `__menu:click` dispatch handlers — `runtime/window.ts` `wireToolbarMenuClicks` (Task 1 Step 9), `runtime/menu.ts` app-menu handler (Task 2 Step 3), `runtime/tray.ts` handler (Task 2 Step 4) — after resolving the matched `fn`/`handler` and BEFORE calling it, look up the clicked item in the retained tree; if it has a `radioGroup`, auto-apply + re-send.

Add a shared helper in `runtime/action-context.ts`:
```ts
/** Find an item by id anywhere in a tree (incl. submenus). */
export function findMenuItem(tree: MenuItemDef[], id: string): MenuItemDef | undefined {
  for (const item of tree) {
    if (item.id === id) return item;
    if (item.submenu) {
      const hit = findMenuItem(item.submenu, id);
      if (hit) return hit;
    }
  }
  return undefined;
}
```
Then in the toolbar pull-down handler (`window.ts`), after computing `ownerKey`/`tree`:
```ts
const tree = ownerKey ? toolbarMenuTrees.get(ownerKey) : undefined;
const clicked = tree ? findMenuItem(tree, id) : undefined;
if (tree && ownerKey && clicked?.radioGroup) {
  const patched = applyRadioSelection(tree, id, clicked.radioGroup);
  toolbarMenuTrees.set(ownerKey, patched);
  const itemId = ownerKey.slice(ownerKey.indexOf(":") + 1);
  win.toolbar.updateItem(itemId, { menu: patched } as any);
}
```
(do this just before `fn({ id, window: win, update })`). In `menu.ts`: if `findMenuItem(appMenuTree, id)?.radioGroup`, `appMenuTree = applyRadioSelection(appMenuTree, id, group)` then re-post `setMenu` with `stripActions(appMenuTree)`. In `tray.ts`: same against `menuTreesByTray.get(trayId)` then `postAction("tray:setMenu", …)`. Add `applyRadioSelection`/`findMenuItem` imports.

- [ ] **Step 6: Migrate the kitchen-sink filter to `radioGroup`**

In `kitchen-sink/src/shell/toolbar-def.ts`, drop the manual `ctx?.update(...)` — the checkmark now moves itself:
```ts
export function filterMenu(): MenuItemDef[] {
  return [
    { id: "kf-all", label: "All", radioGroup: "filter", checked: filter === "all",
      action: () => setFilter("all") },
    { id: "kf-unread", label: "Unread", radioGroup: "filter", checked: filter === "unread",
      action: () => setFilter("unread") },
    { id: "kf-flagged", label: "Flagged", radioGroup: "filter", checked: filter === "flagged",
      action: () => setFilter("flagged") },
  ];
}
```

- [ ] **Step 7: tsc + build + commit**

Run: `bun run check`, `bun test`, `cd kitchen-sink && bun run build`.
```bash
cd /Users/zach/code/zapp
git add runtime/menu.ts runtime/action-context.ts runtime/window.ts runtime/tray.ts runtime/action-context.test.ts kitchen-sink/src/shell/toolbar-def.ts
git commit -m "feat(actions): auto-radio menus (MenuItemDef.radioGroup) — self-moving checkmark

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Discriminated-union `ToolbarItemDef`

**Files:**
- Modify: `runtime/window.ts` — replace the flat `ToolbarItemDef` interface (~331) with a discriminated union; cast the `normalizeToolbar` loop variable so internal heterogeneous reads keep compiling
- Create: `runtime/toolbar-types.test.ts` — `@ts-expect-error` type tests (validated by `bun run check`)

**Interfaces:**
- Produces: `type ToolbarItemDef = ToolbarButtonDef | ToolbarSegmentedDef | ToolbarGroupDef | ToolbarTrackingSepDef | ToolbarSystemDef` — per-type field narrowing. `id` required on button/segmented/group.
- Consumes: existing `ToolbarSegmentDef`, `ToolbarBadge`, `MenuItemDef`, `ToolbarItemPatch`.

- [ ] **Step 1: Write the failing type tests**

Create `runtime/toolbar-types.test.ts`:
```ts
import { test, expect } from "bun:test";
import type { ToolbarItemDef } from "./window";

test("discriminated ToolbarItemDef accepts valid shapes, rejects invalid", () => {
  const ok: ToolbarItemDef[] = [
    { id: "save", icon: "sf:tray", label: "Save", action: () => {} }, // button (type optional)
    { type: "space" },
    { type: "flexibleSpace" },
    { type: "trackingSeparator", pane: "inspector" },
    { type: "segmented", id: "view", segments: [{ id: "g", icon: "sf:square" }] },
    { type: "group", id: "nav", items: [{ id: "back", icon: "sf:chevron.left" }] },
  ];
  expect(ok.length).toBe(6);

  // @ts-expect-error — a system item must not allow an action.
  const bad1: ToolbarItemDef = { type: "space", action: () => {} };
  // @ts-expect-error — a button requires an id.
  const bad2: ToolbarItemDef = { icon: "sf:tray", label: "No id" };
  // @ts-expect-error — a separator must not carry a badge.
  const bad3: ToolbarItemDef = { type: "trackingSeparator", badge: { dot: true } };
  void bad1; void bad2; void bad3;
});
```

- [ ] **Step 2: Run tsc; verify the type tests FAIL (no `@ts-expect-error` satisfied yet)**

Run: `bun run check`
Expected: errors on the three `@ts-expect-error` lines saying "Unused '@ts-expect-error' directive" — because the current flat interface accepts those shapes, so the directive has nothing to suppress. (This is the RED state for type tests.)

- [ ] **Step 3: Replace the flat interface with a discriminated union**

In `runtime/window.ts`, replace `interface ToolbarItemDef { … }` (~331–388) with (carry over the exact field docs/types from the current interface — `style`, `tintColor`, `badge`, `indicator`, `bordered`, `controlRepresentation`, `selectionMode`, `selected`, etc.):
```ts
/** A toolbar button (the default item; `type` may be omitted). */
export interface ToolbarButtonDef {
  type?: "button";
  id: string;
  label?: string;
  icon?: string;
  action?: (ctx?: ActionContext) => void;
  menu?: MenuItemDef[];
  enabled?: boolean;
  indicator?: boolean;
  style?: "plain" | "prominent";
  tintColor?: string;
  badge?: { count: number } | { text: string } | { dot: true } | null;
  bordered?: boolean;
}
export interface ToolbarSegmentedDef {
  type: "segmented";
  id: string;
  segments: ToolbarSegmentDef[];
  selectionMode?: "one" | "momentary" | "select-any";
  selected?: number | number[];
  controlRepresentation?: "automatic" | "expanded" | "collapsed";
}
export interface ToolbarGroupDef {
  type: "group";
  id: string;
  items: ToolbarButtonDef[];
  controlRepresentation?: "automatic" | "expanded" | "collapsed";
}
export interface ToolbarTrackingSepDef {
  type: "trackingSeparator";
  pane?: "sidebar" | "inspector";
}
export interface ToolbarSystemDef {
  type: "toggleSidebar" | "toggleInspector" | "space" | "flexibleSpace";
}
export type ToolbarItemDef =
  | ToolbarButtonDef
  | ToolbarSegmentedDef
  | ToolbarGroupDef
  | ToolbarTrackingSepDef
  | ToolbarSystemDef;
```
Confirm the exact `selectionMode` union and any other field values against the current interface before deleting it — copy them verbatim. (Rename the existing per-segment def if it is already named `ToolbarSegmentDef`; reuse it.)

- [ ] **Step 4: Keep `normalizeToolbar` compiling (internal heterogeneous reads)**

`normalizeToolbar` (665) reads `item.pane`, `item.menu`, `item.action`, `item.segments`, etc. on the union — direct reads now type-error. At the top of its `for (const item of toolbar.items ?? [])` loop, add `const it = item as Record<string, any>;` and replace the type-specific field reads inside the loop with `it.<field>` (keep `item.type` working via `it.type`). This preserves the existing runtime behavior; the union is author-facing only. Do the same in any other internal consumer that iterates `ToolbarItemDef[]` and reads variant fields (e.g. `validateToolbar`, the group sub-item walk ~740).

- [ ] **Step 5: Run tsc; verify clean (type tests now pass)**

Run: `bun run check`
Expected: clean — the three `@ts-expect-error` directives are now satisfied (the union rejects those shapes) and `normalizeToolbar` compiles via the `it` cast.

- [ ] **Step 6: Run the full TS suite + build + commit**

Run: `bun test` (all pass — existing kitchen-sink toolbar defs still type-check), `bun run check`, `cd kitchen-sink && bun run build`. If a kitchen-sink toolbar item now type-errors (e.g. a system item with a stray field), fix the item — that is the union doing its job.
```bash
cd /Users/zach/code/zapp
git add runtime/window.ts runtime/toolbar-types.test.ts
git commit -m "feat(toolbar): discriminated-union ToolbarItemDef (per-type field narrowing)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `type:"label"` text toolbar item (full stack)

**Files:**
- Modify: `runtime/window.ts` — add `ToolbarLabelDef` to the union; emit `text` in `normalizeToolbar`; add `text?` to `ToolbarItemPatch` (396) + `TOOLBAR_PATCH_KEYS` (777) + `normalizeToolbarPatch` (782)
- Modify: `native/nim/window.nim` — add `text*: string` to `ToolbarItemOpt` (99); `of "label":` arm in `serializeToolbar` (~454) and `parseToolbarJson` (~523)
- Modify: `native/platform/darwin/toolbar.m` — `"label"` arm in `zapp_toolbar_parse_items` (~464) + the delegate builder (~370): an `NSToolbarItem` hosting a centered `NSTextField`
- Create/Modify: Nim toolbar serialize/parse test (same harness as the W2/GRP toolbar tests)
- Modify: `runtime/toolbar-types.test.ts` — add a `label` accept/reject case

**Interfaces:**
- Produces: `interface ToolbarLabelDef { type: "label"; id?: string; text: string; }` added to the `ToolbarItemDef` union; `ToolbarItemPatch.text?: string`; Nim `ToolbarItemOpt.text`.
- Consumes: the union from Task 4.

- [ ] **Step 1: Add the `label` type test (RED)**

In `runtime/toolbar-types.test.ts`, add:
```ts
test("ToolbarItemDef accepts a label item, rejects a label without text", () => {
  const ok: ToolbarItemDef = { type: "label", text: "Synced" };
  expect(ok.type).toBe("label");
  // @ts-expect-error — a label requires `text`.
  const bad: ToolbarItemDef = { type: "label" };
  void bad;
});
```
Run `bun run check` → FAIL (`label` not in the union yet; the `@ts-expect-error` is unsatisfied/`ok` errors).

- [ ] **Step 2: Add `ToolbarLabelDef` + emit `text` (TS)**

In `runtime/window.ts`: add `export interface ToolbarLabelDef { type: "label"; id?: string; text: string; }` and add `| ToolbarLabelDef` to the union. In `normalizeToolbar`, add a branch for `it.type === "label"` that pushes `{ type: "label", id: it.id, text: it.text }` (assign an id if absent, like other items). Add `text` to `ToolbarItemPatch` (396): `text?: string;`. Add `"text"` to the `TOOLBAR_PATCH_KEYS` set (777) and emit it in `normalizeToolbarPatch` (782) alongside `label`.

Run `bun run check` → the type tests pass.

- [ ] **Step 3: Nim field + serialize/parse (RED→GREEN)**

Write/extend the Nim toolbar test (mirror the W2-T3 / GRP-T2 serialize-parse round-trip test) asserting a `label` item with `text` survives `serializeToolbar` → `parseToolbarJson`. Run it → FAIL. Then in `native/nim/window.nim`: add `text*: string` to `ToolbarItemOpt` (99–116). In `serializeToolbar` (421–472) add `of "label":` before the `else` button arm, emitting `{"type":"label","id":...,"text":...}`. In `parseToolbarJson` (476–551) add explicit `"label"` handling that reads `text`. Run the Nim test → PASS.

- [ ] **Step 4: Native builder (toolbar.m)**

In `native/platform/darwin/toolbar.m`:
- In `zapp_toolbar_parse_items` (the `if/else if` chain ~428–464): add a `"label"` arm before the `else` that registers the id in `buttons` (so the delegate is asked to build it), carrying the `text`.
- In the delegate `toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:` (~210), before the default plain-button block (~370): add a `"label"` arm that creates an `NSToolbarItem`, builds an `NSTextField` via `[NSTextField labelWithString:text]` (non-editable, non-bezeled label), sets `item.view = textField`, sets `item.label`/`paletteLabel` to the text, and returns it. Match the surrounding memory/registration conventions used by the segmented/group arms.

- [ ] **Step 5: Build matrix + commit**

Run: `bun run check`, `bun test`, the Nim toolbar test, `cd kitchen-sink && bun run build` (`[zapp] build complete:`), and the iOS-sim build gate (must stay green — `text` is a plain field with no iOS arm).
```bash
cd /Users/zach/code/zapp
git add runtime/window.ts runtime/toolbar-types.test.ts native/nim/window.nim native/platform/darwin/toolbar.m <nim-test-file>
git commit -m "feat(toolbar): type:'label' text item (NSTextField) full stack

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Kitchen-sink showcase + docs + final gates (HUMAN VISUAL GATE)

**Files:**
- Modify: `kitchen-sink/src/shell/toolbar-def.ts` — add a `type:"label"` status item to the shell toolbar
- Modify: a kitchen-sink section (e.g. `kitchen-sink/src/sections/toolbar.ts` or a menu section) — demo `ctx.update` on an app menu and tray menu + an auto-radio menu
- Modify: `docs/api-reference.md` — `ActionContext` / `ctx.update`, `radioGroup`, `type:"label"`; update the "moving checkmark" section to the new patterns
- Modify: `docs/superpowers/sdd/progress.md` — note completion (if used)

**Interfaces:** Consumes everything from Tasks 1–5.

- [ ] **Step 1: Add a `label` item + verify it renders**

In `kitchen-sink/src/shell/toolbar-def.ts` `shellToolbar()`, add a `{ type: "label", id: "status", text: "All items" }` item (e.g. after the filter). Optionally wire `setFilter` to also `Window.current().toolbar.updateItem("status", { text: ... })` to demonstrate live label updates.

- [ ] **Step 2: Add an app-menu + tray `ctx.update` / radioGroup demo**

In a kitchen-sink section, add a small demo: an app menu (or tray menu) with a `radioGroup` set of options + a `checkbox` item toggled via `ctx.update({ checked: ... })`, so the showcase exercises ctx-update + auto-radio on the menu surfaces (not just the toolbar). Keep it minimal and labeled.

- [ ] **Step 3: Documentation**

In `docs/api-reference.md`: document the `ActionContext` argument (`id`, `window`, `update`, payload), the uniform `ctx.update(patch)` semantics per surface (toolbar/app/tray/pull-down + context-menu no-op), `MenuItemDef.radioGroup` (auto-checkmark), and the `type:"label"` toolbar item. Replace the existing "moving checkmark / pull-down self-refresh" guidance (the `pickFilter`/`updateItem` example) with the `radioGroup` pattern (and note `ctx.update` for manual cases).

- [ ] **Step 4: Full gates**

Run: `bun run check` (clean), `bun test` (all pass), `cd kitchen-sink && bun run build` (`[zapp] build complete:`), iOS-sim build gate (green).

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/toolbar-def.ts <kitchen-sink-section-file> docs/api-reference.md
git commit -m "docs+demo(actions): ctx-update + auto-radio + label showcase; api-reference

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: HUMAN VISUAL GATE**

STOP. Ask the human to run the kitchen-sink and confirm: (a) the toolbar **Filter** pull-down auto-moves its checkmark with NO manual refresh (radioGroup); (b) the `type:"label"` status text renders in the toolbar (and updates live if wired); (c) the app-menu / tray demo's `ctx.update` toggles a checkmark; (d) toolbar buttons/segments still fire. Do not consider the cycle complete until confirmed.

---

## Self-Review

**Spec coverage:**
- Part A (unified ActionContext) → T1 (toolbar) + T2 (app/tray) + context-menu ctx is the existing `__menu:click` one-shot, which T1's `toolbarMenuActions` lookup leaves untouched (context-menu listener keeps firing its own closure; `ctx` for it is a no-op `update` — documented; no code change needed since context-menu actions stay zero-arg and the spec marks its `update` absent). ✓
- Part A+ (app/tray live update) → T2. ✓
- Part A++ (auto-radio `radioGroup`) → T3. ✓
- Part B (discriminated union) → T4. ✓
- Part C (`type:"label"`) → T5. ✓
- Showcase + docs + gates → T6. ✓

**Note on context menus:** The spec says context-menu actions receive `ctx` with a no-op `update`. `runtime/context-menu.ts`'s one-shot handler currently calls `handler()`. To honor "same shape," T2 may optionally pass a no-op `ctx` there (`{ id, window: Window.current(), update: () => {} }`); since it is purely additive and the action is `(ctx?) =>`, leaving it zero-arg is also spec-compliant (the callback simply receives no ctx). Implementer's choice — if passing ctx, add `runtime/context-menu.ts` to T2's file list and commit.

**Placeholder scan:** No TBD/TODO; every code step has concrete code. The `<nim-test-file>` and `<kitchen-sink-section-file>` placeholders in commit commands are resolved by the implementer when they create/choose those files (named in the task's Files block).

**Type consistency:** `ActionContext`/`MenuItemPatch`/`patchMenuTree`/`applyRadioSelection`/`findMenuItem` names are consistent across T1–T3. `ToolbarItemDef` union member names (`ToolbarButtonDef`/`ToolbarSegmentedDef`/`ToolbarGroupDef`/`ToolbarTrackingSepDef`/`ToolbarSystemDef`/`ToolbarLabelDef`) consistent T4–T5. `radioGroup`/`text` field names consistent across TS + Nim.
