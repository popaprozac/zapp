/**
 * Window — per-window handle with scoped event listening.
 *
 * @example
 * ```ts
 * import { Window, WindowEvent } from "@zappdev/runtime";
 *
 * // Default: visible:true → window auto-shows when content is ready,
 * // no manual show() needed. Just listen for events you actually care
 * // about (resize, focus, close, etc.).
 * const win = Window.current();
 * win.on(WindowEvent.RESIZE, (payload) => console.log(payload.size));
 *
 * // Want to delay showing yourself? Pass visible:false at create time
 * // and call win.show() when you're ready.
 * ```
 */

import { getBridge } from "./bridge";
import { WindowEvent, eventName, type WindowSizePayload, type WindowPayload, type ModalDismissedPayload, type SidebarResizedPayload } from "./events";
import type { Display } from "./screen";
import type { MenuItemDef } from "./menu";

/**
 * Native background materials (NSVisualEffectMaterial names). Used by the
 * window `vibrancy` option and `sidebar.material`. WindowEvent-style const —
 * `Material.Sidebar` autocompletes; plain string literals still type-check.
 * Keep in lockstep with the mapping in native/platform/darwin/window.m.
 */
export const Material = {
  Sidebar: "sidebar",
  HeaderView: "headerView",
  Titlebar: "titlebar",
  Menu: "menu",
  Popover: "popover",
  HudWindow: "hudWindow",
  FullScreenUI: "fullScreenUI",
  Sheet: "sheet",
  ContentBackground: "contentBackground",
  UnderWindowBackground: "underWindowBackground",
  UnderPageBackground: "underPageBackground",
  WindowBackground: "windowBackground",
} as const;
export type Material = (typeof Material)[keyof typeof Material];

/**
 * Per-traffic-light state. `disabled` greys the button, `hidden` removes
 * it entirely (leaves a gap unless paired with a custom titlebar).
 */
export type ButtonState = "enabled" | "disabled" | "hidden";

/** macOS traffic light button states (close / minimize / zoom). */
export interface TrafficLights {
  close?: ButtonState;
  minimize?: ButtonState;
  zoom?: ButtonState;
}

/** Options for creating a window (mirrors native WindowOptions). */
export interface WindowOptions {
  title?: string;
  url?: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  /**
   * Cosmetic — does the user see the window? Default `true` (auto-shows
   * when the bridge bootstrap signals ready, eliminating white flash).
   * Pass `false` to create the window hidden; call `show()` later when
   * your app decides it's ready. The window is fully created either way.
   */
  visible?: boolean;
  resizable?: boolean;
  closable?: boolean;
  minimizable?: boolean;
  maximizable?: boolean;
  fullscreen?: boolean;
  borderless?: boolean;
  transparent?: boolean;
  alwaysOnTop?: boolean;
  /**
   * macOS vibrancy / blur material (G12). When set, an
   * `NSVisualEffectView` is mounted behind the WebView with the
   * named material so the window background shows the system blur
   * (sidebar, hud, titlebar, etc.). Web content needs a
   * transparent / translucent CSS background — `body { background:
   * transparent }` or any color with alpha < 1 — for the effect to
   * be visible.
   *
   * Materials map to macOS `NSVisualEffectMaterial` constants:
   *   `"sidebar"`, `"headerView"`, `"titlebar"`, `"menu"`,
   *   `"popover"`, `"hudWindow"`, `"fullScreenUI"`, `"sheet"`,
   *   `"windowBackground"`, `"contentBackground"`,
   *   `"underWindowBackground"`, `"underPageBackground"`.
   *
   * No-op on iOS / Windows.
   */
  vibrancy?: Material;
  titleBarStyle?: "default" | "hidden" | "hiddenInset";
  /**
   * Atomic create-and-attach-as-sheet. Equivalent to creating the window
   * with `visible: false` then calling `parent.attachModal(modal)` — but
   * done in one native call so the modal never appears as a free-floating
   * window before the sheet wraps it. Pass either a `WindowHandle` or a
   * window ID string ("win-N").
   *
   * When set, `visible` is forced to `false` (the sheet's own appearance
   * is governed by `beginSheet:`, not the window's standalone visibility).
   *
   * @example
   * ```ts
   * const parent = Window.current();
   * const settings = await Window.create({
   *   title: "Settings", width: 500, height: 400,
   *   asSheetOf: parent,
   * });
   * // settings is now a sheet on parent — no manual attachModal needed.
   * ```
   */
  asSheetOf?: WindowHandle | string;
  /**
   * iOS sheet presentation style — only meaningful when `asSheetOf` is
   * also set. Maps to UIKit:
   * - `"page"` → `UIModalPresentationPageSheet` (default — swipeable
   *   card on iPhone, centered card on iPad)
   * - `"form"` → `UIModalPresentationFormSheet` (smaller centered card,
   *   better for short input dialogs on iPad)
   * - `"fullscreen"` → `UIModalPresentationFullScreen` (take-over modal,
   *   no swipe-to-dismiss; the modal must close itself)
   * - `"bottomSheet"` → drawer-style sheet using
   *   `UISheetPresentationController` (iOS 15+); pair with `detents` to
   *   support snap points (medium = half-screen, large = full).
   *
   * No-op on macOS (NSWindow.beginSheet is single-style).
   */
  presentation?: "page" | "form" | "fullscreen" | "bottomSheet";
  /**
   * iOS 15+ `UISheetPresentationController` snap points.
   * - `"small"` → ~25% (custom detent, iOS 16+; silently dropped on iOS 15)
   * - `"medium"` → ~50% (built-in)
   * - `"large"` → full sheet (built-in)
   *
   * Provide multiple to let users swipe between them. Ignored unless
   * `presentation` is `"bottomSheet"` (or any sheet on iOS 15+ that
   * supports sheetPresentationController). When omitted on
   * `bottomSheet`, defaults to `["medium", "large"]`.
   */
  detents?: ("small" | "medium" | "large")[];
  /**
   * Show the small drag-handle "grabber" at the top of an iOS sheet.
   * Makes the swipe-to-dismiss gesture obviously discoverable on
   * full-width iPhone sheets. iOS 15+ only.
   */
  grabber?: boolean;
  /**
   * Per-button state for the macOS traffic lights. Takes precedence over
   * the legacy `closable` / `minimizable` / `maximizable` booleans (those
   * remain as sugar: `false` maps to the corresponding button's
   * `"disabled"` state).
   *
   * @example
   * ```ts
   * Window.create({
   *   trafficLights: { close: "enabled", minimize: "disabled", zoom: "hidden" },
   * });
   * ```
   */
  trafficLights?: TrafficLights;
  /**
   * macOS — accept clicks on an unfocused window so the first click both
   * activates the window and triggers the target control. Default: `true`.
   */
  acceptFirstMouse?: boolean;
  /**
   * Center the window on the active screen at create time. Overrides
   * `x` / `y` when both are set. With `frameAutosaveName`, the saved
   * frame still wins on restore — `autoCenter` is the first-launch
   * fallback before any saved state exists.
   */
  autoCenter?: boolean;
  /**
   * Persist the window's frame (position + size) under this name. AppKit
   * stores it in NSUserDefaults and restores it on next launch — the
   * framework just exposes the knob. Use a stable per-window identifier
   * (e.g. `"main"`, `"settings"`) so the right frame restores to the
   * right window. Empty/omitted means no autosave.
   *
   * @example
   * ```ts
   * Window.create({ frameAutosaveName: "main" });
   * ```
   */
  frameAutosaveName?: string;
  /** Attach a native sidebar (NSSplitViewItem) to this window. macOS only. */
  sidebar?: SidebarOptions;
  /** Attach a native toolbar (NSToolbar). macOS only; no-op elsewhere. */
  toolbar?: ToolbarOptions;
}

