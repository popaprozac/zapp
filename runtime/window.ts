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
import { ensurePermission } from "./permissions";
export {
  WindowError,
  type WindowErrorPayload,
  type WindowOperation,
} from "./window-errors";
import { Platform } from "./platform";
import { WindowEvent, eventName, type WindowSizePayload, type WindowPayload, type ModalDismissedPayload, type SidebarResizedPayload, type InspectorResizedPayload, type RouteChangedPayload } from "./events";
import type { Display } from "./screen";
import type { MenuItemDef } from "./menu";
import { patchMenuTree, applyRadioSelection, findMenuItem } from "./action-context";
import type { ActionContext, MenuItemPatch } from "./action-context";

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
 * Content-pane background behavior relative to the floating sidebar (macOS 26+).
 * `None` = content beside the sidebar (default). `Extend` = content flows under the
 * floating sidebar; lay out with the injected `--zapp-safe-area-*` CSS vars. `Mirror`
 * = NSBackgroundExtensionView mirrors/blurs content behind the glass (full-bleed media).
 * Extend/Mirror fall back to `None` on macOS < 26. Sidebar-edge only.
 */
export const BackgroundExtension = {
  None: "none",
  Extend: "extend",
  Mirror: "mirror",
} as const;
export type BackgroundExtension = (typeof BackgroundExtension)[keyof typeof BackgroundExtension];

/**
 * Per-traffic-light state. `disabled` greys the button, `hidden` removes
 * it entirely (leaves a gap unless paired with a custom titlebar).
 */
export type ButtonState = "enabled" | "disabled" | "hidden";

/**
 * Window-control button states (close / minimize / maximize). Cross-platform:
 * macOS traffic lights, Windows caption buttons. `maximize` is macOS's zoom.
 */
export interface WindowControls {
  close?: ButtonState;
  minimize?: ButtonState;
  maximize?: ButtonState;
}

/** Options for creating a window (mirrors native WindowOptions). */
/** DWM system backdrop (Windows 11 22H2+). Precise override for `vibrancy`. */
export type WindowsBackdrop = "none" | "mica" | "mica-alt" | "acrylic" | "tabbed";

/** Custom Windows title-bar colors (`DWMWA_CAPTION/TEXT/BORDER_COLOR`). Each a CSS
 *  color string (`"#1e1e1e"`, `"teal"`, …). Windows 11+. */
export interface WindowsCustomTheme {
  caption?: string;
  text?: string;
  border?: string;
}

/**
 * Windows-specific window options — the Tier-2 platform namespace. Divergent-only
 * chrome + precise overrides for the Windows (WebView2) build; ignored on other
 * platforms. Universal/semantic options (`transparent`, `vibrancy`,
 * `titleBarStyle`, `windowControls`) stay top-level.
 */
export interface WindowsOptions {
  /** Precise DWM backdrop; overrides the cross-platform `vibrancy` mapping. */
  backdrop?: WindowsBackdrop;
  /** Custom title-bar / border colors. */
  customTheme?: WindowsCustomTheme;
  /** Pass mouse events through to windows below (`WS_EX_TRANSPARENT|WS_EX_LAYERED`)
   *  — for click-through overlays. Usually paired with `transparent`. */
  clickThrough?: boolean;
  /** Exclude the window from screen capture (`SetWindowDisplayAffinity`). */
  contentProtection?: boolean;
  /** Hide the window's taskbar button (`WS_EX_TOOLWINDOW`). */
  hiddenOnTaskbar?: boolean;
  /** Show the draggable band between the sidebar/inspector and content
   *  (default `true`). Set `false` for a flush, seamless split — the splitter
   *  band collapses to zero width. Pairs well with `sidebar.resizable: false`. */
  paneSeparators?: boolean;
}

/**
 * macOS-specific window options — the Tier-2 platform namespace (mirrors
 * `windows:`). Divergent-only AppKit chrome; ignored on non-macOS builds.
 */
export interface MacOptions {
  /** Native toolbar (NSToolbar) integrated with the title bar. macOS only. */
  toolbar?: ToolbarOptions;
  /**
   * `NSVisualEffectMaterial` for this window — the **macOS-only** precise override
   * of the cross-platform `vibrancy`. Use this (instead of top-level `vibrancy`)
   * when you want vibrancy on macOS but an **opaque** window on Windows, e.g. to
   * keep Windows' native caption-button hover working (a transparent WebView2
   * composites over them). Windows stays opaque unless you set `windows.backdrop`.
   */
  material?: Material;
}

export interface WindowOptions {
  title?: string;
  url?: string;
  width?: number;
  height?: number;
  /** Optional top-level size limits (logical px). Unset = no limit. Enforced
   *  natively (Windows WM_GETMINMAXINFO / macOS contentMin/MaxSize). */
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
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
  /** Window background color. Accepts a CSS name (`"teal"`), `#rgb`/`#rrggbb`/
   *  `#rrggbbaa`, `rgb()`, or `rgba()`. The window is opaque, so alpha is
   *  clamped to fully opaque. Opaque windows only (ignored when transparent or
   *  `vibrancy` is set). macOS; create-time. Invalid colors are ignored with a
   *  `[zapp] invalid backgroundColor` warning. */
  backgroundColor?: string;
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
   * On Windows 11 this maps to a DWM system backdrop: transient/floating
   * materials (`popover`, `menu`, `hudWindow`, `sheet`, `tooltip`) → Acrylic,
   * everything else → Mica. Windows-native values are also accepted:
   * `"mica"`, `"mica-alt"`, `"acrylic"`, `"none"`. The same transparent-CSS
   * requirement applies. Falls back to a normal opaque window on Windows 10 /
   * pre-22H2. No-op on iOS.
   */
  vibrancy?: Material;
  /**
   * Windows-specific window chrome (Tier-2 platform namespace) — precise DWM
   * backdrop, custom title-bar colors, click-through, content protection,
   * taskbar visibility. Ignored on non-Windows builds. `mac:`/`linux:` namespaces
   * to follow the same shape.
   */
  windows?: WindowsOptions;
  /**
   * macOS-specific window chrome (Tier-2 platform namespace) — currently the
   * native `toolbar`. Ignored on non-macOS builds.
   */
  mac?: MacOptions;
  /**
   * macOS title-bar style. `"hidden"`/`"hiddenInset"` hide the title and let
   * content extend under the title bar; `"default"` is a standard title bar.
   * Omitting this is distinct from `"default"`: a plain window with no value
   * gets a standard title bar, but a window with a `sidebar`/`inspector` pane
   * defaults to the unified hidden-title chrome (standard sidebar-app look).
   * Set `"default"` explicitly to force a standard title bar on such a window.
   * No-op on iOS.
   */
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
   * Per-button state for the window controls (close / minimize / maximize) —
   * macOS traffic lights, Windows caption buttons. Takes precedence over the
   * legacy `closable` / `minimizable` / `maximizable` booleans (those remain as
   * sugar: `false` maps to the corresponding button's `"disabled"` state).
   *
   * @example
   * ```ts
   * Window.create({
   *   windowControls: { close: "enabled", minimize: "disabled", maximize: "hidden" },
   * });
   * ```
   */
  windowControls?: WindowControls;
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
  /** Attach a native toolbar (NSToolbar). macOS only; no-op elsewhere.
   *  @deprecated Use `mac: { toolbar }` — the Tier-2 platform namespace. Still
   *  honored (falls back to this) so existing code keeps working. */
  toolbar?: ToolbarOptions;
  /** Attach a native inspector (trailing NSSplitViewItem). macOS only; no-op elsewhere. */
  inspector?: InspectorOptions;
  /** macOS 26+. How the content pane's background relates to the floating sidebar.
   *  Default `None`. Extend/Mirror fall back to `None` on older macOS. Create-time. */
  backgroundExtension?: BackgroundExtension;
}

/** Options for a native sidebar (NSSplitViewItem) attached to a window. */
export interface SidebarOptions {
  /** Entry URL/route for the sidebar webview (resolved like the window url). Required. */
  url: string;
  /** #782. Title shown in the sidebar's own toolbar/nav region (its travel to
   *  native is wired later). Preserved on the options; NOT merged into toolbar items. */
  title?: string;
  /** #782. A toolbar scoped to the sidebar pane. Its items are folded into the
   *  window's single toolbar def tagged `pane: "sidebar"` at create time. */
  toolbar?: ToolbarOptions;
  /** Initial width in points. Default 260. */
  width?: number;
  /** Divider drag limits. Defaults 180 / 400. */
  minWidth?: number;
  maxWidth?: number;
  /** User can collapse via system behaviors. Default true. */
  collapsible?: boolean;
  /** Start collapsed. Default false. */
  collapsed?: boolean;
  /** User can resize by dragging the divider. Default true; false locks the
   *  pane at `width`. Toggle later with `win.sidebar.setResizable(...)`. */
  resizable?: boolean;
  /** Solid backdrop color behind the transparent pane webview (the flat,
   *  non-vibrant path — `material` takes precedence if both are set). Accepts a
   *  CSS name, `#rgb`/`#rrggbb`/`#rrggbbaa`, `rgb()`, or `rgba()`; an `rgba()`
   *  alpha lets the window background behind the pane show through. macOS;
   *  create-time. Invalid colors are ignored with a warning. */
  backgroundColor?: string;
  /** Background material. Default Material.Sidebar (liquid glass on macOS 26+). */
  material?: Material;
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
   *   never floats over content); the sidebar stays tiled-collapsible.
   * - iPhone (compact width): NO-OP. The split always collapses to a
   *   master-detail navigation stack regardless of this value.
   *
   * Create-time only. Default "tile".
   */
  presentation?: "tile" | "overlay";
}

/** Options for a native inspector pane attached to a window.
 *  Platform behavior:
 *  - macOS / iPad (regular width): a trailing pane beside the content.
 *  - iPhone (compact width): presented as a sheet (summon-only; never shown
 *    at launch). Detents default to medium+large.
 *  Width/min/max/resizable apply to the pane; on the iPhone sheet they are
 *  ignored (the sheet is full-width with system detents). */
