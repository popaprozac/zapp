# Native Toolbar (macOS v1) — Design

**Date:** 2026-06-11
**Branch:** `feat/native-toolbar`
**Status:** Approved

## Goal

Real `NSToolbar` on Zapp windows — the sidebar-toggle pairing from the
native-elements roadmap ("native chrome you can't fake in CSS"). v1 scope:
the system sidebar-toggle button + tracking separator, plus declarative
custom SF-symbol buttons with click delivery matching the menu pattern.

## Decisions (user-confirmed)

1. **v1 scope:** toggle + custom items. Search field, dropdown items,
   dynamic updates deferred.
2. **API shape:** create-time only — `Window.create({ toolbar: {...} })`,
   mirroring the sidebar v1 precedent. No `setItems` in v1.
3. **Click delivery:** the menu pattern — one native broadcast feeding both
   surfaces: creator-context `action` callbacks (Menu.build's shape) AND a
   `WindowEvent.TOOLBAR_CLICKED` window event for panes.
4. **Architecture:** dedicated `toolbar.m` registry module (sidebar.m's
   shape), not inline in window.m.
5. **Style:** `style` option mapping to `NSWindow.toolbarStyle`, default
   `"unified"`.

## API surface (runtime/window.ts)

```ts
export interface ToolbarItemDef {
  /** Custom-button identifier; REQUIRED for type "button" (it keys click
   *  routing). Ignored for system types. */
  id?: string;
  /** "button" (default) | "toggleSidebar" | "trackingSeparator" |
   *  "space" | "flexibleSpace" */
  type?: "button" | "toggleSidebar" | "trackingSeparator" | "space" | "flexibleSpace";
  /** Tooltip; visible text in the "expanded" style. */
  label?: string;
  /** Icon via the existing resolver: "sf:<symbol>", file path, or data URL. */
  icon?: string;
  /** Creator-context callback (menu pattern). Stripped before the wire. */
  action?: () => void;
}

export interface ToolbarOptions {
  items: ToolbarItemDef[];
  /** NSWindow.toolbarStyle. Default "unified". */
  style?: "unified" | "unifiedCompact" | "expanded";
}

// WindowOptions gains:
toolbar?: ToolbarOptions;
```

`WindowEvent` gains `TOOLBAR_CLICKED = 15` → `"window:toolbar-clicked"`,
payload `{ id: string }`. Like the sidebar events (12–14), 15 is above the
native event-table cap — irrelevant here because TOOLBAR_CLICKED never goes
through the native table at all (see Click delivery).

### Validation rules

- `type: "button"` (or omitted type) without `id` → error at create
  (rejected in runtime before the wire).
- `toggleSidebar` / `trackingSeparator` on a window with no `sidebar`
  option → warn (`[zapp]` log) and drop the item; remaining items still
  attach.
- Duplicate button ids → error.

## Click delivery — one emit, two surfaces

Native custom-button click → app-wide broadcast, verbatim menu.m pattern
(escape id, `__toolbar:click`, `darwin_webview_eval_all` +
`worker_broadcast_eval_js`):

```
__toolbar:click  payload {"windowId":"win-<n>","id":"<itemId>"}
```

(The windowId field is the one addition vs `__menu:click` — toolbars are
per-window, menus are app-global.)

On top of that single emit:

1. **Creator callbacks** — `Window.create` collects `action` fns into a
   module-level map keyed `"<windowId>:<itemId>"` (populated after create
   resolves and the windowId is known), with one module-level
   `Events.on("__toolbar:click")` listener running matches. Exactly
   Menu.build's collect/strip/listen shape (runtime/menu.ts:78–96).
2. **Pane window event** — `win.on(WindowEvent.TOOLBAR_CLICKED, h)` is
   runtime-only sugar in `createWindowHandle`: subscribes the same
   broadcast and filters `payload.windowId === this windowId`. No second
   native path, no dispatchWindowEvent involvement.

Broadcasts reach sidebar-window panes because `darwin_webview_eval_all`
iterates the webview dispatch table (fixed `dc009c4`).

## Native: toolbar.m (new file)

Registry + delegate module, sidebar.m's shape:

- `static NSMutableDictionary<NSValue*, ZappToolbarController*>* zapp_toolbars`
  keyed by NSWindow pointer.
- `ZappToolbarController : NSObject <NSToolbarDelegate>` holds the
  NSToolbar, the parsed item-def array (from JSON via NSJSONSerialization
  — same parser tray.m uses), and the host window's numeric id (for the
  click payload's windowId).
- **`void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json)`**
  (router/window.m entry point): parse json `{style, items}`, build the
  identifier list in declared order, set `window.toolbarStyle`
  (unified/unifiedCompact/expanded; default unified), create the NSToolbar
  with a unique identifier (`"zapp-toolbar-<n>"`), `displayMode =
  NSToolbarDisplayModeIconOnly`, assign delegate + `window.toolbar`,
  register in the dictionary.
- Delegate `toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:`:
  - `toggleSidebar` → return nil and instead list
    `NSToolbarToggleSidebarItemIdentifier` in the identifier arrays —
    AppKit builds the system item and routes it to the split view
    controller's `toggleSidebar:` (standard icon, animation, tooltip).
    Consistent with `win.sidebar.*`: both mutate the same
    `NSSplitViewItem.collapsed`, so the existing KVO still emits
    `SIDEBAR_COLLAPSED`/`SIDEBAR_EXPANDED` whichever path is used.
  - `trackingSeparator` → `NSTrackingSeparatorToolbarItem` tracking the
    window's split view, divider index 0.
  - `space` / `flexibleSpace` → the system space identifiers (listed, not
    built).
  - `button` → `NSToolbarItem` with image via `zapp_resolve_icon`
    (menu-icons resolver: `sf:`/path/data-URL), label/tooltip from
    `label`, target = controller, action emits the `__toolbar:click`
    broadcast with the controller's windowId + the item's id.
- `allowedToolbarItemIdentifiers` / `defaultToolbarItemIdentifiers`: the
  declared order, nothing more (`allowsUserCustomization` stays NO in v1).
- **`void zapp_toolbar_unregister(void* window_ptr)`** — called from
  `darwin_window_destroy` next to `zapp_sidebar_unregister`; removes the
  registry entry (the NSToolbar itself dies with the window). Close
  remains reversible: no toolbar work in `windowWillClose:`.

## Wire + Zen-C chain (native-first order)

1. **C primitive:** `darwin_toolbar_attach` / `zapp_toolbar_unregister`
   (toolbar.m).
2. **Zen-C:** `WindowOptions` (window.zc) gains `toolbarJson: string`
   (+ `_toolbarJson_heap` flag, matching sidebarUrl's pattern) and accessor
   `fn wopts_toolbar_json(opts) -> string`. Native Zen-C apps set it
   directly on the options struct.
3. **Router:** the `__window:create` route extracts the raw `toolbar`
   sub-object from the create payload as a JSON string (same family as the
   tray routes' payload-driven extraction) and stores it in `toolbarJson`
   (actions already stripped runtime-side).
4. **window.m:** in `darwin_window_create`, AFTER the split construction
   (the tracking separator must find the live split view) and after
   delegate setup: `if (toolbarJson non-empty) darwin_toolbar_attach(...)`.
5. **Runtime:** ToolbarItemDef/ToolbarOptions types, validation, action
   collection, TOOLBAR_CLICKED sugar (runtime/window.ts + events.ts).
6. **Docs:** api-reference Toolbar section under the Window/Sidebar docs.

## Platform stubs

- `native/platform/ios/toolbar.m`: no-op `darwin_toolbar_attach` /
  `zapp_toolbar_unregister` (the #281 ios-platform-parity test enforces
  defs for any darwin_* referenced from .zc — attach is called from
  window.m (.m-only), but unregister/attach may be referenced from window.zc;
  stub both regardless, it's two lines).
- Windows: untouched; the option is a silent no-op (documented).
- `getPlatformSources` (cli/src/native.ts): add toolbar.m to the macOS
  list and the iOS list — it is the authoritative .m inventory.

## Permissions

No new permission id in v1. Toolbars attach at window creation, which the
presence-activated `window` module already governs. (Menus have their own
`menu` permission because `Menu.build` is a standalone post-create surface;
toolbar v1 has no post-create surface.)

## Testing

- **bun tests:** item validation (button-without-id error, duplicate ids,
  toggleSidebar-without-sidebar warn+drop), action-map routing (synthetic
  `__toolbar:click` payload → correct callback, wrong-window filtered),
  TOOLBAR_CLICKED filter logic.
- **Gates:** `bun run test:all`, hello-world build ending
  `[zapp] build complete:`, ios-simulator compile (stub coverage).
- **Smoke (hello-world):** the sidebar demo window grows a toolbar:
  `toggleSidebar + trackingSeparator + compose(button, action→launcher
  log) + flexibleSpace + filter(button)`. Main pane subscribes
  TOOLBAR_CLICKED and logs/updates UI. Visual gate (user, macOS 26):
  unified style sits the toggle next to the traffic lights; toggle
  animates the sidebar; separator tracks the divider; SF symbols render.

## Out of scope (follow-ups)

Dynamic `setItems` / per-item enable-disable, `NSSearchToolbarItem`
search field, dropdown-menu toolbar items, `allowsUserCustomization`,
inspector/trailing-split pairing, iOS (UINavigationBar is a different
animal), Windows.