/** Options for a native sidebar (NSSplitViewItem) attached to a window. */
export interface SidebarOptions {
  /** Entry URL/route for the sidebar webview (resolved like the window url). Required. */
  url: string;
  /** Initial width in points. Default 260. */
  width?: number;
  /** Divider drag limits. Defaults 180 / 400. */
  minWidth?: number;
  maxWidth?: number;
  /** User can collapse via system behaviors. Default true. */
  collapsible?: boolean;
  /** Start collapsed. Default false. */
  collapsed?: boolean;
  /** Background material. Default Material.Sidebar (liquid glass on macOS 26+). */
  material?: Material;
}

/** One toolbar item. `type` defaults to "button". */
export interface ToolbarItemDef {
  /** Identifier for custom buttons — REQUIRED for type "button" (keys
   *  click routing). Ignored for system types. Allowed charset: letters,
   *  digits, `.`, `_`, `-`. Prefixes `"zapp."` and `"NSToolbar"` are reserved. */
  id?: string;
  /** "button" (default) | system items. `toggleSidebar` is AppKit's
   *  standard sidebar button (auto-wired to the split view controller);
   *  `trackingSeparator` makes the toolbar divider track the sidebar
   *  split. Both require the window to have a `sidebar` (warned + dropped
   *  otherwise). */
  type?: "button" | "toggleSidebar" | "trackingSeparator" | "space" | "flexibleSpace";
  /** Tooltip; visible text in the "expanded" style. */
  label?: string;
  /** Icon via the shared resolver: "sf:<symbol>", file path, or data URL. */
  icon?: string;
  /** Creator-context callback (menu pattern). Stripped before the wire. */
  action?: () => void;
  /** Pull-down menu (NSMenuToolbarItem — e.g. Mail's filter button). Items
   *  are the same MenuItemDef used by Menu/ContextMenu/Tray; their `action`
   *  callbacks run in this (creator) context via the __menu:click pipeline. */
  menu?: MenuItemDef[];
  /** Buttons: enabled state. Default true. AppKit-validated, so it sticks
   *  across revalidation. Patchable via win.toolbar.updateItem. */
  enabled?: boolean;
  /** Menu buttons: show the pull-down chevron. Default true; false is the
   *  Messages-app no-chevron look. */
  indicator?: boolean;
}

/** Options for a native toolbar (NSToolbar) attached at Window.create. */
export interface ToolbarOptions {
  items: ToolbarItemDef[];
  /** NSWindow.toolbarStyle. Default "unified". macOS only. */
  style?: "unified" | "unifiedCompact" | "expanded";
}