export interface InspectorOptions {
  /** Entry URL/route for the inspector webview (resolved like sidebar.url). Required. */
  url: string;
  /** #782. Title shown in the inspector's own toolbar/nav region (its travel to
   *  native is wired later). Preserved on the options; NOT merged into toolbar items. */
  title?: string;
  /** #782. A toolbar scoped to the inspector pane. Its items are folded into the
   *  window's single toolbar def tagged `pane: "inspector"` at create time. */
  toolbar?: ToolbarOptions;
  /** Initial width in points. Default 280. */
  width?: number;
  /** Divider drag limits. Defaults 180 / 400. */
  minWidth?: number;
  maxWidth?: number;
  /** User can collapse via system behaviors. Default true. */
  collapsible?: boolean;
  /** Start collapsed (the common "hidden until summoned" inspector). Default false. */
  collapsed?: boolean;
  /** User can resize by dragging the divider. Default true; false locks the
   *  pane at `width`. Toggle later with `win.inspector.setResizable(...)`. */
  resizable?: boolean;
  /** Solid backdrop color behind the transparent pane webview (the flat,
   *  non-vibrant path — `material` takes precedence if both are set). Accepts a
   *  CSS name, `#rgb`/`#rrggbb`/`#rrggbbaa`, `rgb()`, or `rgba()`; an `rgba()`
   *  alpha lets the window background behind the pane show through. macOS;
   *  create-time. Invalid colors are ignored with a warning. */
  backgroundColor?: string;
  /** Background material. Default matches the sidebar pane default. */
  material?: Material;
}

/** Which toolbar slot an item belongs to. macOS sorts items into these slots
 *  (leading → center → trailing) with flexible space auto-inserted between
 *  non-empty groups; iOS maps them to navigation-bar leading/title/trailing
 *  (a later cycle). Default "leading". */
export type ToolbarPlacement = "leading" | "center" | "trailing";

/** One segment of a `type: "segmented"` toolbar group. A menu-like item:
 *  same `action: () => void` primitive as MenuItemDef/ToolbarItemDef. */
export interface ToolbarSegmentDef {
  /** Optional id (currently informational; segments route by index). */
  id?: string;
  /** Segment label OR icon — the convenience control takes titles or images. */
  label?: string;
  icon?: string;
  /** Default true. */
  enabled?: boolean;
  /** Fires when this segment is pressed (momentary) or becomes selected. */
  action?: (ctx?: ActionContext) => void;
}

/** A toolbar button (the default item; `type` may be omitted).
 *  `id` is REQUIRED — it keys click routing. Allowed charset: letters,
 *  digits, `.`, `_`, `-`. Prefixes `"zapp."` and `"NSToolbar"` are reserved. */
export interface ToolbarButtonDef {
  type?: "button";
  /** Required. Keys click routing and native NSToolbar identifier. */
  id: string;
  /** Tooltip; visible text in the "expanded" style. */
  label?: string;
  /** Icon via the shared resolver: "sf:<symbol>", file path, or data URL. */
  icon?: string;
  /** Creator-context callback (menu pattern). Stripped before the wire. */
  action?: (ctx?: ActionContext) => void;
  /** Pull-down menu (NSMenuToolbarItem — e.g. Mail's filter button). Items
   *  are the same MenuItemDef used by Menu/ContextMenu/Tray; their `action`
   *  callbacks run in this (creator) context via the __menu:click pipeline. */
  menu?: MenuItemDef[];
  /** Enabled state. Default true. AppKit-validated, so it sticks
   *  across revalidation. Patchable via win.toolbar.updateItem. */
  enabled?: boolean;
  /** Menu buttons: show the pull-down chevron. Default true; false is the
   *  Messages-app no-chevron look. */
  indicator?: boolean;
  /** macOS 26+. "prominent" tints the item background (the new-design
   *  highlighted action). Default "plain". No-op < macOS 26. */
  style?: "plain" | "prominent";
  /** macOS 26+. Hex color tinting a prominent item's background; ignored
   *  unless `style` is "prominent". Omit → system accent. No-op < macOS 26. */
  tintColor?: string;
  /** macOS 26+. A badge: a count, short text, or a plain dot. No-op < macOS 26. */
  badge?: { count: number } | { text: string } | { dot: true } | null;
  /** Draw the item's standard bordered background. Default true; false → flat.
   *  All macOS versions. */
  bordered?: boolean;
  /** Toolbar slot. Default "leading". macOS sorts by placement; iOS (later)
   *  maps to nav-bar slots. */
  placement?: ToolbarPlacement;
  /** #782. Route this item into a pane's toolbar region: "sidebar" places it
   *  before the sidebar tracking separator, "inspector" after the inspector
   *  tracking separator. Untagged (default) → the content region. Ignored
   *  (with a warning) when the named pane isn't attached to the window. */
  pane?: "sidebar" | "inspector";
}

/** A segmented control toolbar item. */
export interface ToolbarSegmentedDef {
  type: "segmented";
  /** Required. Native NSToolbar identifier. */
  id: string;
  /** Group label — names the collapsed chevron button and the customization
   *  palette on macOS. Distinct from each segment's own `label`. Recommended
   *  for icon-only groups (an unlabeled collapsed group renders a blank
   *  chevron button). Omit → unlabeled (prior behavior). */
  label?: string;
  /** Group icon (`sf:`/path/data-URL) — renders the collapsed pull-down
   *  button body in icon-only toolbars (pair with `label`). */
  icon?: string;
  /** The segments of the control. label OR icon each. */
  segments: ToolbarSegmentDef[];
  /** Selection behavior. Default "momentary". */
  selectionMode?: "one" | "any" | "momentary";
  /** Initial selection — index ("one") or indices ("any").
   *  Ignored for "momentary". */
  selected?: number | number[];
  /** How the control collapses. Default "automatic". */
  controlRepresentation?: "automatic" | "expanded" | "collapsed";
  /** Toolbar slot. Default "leading". macOS sorts by placement; iOS (later)
   *  maps to nav-bar slots. */
  placement?: ToolbarPlacement;
  /** #782. Route this item into a pane's toolbar region. See ToolbarButtonDef.pane. */
  pane?: "sidebar" | "inspector";
}

/** A group of toolbar buttons (one level — no nested groups). */
export interface ToolbarGroupDef {
  type: "group";
  /** Required. Native NSToolbar identifier. */
  id: string;
  /** Clustered full button items (one level — no nested groups). */
  items: ToolbarButtonDef[];
  /** How the group collapses. Default "automatic". */
  controlRepresentation?: "automatic" | "expanded" | "collapsed";
  /** Toolbar slot. Default "leading". macOS sorts by placement; iOS (later)
   *  maps to nav-bar slots. */
  placement?: ToolbarPlacement;
  /** #782. Route this item into a pane's toolbar region. See ToolbarButtonDef.pane. */
  pane?: "sidebar" | "inspector";
}

/** A tracking separator that follows a split-view divider. */
export interface ToolbarTrackingSepDef {
  type: "trackingSeparator";
  /** Which split divider to track. Default "sidebar". `toggleSidebar`/sidebar-tracking
   *  require a `sidebar`; `toggleInspector`/inspector-tracking require an
   *  `inspector` (warned + dropped otherwise). */
  pane?: "sidebar" | "inspector";
  /** Toolbar slot. Default "leading". macOS sorts by placement; iOS (later)
   *  maps to nav-bar slots. */
  placement?: ToolbarPlacement;
}

/** A system toolbar item: fixed/flexible space or sidebar/inspector toggles.
 *  `toggleSidebar` is AppKit's standard sidebar button (auto-wired to the
 *  split view controller); `toggleInspector` toggles the trailing inspector
 *  pane. Both require the corresponding pane (warned + dropped otherwise). */
export interface ToolbarSystemDef {
  type: "toggleSidebar" | "toggleInspector" | "space" | "flexibleSpace";
  /** Toolbar slot. Default "leading". macOS sorts by placement; iOS (later)
   *  maps to nav-bar slots. */
  placement?: ToolbarPlacement;
  /** #782. On `space`/`flexibleSpace`, route the spacer into a pane region.
   *  Ignored on `toggleSidebar`/`toggleInspector` (they anchor by convention).
   *  See ToolbarButtonDef.pane. */
  pane?: "sidebar" | "inspector";
}

/** A non-interactive text label in the toolbar (NSToolbarItem hosting an
 *  NSTextField). macOS-only; no action/icon. Useful for status strings. */
export interface ToolbarLabelDef {
  type: "label";
  /** Optional NSToolbar identifier. Auto-assigned if absent (like button ids). */
  id?: string;
  /** The text to display. Required. */
  text: string;
  /** Toolbar slot. Default "leading". macOS sorts by placement; iOS (later)
   *  maps to nav-bar slots. */
  placement?: ToolbarPlacement;
  /** #782. Route this item into a pane's toolbar region. See ToolbarButtonDef.pane. */
  pane?: "sidebar" | "inspector";
}

/** One toolbar item. `type` defaults to `"button"`. */
export type ToolbarItemDef =
  | ToolbarButtonDef
  | ToolbarSegmentedDef
  | ToolbarGroupDef
  | ToolbarTrackingSepDef
  | ToolbarSystemDef
  | ToolbarLabelDef;

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
  /** For `type:"label"` items: update the displayed text string. */
  text?: string;
  /** Icon via the shared resolver: "sf:<symbol>", file path, or data URL. */
  icon?: string;
  enabled?: boolean;
  /** Menu buttons: show the pull-down chevron. */
  indicator?: boolean;
  /** REPLACES the pull-down menu (the moving-checkmark refresh). Actions
   *  are stripped + re-registered like setItems. */
  menu?: MenuItemDef[];
  /** Replaces the creator callback for this button. */
  action?: (ctx?: ActionContext) => void;
  style?: "plain" | "prominent";
  tintColor?: string;
  /** Pass null to clear the badge. */
  badge?: { count: number } | { text: string } | { dot: true } | null;
  bordered?: boolean;
  /** "segmented": set selection live — index ("one") or indices ("any"). */
  selected?: number | number[];
  controlRepresentation?: "automatic" | "expanded" | "collapsed";
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
const toolbarActions = new Map<string, (ctx?: ActionContext) => void>();
let toolbarClickWired = false;

