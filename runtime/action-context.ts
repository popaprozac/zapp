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

/** Pure: return a new tree where every item with `radioGroup === group` gets
 *  `checked = (item.id === selectedId)`. Recurses into submenu. Does not
 *  mutate the original tree. */
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