/** Patch for one toolbar item (win.toolbar.updateItem). Omitted keys are
 * left unchanged on the live item. */
export interface ToolbarItemPatch {
  label?: string;
  /** Icon via the shared resolver: "sf:<symbol>", file path, or data URL. */
  icon?: string;
  enabled?: boolean;
  /** Menu buttons: show the pull-down chevron. */
  indicator?: boolean;
  /** REPLACES the pull-down menu (the moving-checkmark refresh). Actions
   *  are stripped + re-registered like setItems. */
  menu?: MenuItemDef[];
  /** Replaces the creator callback for this button. */
  action?: () => void;
}

/** Lifecycle handle for a window's NSToolbar — present on every
 * WindowHandle. macOS only; all ops no-op elsewhere. */
export interface ToolbarHandle {
  /** Replace the full item set; ATTACHES a toolbar when none exists
   *  (late-attach). `style` applies only on a fresh attach — native warns
   *  and ignores it when a toolbar is already present. */
  setItems(items: ToolbarItemDef[], opts?: { style?: "unified" | "unifiedCompact" | "expanded" }): void;
  /** In-place patch of one item by id. Unknown id → native warn + no-op. */
  updateItem(id: string, patch: ToolbarItemPatch): void;
  /** Destroy the toolbar. Chrome metrics re-inject (--zapp-titlebar-height
   *  shrinks back; --zapp-toolbar-height → 0px). No-op when none. */
  remove(): void;
}

/** Shared anchor vocabulary — also accepted by ContextMenu.show's anchor.
 * Element is measured at show time (one-shot); MouseEvent becomes a 1x1
 * point rect at clientX/Y; rects are pane-viewport CSS pixels. */
export type Anchor =
  | Element
  | { x: number; y: number; width?: number; height?: number }
  | MouseEvent;

/** Normalize any Anchor to the wire rect. Pure — unit-tested. */
export function normalizeAnchor(anchor: Anchor): { x: number; y: number; width: number; height: number } {
  if (anchor == null) {
    // The most common way to get here: `show(e.currentTarget)` after an
    // `await` — currentTarget is nulled when event dispatch ends. Spell
    // that out; the generic message below sends people in circles.
    throw new Error(
      "[zapp] anchor: got null/undefined — if this was e.currentTarget, " +
      "capture it in a variable BEFORE any await (currentTarget is null once dispatch ends)",
    );
  }
  if (typeof (anchor as any)?.getBoundingClientRect === "function") {
    const r = (anchor as Element).getBoundingClientRect();
    return { x: r.left, y: r.top, width: r.width, height: r.height };
  }
  if (typeof (anchor as any)?.clientX === "number" && typeof (anchor as any)?.clientY === "number") {
    const e = anchor as MouseEvent;
    return { x: e.clientX, y: e.clientY, width: 1, height: 1 };
  }
  const r = anchor as { x: number; y: number; width?: number; height?: number };
  if (typeof r?.x !== "number" || typeof r?.y !== "number") {
    throw new Error("[zapp] anchor: invalid anchor — pass an Element, a MouseEvent, or {x, y, width?, height?}");
  }
  return { x: r.x, y: r.y, width: r.width ?? 1, height: r.height ?? 1 };
}

/** Options for a native popover (NSPopover) hosting trusted web content. */
export interface PopoverOptions {
  /** Entry URL/route — resolves like sidebar.url (app routes only). Required. */
  url: string;
  /** Content size in points. Defaults 320x400. */
  width?: number;
  height?: number;
  /** NSPopover.behavior. Default "transient" (auto-dismiss on outside click). */
  behavior?: "transient" | "semitransient" | "applicationDefined";
}

const POPOVER_BEHAVIORS = ["transient", "semitransient", "applicationDefined"];

/** Validate + default PopoverOptions. Pure — unit-tested. */
export function normalizePopoverOptions(opts: PopoverOptions): { url: string; width: number; height: number; behavior: string } {
  if (!opts?.url) throw new Error('[zapp] popover: "url" is required');
  const behavior = opts.behavior ?? "transient";
  if (!POPOVER_BEHAVIORS.includes(behavior)) {
    throw new Error(`[zapp] popover: invalid behavior "${behavior}"`);
  }
  return { url: opts.url, width: opts.width ?? 320, height: opts.height ?? 400, behavior };
}

/** A handle to a persistent popover. The pane webview loads once at create
 * (warm); show()/hide() reuse it and page state survives; destroy() frees
 * the webview and its dispatch slot. */
export interface PopoverHandle {
  readonly id: string;
  show(anchor: Anchor | { toolbarItem: string }, opts?: { edge?: "top" | "bottom" | "left" | "right" }): void;
  hide(): void;
  destroy(): void;
}

/** Toolbar action callbacks keyed "<windowId>:<itemId>" — Menu.build's
 * collect/strip/listen shape (runtime/menu.ts), but per-window.
 * Hygiene: setItems/remove purge the window's entries; updateItem swaps
 * one entry. Only windows that never touch their toolbar again keep
 * entries for the app lifetime (create-time-only apps — the v1 behavior). */
const toolbarActions = new Map<string, () => void>();
let toolbarClickWired = false;

