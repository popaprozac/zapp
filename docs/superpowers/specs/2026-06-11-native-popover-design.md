# Native Popovers + Pull-Down Toolbar Items — Design

**Date:** 2026-06-11
**Branch:** `feat/native-popover`
**Status:** Approved

## Goal

Complete the "native chrome you can't fake in CSS" trilogy: `NSPopover`
hosting trusted web content (anchored to DOM elements, rects, mouse
events, or toolbar items) plus `menu:` pull-down toolbar items
(`NSMenuToolbarItem` — Mail's filter button). Both make the hello-world
toolbar's filter button real.

## Decisions (user-confirmed)

1. **Scope:** both pieces in one cycle — popovers AND `menu:` toolbar
   items.
2. **Popover lifecycle:** persistent handle. `createPopover` loads the
   webview ONCE (hidden, warm); `.show()`/`.hide()` reuse it (fast
   re-open, page state survives); `.destroy()` frees it. One dispatch
   slot per live popover.
3. **Trust model:** trusted host-twin (the sidebar's model). Full
   bootstrap + bridge; identifies as the anchor window; URL resolves
   like `sidebar.url` (app routes only).
4. **Anchors:** element + toolbar item + raw rect (+ MouseEvent, added
   during the ContextMenu-alignment review).
5. **API alignment with ContextMenu:** shared `Anchor` runtime type
   (`Element | {x,y,width?,height?} | MouseEvent`) used by both
   `ContextMenu.show` and `popover.show`; popover additionally accepts
   `{ toolbarItem }`. Content (`items` vs `url`) and lifecycle
   (one-shot vs persistent handle) intentionally differ. Docs get a
   "pick your surface" table.

## API surface (runtime)

```ts
// --- Popovers ---
export interface PopoverOptions {
  url: string;                 // required; resolves like sidebar.url (app routes)
  width?: number;              // default 320 (content size)
  height?: number;             // default 400
  /** NSPopover.behavior. Default "transient" (auto-dismiss on outside
   *  click). "semitransient" | "applicationDefined" for sticky panels. */
  behavior?: "transient" | "semitransient" | "applicationDefined";
}

/** Shared anchor vocabulary (also adopted by ContextMenu.show). */
export type Anchor =
  | Element                                    // measured at show time (one-shot)
  | { x: number; y: number; width?: number; height?: number }  // pane-viewport CSS px
  | MouseEvent;                                // degenerate point-rect at clientX/Y

export interface PopoverHandle {
  readonly id: string;         // "pop-<n>"
  show(anchor: Anchor | { toolbarItem: string }, opts?: { edge?: "top" | "bottom" | "left" | "right" }): void;
  hide(): void;                // dismiss; webview stays warm
  destroy(): void;             // teardown + slot freed
}

// WindowHandle gains:
createPopover(opts: PopoverOptions): Promise<PopoverHandle>;

// WindowEvent gains:
POPOVER_CLOSED = 16,           // "window:popover-closed", payload { windowId, popoverId }
                               // fires on hide() AND transient auto-dismissal

// --- menu: toolbar items ---
// ToolbarItemDef gains:
menu?: MenuItemDef[];          // pull-down NSMenuToolbarItem; icon/label as usual
```

- `createPopover` works from any window handle — the creator's or either
  pane's (`windowId` routing resolved from the payload, the sidebar
  lesson). The popover belongs to that window; its pane is a host-twin
  (own transport slot, host's `win-<id>` identity,
  `Symbol.for('zapp.isPopover')=true` via document-start user script —
  the hasSidebar lesson).
- `show(element)` / `show(mouseEvent)` only make sense from a pane of
  the anchor window (the rect is pane-viewport-relative); the runtime
  converts both to the rect form before the wire. `{ toolbarItem }` and
  raw rects work from anywhere.
- Default `edge`: `"bottom"` (arrow on top edge of the popover, below
  the anchor) — matches NSPopover convention `NSRectEdgeMinY` mapping.
- Validation: `url` required; `toolbarItem` id must satisfy the toolbar
  id charset; unknown `toolbarItem` at show time → native no-op + NSLog
  warn.

### ContextMenu alignment (small refactor, non-breaking)

`ContextMenuOptions`' anchor inputs (`anchor: HTMLElement`, `{x,y}`,
MouseEvent, pointer fallback) are retyped onto the shared `Anchor` type
internally. No behavior change; ContextMenu keeps its last-pointer
fallback (at-cursor is its idiom) and does NOT gain `toolbarItem` —
"menu from a toolbar button" is the `menu:` item, natively.

## Native: popover.m (new module, registry shape rev 3)

- Registry: `NSMutableDictionary<NSString*, ZappPopoverController*>`
  keyed by popover id (`pop-<n>`); a second window→ids index (or a
  linear sweep — few popovers) for destroy-time cleanup.
- `ZappPopoverController : NSObject <NSPopoverDelegate>` holds the
  NSPopover, an NSViewController whose view is a container NSView
  hosting the persistent WKWebView, the host window numeric id, the
  popover slot, and the declared content size.