/** `toolbarActions` keys registered by `router.push`'s `toolbar` override
 * (⊂ toolbarActions, tagged at push-registration time — #771 T8 review I2),
 * windowId → (key → the registering route's url, provenance — #771 T8
 * round-2 review). `purgeWindowToolbarActions` spares tagged keys: a route
 * override's action must keep firing after a window-toolbar `setItems`/
 * `remove` call and after `router.forward` replays the route (replay never
 * re-registers — the JS side only registers once, at the original `push`),
 * so route action keys are intentionally NEVER purged.
 *
 * Unlike pull-down menu-item ids (see `stripMenuActions`'/`normalizeToolbar`'s
 * `idBase`, which folds in the route `url`), PLAIN button action keys are
 * `${windowId}:${id}` with no route discriminator — that's the app-declared
 * item id verbatim, so it can't be silently rewritten. Two sibling routes on
 * one window's stack that reuse the same button id therefore still share ONE
 * `toolbarActions` entry: the second push's registration overwrites the
 * first's closure (last-push-wins), and firing the id later always calls
 * whichever route registered most recently — even while the OTHER route's
 * button is the one currently visible. The url stored here lets push-time
 * registration detect that mismatch and warn (see `router.push`); it does
 * not change the overwrite behavior — apps must use distinct ids across
 * routes that can coexist on one window's stack. */
const routeToolbarActionKeys = new Map<string, Map<string, string>>();

function wireToolbarClicks(): void {
  if (toolbarClickWired) return;
  toolbarClickWired = true;
  getBridge().on(eventName(WindowEvent.TOOLBAR_CLICKED), (payload: any) => {
    const windowId = payload?.windowId;
    const id = payload?.id;
    const fn = toolbarActions.get(`${windowId}:${id}`);
    if (!fn) return;
    const win = Window.current();
    fn({ id, window: win, update: (patch) => win.toolbar.updateItem(id, patch as any) });
  });
}

let toolbarGroupWired = false;
function wireToolbarGroupSelect(): void {
  if (toolbarGroupWired) return;
  toolbarGroupWired = true;
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
}

let tbMenuIdCounter = 0;
/** Toolbar pull-down menu actions, keyed by menu-item id ("__menu:click"
 * carries only the id — app-global like Menu.build; reused ids across
 * windows collide, same caveat as Menu). App-lifetime, like toolbarActions. */
const toolbarMenuActions = new Map<string, (ctx?: ActionContext) => void>();
let toolbarMenuClickWired = false;

// Retained pull-down menu trees (with actions) so a pull-down item's
// ctx.update can patch the item + re-send the owning toolbar item's whole menu.
// Keyed "windowId:itemId" (the owning toolbar item).
const toolbarMenuTrees = new Map<string, MenuItemDef[]>();
// Reverse: a pull-down menu item id → the "windowId:itemId" that owns it.
const toolbarMenuItemOwner = new Map<string, string>();

/** Merge auto-assigned ids from the stripped output back onto the originals,
 *  producing a tree with ids + actions. Recurses into submenu in parallel.
 *  `stripped` is the output of stripMenuActions (ids set, actions removed);
 *  `originals` is the source tree (actions present, ids may be missing). */
function mergeMenuIds(stripped: any[], originals: MenuItemDef[]): MenuItemDef[] {
  // stripMenuActions maps 1:1 over the same tree, so lengths always match.
  // Guard defensively: a mismatch would silently misalign the positional zip
  // (wrong ids onto items) — surface it instead.
  if (stripped.length !== originals.length) {
    console.warn(
      `[zapp] mergeMenuIds: length mismatch (${stripped.length} stripped vs ${originals.length} originals) — menu-item id alignment may be off`,
    );
  }
  return originals.map((orig, i) => {
    const s = stripped[i];
    const merged: MenuItemDef = { ...orig };
    // Propagate auto-assigned id from stripped copy back to retained item.
    if (s?.id !== undefined) merged.id = s.id;
    if (orig.submenu && s?.submenu) {
      merged.submenu = mergeMenuIds(s.submenu, orig.submenu);
    }
    return merged;
  });
}

/** Record a toolbar item's pull-down menu tree (with actions + ids, already
 *  merged via mergeMenuIds) so wireToolbarMenuClicks can call patchMenuTree +
 *  updateItem on ctx.update. */
function recordToolbarMenuTree(windowId: string, itemId: string, retained: MenuItemDef[]): void {
  const ownerKey = `${windowId}:${itemId}`;
  toolbarMenuTrees.set(ownerKey, retained);
  const walk = (items: MenuItemDef[]) => {
    for (const m of items) {
      if (m.id) toolbarMenuItemOwner.set(m.id, ownerKey);
      if (m.submenu) walk(m.submenu);
    }
  };
  walk(retained);
}

function wireToolbarMenuClicks(): void {
  if (toolbarMenuClickWired) return;
  toolbarMenuClickWired = true;
  // Uses getBridge().on (not Events.on) to match the sibling toolbar handlers
  // above (TOOLBAR_CLICKED / TOOLBAR_GROUP_SELECTED). menu.ts/tray.ts/context-menu.ts
  // listen for this same "__menu:click" via Events.on — both target the one bridge
  // bus, so all four handlers receive every click and self-filter by surface.
  getBridge().on("__menu:click", (payload: any) => {
    const id = typeof payload === "string" ? JSON.parse(payload).id : payload?.id;
    // Key off the owner map (covers radio-only pull-down items with NO action)
    // rather than the action map — so radioGroup items still move their check.
    const ownerKey = toolbarMenuItemOwner.get(id); // "windowId:itemId"
    if (!ownerKey) return; // not a toolbar pull-down item — app menu / tray handles it
    const win = Window.current();
    const itemId = ownerKey.slice(ownerKey.indexOf(":") + 1);
    let tree = toolbarMenuTrees.get(ownerKey);
    const clicked = tree ? findMenuItem(tree, id) : undefined;
    // Auto-radio: move the checkmark regardless of whether an action exists.
    if (tree && clicked?.radioGroup) {
      const patched = applyRadioSelection(tree, id, clicked.radioGroup);
      toolbarMenuTrees.set(ownerKey, patched);
      tree = patched;
      win.toolbar.updateItem(itemId, { menu: patched } as any);
    }
    // Fire the action only if one is registered for this item.
    const fn = toolbarMenuActions.get(id);
    if (!fn) return;
    const update = (patch: MenuItemPatch) => {
      const currentTree = toolbarMenuTrees.get(ownerKey);
      if (!currentTree) return;
      const patched = patchMenuTree(currentTree, id, patch);
      toolbarMenuTrees.set(ownerKey, patched);
      win.toolbar.updateItem(itemId, { menu: patched } as any);
    };
    // Read checked from the (post-radio) patched tree so ctx.checked is
    // current — uniform with the app-menu + tray dispatch handlers.
    fn({ id, window: win, checked: findMenuItem(tree ?? [], id)?.checked, update });
  });
}

/** Strip `action` callbacks out of a MenuItemDef tree (recursing submenus),
 * collecting them into `out` keyed by (possibly auto-generated) id. Mirrors
 * context-menu.ts's collectAndStrip.
 *
 * `idBase`, when provided (the `router.push` toolbar-override path — #771
 * T8 review I3), derives auto-generated ids from `${idBase}_${n}` — a
 * counter local to this call (flat across the whole tree, via `counter`) —
 * instead of the module-global `tbMenuIdCounter`. Re-stripping the identical
 * menu tree (e.g. an identical repeated push) then re-derives the SAME ids,
 * so the caller's `Map.set()` overwrites the existing entry instead of
 * minting a fresh one and orphaning the old. Omitted (the `setItems` /
 * `updateItem` paths) keeps the original ever-growing global-counter
 * behavior — those paths purge-and-rebuild a window's registrations
 * wholesale on every call, so an ever-growing counter never leaks there.
 *
 * #771 T8 round-2 review: `normalizeToolbar` (the only caller that passes
 * `idBase`) now folds the pushed route's `url` into it, alongside the
 * `windowId` and the toolbar item's own id — see its call site. Round 1's
 * `${windowId}_${itemId}` base was stable across repeated pushes of ONE
 * route but collided across sibling routes on the same window reusing the
 * same item id (last push's ids silently overwrote the first's map entries
 * — the wrong route's closure would fire after navigating back to the
 * first). Adding `url` scopes ids per ROUTE while keeping the same-route
 * repeat-push property this parameter exists for. */