function wireToolbarClicks(): void {
  if (toolbarClickWired) return;
  toolbarClickWired = true;
  getBridge().on(eventName(WindowEvent.TOOLBAR_CLICKED), (payload: any) => {
    const fn = toolbarActions.get(`${payload?.windowId}:${payload?.id}`);
    if (fn) fn();
  });
}

let tbMenuIdCounter = 0;
/** Toolbar pull-down menu actions, keyed by menu-item id ("__menu:click"
 * carries only the id — app-global like Menu.build; reused ids across
 * windows collide, same caveat as Menu). App-lifetime, like toolbarActions. */
const toolbarMenuActions = new Map<string, () => void>();
let toolbarMenuClickWired = false;

function wireToolbarMenuClicks(): void {
  if (toolbarMenuClickWired) return;
  toolbarMenuClickWired = true;
  getBridge().on("__menu:click", (payload: any) => {
    const id = typeof payload === "string" ? JSON.parse(payload).id : payload?.id;
    const fn = toolbarMenuActions.get(id);
    if (fn) fn();
  });
}

/** Strip `action` callbacks out of a MenuItemDef tree (recursing submenus),
 * collecting them into `out` keyed by (possibly auto-generated) id. Mirrors
 * context-menu.ts's collectAndStrip. */
function stripMenuActions(items: MenuItemDef[], out: Map<string, () => void>): any[] {
  return items.map((item) => {
    const clean: any = { ...item };
    if (clean.action) {
      if (!clean.id) clean.id = `__tbmenu_${++tbMenuIdCounter}`;
      out.set(clean.id, clean.action);
      delete clean.action;
    }
    if (clean.submenu) clean.submenu = stripMenuActions(clean.submenu, out);
    return clean;
  });
}

/** Per-window record of which menu-action ids each toolbar item registered
 * (windowId → itemId → menu ids). Lets setItems/updateItem/remove purge
 * exactly what that window's toolbar put into the app-global
 * toolbarMenuActions map. */
const toolbarMenuIdsByWindow = new Map<string, Map<string, Set<string>>>();

/** Remove a window's toolbar registrations from both action maps.
 * Maps are injected for unit tests; production callers pass the module
 * maps. */
export function purgeWindowToolbarActions(
  windowId: string,
  actions: Map<string, () => void>,
  menuActions: Map<string, () => void>,
  menuIdsByWindow: Map<string, Map<string, Set<string>>>,
): void {
  for (const key of [...actions.keys()]) {
    if (key.startsWith(`${windowId}:`)) actions.delete(key);
  }
  const perItem = menuIdsByWindow.get(windowId);
  if (perItem) {
    for (const ids of perItem.values()) {
      for (const mid of ids) menuActions.delete(mid);
    }
    menuIdsByWindow.delete(windowId);
  }
}

/** Remove the menu-action ids previously registered for ONE item
 * (updateItem with a replacement menu). */
export function purgeItemToolbarMenuActions(
  windowId: string,
  itemId: string,
  menuActions: Map<string, () => void>,
  menuIdsByWindow: Map<string, Map<string, Set<string>>>,
): void {
  const perItem = menuIdsByWindow.get(windowId);
  const ids = perItem?.get(itemId);
  if (!ids) return;
  for (const mid of ids) menuActions.delete(mid);
  perItem!.delete(itemId);
}

/** Record which menu ids a window's items registered (merges per item). */
export function recordToolbarMenuIds(
  windowId: string,
  menuIdsByItem: Map<string, Set<string>>,
  menuIdsByWindow: Map<string, Map<string, Set<string>>>,
): void {
  if (menuIdsByItem.size === 0) return;
  let perItem = menuIdsByWindow.get(windowId);
  if (!perItem) {
    perItem = new Map();
    menuIdsByWindow.set(windowId, perItem);
  }
  for (const [itemId, ids] of menuIdsByItem) perItem.set(itemId, ids);
}

/** Guard for ToolbarHandle.setItems: an empty (post-validation) item set
 * is almost always a mistake — native keeps the old toolbar and the purge
 * would have killed its callbacks. Exported for tests. */
export function assertToolbarItemsNonEmpty(json: string): void {
  if (JSON.parse(json).items.length === 0) {
    throw new Error("[zapp] toolbar: setItems with no items — use toolbar.remove() to destroy the toolbar");
  }
}

/** Validate a ToolbarOptions and split it into the wire JSON (actions
 * stripped, defaults applied) and the action maps. Pure — unit-tested. */