- **create** (`darwin_popover_create(window_ptr, popover_id, url,
  width, height, behavior, host_slot, popover_slot)`): build container
  view at content size; mount the webview via the existing
  `darwin_webview_create_ext` (container path, identity = host window,
  new is_popover marker — see below); register both panes' pattern: the
  popover slot registers in window.m's dispatch table with the host's
  "win-<id>" string (same as the sidebar pane). The page loads
  immediately (warm before first show). The NSPopover itself is created
  eagerly at create time (lightweight object; lazy buys nothing).
- **show** (`darwin_popover_show(popover_id, anchor_json)`):
  - `{toolbarItem}` → find the NSToolbarItem by identifier in the host
    window's toolbar; `@available(macOS 14)`
    `showRelativeToToolbarItem:preferredEdge:`; fallback (or item not
    found): anchor to the titlebar rect of the content view.
  - rect → `showRelativeToRect:ofView:preferredEdge:` with the rect
    relative to the HOST PANE's WKWebView (reuse panel.m's CSS-px →
    view-coordinate conversion incl. the Y-flip handling).
- **hide** → `[popover performClose:nil]`; **destroy** →
  close + `zapp_teardown_webview` (alpha.29 hardening) + slot clear +
  registry removal.
- `popoverDidClose:` → emit `popover-closed` `{windowId, popoverId}`
  with the toolbar-click broadcast pattern (`window:popover-closed` via
  `_onEvent` to all webviews + workers — creator and panes both hear
  it; WindowEvent 16 never touches the native event-id table, sidebar
  precedent).
- Window teardown: `zapp_popover_unregister_window(window_ptr)` called
  from `darwin_window_destroy` next to sidebar/toolbar unregisters —
  destroys all popovers belonging to that window.

### webview.m: `is_popover` marker

`darwin_webview_create_ext` grows the popover case. To avoid signature
churn, generalize the existing `is_sidebar` bool into an int
`pane_role` (0 = main, 1 = sidebar, 2 = popover) mapped to the
document-start markers `zapp.isSidebar` / `zapp.isPopover`; existing
callers updated in the same commit (mechanical). `zapp.hasSidebar`
injection unchanged.

### Slot allocation

Popover slots draw from the same `WindowManager.next_id` counter:
window.zc gains `fn window_manager_alloc_slot() -> int` exposed through
the router's popover:create route. Each live popover costs one of the
64 dispatch slots (documented; same ceiling family as sidebar's
2-slots-per-window note).

## Native: NSMenuToolbarItem (toolbar.m extension)

In `darwin_toolbar_attach`'s item loop: a button def carrying a
`"menu"` array builds an `NSMenuToolbarItem` instead of a plain
`NSToolbarItem` — same identifier/label/icon handling, `item.menu =`
the result of the existing JSON wrapper around `build_menu_from_json`
(menu.m). Menu item clicks ride the existing `__menu:click` broadcast —
zero new click plumbing. `showsIndicator` left at default (YES — the
little chevron).

Runtime: `normalizeToolbar` strips nested `action` callbacks from
`menu` items into the SAME map/listener Menu.build uses (reuse
`collectAndStrip`-style logic from context-menu.ts or menu.ts —
whichever exports cleanly; auto-generated ids for action-bearing items
without one, menu precedent). The cleaned menu array rides inside the
item def in `toolbarJson`.

## Wire + routing

New windowAction routes (router.zc, payload-windowId resolution like
the fixed sidebar routes):
- `popover:create { windowId, url, width, height, behavior }` —
  invoke-style: the route allocates the slot via
  `window_manager_alloc_slot()`, derives the id `pop-<slot>`, calls
  `darwin_popover_create`, and returns `{ popoverId }` to the runtime.
- `popover:show { windowId, popoverId, anchor: {...} }` — anchor object:
  `{ toolbarItem }` or `{ x, y, width, height }` (runtime already
  converted Element/MouseEvent to rect).
- `popover:hide { popoverId }`, `popover:destroy { popoverId }`.

URL resolution mirrors `sidebar.url` (same resolver in the create
path).

## Testing

- bun tests: PopoverOptions validation (url required, behavior enum),
  Anchor → rect normalization (element mock via plain object with
  getBoundingClientRect, MouseEvent point-rect, passthrough rect),
  `normalizeToolbar` with `menu:` (actions stripped recursively, ids
  auto-generated, wire shape pinned).
- Gates: `bun run test:all`, hello-world build (`[zapp] build
  complete:` last line), ios-simulator build (new stubs:
  ios/popover.m; toolbar.m stub untouched).
- Demo (hello-world, user-WIP — never committed): filter button gains
  `menu:` (All/Unread/Flagged → main-pane log); compose button's action
  opens a popover anchored to `{toolbarItem:"compose"}`; main pane
  gains a "Filter (popover)" button anchoring a popover to itself; the
  popover page (#popover-pane hash route) has a button that
  Events-emits to prove the bridge + a counter to prove state survives
  hide/show.
- Visual gate (user): bubble + arrow at the anchor, transient dismissal
  fires POPOVER_CLOSED, warm re-open keeps state, menu chevron renders.

## Out of scope (follow-ups)

Detachable popovers (`detachableWindow`), live anchor tracking during
host scroll (transient popovers dismiss on scroll anyway — documented),
per-show URL changes, iOS (`UIPopoverPresentationController`), Windows,
popover-from-tray.

## Permissions

No new permission id — popovers and toolbar menus attach to windows the
`window` module already governs (toolbar/sidebar precedent; documented
in security.md's surface table if it enumerates).