function stripMenuActions(
  items: MenuItemDef[],
  out: Map<string, (ctx?: ActionContext) => void>,
  idBase?: string,
  counter: { n: number } = { n: 0 },
): any[] {
  return items.map((item) => {
    const clean: any = { ...item };
    if (clean.action) {
      if (!clean.id) {
        clean.id = idBase ? `__tbmenu_${idBase}_${counter.n++}` : `__tbmenu_${++tbMenuIdCounter}`;
      }
      out.set(clean.id, clean.action);
      delete clean.action;
    }
    if (clean.submenu) clean.submenu = stripMenuActions(clean.submenu, out, idBase, counter);
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
 * maps. `routeActionKeys` (#771 T8 review I2; values became key→url
 * provenance in round 2) tags `router.push` toolbar-override action keys —
 * those are spared (see `routeToolbarActionKeys` doc comment for why
 * they're never purged). Only key *presence* matters here — the url
 * payload is provenance for `router.push`'s warn check, not the purge. */
export function purgeWindowToolbarActions(
  windowId: string,
  actions: Map<string, (ctx?: ActionContext) => void>,
  menuActions: Map<string, (ctx?: ActionContext) => void>,
  menuIdsByWindow: Map<string, Map<string, Set<string>>>,
  routeActionKeys: Map<string, Map<string, string>>,
): void {
  const spared = routeActionKeys.get(windowId);
  for (const key of [...actions.keys()]) {
    if (key.startsWith(`${windowId}:`) && !spared?.has(key)) actions.delete(key);
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
  menuActions: Map<string, (ctx?: ActionContext) => void>,
  menuIdsByWindow: Map<string, Map<string, Set<string>>>,
): void {
  const perItem = menuIdsByWindow.get(windowId);
  const ids = perItem?.get(itemId);
  if (!ids) return;
  for (const mid of ids) menuActions.delete(mid);
  perItem!.delete(itemId);
}

/** Remove a window's retained pull-down trees + reverse owner entries.
 * Pairs with purgeWindowToolbarActions (setItems/remove). Maps are injected
 * for unit tests; production callers pass the module maps. */
export function purgeWindowToolbarMenuTrees(
  windowId: string,
  menuTrees: Map<string, MenuItemDef[]>,
  menuItemOwner: Map<string, string>,
): void {
  for (const ownerKey of [...menuTrees.keys()]) {
    if (ownerKey.startsWith(`${windowId}:`)) menuTrees.delete(ownerKey);
  }
  for (const [menuItemId, ownerKey] of [...menuItemOwner]) {
    if (ownerKey.startsWith(`${windowId}:`)) menuItemOwner.delete(menuItemId);
  }
}

/** Remove ONE item's retained pull-down tree + its reverse owner entries
 * (updateItem with a replacement menu). Pairs with purgeItemToolbarMenuActions. */
export function purgeItemToolbarMenuTree(
  windowId: string,
  itemId: string,
  menuTrees: Map<string, MenuItemDef[]>,
  menuItemOwner: Map<string, string>,
): void {
  const ownerKey = `${windowId}:${itemId}`;
  menuTrees.delete(ownerKey);
  for (const [menuItemId, owner] of [...menuItemOwner]) {
    if (owner === ownerKey) menuItemOwner.delete(menuItemId);
  }
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

/** Convert a ToolbarItemDef/Patch badge value to its tagged wire form.
 *  null (patch-only) → clear. */
function badgeToWire(
  b: { count: number } | { text: string } | { dot: true } | null,
): Record<string, unknown> {
  if (b === null) return { kind: "none" };
  if ("count" in b) return { kind: "count", count: b.count };
  if ("text" in b) return { kind: "text", text: b.text };
  return { kind: "dot" };
}

/** Normalize a `selected` value to the wire array form ([]/[n]/[a,b]). */
function selectedToWire(s: number | number[] | undefined): number[] {
  if (s === undefined) return [];
  return Array.isArray(s) ? s.slice() : [s];
}

/** Validate a toolbar item id: must match [A-Za-z0-9._-]+ and must not start
 * with the reserved prefixes "zapp." or "NSToolbar". Used for button, segmented,
 * and group ids (all become native NSToolbar identifiers). */
function assertValidToolbarId(id: string): void {
  if (!/^[A-Za-z0-9._-]+$/.test(id) || id.startsWith("zapp.") || id.startsWith("NSToolbar")) {
    throw new Error(
      `[zapp] toolbar: invalid item id "${id}" — use letters, digits, ".", "_", "-" (ids prefixed "zapp." or "NSToolbar" are reserved)`,
    );
  }
}

/** T1 convention pass — THE single placement-resolution point. The future
 *  per-pane placement config feeds overrides into this function; nothing
 *  else in the pipeline reorders items. Anchors (native convention):
 *  leading = [flexibleSpace, toggleSidebar, trackingSeparator(sidebar)],
 *  trailing tail = [trackingSeparator(inspector), toggleInspector].
 *  App items keep declared order. Documented behavior change (pre-1.0).
 *
 *  #782: items carrying `pane: "sidebar" | "inspector"` bucket into that
 *  pane's toolbar region — sidebar-tagged items land before the sidebar
 *  tracking separator, inspector-tagged items after the inspector one, while
 *  untagged items keep today's exact ordering in the content region. A
 *  region's tracking separator is synthesized when tagged items need a
 *  delimiter but none was declared (the separator has no wire id — native
 *  locates it by type+pane). */
export function applyToolbarConventions(
  items: Record<string, unknown>[],
): Record<string, unknown>[] {
  let toggleSidebar: Record<string, unknown> | undefined;
  let sepSidebar: Record<string, unknown> | undefined;
  let sepInspector: Record<string, unknown> | undefined;
  let toggleInspector: Record<string, unknown> | undefined;
  const rest: Record<string, unknown>[] = [];
  for (const item of items) {
    const t = item.type;
    if (t === "toggleSidebar") { toggleSidebar ??= { ...item, placement: "leading" }; continue; }
    if (t === "toggleInspector") { toggleInspector ??= { ...item, placement: "trailing" }; continue; }
    if (t === "trackingSeparator") {
      if (item.pane === "inspector") sepInspector ??= { ...item, placement: "trailing" };
      else sepSidebar ??= { ...item, placement: "leading" };
      continue;
    }
    rest.push(item);
  }
  // #782: partition the app items by pane tag. Untagged items stay in the
  // content region (order-preserving) exactly as before.
  const sidebarItems: Record<string, unknown>[] = [];
  const inspectorItems: Record<string, unknown>[] = [];
  const contentItems: Record<string, unknown>[] = [];
  for (const item of rest) {
    if (item.pane === "sidebar") sidebarItems.push(item);
    else if (item.pane === "inspector") inspectorItems.push(item);
    else contentItems.push(item);
  }
  // A pane region needs a tracking separator to delimit it; synthesize one
  // when tagged items exist but none was declared (id-less — located by
  // type+pane on the native side, mirroring the declared separator).
  if (sidebarItems.length > 0) sepSidebar ??= { type: "trackingSeparator", pane: "sidebar", placement: "leading" };
  if (inspectorItems.length > 0) sepInspector ??= { type: "trackingSeparator", pane: "inspector", placement: "trailing" };
  const prefix: Record<string, unknown>[] = [];
  if (toggleSidebar && sepSidebar) {
    prefix.push({ type: "flexibleSpace", placement: "leading" }, ...sidebarItems, toggleSidebar, sepSidebar);
    // Collapse an app-declared leading flex that duplicated the convention.
    if (contentItems[0]?.type === "flexibleSpace" && contentItems[0]?.placement === "leading") contentItems.shift();
  } else if (sepSidebar) prefix.push(...sidebarItems, sepSidebar);
  else if (toggleSidebar) prefix.push(...sidebarItems, toggleSidebar);
  const suffix: Record<string, unknown>[] = [];
  if (sepInspector) suffix.push(sepInspector, ...inspectorItems);
  if (toggleInspector) suffix.push(toggleInspector);
  return [...prefix, ...contentItems, ...suffix];
}

/** #782 desugar — fold pane-scoped toolbars into the window's single toolbar
 *  def. The window's own items pass through untagged; each `sidebar.toolbar`
 *  item is tagged `pane: "sidebar"` and each `inspector.toolbar` item
 *  `pane: "inspector"`, so downstream `applyToolbarConventions` buckets them
 *  into their pane regions. Returns undefined when there is nothing to build.
 *  The pane TITLES travel separately (native reads them off the pane options);
 *  they are NOT merged into items here. Pure — unit-tested. */
export function mergePaneToolbars(
  windowToolbar: ToolbarOptions | undefined,
  sidebarToolbar: ToolbarOptions | undefined,
  inspectorToolbar: ToolbarOptions | undefined,
): ToolbarOptions | undefined {
  if (!windowToolbar && !sidebarToolbar && !inspectorToolbar) return undefined;
  const items: ToolbarItemDef[] = [];
  if (windowToolbar?.items) items.push(...windowToolbar.items);
  if (sidebarToolbar?.items) {
    for (const it of sidebarToolbar.items) items.push({ ...it, pane: "sidebar" } as ToolbarItemDef);
  }
  if (inspectorToolbar?.items) {
    for (const it of inspectorToolbar.items) items.push({ ...it, pane: "inspector" } as ToolbarItemDef);
  }
  // The window toolbar's style wins; fall back to a pane's if only panes bring
  // a toolbar. Omit when none set (normalizeToolbar defaults it to "unified").
  const style = windowToolbar?.style ?? sidebarToolbar?.style ?? inspectorToolbar?.style;
  return style ? { items, style } : { items };
}

/** Validate a ToolbarOptions and split it into the wire JSON (actions
 * stripped, defaults applied) and the action maps. Pure — unit-tested. */
export function normalizeToolbar(
  toolbar: ToolbarOptions,
  hasSidebar: boolean,
  hasInspector: boolean,
  // #771 T8 review I3: when set (the router.push call site), threads through
  // to stripMenuActions as the stable auto-id base. Omitted by every other
  // caller (setItems et al.), which keeps the original global-counter
  // behavior — see stripMenuActions' doc comment.
  windowId?: string,
  // #771 T8 round-2 review: the pushed route's url, paired with windowId to
  // scope the auto-id base per ROUTE (not just per window) — see
  // stripMenuActions' doc comment for the collision round 1 left open.
  // Always passed together with windowId by the one caller that passes
  // either (router.push); every other caller omits both.
  url?: string,
): {
  json: string;
  actions: Map<string, (ctx?: ActionContext) => void>;
  menuActions: Map<string, (ctx?: ActionContext) => void>;
  menuIdsByItem: Map<string, Set<string>>;
  /** Retained pull-down trees (with actions + auto-assigned ids) keyed by
   *  toolbar item id. Populated only for items that have a `menu`. */
  menuTrees: Map<string, MenuItemDef[]>;
} {
  const actions = new Map<string, (ctx?: ActionContext) => void>();
  const menuActions = new Map<string, (ctx?: ActionContext) => void>();
  const menuTrees = new Map<string, MenuItemDef[]>();
  const menuIdsByItem = new Map<string, Set<string>>();
  const seen = new Set<string>();
  const items: Record<string, unknown>[] = [];
  // #782: validate an app item's optional `pane` tag (mirrors the
  // trackingSeparator pane check). Returns the tag when the named pane is
  // attached, else warns and returns undefined so the item falls back to the
  // content region — never synthesizing an orphan region separator.
  const validatedPane = (it: Record<string, any>): "sidebar" | "inspector" | undefined => {
    const p = it.pane;
    if (p !== "sidebar" && p !== "inspector") return undefined;
    const ok = p === "inspector" ? hasInspector : hasSidebar;
    if (!ok) {
      console.warn(`[zapp] toolbar: item "${it.id ?? it.type ?? "?"}" is tagged pane:"${p}" but the window has no ${p} — pane tag ignored`);
      return undefined;
    }
    return p;
  };
  for (const item of toolbar.items ?? []) {
    // Internal cast: the union is author-facing; internal heterogeneous reads
    // use `it` so the type system stays author-safe without narrowing every branch.
    const it = item as Record<string, any>;
    const type = it.type ?? "button";
    const placement: ToolbarPlacement = it.placement ?? "leading";
    if (placement !== "leading" && placement !== "center" && placement !== "trailing") {
      throw new Error(`[zapp] toolbar: invalid placement "${placement}" — use "leading", "center", or "trailing"`);
    }
    if (type === "toggleSidebar") {
      if (it.menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      if (!hasSidebar) {
        console.warn(`[zapp] toolbar: "toggleSidebar" requires the window to have a sidebar — item dropped`);
        continue;
      }
      items.push({ type, placement });
      continue;
    }
    if (type === "toggleInspector") {
      if (it.menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      if (!hasInspector) {
        console.warn(`[zapp] toolbar: "toggleInspector" requires the window to have an inspector — item dropped`);
        continue;
      }
      items.push({ type, placement });
      continue;
    }
    if (type === "trackingSeparator") {
      if (it.menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      const pane = it.pane ?? "sidebar";
      const ok = pane === "inspector" ? hasInspector : hasSidebar;
      if (!ok) {
        console.warn(`[zapp] toolbar: "trackingSeparator" (pane: "${pane}") requires the window to have ${pane === "inspector" ? "an" : "a"} ${pane} — item dropped`);
        continue;
      }
      items.push({ type, pane, placement });
      continue;
    }
    if (type === "space" || type === "flexibleSpace") {
      if (it.menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      const spacePane = validatedPane(it);
      items.push(spacePane ? { type, pane: spacePane, placement } : { type, placement });
      continue;
    }
    if (type === "label") {
      if (!it.text) throw new Error('[zapp] toolbar: "label" items require a non-empty "text"');
      if (it.id) {
        assertValidToolbarId(it.id);
        if (seen.has(it.id)) throw new Error(`[zapp] toolbar: duplicate item id "${it.id}"`);
        seen.add(it.id);
      } else {
        it.id = `zapp.label.${items.length}`;
      }
      const labelWire: Record<string, unknown> = { type: "label", id: it.id, text: it.text, placement };
      const labelPane = validatedPane(it);
      if (labelPane) labelWire.pane = labelPane;
      items.push(labelWire);
      continue;
    }
    if (type === "segmented") {
      if (!it.id) throw new Error('[zapp] toolbar: "segmented" items require an "id"');
      if (!it.segments || it.segments.length === 0) throw new Error('[zapp] toolbar: "segmented" requires a non-empty "segments" array');
      assertValidToolbarId(it.id);
      if (seen.has(it.id)) throw new Error(`[zapp] toolbar: duplicate item id "${it.id}"`);
      seen.add(it.id);
      const wireSegs = it.segments.map((s: any, i: number) => {
        if (s.action) actions.set(`${it.id}:${i}`, s.action);
        if (s.icon && !s.label) {
          console.warn(`[zapp] toolbar: icon-only segment in "${it.id}" has no "label" — AppKit uses labels for the collapsed/overflow menu (add one to avoid a blank menu entry)`);
        }
        const w: Record<string, unknown> = {};
        if (s.id !== undefined) w.id = s.id;
        if (s.label !== undefined) w.label = s.label;
        if (s.icon !== undefined) w.icon = s.icon;
        if (s.enabled !== undefined) w.enabled = s.enabled;
        return w;
      });
      const seg: Record<string, unknown> = { type: "segmented", id: it.id, segments: wireSegs,
        selectionMode: it.selectionMode ?? "momentary", selected: selectedToWire(it.selected) };
      if (it.label !== undefined) seg.label = it.label;
      if (it.icon !== undefined) seg.icon = it.icon;
      if (it.controlRepresentation !== undefined) seg.controlRepresentation = it.controlRepresentation;
      seg.placement = placement;
      const segPane = validatedPane(it);
      if (segPane) seg.pane = segPane;
      items.push(seg);
      continue;
    }
    if (type === "group") {
      if (!it.id) throw new Error('[zapp] toolbar: "group" items require an "id"');
      if (!it.items || it.items.length === 0) throw new Error('[zapp] toolbar: "group" requires a non-empty "items" array');
      assertValidToolbarId(it.id);
      if (seen.has(it.id)) throw new Error(`[zapp] toolbar: duplicate item id "${it.id}"`);
      seen.add(it.id);
      const wireItems: Record<string, unknown>[] = [];
      for (const sub of it.items as Array<Record<string, any>>) {
        if (sub.type === "group" || sub.type === "segmented") throw new Error('[zapp] toolbar: groups cannot nest groups');
        if (!sub.id) throw new Error('[zapp] toolbar: group sub-items require an "id"');
        assertValidToolbarId(sub.id);
        if (seen.has(sub.id)) throw new Error(`[zapp] toolbar: duplicate item id "${sub.id}"`);
        seen.add(sub.id);
        if (sub.action) actions.set(sub.id, sub.action);
        const w: Record<string, unknown> = { type: "button", id: sub.id, label: sub.label ?? "", icon: sub.icon ?? "" };
        if (sub.enabled !== undefined) w.enabled = sub.enabled;
        if (sub.bordered !== undefined) w.bordered = sub.bordered;
        wireItems.push(w);
      }
      const g: Record<string, unknown> = { type: "group", id: it.id, items: wireItems };
      if (it.controlRepresentation !== undefined) g.controlRepresentation = it.controlRepresentation;
      g.placement = placement;
      const groupPane = validatedPane(it);
      if (groupPane) g.pane = groupPane;
      items.push(g);
      continue;
    }
    if (!it.id) throw new Error('[zapp] toolbar: button items require an "id"');
    if (it.action && it.menu) {
      throw new Error('[zapp] toolbar: a button cannot have both "action" and "menu" — the menu consumes the click');
    }
    assertValidToolbarId(it.id);
    if (seen.has(it.id)) throw new Error(`[zapp] toolbar: duplicate item id "${it.id}"`);
    seen.add(it.id);
    if (it.action) actions.set(it.id, it.action);
    const wire: Record<string, unknown> = { type: "button", id: it.id, label: it.label ?? "", icon: it.icon ?? "" };
    if (it.enabled !== undefined) wire.enabled = it.enabled;
    if (it.indicator !== undefined) wire.indicator = it.indicator;
    if (it.style !== undefined) wire.style = it.style;
    if (it.tintColor !== undefined) wire.tintColor = it.tintColor;
    if (it.bordered !== undefined) wire.bordered = it.bordered;
    if (it.badge !== undefined) wire.badge = badgeToWire(it.badge);
    if (it.menu) {
      const itemMenuActions = new Map<string, (ctx?: ActionContext) => void>();
      // #771 T8 round-2 review: fold `url` in alongside `windowId` — round 1's
      // `${windowId}_${itemId}` base collided across sibling routes on one
      // window reusing the same item id (see stripMenuActions' doc comment).
      const idBase = windowId ? `${windowId}_${url}_${it.id}` : undefined;
      const strippedMenu = stripMenuActions(it.menu, itemMenuActions, idBase);
      wire.menu = strippedMenu;
      for (const [mid, fn] of itemMenuActions) menuActions.set(mid, fn);
      if (itemMenuActions.size > 0) menuIdsByItem.set(it.id, new Set(itemMenuActions.keys()));
      // Retain a tree with ids (from stripped) + actions (from originals) for
      // ctx.update in pull-down callbacks (patchMenuTree + updateItem refresh).
      menuTrees.set(it.id!, mergeMenuIds(strippedMenu, it.menu));
    }
    wire.placement = placement;
    const buttonPane = validatedPane(it);
    if (buttonPane) wire.pane = buttonPane;
    items.push(wire);
  }
  return { json: JSON.stringify({ style: toolbar.style ?? "unified", items: applyToolbarConventions(items) }), actions, menuActions, menuIdsByItem, menuTrees };
}

const TOOLBAR_PATCH_KEYS = new Set(["label", "text", "icon", "enabled", "indicator", "menu", "action", "style", "tintColor", "badge", "bordered", "selected", "controlRepresentation"]);

/** Validate a ToolbarItemPatch and split it into the wire JSON (only
 * patched keys, plus id), the replacement action, and stripped menu
 * actions. Pure — unit-tested. */
export function normalizeToolbarPatch(
  id: string,
  patch: ToolbarItemPatch,
): { json: string; action?: (ctx?: ActionContext) => void; menuActions: Map<string, (ctx?: ActionContext) => void>; menuTree?: MenuItemDef[] } {
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
  const menuActions = new Map<string, (ctx?: ActionContext) => void>();
  const wire: Record<string, unknown> = { id };
  if (patch.label !== undefined) wire.label = patch.label;
  if (patch.text !== undefined) wire.text = patch.text;
  // Empty icon strings are stripped: native ignores them on the live item,
  // but a merged stored def carrying "" would silently lose the icon on the
  // next shape rebuild. Icons can be swapped, not cleared (documented).
  if (patch.icon !== undefined && patch.icon !== "") wire.icon = patch.icon;
  if (patch.enabled !== undefined) wire.enabled = patch.enabled;
  if (patch.indicator !== undefined) wire.indicator = patch.indicator;
  if (patch.style !== undefined) wire.style = patch.style;
  if (patch.tintColor !== undefined) wire.tintColor = patch.tintColor;
  if (patch.bordered !== undefined) wire.bordered = patch.bordered;
  if (patch.badge !== undefined) wire.badge = badgeToWire(patch.badge);
  if (patch.selected !== undefined) wire.selected = selectedToWire(patch.selected);
  if (patch.controlRepresentation !== undefined) wire.controlRepresentation = patch.controlRepresentation;
  let menuTree: MenuItemDef[] | undefined;
  if (patch.menu !== undefined) {
    const strippedMenu = stripMenuActions(patch.menu, menuActions);
    wire.menu = strippedMenu;
    menuTree = mergeMenuIds(strippedMenu, patch.menu);
  }
  // Explicit-undefined values pass the keys.length guard above (key exists,
  // value is undefined) but produce a wire with only the id — detect here.
  if (Object.keys(wire).length === 1 && !patch.action) {
    throw new Error('[zapp] toolbar: empty patch — pass at least one of label/icon/enabled/indicator/menu/action');
  }
  return { json: JSON.stringify(wire), action: patch.action, menuActions, menuTree };
}

/** A handle to the sidebar attached to a window. */
export interface SidebarHandle {
  toggle(): void;
  collapse(): void;
  expand(): void;
  setWidth(px: number): void;
  /**
   * Reveal the content (secondary) column / collapse the sidebar.
   * - iPhone (compact): drives the collapsed nav stack to the content pane.
   * - iPad (regular): hides the sidebar — `tile` collapses it beside content,
   *   `overlay` dismisses the flyout.
   * - macOS: collapses the tiled sidebar.
   * Only a true no-op when the window has no sidebar.
   */
  showContent(): void;
  /**
   * Reveal the sidebar (primary) column.
   * - iPhone (compact): pops the nav stack back to the sidebar ("back").
   * - iPad (regular): shows the sidebar — `tile` slides it beside content,
   *   `overlay` floats the flyout in.
   * - macOS: expands the tiled sidebar.
   */
  showSidebar(): void;
  /** Allow/disallow the user collapsing the pane (system behaviors: divider
   *  snap, toolbar toggle). Programmatic collapse/expand still work. */
  setCollapsible(allowed: boolean): void;
  /** Allow/disallow resizing by dragging the divider. false locks the current width. */
  setResizable(allowed: boolean): void;
  /** Switch the iPad sidebar split presentation at runtime. iOS-only;
   *  no-op on macOS (AppKit tiles, never overlays). */
  setPresentation(mode: "automatic" | "tile" | "overlay"): void;
  /** Update the sidebar pane's title live. iOS updates the sidebar nav's
   *  navigationItem.title; macOS is a no-op (the app owns the sidebar header
   *  in HTML). v1 boundary: if the sidebar bar is currently hidden (no title
   *  + no items → want-state NO), the title is stored but the bar itself
   *  won't appear until the next viewWillAppear. */
  setTitle(s: string): void;
  /** Tracked from SIDEBAR_COLLAPSED/EXPANDED events, seeded by the create option. */
  readonly collapsed: boolean;
  /** Last width from SIDEBAR_RESIZED (the create option until the first event). */
  readonly width: number;
}

/** Handle to a window's inspector. On iPhone the pane ops present/dismiss a
 *  sheet; on iPad/macOS they show/hide the trailing pane. */
export interface InspectorHandle {
  toggle(): void;
  collapse(): void;
  expand(): void;
  setWidth(px: number): void;
  /** Allow/disallow the user collapsing the pane. Programmatic collapse/expand still work. */
  setCollapsible(allowed: boolean): void;
  /** Allow/disallow resizing by dragging the divider. false locks the current width. */
  setResizable(allowed: boolean): void;
  /** Update the inspector pane's title live. iOS updates the inspector nav's
   *  navigationItem.title; macOS is a no-op (the app owns the inspector header
   *  in HTML). */
  setTitle(s: string): void;
  /** Tracked from INSPECTOR_COLLAPSED/EXPANDED, seeded by the create option. */
  readonly collapsed: boolean;
  /** Last width from INSPECTOR_RESIZED (the create option until the first event). */
  readonly width: number;
}

/**
 * Options passed to `router.push` and `router.replace`.
 * - `url` is the logical route path (e.g. `"/settings"`).
 * - `title` is an optional display title hint; native may surface it in the
 *   toolbar's back-button label or window title (N2b).
 * - `params` are ephemeral route parameters — they are NOT encoded in the
 *   URL. They are available via `router.params` until the next navigation.
 *   Use the URL itself for durable, bookmarkable identity.
 * - `presentation` is an iOS sheet presentation style, only meaningful when
 *   the route maps to a sheet (`asSheetOf`). Ignored on macOS.
 */
export interface RouteOptions {
  url: string;
  title?: string;
  params?: Record<string, unknown>;
  presentation?: "page" | "form" | "fullscreen" | "bottomSheet";
  /**
   * iOS native routing only: hide the native navigation bar for this pushed
   * route (bring-your-own-chrome pages). Edge swipe-back KEEPS working — the
   * framework re-arms the pop gesture. Ignored on macOS/Windows and by
   * `replace`.
   */
  navbar?: { hidden: boolean };
  /**
   * iOS native routing only: per-route toolbar override for the pushed view
   * controller's nav bar. Falls back to the window's toolbar when absent.
   * Same item defs as `toolbar.setItems` (actions are stripped + registered
   * the same way). `updateItem` keeps targeting the WINDOW toolbar defs —
   * override items are static for their route's lifetime (v1). Prefer item
   * ids distinct from the window toolbar's.
   */
  toolbar?: ToolbarItemDef[];
}

/**
 * Handle for a window's logical route stack. Always present on `WindowHandle`
 * and accessible from any context (webview or worker) by window id.
 *
 * State (url/params/canGoBack/canGoForward) is seeded from native via a
 * best-effort `__router:state` INVOKE on construction, then kept current via
 * `ROUTE_CHANGED` broadcast events filtered to this window's id.
 */
export interface RouterHandle {
  /** Navigate to a new route, pushing it onto the stack. Truncates any
   *  forward history. */
  push(opts: RouteOptions | string): void;
  /** Navigate back one step. No-op if at the root. */
  pop(): void;
  /** Navigate forward one step (after a pop). No-op if at the head. */
  forward(): void;
  /** Replace the current route in place. Does NOT affect forward history. */
  replace(opts: RouteOptions | string): void;
  /** Pop all entries back to the root route. No-op if already at root. */
  popToRoot(): void;
  /** Subscribe to ROUTE_CHANGED for this window. Returns an unsubscribe fn. */
  on(handler: (payload: RouteChangedPayload) => void): () => void;
  /** Resolve the authoritative current route from native (async). Updates the
   *  cache and returns the snapshot. Use for first render / reload-restore,
   *  where the synchronously-cached getters may not be seeded yet. */
  current(): Promise<{ url: string; params: Record<string, unknown> | null; canGoBack: boolean; canGoForward: boolean }>;
  /** Whether the router can go back (at least one entry before current). */
  readonly canGoBack: boolean;
  /** Whether the router can go forward (entries after current exist). */
  readonly canGoForward: boolean;
  /** The current route URL. Empty string before the first navigation. */
  readonly url: string;
  /** The current route params (ephemeral — not in URL). `null` when none. */
  readonly params: Record<string, unknown> | null;
}

/** Size events that include width/height/position data. */
type SizeEvent = WindowEvent.RESIZE | WindowEvent.MOVE | WindowEvent.MAXIMIZE | WindowEvent.RESTORE;

/** A handle to a specific window. */
export interface WindowHandle {
  readonly id: string;
  /** Handle for the sidebar attached to this window, if any. */
  readonly sidebar?: SidebarHandle;
  /** Handle for the inspector attached to this window, if any. */
  readonly inspector?: InspectorHandle;
  /** Lifecycle handle for this window's native toolbar (macOS). Always
   *  present — setItems attaches when no toolbar exists. */
  readonly toolbar: ToolbarHandle;
  /** Router handle — push/pop/forward/replace/popToRoot + canGoBack/
   *  canGoForward/url/params getters. Always present; works from any
   *  context (webview or worker) using the window id. */
  readonly router: RouterHandle;

  on(event: SizeEvent, handler: (payload: WindowSizePayload) => void): () => void;
  on(event: WindowEvent.MODAL_DISMISSED, handler: (payload: ModalDismissedPayload) => void): () => void;
  on(event: WindowEvent.SIDEBAR_RESIZED, handler: (payload: SidebarResizedPayload) => void): () => void;
  on(event: WindowEvent.INSPECTOR_RESIZED, handler: (payload: InspectorResizedPayload) => void): () => void;
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
  /** Toggle between standard and zoomed (macOS `zoom:` toggle). No-op on iOS. */
  zoom(): void;
  setFullscreen(on: boolean): void;
  setAlwaysOnTop(on: boolean): void;
  setCloseGuard(enabled: boolean): void;
  loadUrl(url: string): void;
  /** The display this window is currently on (top-left global coords). */
  getScreen(): Promise<Display>;

  /**
   * Open DevTools for this window's web content, in its own standalone
   * window. Engine-aware: on a CEF (`webview.engine: "chromium"`) window this opens
   * real Chromium DevTools (dev-gated — same `webContentInspectable` gate as
   * the WKWebView inspector); on a standard WKWebView window this is a no-op
   * (use the macOS system Develop menu / right-click "Inspect Element").
   */
  openDevTools(): void;
  /** Close the DevTools window opened by `openDevTools()`, if any. No-op on
   *  WKWebView (see `openDevTools`). */
  closeDevTools(): void;

  /**
   * Attach `modal` as a sheet on this window. The modal slides down from
   * this window's titlebar and blocks interaction with the parent (only)
   * until dismissed. Closing the modal — via its close button,
   * `modal.close()`, or `modal.destroy()` — auto-dismisses the sheet.
   *
   * Honored options on the modal: `title`, `url`, `width`, `height`,
   * `transparent`, `webContentInspectable`. Position, fullscreen,
   * borderless, titleBarStyle, windowControls, and alwaysOnTop are
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
    showContent()         { windowAction("sidebar:showContent", { windowId }); },
    showSidebar()         { windowAction("sidebar:showSidebar", { windowId }); },
    setCollapsible(allowed: boolean) { windowAction("sidebar:setCollapsible", { windowId, value: allowed }); },
    setResizable(allowed: boolean)   { windowAction("sidebar:setResizable",   { windowId, value: allowed }); },
    setPresentation(mode: "automatic" | "tile" | "overlay") { windowAction("sidebar:setPresentation", { windowId, mode }); },
    setTitle(s: string)   { windowAction("sidebar:setTitle", { windowId, title: s }); },
  };
}

/** Per-window inspector state, shared across repeated Window.current() calls. */
const inspectorState = new Map<string, { collapsed: boolean; width: number }>();
/** Windows whose inspector event listeners are already registered. */
const inspectorWired = new Set<string>();

/** Create an InspectorHandle that tracks collapsed/width state via events. */
function createInspectorHandle(
  windowId: string,
  initialCollapsed: boolean,
  initialWidth: number,
): InspectorHandle {
  if (!inspectorState.has(windowId)) {
    inspectorState.set(windowId, { collapsed: initialCollapsed, width: initialWidth });
  }
  if (!inspectorWired.has(windowId)) {
    const bridge = getBridge();
    bridge.on(eventName(WindowEvent.INSPECTOR_COLLAPSED), (payload: any) => {
      if (payload?.windowId === windowId) inspectorState.get(windowId)!.collapsed = true;
    });
    bridge.on(eventName(WindowEvent.INSPECTOR_EXPANDED), (payload: any) => {
      if (payload?.windowId === windowId) inspectorState.get(windowId)!.collapsed = false;
    });
    bridge.on(eventName(WindowEvent.INSPECTOR_RESIZED), (payload: any) => {
      if (payload?.windowId === windowId && typeof payload.width === "number") {
        inspectorState.get(windowId)!.width = payload.width;
      }
    });
    inspectorWired.add(windowId);
  }
  return {
    get collapsed() { return inspectorState.get(windowId)!.collapsed; },
    get width()     { return inspectorState.get(windowId)!.width; },
    toggle()              { windowAction("inspector:toggle",   { windowId }); },
    collapse()            { windowAction("inspector:collapse", { windowId }); },
    expand()              { windowAction("inspector:expand",   { windowId }); },
    setWidth(px: number)  { windowAction("inspector:setWidth", { windowId, width: px }); },
    setCollapsible(allowed: boolean) { windowAction("inspector:setCollapsible", { windowId, value: allowed }); },
    setResizable(allowed: boolean)   { windowAction("inspector:setResizable",   { windowId, value: allowed }); },
    setTitle(s: string)              { windowAction("inspector:setTitle", { windowId, title: s }); },
  };
}

/**
 * Module-scope router state records keyed by windowId. Shared across repeated
 * createWindowHandle calls (same pattern as sidebarState / inspectorState).
 */
const routerState = new Map<string, { url: string; params: Record<string, unknown> | null; canGoBack: boolean; canGoForward: boolean; version: number }>();

/** Windows whose ROUTE_CHANGED bridge listener is already registered. */
const routerWired = new Set<string>();

/** Create a RouterHandle that caches route state from ROUTE_CHANGED events.
 *  `hasSidebar`/`hasInspector` describe the window's pane shape so a
 *  per-route `toolbar` override (R2′ #771) validates pane-dependent items
 *  exactly like `toolbar.setItems` does. */
function createRouterHandle(windowId: string, hasSidebar = false, hasInspector = false): RouterHandle {
  // Seed with defaults on first creation; leave alone if already seeded.
  if (!routerState.has(windowId)) {
    routerState.set(windowId, { url: "", params: null, canGoBack: false, canGoForward: false, version: 0 });
  }

  // Wire the live listener + best-effort seed ONCE per window (M-a). The seed is
  // version-guarded so a push that lands before it resolves is never clobbered
  // by the stale snapshot (M-c).
  if (!routerWired.has(windowId)) {
    const bridge = getBridge();
    bridge.on(eventName(WindowEvent.ROUTE_CHANGED), (payload: any) => {
      if (payload?.windowId === windowId) {
        const rec = routerState.get(windowId);
        if (rec) {
          rec.url          = payload.url;
          rec.params       = payload.params ?? null;
          rec.canGoBack    = payload.canGoBack;
          rec.canGoForward = payload.canGoForward;
          rec.version++;
        }
      }
    });
    const seedVersion = routerState.get(windowId)!.version;
    bridge.invoke("__router:state", { windowId }).then((r: any) => {
      if (r && typeof r === "object") {
        const rec = routerState.get(windowId);
        // Only apply the seed if no ROUTE_CHANGED arrived meanwhile (M-c).
        if (rec && rec.version === seedVersion) {
          if (typeof r.url === "string")              rec.url          = r.url;
          if (r.params !== undefined)                 rec.params       = r.params ?? null;
          if (typeof r.canGoBack === "boolean")       rec.canGoBack    = r.canGoBack;
          if (typeof r.canGoForward === "boolean")    rec.canGoForward = r.canGoForward;
        }
      }
    }).catch(() => { /* best-effort — ignore failures (e.g. route not yet seeded) */ });
    routerWired.add(windowId);
  }

  return {
    push(opts: RouteOptions | string): void {
      const o = typeof opts === "string" ? { url: opts } : opts;
      // R2′ (#771): a per-route toolbar override serializes through the SAME
      // normalizeToolbar pipeline as toolbar.setItems (actions stripped +
      // registered), but WITHOUT purging — route overrides register
      // additively so the window toolbar's own actions survive the route.
      let toolbarJson: string | undefined;
      if (o.toolbar !== undefined) {
        // I3 (#771 T8 review); round-2 review: pass windowId AND url so
        // auto-generated menu-item ids derive from (windowId, url, itemId,
        // menu-path-index) instead of the module-global counter — repeating
        // this same push (e.g. after a pop/forward round-trip, or the app
        // just pushing the same route again) re-derives the SAME ids and
        // overwrites the existing map entries instead of minting fresh ones
        // and orphaning the old, while two DIFFERENT routes reusing the same
        // itemId now derive DISTINCT ids (round-1 left this open — see
        // normalizeToolbar's `url` param doc).
        const { json, actions, menuActions, menuIdsByItem, menuTrees } =
          normalizeToolbar({ items: o.toolbar }, hasSidebar, hasInspector, windowId, o.url);
        const parsed = JSON.parse(json);
        delete parsed.style;               // per-route override never carries style
        toolbarJson = JSON.stringify(parsed);
        if (actions.size > 0) {
          wireToolbarClicks();
          wireToolbarGroupSelect();
          // I2 (#771 T8 review): tag each key as route-registered so a later
          // window-toolbar setItems/remove purge spares it (see
          // routeToolbarActionKeys doc comment). Round-2 review: PLAIN button
          // ids (unlike menu ids above) are NOT route-scoped — `${windowId}:${id}`
          // is the app-declared id verbatim. If a DIFFERENT route already
          // tagged this exact key, the two routes share one toolbarActions
          // entry and this push's registration silently wins (last-push-wins)
          // — warn so the app can pick distinct ids across sibling routes.
          let tagged = routeToolbarActionKeys.get(windowId);
          if (!tagged) { tagged = new Map(); routeToolbarActionKeys.set(windowId, tagged); }
          for (const [id, fn] of actions) {
            const key = `${windowId}:${id}`;
            const existingUrl = tagged.get(key);
            if (existingUrl !== undefined && existingUrl !== o.url) {
              console.warn(
                `[zapp] toolbar: route action id "${id}" is already registered by route "${existingUrl}" on this window — sibling routes sharing a toolbar action id last-push-wins (now "${o.url}"); use distinct ids across routes that can coexist on the same window's stack`,
              );
            }
            toolbarActions.set(key, fn);
            tagged.set(key, o.url);
          }
        }
        if (menuActions.size > 0) {
          wireToolbarMenuClicks();
          for (const [mid, fn] of menuActions) toolbarMenuActions.set(mid, fn);
        }
        recordToolbarMenuIds(windowId, menuIdsByItem, toolbarMenuIdsByWindow);
        for (const [itemId, tree] of menuTrees) recordToolbarMenuTree(windowId, itemId, tree);
      }
      windowAction("router:push", {
        windowId,
        url: o.url,
        ...(o.title !== undefined ? { title: o.title } : {}),
        ...(o.params !== undefined ? { params: o.params } : {}),
        ...(o.presentation !== undefined ? { presentation: o.presentation } : {}),
        ...(o.navbar !== undefined ? { navbar: o.navbar } : {}),
        ...(toolbarJson !== undefined ? { toolbarJson } : {}),
      });
    },
    pop(): void        { windowAction("router:pop",       { windowId }); },
    forward(): void    { windowAction("router:forward",   { windowId }); },
    replace(opts: RouteOptions | string): void {
      const o = typeof opts === "string" ? { url: opts } : opts;
      windowAction("router:replace", {
        windowId,
        url: o.url,
        ...(o.title !== undefined ? { title: o.title } : {}),
        ...(o.params !== undefined ? { params: o.params } : {}),
        ...(o.presentation !== undefined ? { presentation: o.presentation } : {}),
      });
    },
    popToRoot(): void  { windowAction("router:popToRoot", { windowId }); },
    on(handler: (payload: RouteChangedPayload) => void): () => void {
      const bridge = getBridge();
      return bridge.on(eventName(WindowEvent.ROUTE_CHANGED), (p: any) => {
        if (p?.windowId === windowId) handler(p as RouteChangedPayload);
      });
    },
    get canGoBack():    boolean                            { return routerState.get(windowId)!.canGoBack; },
    get canGoForward(): boolean                            { return routerState.get(windowId)!.canGoForward; },
    get url():          string                             { return routerState.get(windowId)!.url; },
    get params():       Record<string, unknown> | null     { return routerState.get(windowId)!.params; },
    async current() {
      const r: any = await getBridge().invoke("__router:state", { windowId });
      const rec = routerState.get(windowId);
      if (rec && r && typeof r === "object") {
        if (typeof r.url === "string")           rec.url          = r.url;
        if (r.params !== undefined)              rec.params       = r.params ?? null;
        if (typeof r.canGoBack === "boolean")    rec.canGoBack    = r.canGoBack;
        if (typeof r.canGoForward === "boolean") rec.canGoForward = r.canGoForward;
        rec.version++; // authoritative read counts as a write so a racing seed won't clobber it
      }
      return {
        url:          rec?.url ?? "",
        params:       rec?.params ?? null,
        canGoBack:    rec?.canGoBack ?? false,
        canGoForward: rec?.canGoForward ?? false,
      };
    },
  };
}

export function createWindowHandle(windowId: string, sidebarOpts?: SidebarOptions, inspectorOpts?: InspectorOptions): WindowHandle {
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
    zoom()                            { windowAction("zoom", { windowId }); },
    setFullscreen(on: boolean)        { windowAction("setFullscreen", { windowId, on }); },
    setAlwaysOnTop(on: boolean)       { windowAction("setAlwaysOnTop", { windowId, on }); },
    setCloseGuard(on: boolean)        { windowAction("setCloseGuard", { windowId, on }); },
    loadUrl(url: string)              { windowAction("loadUrl", { windowId, url }); },
    openDevTools()                    { windowAction("devtools:open",  { windowId }); },
    closeDevTools()                   { windowAction("devtools:close", { windowId }); },

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

    inspector: inspectorOpts !== undefined
      ? createInspectorHandle(windowId, inspectorOpts.collapsed ?? false, inspectorOpts.width ?? 280)
      : undefined,

    router: createRouterHandle(windowId, sidebarOpts !== undefined, inspectorOpts !== undefined),

    toolbar: {
      setItems(items: ToolbarItemDef[], setOpts?: { style?: "unified" | "unifiedCompact" | "expanded" }) {
        const { json, actions, menuActions, menuIdsByItem, menuTrees } =
          normalizeToolbar({ items, style: setOpts?.style }, sidebarOpts !== undefined, inspectorOpts !== undefined);
        // Parse once: guard on empty items, then conditionally strip style.
        // Only send style when the caller set one — native warns when style
        // arrives for an already-attached toolbar, and normalizeToolbar
        // always defaults it.
        const parsed = JSON.parse(json);
        assertToolbarItemsNonEmpty(json);
        if (setOpts?.style === undefined) delete parsed.style;
        const wireJson = JSON.stringify(parsed);
        purgeWindowToolbarActions(windowId, toolbarActions, toolbarMenuActions, toolbarMenuIdsByWindow, routeToolbarActionKeys);
        purgeWindowToolbarMenuTrees(windowId, toolbarMenuTrees, toolbarMenuItemOwner);
        if (actions.size > 0) {
          wireToolbarClicks();
          wireToolbarGroupSelect();
          for (const [id, fn] of actions) toolbarActions.set(`${windowId}:${id}`, fn);
        }
        if (menuActions.size > 0) {
          wireToolbarMenuClicks();
          for (const [id, fn] of menuActions) toolbarMenuActions.set(id, fn);
        }
        recordToolbarMenuIds(windowId, menuIdsByItem, toolbarMenuIdsByWindow);
        // Record retained pull-down trees for ctx.update in wireToolbarMenuClicks.
        for (const [itemId, tree] of menuTrees) {
          recordToolbarMenuTree(windowId, itemId, tree);
        }
        windowAction("toolbar:setItems", { windowId, toolbarJson: wireJson });
      },
      updateItem(id: string, patch: ToolbarItemPatch) {
        const { json, action, menuActions, menuTree } = normalizeToolbarPatch(id, patch);
        if (action) {
          wireToolbarClicks();
          wireToolbarGroupSelect();
          toolbarActions.set(`${windowId}:${id}`, action);
        }
        if (patch.menu !== undefined) {
          // The item is becoming (or refreshing) a menu button — its click is
          // consumed by the menu, so any old action callback can never fire.
          toolbarActions.delete(`${windowId}:${id}`);
          purgeItemToolbarMenuActions(windowId, id, toolbarMenuActions, toolbarMenuIdsByWindow);
          purgeItemToolbarMenuTree(windowId, id, toolbarMenuTrees, toolbarMenuItemOwner);
          if (menuActions.size > 0) {
            wireToolbarMenuClicks();
            for (const [mid, fn] of menuActions) toolbarMenuActions.set(mid, fn);
            recordToolbarMenuIds(windowId, new Map([[id, new Set(menuActions.keys())]]), toolbarMenuIdsByWindow);
          }
          // Refresh retained pull-down tree for ctx.update.
          if (menuTree) {
            recordToolbarMenuTree(windowId, id, menuTree);
          }
        }
        windowAction("toolbar:updateItem", { windowId, itemJson: json });
      },
      remove() {
        purgeWindowToolbarActions(windowId, toolbarActions, toolbarMenuActions, toolbarMenuIdsByWindow, routeToolbarActionKeys);
        purgeWindowToolbarMenuTrees(windowId, toolbarMenuTrees, toolbarMenuItemOwner);
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
    const inInspectorWindow = Window.isInspector() ||
      (globalThis as any)[Symbol.for("zapp.hasInspector")] === true;
    const inspectorOpts: InspectorOptions | undefined = inInspectorWindow
      ? { url: "" }  // url unused here — the pane is already running; we only need the shape.
      : undefined;
    return createWindowHandle(id, sidebarOpts, inspectorOpts);
  },

  /** True when this code runs inside a window's sidebar webview.
   *
   * Native sets Symbol.for('zapp.isSidebar') in the sidebar webview's
   * bootstrap (window.m/webview.m, sidebar cycle).
   */
  isSidebar(): boolean {
    return (globalThis as any)[Symbol.for("zapp.isSidebar")] === true;
  },

  /** True when this code runs inside a window's inspector webview. */
  isInspector(): boolean {
    return (globalThis as any)[Symbol.for("zapp.isInspector")] === true;
  },

  /** Create a new window. Returns a handle for the new window. */
  async create(opts?: Partial<WindowOptions>): Promise<WindowHandle> {
    // iOS is single-window. A secondary top-level window would materialize a
    // stacked UIWindow, which corrupts UIKit's presentation state (presenting a
    // sheet on top crashes — "unbalanced begin/end appearance transitions"). The
    // supported secondary-surface patterns on iOS are sheets (`asSheetOf`) and
    // sidebar/inspector panes. So a non-sheet create on iOS is a no-op that
    // returns the current (main) window. iPad multi-window (UIScene) is planned.
    if (Platform.isIOS && opts?.asSheetOf === undefined) {
      const current = Window.current();
      if (opts?.url) {
        // iOS is single-window: a non-sheet create becomes an in-window route
        // push. The logical stack + ROUTE_CHANGED + content-swap all work on the
        // single webview; native UINavigationController routing is a later cycle.
        console.warn(
          "[zapp] iOS is single-window — Window.create() without `asSheetOf` became an " +
          "in-window route push (router.push). Use a sheet (`asSheetOf`) for a modal " +
          "surface; iPad multi-window is planned.",
        );
        current.router.push({
          url: opts.url,
          ...(opts.title !== undefined ? { title: opts.title } : {}),
          ...(opts.presentation !== undefined ? { presentation: opts.presentation } : {}),
        });
      } else {
        console.warn(
          "[zapp] iOS is single-window — Window.create() without `asSheetOf` is a no-op " +
          "(returns the current window). Use a sheet (`asSheetOf`) or a sidebar/inspector " +
          "pane for secondary surfaces; iPad multi-window is planned.",
        );
      }
      return current;
    }
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
    //
    // #782 desugar: the window toolbar plus any pane-scoped `sidebar.toolbar`
    // / `inspector.toolbar` fold into ONE toolbar def (pane items tagged), so
    // there is a single normalized wire toolbar for the window.
    let pendingToolbarActions: Map<string, () => void> | undefined;
    let pendingToolbarMenuIds: Map<string, Set<string>> | undefined;
    const combinedToolbar = mergePaneToolbars(
      opts?.mac?.toolbar ?? opts?.toolbar,   // Tier-2 mac:{toolbar}; top-level is deprecated
      opts?.sidebar?.toolbar,
      opts?.inspector?.toolbar,
    );
    if (combinedToolbar) {
      const { json, actions, menuActions, menuIdsByItem } = normalizeToolbar(combinedToolbar, opts?.sidebar !== undefined, opts?.inspector !== undefined);
      normalized.toolbarJson = json;
      delete normalized.toolbar;
      // The toolbar (now toolbarJson) may have come from mac:{toolbar}; strip it
      // from the payload too — its action closures aren't serializable.
      if (normalized.mac && (normalized.mac as MacOptions).toolbar) {
        const { toolbar: _m, ...rest } = normalized.mac as MacOptions;
        normalized.mac = rest;
      }
      // Strip the pane-scoped toolbars from the native payload — their items
      // now live in toolbarJson, and their `action` callbacks aren't
      // serializable. Shallow-copy the pane options first so we never mutate
      // the caller's `opts`. Pane titles stay put (native reads them directly).
      if (normalized.sidebar && (normalized.sidebar as SidebarOptions).toolbar) {
        const { toolbar: _s, ...rest } = normalized.sidebar as SidebarOptions;
        normalized.sidebar = rest;
      }
      if (normalized.inspector && (normalized.inspector as InspectorOptions).toolbar) {
        const { toolbar: _i, ...rest } = normalized.inspector as InspectorOptions;
        normalized.inspector = rest;
      }
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
      wireToolbarGroupSelect();
      for (const [id, fn] of pendingToolbarActions) toolbarActions.set(`${windowId}:${id}`, fn);
    };
    // Worker context: call the createWindow host directly (sync C call).
    const host = (globalThis as any).__zappBridge;
    if (host?.createWindow) {
      const r = host.createWindow(normalized) as { windowId: string };
      registerToolbarActions(r.windowId);
      return createWindowHandle(r.windowId, opts?.sidebar, opts?.inspector);
    }
    // Webview context: async IPC roundtrip through the WKWebView bridge.
    const result = await getBridge().invoke("__window:create", normalized) as { windowId: string };
    registerToolbarActions(result.windowId);
    return createWindowHandle(result.windowId, opts?.sidebar, opts?.inspector);
  },

  /**
   * Get a handle for any window by its id string (e.g. `"win-1"`). Works
   * from any context — webview, worker, or backend. Does NOT perform a
   * round-trip; the handle's router/toolbar/base ops all use the supplied id.
   *
   * Note: sidebar/inspector ops on cross-window handles are not supported in
   * v1 — those require the native window to be the current context.
   */
  get(id: string): WindowHandle {
    return createWindowHandle(id);
  },

  /**
   * List all currently open windows. Returns `WindowHandle` objects for each.
   *
   * Backed by the `__zapp:windows-list` native INVOKE. Requires the bridge's
   * `invoke` to be available (it is in both webview and worker contexts).
   *
   * @example
   * ```ts
   * const wins = await Window.all();
   * console.log(wins.map(w => w.id));
   * ```
   */
  async all(): Promise<WindowHandle[]> {
    let r: { ids?: string[] } | undefined;
    try {
      r = await getBridge().invoke("__zapp:windows-list", {}) as { ids?: string[] };
    } catch (e) {
      console.warn("[zapp] Window.all(): invoke failed —", e);
      return [];
    }
    return (r?.ids ?? []).map((id) => createWindowHandle(id));
  },
};

/**
 * Frontend-safe options for creating a native window.
 *
 * Trusted document-start/document-end/style injection is intentionally absent:
 * those profiles are application-owned native policy, not WebView input.
 */
export type WindowCreateOptions = Pick<
  WindowOptions,
  "title" | "url" | "width" | "height" | "visible" | "resizable"
>;

/** Return the identity-bearing handle for the current WebView window. */
export function currentWindow(): WindowHandle {
  return Window.current();
}

/**
 * Ask the application-owned native WindowManager to realize a new window.
 * Creation is asynchronous because the WebView/native boundary can fail.
 */
export async function createWindow(
  options: WindowCreateOptions = {},
): Promise<WindowHandle> {
  ensurePermission("window:create");
  const host = (globalThis as any).__zappBridge;
  if (host?.createWindow) {
    const result = host.createWindow(options) as { windowId: string };
    return createWindowHandle(result.windowId);
  }
  const result = await getBridge().invoke(
    "__window:create",
    options as Record<string, unknown>,
  ) as { windowId: string };
  return createWindowHandle(result.windowId);
}