export function normalizeToolbar(
  toolbar: ToolbarOptions,
  hasSidebar: boolean,
): {
  json: string;
  actions: Map<string, () => void>;
  menuActions: Map<string, () => void>;
  menuIdsByItem: Map<string, Set<string>>;
} {
  const actions = new Map<string, () => void>();
  const menuActions = new Map<string, () => void>();
  const menuIdsByItem = new Map<string, Set<string>>();
  const seen = new Set<string>();
  const items: Record<string, unknown>[] = [];
  for (const item of toolbar.items ?? []) {
    const type = item.type ?? "button";
    if (type === "toggleSidebar" || type === "trackingSeparator") {
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      if (!hasSidebar) {
        console.warn(`[zapp] toolbar: "${type}" requires the window to have a sidebar — item dropped`);
        continue;
      }
      items.push({ type });
      continue;
    }
    if (type === "space" || type === "flexibleSpace") {
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      items.push({ type });
      continue;
    }
    if (!item.id) throw new Error('[zapp] toolbar: button items require an "id"');
    if (item.action && item.menu) {
      throw new Error('[zapp] toolbar: a button cannot have both "action" and "menu" — the menu consumes the click');
    }
    if (!/^[A-Za-z0-9._-]+$/.test(item.id) || item.id.startsWith("zapp.") || item.id.startsWith("NSToolbar")) {
      throw new Error(
        `[zapp] toolbar: invalid item id "${item.id}" — use letters, digits, ".", "_", "-" (ids prefixed "zapp." or "NSToolbar" are reserved)`,
      );
    }
    if (seen.has(item.id)) throw new Error(`[zapp] toolbar: duplicate item id "${item.id}"`);
    seen.add(item.id);
    if (item.action) actions.set(item.id, item.action);
    const wire: Record<string, unknown> = { type: "button", id: item.id, label: item.label ?? "", icon: item.icon ?? "" };
    if (item.enabled !== undefined) wire.enabled = item.enabled;
    if (item.indicator !== undefined) wire.indicator = item.indicator;
    if (item.menu) {
      const itemMenuActions = new Map<string, () => void>();
      wire.menu = stripMenuActions(item.menu, itemMenuActions);
      for (const [mid, fn] of itemMenuActions) menuActions.set(mid, fn);
      if (itemMenuActions.size > 0) menuIdsByItem.set(item.id, new Set(itemMenuActions.keys()));
    }
    items.push(wire);
  }
  return { json: JSON.stringify({ style: toolbar.style ?? "unified", items }), actions, menuActions, menuIdsByItem };
}

const TOOLBAR_PATCH_KEYS = new Set(["label", "icon", "enabled", "indicator", "menu", "action"]);

/** Validate a ToolbarItemPatch and split it into the wire JSON (only
 * patched keys, plus id), the replacement action, and stripped menu
 * actions. Pure — unit-tested. */
export function normalizeToolbarPatch(
  id: string,
  patch: ToolbarItemPatch,
): { json: string; action?: () => void; menuActions: Map<string, () => void> } {
  if (!id || !/^[A-Za-z0-9._-]+$/.test(id) || id.startsWith("zapp.") || id.startsWith("NSToolbar")) {
    throw new Error(
      `[zapp] toolbar: invalid item id "${id}" — use letters, digits, ".", "_", "-" (ids prefixed "zapp." or "NSToolbar" are reserved)`,
    );
  }
  const keys = Object.keys(patch ?? {});
  if (keys.length === 0) {
    throw new Error('[zapp] toolbar: empty patch — pass at least one of label/icon/enabled/indicator/menu/action');
  }
  for (const k of keys) {
    if (!TOOLBAR_PATCH_KEYS.has(k)) throw new Error(`[zapp] toolbar: unknown patch key "${k}"`);
  }
  if (patch.action && patch.menu) {
    throw new Error('[zapp] toolbar: a button cannot have both "action" and "menu" — the menu consumes the click');
  }
  const menuActions = new Map<string, () => void>();
  const wire: Record<string, unknown> = { id };
  if (patch.label !== undefined) wire.label = patch.label;
  if (patch.icon !== undefined) wire.icon = patch.icon;
  if (patch.enabled !== undefined) wire.enabled = patch.enabled;
  if (patch.indicator !== undefined) wire.indicator = patch.indicator;
  if (patch.menu !== undefined) wire.menu = stripMenuActions(patch.menu, menuActions);
  // Explicit-undefined values pass the keys.length guard above (key exists,
  // value is undefined) but produce a wire with only the id — detect here.
  if (Object.keys(wire).length === 1 && !patch.action) {
    throw new Error('[zapp] toolbar: empty patch — pass at least one of label/icon/enabled/indicator/menu/action');
  }
  return { json: JSON.stringify(wire), action: patch.action, menuActions };
}

/** A handle to the sidebar attached to a window. */
export interface SidebarHandle {
  toggle(): void;
  collapse(): void;
  expand(): void;
  setWidth(px: number): void;
  /** Tracked from SIDEBAR_COLLAPSED/EXPANDED events, seeded by the create option. */
  readonly collapsed: boolean;
  /** Last width from SIDEBAR_RESIZED (the create option until the first event). */
  readonly width: number;
}

/** Size events that include width/height/position data. */
type SizeEvent = WindowEvent.RESIZE | WindowEvent.MOVE | WindowEvent.MAXIMIZE | WindowEvent.RESTORE;

/** A handle to a specific window. */
export interface WindowHandle {
  readonly id: string;
  /** Handle for the sidebar attached to this window, if any. */
  readonly sidebar?: SidebarHandle;
  /** Lifecycle handle for this window's native toolbar (macOS). Always
   *  present — setItems attaches when no toolbar exists. */
  readonly toolbar: ToolbarHandle;

  on(event: SizeEvent, handler: (payload: WindowSizePayload) => void): () => void;
  on(event: WindowEvent.MODAL_DISMISSED, handler: (payload: ModalDismissedPayload) => void): () => void;
  on(event: WindowEvent.SIDEBAR_RESIZED, handler: (payload: SidebarResizedPayload) => void): () => void;
  on(event: WindowEvent, handler: (payload: WindowPayload) => void): () => void;

  show(): void;
  hide(): void;
  close(): void;
  setTitle(title: string): void;
  setSize(width: number, height: number): void;
  setPosition(x: number, y: number): void;
  minimize(): void;
  /** Raise this window and bring the app to the foreground (macOS). */
  setFocus(): void;
  maximize(): void;
  setFullscreen(on: boolean): void;
  setAlwaysOnTop(on: boolean): void;
  setCloseGuard(enabled: boolean): void;
  loadUrl(url: string): void;
  /** The display this window is currently on (top-left global coords). */
  getScreen(): Promise<Display>;

  /**
   * Attach `modal` as a sheet on this window. The modal slides down from
   * this window's titlebar and blocks interaction with the parent (only)
   * until dismissed. Closing the modal — via its close button,
   * `modal.close()`, or `modal.destroy()` — auto-dismisses the sheet.
   *
   * Honored options on the modal: `title`, `url`, `width`, `height`,
   * `transparent`, `webContentInspectable`. Position, fullscreen,
   * borderless, titleBarStyle, trafficLights, and alwaysOnTop are
   * meaningless for sheets and ignored.
   *
   * @example
   * ```ts
   * const modal = await Window.create({
   *   title: "Settings",
   *   width: 500, height: 400,
   *   visible: false,        // create hidden so it appears as a sheet
   * });
   * Window.current().attachModal(modal);
   * ```
   *
   * Currently macOS-only; no-op on Windows until WebView2 modal support
   * lands.
   */
  attachModal(modal: WindowHandle): void;

  /**
   * Dismiss a modal sheet without closing the modal window. Use
   * `modal.close()` (or `modal.destroy()`) when you also want the modal
   * gone — that path auto-detaches anyway.
   */
  detachModal(modal: WindowHandle): void;

  /** Create a persistent native popover owned by this window. macOS only. */
  createPopover(opts: PopoverOptions): Promise<PopoverHandle>;
}

/** Send a window action to native. Uses message type 4 (WINDOW_ACTION). */
function windowAction(action: string, args: Record<string, unknown> = {}): void {
  const bridge = getBridge();
  // Post raw message with t:4 for window actions (fire-and-forget)
  const msg = JSON.stringify({ t: 4, m: action, a: args });
  (bridge as any).post ? (bridge as any).post(msg) : bridge.emit("__window_action:" + action, args);
}

/**
 * Module-scope state records keyed by windowId. All SidebarHandle instances
 * for the same window share a single record so repeated Window.current()
 * calls in a sidebar see consistent collapsed/width values.
 */
const sidebarState = new Map<string, { collapsed: boolean; width: number }>();

/**
 * Track which windowIds have already had their three bridge listeners
 * registered. Prevents subscription accumulation when Window.current() is
 * called multiple times (each call constructs a new handle but must not
 * add another set of listeners to the global bus).
 */
const sidebarWired = new Set<string>();

/** Create a SidebarHandle that tracks collapsed/width state via events. */
function createSidebarHandle(
  windowId: string,
  initialCollapsed: boolean,
  initialWidth: number,
): SidebarHandle {
  // Seed the shared state record on first creation; leave it alone if a
  // previous handle already seeded it (state may have been updated by events).
  if (!sidebarState.has(windowId)) {
    sidebarState.set(windowId, { collapsed: initialCollapsed, width: initialWidth });
  }

  if (!sidebarWired.has(windowId)) {
    // Use bridge.on directly here — the WindowHandle being built isn't
    // returned yet, so handle.on() isn't available. bridge.on uses the same
    // event bus and the same windowId filter as handle.on() would.
    const bridge = getBridge();
    bridge.on(eventName(WindowEvent.SIDEBAR_COLLAPSED), (payload: any) => {
      if (payload?.windowId === windowId) {
        sidebarState.get(windowId)!.collapsed = true;
      }
    });
    bridge.on(eventName(WindowEvent.SIDEBAR_EXPANDED), (payload: any) => {
      if (payload?.windowId === windowId) {
        sidebarState.get(windowId)!.collapsed = false;
      }
    });
    bridge.on(eventName(WindowEvent.SIDEBAR_RESIZED), (payload: any) => {
      if (payload?.windowId === windowId && typeof payload.width === "number") {
        sidebarState.get(windowId)!.width = payload.width;
      }
    });
    sidebarWired.add(windowId);
  }

  return {
    get collapsed() { return sidebarState.get(windowId)!.collapsed; },
    get width()     { return sidebarState.get(windowId)!.width; },
    toggle()              { windowAction("sidebar:toggle",   { windowId }); },
    collapse()            { windowAction("sidebar:collapse", { windowId }); },
    expand()              { windowAction("sidebar:expand",   { windowId }); },
    setWidth(px: number)  { windowAction("sidebar:setWidth", { windowId, width: px }); },
  };
}

function createWindowHandle(windowId: string, sidebarOpts?: SidebarOptions): WindowHandle {
  const bridge = getBridge();

  return {
    id: windowId,

    on(event: WindowEvent, handler: (payload: any) => void): () => void {
      const name = eventName(event);
      return bridge.on(name, (payload: any) => {
        if (payload?.windowId === windowId) {
          handler(payload);
        }
      });
    },

    show()                            { windowAction("show", { windowId }); },
    hide()                            { windowAction("hide", { windowId }); },
    close()                           { windowAction("close", { windowId }); },
    setTitle(title: string)           { windowAction("setTitle", { windowId, title }); },
    setSize(width: number, h: number) { windowAction("setSize", { windowId, width, height: h }); },
    setPosition(x: number, y: number) { windowAction("setPosition", { windowId, x, y }); },
    minimize()                        { windowAction("minimize", { windowId }); },
    setFocus()                        { windowAction("setFocus", { windowId }); },
    maximize()                        { windowAction("maximize", { windowId }); },
    setFullscreen(on: boolean)        { windowAction("setFullscreen", { windowId, on }); },
    setAlwaysOnTop(on: boolean)       { windowAction("setAlwaysOnTop", { windowId, on }); },
    setCloseGuard(on: boolean)        { windowAction("setCloseGuard", { windowId, on }); },
    loadUrl(url: string)              { windowAction("loadUrl", { windowId, url }); },

    async getScreen(): Promise<Display> {
      const r = await bridge.invoke("__screen:forWindow", { windowId });
      return (typeof r === "string" ? JSON.parse(r) : r) as Display;
    },

    attachModal(modal: WindowHandle) {
      // Pass string IDs straight through — the native router resolves
      // pointer-based window IDs ("win-0xPTR") to internal numeric IDs.
      // Parsing on the JS side would fail for the actual pointer format
      // and the action would silently no-op.
      windowAction("attachModal", { windowId, parentId: windowId, modalId: modal.id });
    },
    detachModal(modal: WindowHandle) {
      windowAction("detachModal", { windowId, parentId: windowId, modalId: modal.id });
    },
    sidebar: sidebarOpts !== undefined
      ? createSidebarHandle(windowId, sidebarOpts.collapsed ?? false, sidebarOpts.width ?? 260)
      : undefined,

    toolbar: {
      setItems(items: ToolbarItemDef[], setOpts?: { style?: "unified" | "unifiedCompact" | "expanded" }) {
        const { json, actions, menuActions, menuIdsByItem } =
          normalizeToolbar({ items, style: setOpts?.style }, sidebarOpts !== undefined);
        // Parse once: guard on empty items, then conditionally strip style.
        // Only send style when the caller set one — native warns when style
        // arrives for an already-attached toolbar, and normalizeToolbar
        // always defaults it.
        const parsed = JSON.parse(json);
        assertToolbarItemsNonEmpty(json);
        if (setOpts?.style === undefined) delete parsed.style;
        const wireJson = JSON.stringify(parsed);
        purgeWindowToolbarActions(windowId, toolbarActions, toolbarMenuActions, toolbarMenuIdsByWindow);
        if (actions.size > 0) {
          wireToolbarClicks();
          for (const [id, fn] of actions) toolbarActions.set(`${windowId}:${id}`, fn);
        }
        if (menuActions.size > 0) {
          wireToolbarMenuClicks();
          for (const [id, fn] of menuActions) toolbarMenuActions.set(id, fn);
        }
        recordToolbarMenuIds(windowId, menuIdsByItem, toolbarMenuIdsByWindow);
        windowAction("toolbar:setItems", { windowId, toolbarJson: wireJson });
      },
      updateItem(id: string, patch: ToolbarItemPatch) {
        const { json, action, menuActions } = normalizeToolbarPatch(id, patch);
        if (action) {
          wireToolbarClicks();
          toolbarActions.set(`${windowId}:${id}`, action);
        }
        if (patch.menu !== undefined) {
          // The item is becoming (or refreshing) a menu button — its click is
          // consumed by the menu, so any old action callback can never fire.
          toolbarActions.delete(`${windowId}:${id}`);
          purgeItemToolbarMenuActions(windowId, id, toolbarMenuActions, toolbarMenuIdsByWindow);
          if (menuActions.size > 0) {
            wireToolbarMenuClicks();
            for (const [mid, fn] of menuActions) toolbarMenuActions.set(mid, fn);
            recordToolbarMenuIds(windowId, new Map([[id, new Set(menuActions.keys())]]), toolbarMenuIdsByWindow);
          }
        }
        windowAction("toolbar:updateItem", { windowId, itemJson: json });
      },
      remove() {
        purgeWindowToolbarActions(windowId, toolbarActions, toolbarMenuActions, toolbarMenuIdsByWindow);
        windowAction("toolbar:remove", { windowId });
      },
    },

    async createPopover(opts: PopoverOptions): Promise<PopoverHandle> {
      // Worker contexts can't measure elements and the worker bridges
      // don't route __popover:create — webview-only in v1.
      if ((globalThis as any).__zappBridge) {
        throw new Error("[zapp] createPopover is only available in WebView contexts (v1)");
      }
      const norm = normalizePopoverOptions(opts);
      const r = await bridge.invoke("__popover:create", { windowId, ...norm }) as { popoverId: string };
      const popoverId = r.popoverId;
      return {
        id: popoverId,
        show(anchor: Anchor | { toolbarItem: string }, showOpts?: { edge?: "top" | "bottom" | "left" | "right" }) {
          const isToolbar = typeof anchor === "object" && anchor !== null &&
            "toolbarItem" in anchor &&
            typeof (anchor as any).getBoundingClientRect !== "function";
          let a: Record<string, unknown>;
          if (isToolbar) {
            const tid = (anchor as { toolbarItem: string }).toolbarItem;
            if (!/^[A-Za-z0-9._-]+$/.test(tid)) {
              throw new Error(`[zapp] popover: invalid toolbarItem id "${tid}"`);
            }
            a = { toolbarItem: tid };
          } else {
            a = normalizeAnchor(anchor as Anchor);
          }
          windowAction("popover:show", { windowId, popoverId, anchor: a, edge: showOpts?.edge ?? "bottom" });
        },
        hide()    { windowAction("popover:hide",    { windowId, popoverId }); },
        destroy() { windowAction("popover:destroy", { windowId, popoverId }); },
      };
    },
  };
}

function getCurrentWindowId(): string | null {
  return (globalThis as any)[Symbol.for("zapp.windowId")] ?? null;
}

export const Window = {
  /** Get the current window handle. Only available in WebView context. */
  current(): WindowHandle {
    const id = getCurrentWindowId();
    if (!id) {
      throw new Error("[zapp] Window.current() is only available in WebView context. Use Window.create() in backend/workers.");
    }
    // Attach a SidebarHandle when this webview belongs to a window that has
    // a sidebar — either pane qualifies: the sidebar pane (zapp.isSidebar)
    // and the main pane (zapp.hasSidebar, injected into both panes at window
    // construction). State seeds defaults and syncs via sidebar-* events.
    const inSidebarWindow = Window.isSidebar() ||
      (globalThis as any)[Symbol.for("zapp.hasSidebar")] === true;
    const sidebarOpts: SidebarOptions | undefined = inSidebarWindow
      ? { url: "" }  // url is unused here — the pane's webview is already running;
                     // we only need the options shape so createWindowHandle wires up the SidebarHandle.
      : undefined;
    return createWindowHandle(id, sidebarOpts);
  },

  /** True when this code runs inside a window's sidebar webview.
   *
   * Native sets Symbol.for('zapp.isSidebar') in the sidebar webview's
   * bootstrap (window.m/webview.m, sidebar cycle).
   */
  isSidebar(): boolean {
    return (globalThis as any)[Symbol.for("zapp.isSidebar")] === true;
  },

  /** Create a new window. Returns a handle for the new window. */
  async create(opts?: Partial<WindowOptions>): Promise<WindowHandle> {
    // Normalize asSheetOf to its string window ID. The native side
    // resolves the JS-visible "win-0xPTR" string back to its internal
    // numeric ID via darwin_window_numeric_id_for_string.
    const normalized: Record<string, unknown> = { ...(opts ?? {}) };
    if (normalized.asSheetOf !== undefined) {
      const raw = normalized.asSheetOf as WindowHandle | string;
      const idStr = typeof raw === "string" ? raw : raw?.id;
      if (idStr) normalized.asSheetOf = idStr;
      else delete normalized.asSheetOf;
    }
    // Toolbar: validate, strip actions, pre-stringify (window.zc stores the
    // raw JSON; toolbar.m parses it). Actions register post-create once the
    // windowId is known.
    let pendingToolbarActions: Map<string, () => void> | undefined;
    let pendingToolbarMenuIds: Map<string, Set<string>> | undefined;
    if (opts?.toolbar) {
      const { json, actions, menuActions, menuIdsByItem } = normalizeToolbar(opts.toolbar, opts.sidebar !== undefined);
      normalized.toolbarJson = json;
      delete normalized.toolbar;
      if (actions.size > 0) pendingToolbarActions = actions;
      if (menuIdsByItem.size > 0) pendingToolbarMenuIds = menuIdsByItem;
      if (menuActions.size > 0) {
        wireToolbarMenuClicks();
        for (const [id, fn] of menuActions) toolbarMenuActions.set(id, fn);
      }
    }
    const registerToolbarActions = (windowId: string) => {
      if (pendingToolbarMenuIds) recordToolbarMenuIds(windowId, pendingToolbarMenuIds, toolbarMenuIdsByWindow);
      if (!pendingToolbarActions) return;
      wireToolbarClicks();
      for (const [id, fn] of pendingToolbarActions) toolbarActions.set(`${windowId}:${id}`, fn);
    };
    // Worker context: call the createWindow host directly (sync C call).
    const host = (globalThis as any).__zappBridge;
    if (host?.createWindow) {
      const r = host.createWindow(normalized) as { windowId: string };
      registerToolbarActions(r.windowId);
      return createWindowHandle(r.windowId, opts?.sidebar);
    }
    // Webview context: async IPC roundtrip through the WKWebView bridge.
    const result = await getBridge().invoke("__window:create", normalized) as { windowId: string };
    registerToolbarActions(result.windowId);
    return createWindowHandle(result.windowId, opts?.sidebar);
  },
};
