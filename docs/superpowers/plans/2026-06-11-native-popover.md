# Native Popovers + Pull-Down Toolbar Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `NSPopover` hosting trusted web content (anchored to DOM elements, rects, mouse events, or toolbar items) plus `menu:` pull-down toolbar items (`NSMenuToolbarItem`).

**Architecture:** Persistent `PopoverHandle` from `win.createPopover({url,...})` — the pane webview mounts once via `darwin_webview_create_ext` (container path, host-twin identity, new `pane_role` int generalizing `is_sidebar`) into a new `popover.m` registry module; `show()` uses `showRelativeToToolbarItem:` (macOS 14+) or `showRelativeToRect:ofView:hostPane` (WKWebView is flipped, so DOM rects map directly). `menu:` items build `NSMenuToolbarItem`s via the existing `darwin_menu_build_from_items_json` and ride the existing `__menu:click` pipeline. A shared `Anchor` runtime type aligns `popover.show` with `ContextMenu.show`.

**Tech Stack:** TypeScript (runtime, bun:test), Zen-C (window.zc/router.zc), Objective-C (popover.m, toolbar.m, webview.m).

**Spec:** `docs/superpowers/specs/2026-06-11-native-popover-design.md`.

**Working rules for every task:**
- Branch: `feat/native-popover` (already created, spec committed).
- Build success = the LAST line is `[zapp] build complete: <path>` (Vite's `✓ built` alone is NOT success). `bun run build` does NOT type-check; `bun run check` does. Always Bun.
- NEVER stage `hello-world/src/main.ts`, `hello-world/src/worker.ts`, `hello-world/zapp.config.ts`, `vendor/*`, `kitchen-sink/`, `native/worker/engines/zjs-cross-eval-test.c` — user WIP.
- Commit trailer (exact): `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Runtime — Anchor type, normalizeAnchor/normalizePopoverOptions (TDD), POPOVER_CLOSED, createPopover

**Files:**
- Modify: `runtime/events.ts` (WindowEvent enum, after `TOOLBAR_CLICKED = 15`; `WINDOW_EVENT_NAMES` map)
- Modify: `runtime/window.ts` (types near ToolbarOptions; `createWindowHandle` gains `createPopover`)
- Test: `runtime/popover.test.ts` (new)

- [ ] **Step 1: Write the failing tests** — create `runtime/popover.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { normalizeAnchor, normalizePopoverOptions } from "./window";

describe("normalizeAnchor", () => {
  test("element-like → measured rect", () => {
    const el = { getBoundingClientRect: () => ({ left: 10, top: 20, width: 80, height: 30 }) };
    expect(normalizeAnchor(el as any)).toEqual({ x: 10, y: 20, width: 80, height: 30 });
  });

  test("mouse-event-like → 1x1 point rect", () => {
    const ev = { clientX: 100, clientY: 250 };
    expect(normalizeAnchor(ev as any)).toEqual({ x: 100, y: 250, width: 1, height: 1 });
  });

  test("rect passthrough with width/height defaults", () => {
    expect(normalizeAnchor({ x: 5, y: 6 })).toEqual({ x: 5, y: 6, width: 1, height: 1 });
    expect(normalizeAnchor({ x: 5, y: 6, width: 40, height: 8 }))
      .toEqual({ x: 5, y: 6, width: 40, height: 8 });
  });

  test("garbage throws", () => {
    expect(() => normalizeAnchor({} as any)).toThrow(/invalid anchor/);
    expect(() => normalizeAnchor(null as any)).toThrow(/invalid anchor/);
  });
});

describe("normalizePopoverOptions", () => {
  test("defaults applied", () => {
    expect(normalizePopoverOptions({ url: "#p" }))
      .toEqual({ url: "#p", width: 320, height: 400, behavior: "transient" });
  });

  test("explicit values pass through", () => {
    expect(normalizePopoverOptions({ url: "#p", width: 200, height: 150, behavior: "semitransient" }))
      .toEqual({ url: "#p", width: 200, height: 150, behavior: "semitransient" });
  });

  test("missing url throws", () => {
    expect(() => normalizePopoverOptions({} as any)).toThrow(/"url" is required/);
  });

  test("bad behavior throws", () => {
    expect(() => normalizePopoverOptions({ url: "#p", behavior: "weird" as any }))
      .toThrow(/invalid behavior/);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/zach/code/zapp && bun test runtime/popover.test.ts`
Expected: FAIL — `normalizeAnchor` not exported from `./window`.

- [ ] **Step 3: runtime/events.ts** — after `TOOLBAR_CLICKED = 15,` in the enum:

```ts
  /** Fires when a popover closes — both explicit hide() and transient
   * auto-dismissal. Broadcast to ALL webviews + workers (toolbar-click
   * pattern). Payload: `{ windowId, popoverId }`. */
  POPOVER_CLOSED = 16,
```

In `WINDOW_EVENT_NAMES`, after the TOOLBAR_CLICKED entry:

```ts
  [WindowEvent.POPOVER_CLOSED]: "window:popover-closed",
```

- [ ] **Step 4: runtime/window.ts types + helpers** — after the `ToolbarOptions` interface:

```ts
/** Shared anchor vocabulary — also accepted by ContextMenu.show's anchor.
 * Element is measured at show time (one-shot); MouseEvent becomes a 1x1
 * point rect at clientX/Y; rects are pane-viewport CSS pixels. */
export type Anchor =
  | Element
  | { x: number; y: number; width?: number; height?: number }
  | MouseEvent;

/** Normalize any Anchor to the wire rect. Pure — unit-tested. */
export function normalizeAnchor(anchor: Anchor): { x: number; y: number; width: number; height: number } {
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
    throw new Error("[zapp] popover: invalid anchor — pass an Element, a MouseEvent, or {x, y, width?, height?}");
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
```

- [ ] **Step 5: createPopover on the handle** — inside the object returned by
`createWindowHandle` (next to the `sidebar:` property; `windowId` and
`bridge` are in scope):

```ts
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
```

Also add the method to the `WindowHandle` interface declaration (next to the
`sidebar` member):

```ts
  /** Create a persistent native popover owned by this window. macOS only. */
  createPopover(opts: PopoverOptions): Promise<PopoverHandle>;
```

- [ ] **Step 6: Verify**

Run: `bun test runtime/popover.test.ts` — 8 pass.
Run: `bun run check && bun run test` — tsc clean, all pass (107 existing + 8).

- [ ] **Step 7: Commit**

```bash
git add runtime/events.ts runtime/window.ts runtime/popover.test.ts
git commit -m "feat(runtime): popover handle, Anchor type, POPOVER_CLOSED (16)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Runtime — ToolbarItemDef.menu + ContextMenu Anchor alignment (TDD)

**Files:**
- Modify: `runtime/window.ts` (`ToolbarItemDef`, `normalizeToolbar`, new menu-click wiring)
- Modify: `runtime/context-menu.ts` (`ContextMenuOptions.anchor` widened to `Anchor`)
- Test: `runtime/toolbar.test.ts` (extend)

- [ ] **Step 1: Write the failing tests** — append to `runtime/toolbar.test.ts`:

```ts
describe("normalizeToolbar menu items", () => {
  test("menu actions stripped into menuActions, wire shape keeps menu", () => {
    let hit = "";
    const { json, menuActions } = normalizeToolbar({
      items: [{
        id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
        menu: [
          { id: "all", label: "All", action: () => { hit = "all"; } },
          { id: "unread", label: "Unread" },
        ],
      }],
    }, false);
    const item = JSON.parse(json).items[0];
    expect(item.menu).toEqual([
      { id: "all", label: "All" },
      { id: "unread", label: "Unread" },
    ]);
    expect(JSON.stringify(item)).not.toContain("action");
    expect(menuActions.size).toBe(1);
    menuActions.get("all")!();
    expect(hit).toBe("all");
  });

  test("action-bearing menu items without id get auto-ids", () => {
    const { json, menuActions } = normalizeToolbar({
      items: [{ id: "f", menu: [{ label: "X", action: () => {} }] }],
    }, false);
    const autoId = JSON.parse(json).items[0].menu[0].id;
    expect(autoId).toMatch(/^__tbmenu_\d+$/);
    expect(menuActions.has(autoId)).toBe(true);
  });

  test("submenus are walked", () => {
    const { menuActions } = normalizeToolbar({
      items: [{ id: "f", menu: [{ label: "More", submenu: [{ id: "deep", label: "D", action: () => {} }] }] }],
    }, false);
    expect(menuActions.has("deep")).toBe(true);
  });

  test("menu on non-button types throws", () => {
    expect(() => normalizeToolbar({ items: [{ type: "flexibleSpace", menu: [] } as any] }, false))
      .toThrow(/only valid on button/);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `bun test runtime/toolbar.test.ts`
Expected: FAIL — `normalizeToolbar` result has no `menuActions` / menu handling.

- [ ] **Step 3: Extend ToolbarItemDef + normalizeToolbar in runtime/window.ts**

Add to `ToolbarItemDef` (after `action`):

```ts
  /** Pull-down menu (NSMenuToolbarItem — e.g. Mail's filter button). Items
   *  are the same MenuItemDef used by Menu/ContextMenu/Tray; their `action`
   *  callbacks run in this (creator) context via the __menu:click pipeline. */
  menu?: MenuItemDef[];
```

Import the type: `import type { MenuItemDef } from "./menu";`

Add module-level (next to `toolbarActions`):

```ts
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
```

In `normalizeToolbar`: widen the return type to
`{ json: string; actions: Map<string, () => void>; menuActions: Map<string, () => void> }`,
create `const menuActions = new Map<string, () => void>();` at the top, and:

- In the system-type branches (`toggleSidebar`/`trackingSeparator`/`space`/`flexibleSpace`),
  BEFORE pushing, add:

```ts
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
```

- In the button branch, after the id validations:

```ts
    const wire: Record<string, unknown> = { type: "button", id: item.id, label: item.label ?? "", icon: item.icon ?? "" };
    if (item.menu) wire.menu = stripMenuActions(item.menu, menuActions);
    items.push(wire);
```

(replacing the existing plain `items.push({...})` for buttons), and return
`{ json: ..., actions, menuActions }`.

In `Window.create`'s toolbar block, register the menu actions alongside the
button actions:

```ts
    if (opts?.toolbar) {
      const { json, actions, menuActions } = normalizeToolbar(opts.toolbar, opts.sidebar !== undefined);
      (normalized as any).toolbarJson = json;
      delete (normalized as any).toolbar;
      if (actions.size > 0) pendingToolbarActions = actions;
      if (menuActions.size > 0) {
        wireToolbarMenuClicks();
        for (const [id, fn] of menuActions) toolbarMenuActions.set(id, fn);
      }
    }
```

(Menu-action keys are app-global ids — no windowId prefix; they register
immediately, not post-create.)

- [ ] **Step 4: ContextMenu alignment (non-breaking)** — in `runtime/context-menu.ts`:

```ts
import type { Anchor } from "./window";
import { normalizeAnchor } from "./window";
```

Widen the option (keep the name `anchor`; doc comment updated):

```ts
  /**
   * Show the menu anchored to this Anchor (shared vocabulary with
   * popover.show): an Element (menu at its bottom-left, the dropdown-button
   * convention), a MouseEvent (at clientX/Y), or a {x, y, width?, height?}
   * rect (at its bottom-left).
   */
  anchor?: Anchor;
```

And in `resolvePosition`, replace the `options?.anchor` branch with:

```ts
  if (options?.anchor) {
    const r = normalizeAnchor(options.anchor);
    return { x: r.x, y: r.y + r.height };  // bottom-left, dropdown convention
  }
```

(`x`/`y` and `event` branches unchanged; pointer fallback unchanged.)

- [ ] **Step 5: Verify**

Run: `bun test runtime/toolbar.test.ts runtime/popover.test.ts` — all pass
(12 toolbar + 8 popover).
Run: `bun run check && bun run test` — tsc clean, all pass.

- [ ] **Step 6: Commit**

```bash
git add runtime/window.ts runtime/context-menu.ts runtime/toolbar.test.ts
git commit -m "feat(runtime): menu: pull-down toolbar items + shared Anchor for ContextMenu

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Native — pane_role refactor, popover.m, window.m exports, iOS stubs, source registration

**Files:**
- Modify: `native/platform/darwin/webview.m` (`darwin_webview_create_ext` ~line 786; marker block ~line 919; hasSidebar block "3c"; legacy delegate ~line 1128)
- Modify: `native/platform/darwin/window.m` (extern decl ~line 18; callers ~line 721/724; new exports near `zapp_webview_for_slot`; destroy hook ~`zapp_toolbar_unregister(handle)`)
- Create: `native/platform/darwin/popover.m`
- Create: `native/platform/ios/popover.m`
- Modify: `cli/src/native.ts` (darwin + ios source lists, next to toolbar.m)

- [ ] **Step 1: webview.m — generalize is_sidebar → pane_role.** Change the
signature (and its doc comment at ~line 774):

```objc
// - pane_role: 0 = main pane, 1 = sidebar pane (sets zapp.isSidebar),
//   2 = popover pane (sets zapp.isPopover). Document-start markers.
void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
                               const char* url_override, int32_t numeric_id_pre_alloc,
                               bool transparent_background,
                               void* container_view, int32_t identity_window_id,
                               int32_t pane_role) {
```

Marker block (~line 919) — replace `if (is_sidebar) { ... }` with:

```objc
    if (pane_role == 1) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isSidebar')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    } else if (pane_role == 2) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isPopover')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
```

**CRITICAL:** the "3c. hasSidebar marker" block currently keys on
`container_view != NULL` — popover panes ALSO mount via a container but their
window need not have a sidebar. Change its condition to:

```objc
    if (container_view != NULL && pane_role != 2) {
```

(and extend its comment: "popover panes also mount via containers but say
nothing about the window's sidebar — excluded").

Legacy delegate (~line 1128): change the final argument `false` → `0`.

- [ ] **Step 2: window.m — decl + callers + pane exports + destroy hook.**

(a) Extern decl (~line 18-22): change `bool is_sidebar` → `int32_t pane_role`
in the redeclaration.

(b) Callers: line ~721 (main pane) final arg `false` → `0`; line ~724
(sidebar pane) final arg `true` → `1`.

(c) New exports, after `zapp_sidebar_slot_lookup`:

```objc
// Pane registration/teardown for popover.m — popover panes register OUTSIDE
// window construction (sidebar panes register inline there), and the table
// + teardown helper are static in this file.
void zapp_register_pane_webview(int32_t slot, WKWebView* wv, int32_t host_slot) {
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    NSString* hostId = zapp_window_ids[host_slot];
    if (!hostId) hostId = [NSString stringWithFormat:@"win-%d", host_slot];
    zapp_register_webview(slot, wv, hostId);
}

void zapp_clear_pane_slot(int32_t slot) {
    if (slot < 0 || slot >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    zapp_webviews[slot] = nil;
    zapp_window_ids[slot] = nil;
}
```

(d) Export the teardown helper: `zapp_teardown_webview` is `static` — add a
public wrapper right after its definition:

```objc
// Public wrapper for popover.m (the helper itself stays static/local).
void zapp_teardown_pane_webview(WKWebView* wv) {
    zapp_teardown_webview(wv);
}
```

(e) Destroy hook — in `darwin_window_destroy`, next to
`zapp_toolbar_unregister(handle);`:

```objc
        extern void zapp_popover_unregister_window(void* window_ptr);
        zapp_popover_unregister_window(handle);
```

- [ ] **Step 3: Create native/platform/darwin/popover.m:**

```objc
// macOS native popovers (NSPopover) — registry + delegate module.
// Shape mirrors sidebar.m/toolbar.m: a dictionary registry, create called
// from the router's __popover:create route, destroy from popover:destroy or
// the owning window's darwin_window_destroy sweep.
//
// The pane is a persistent, trusted host-twin webview (sidebar's model):
// full bootstrap, identifies as the host window, own transport slot. It
// loads ONCE at create (warm before first show); show()/hide() reuse it so
// page state survives. popoverDidClose broadcasts window:popover-closed
// {windowId, popoverId} to all webviews + workers (toolbar-click pattern).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

extern void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
                                      const char* url_override, int32_t numeric_id_pre_alloc,
                                      bool transparent_background,
                                      void* container_view, int32_t identity_window_id,
                                      int32_t pane_role);
extern void darwin_webview_eval_all(const char* js);
extern void worker_broadcast_eval_js(char* js);
extern WKWebView* zapp_webview_for_slot(int32_t slot);
extern void zapp_register_pane_webview(int32_t slot, WKWebView* wv, int32_t host_slot);
extern void zapp_clear_pane_slot(int32_t slot);
extern void zapp_teardown_pane_webview(WKWebView* wv);

@interface ZappPopoverController : NSObject <NSPopoverDelegate>
@property (nonatomic, strong) NSPopover* popover;
@property (nonatomic, strong) NSView* container;       // hosts the persistent webview
@property (nonatomic, weak) WKWebView* webview;
@property (nonatomic, weak) NSWindow* hostWindow;
@property (nonatomic, assign) void* hostWindowPtr;     // registry sweep key (darwin_window_destroy)
@property (nonatomic, assign) int32_t hostSlot;
@property (nonatomic, assign) int32_t popoverSlot;
@property (nonatomic, copy) NSString* popoverId;
@end

static NSMutableDictionary<NSString*, ZappPopoverController*>* zapp_popovers = nil;

@implementation ZappPopoverController

- (void)popoverDidClose:(NSNotification*)notification {
    (void)notification;
    // Fires for BOTH explicit hide() and transient auto-dismissal. The
    // popover (and its warm webview) stay alive — re-showable.
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&b._onEvent)b._onEvent('window:popover-closed',"
        "'{\"windowId\":\"win-%d\",\"popoverId\":\"%@\"}');})();",
        self.hostSlot, self.popoverId];
    darwin_webview_eval_all([js UTF8String]);
    worker_broadcast_eval_js((char*)[js UTF8String]);
}

@end

void darwin_popover_create(void* window_ptr, const char* popover_id,
                           const char* url, int32_t width, int32_t height,
                           const char* behavior, int32_t host_slot, int32_t popover_slot) {
    if (!window_ptr || !popover_id || !url || !url[0]) return;
    NSCAssert([NSThread isMainThread], @"zapp popover registry is main-thread-only");
    NSWindow* window = (__bridge NSWindow*)window_ptr;

    ZappPopoverController* c = [[ZappPopoverController alloc] init];
    c.hostWindow = window;
    c.hostWindowPtr = window_ptr;
    c.hostSlot = host_slot;
    c.popoverSlot = popover_slot;
    c.popoverId = [NSString stringWithUTF8String:popover_id];

    // Container at content size; the webview mounts into it and loads NOW
    // (warm before first show). pane_role 2 = popover (zapp.isPopover);
    // identity = the host window (host-twin, sidebar's model).
    // v1 simplification: inspectable/accept_first_mouse fixed to true —
    // threading the host window's original options through create is a
    // follow-up (popovers host the app's own dev-facing UI).
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    c.container = container;
    darwin_webview_create_ext(window_ptr, true, true, url, popover_slot, true,
                              (__bridge void*)container, host_slot, 2);
    for (NSView* sub in container.subviews) {
        if ([sub isKindOfClass:[WKWebView class]]) { c.webview = (WKWebView*)sub; break; }
    }
    if (c.webview) {
        zapp_register_pane_webview(popover_slot, c.webview, host_slot);
    }

    NSViewController* vc = [[NSViewController alloc] init];
    vc.view = container;

    NSPopover* pop = [[NSPopover alloc] init];
    pop.contentViewController = vc;
    pop.contentSize = NSMakeSize(width, height);
    pop.delegate = c;
    NSString* b = [NSString stringWithUTF8String:behavior ?: "transient"];
    if ([b isEqualToString:@"semitransient"])           pop.behavior = NSPopoverBehaviorSemitransient;
    else if ([b isEqualToString:@"applicationDefined"]) pop.behavior = NSPopoverBehaviorApplicationDefined;
    else                                                pop.behavior = NSPopoverBehaviorTransient;
    c.popover = pop;

    if (!zapp_popovers) zapp_popovers = [NSMutableDictionary dictionary];
    zapp_popovers[c.popoverId] = c;
}

// args_json: {"popoverId":..., "anchor":{...}, "edge":"bottom"} — anchor is
// either {"toolbarItem":"id"} or {"x","y","width","height"} in the HOST
// pane's CSS pixels. WKWebView is flipped (top-left origin, panel.m
// precedent) so DOM rects map directly to view coordinates; flipped-view
// edges: top=MinY, bottom=MaxY, left=MinX, right=MaxX.
void darwin_popover_show(const char* popover_id, const char* args_json) {
    if (!popover_id || !zapp_popovers) return;
    NSCAssert([NSThread isMainThread], @"zapp popover show is main-thread-only");
    ZappPopoverController* c = zapp_popovers[[NSString stringWithUTF8String:popover_id]];
    if (!c || !c.popover) return;
    NSWindow* window = c.hostWindow;
    if (!window) return;

    NSDictionary* args = nil;
    if (args_json) {
        NSData* data = [NSData dataWithBytes:args_json length:strlen(args_json)];
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) args = parsed;
    }
    NSDictionary* anchor = [args[@"anchor"] isKindOfClass:[NSDictionary class]] ? args[@"anchor"] : nil;
    NSString* edgeName = [args[@"edge"] isKindOfClass:[NSString class]] ? args[@"edge"] : @"bottom";
    NSRectEdge edge = NSRectEdgeMaxY;                      // "bottom" (flipped view)
    if ([edgeName isEqualToString:@"top"])        edge = NSRectEdgeMinY;
    else if ([edgeName isEqualToString:@"left"])  edge = NSRectEdgeMinX;
    else if ([edgeName isEqualToString:@"right"]) edge = NSRectEdgeMaxX;

    NSString* toolbarItemId = [anchor[@"toolbarItem"] isKindOfClass:[NSString class]] ? anchor[@"toolbarItem"] : nil;
    if (toolbarItemId.length) {
        if (@available(macOS 14.0, *)) {
            for (NSToolbarItem* item in window.toolbar.items) {
                if ([item.itemIdentifier isEqualToString:toolbarItemId]) {
                    [c.popover showRelativeToToolbarItem:item];
                    return;
                }
            }
        }
        NSLog(@"[zapp] popover: toolbar item \"%@\" not found (or macOS < 14) — anchoring to titlebar", toolbarItemId);
        WKWebView* hostPane = zapp_webview_for_slot(c.hostSlot);
        if (!hostPane) return;
        [c.popover showRelativeToRect:NSMakeRect(0, 0, hostPane.bounds.size.width, 1)
                               ofView:hostPane preferredEdge:NSRectEdgeMaxY];
        return;
    }

    CGFloat x = [anchor[@"x"] isKindOfClass:[NSNumber class]] ? [anchor[@"x"] doubleValue] : 0;
    CGFloat y = [anchor[@"y"] isKindOfClass:[NSNumber class]] ? [anchor[@"y"] doubleValue] : 0;
    CGFloat w = [anchor[@"width"] isKindOfClass:[NSNumber class]] ? [anchor[@"width"] doubleValue] : 1;
    CGFloat h = [anchor[@"height"] isKindOfClass:[NSNumber class]] ? [anchor[@"height"] doubleValue] : 1;
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    WKWebView* hostPane = zapp_webview_for_slot(c.hostSlot);
    if (!hostPane) return;
    [c.popover showRelativeToRect:NSMakeRect(x, y, w, h) ofView:hostPane preferredEdge:edge];
}

void darwin_popover_hide(const char* popover_id) {
    if (!popover_id || !zapp_popovers) return;
    NSCAssert([NSThread isMainThread], @"zapp popover hide is main-thread-only");
    ZappPopoverController* c = zapp_popovers[[NSString stringWithUTF8String:popover_id]];
    if (c.popover.isShown) [c.popover performClose:nil];
}

// Full teardown: close, harden-teardown the webview (alpha.29 pattern),
// free the dispatch slot, drop the registry entry.
static void zapp_popover_destroy_controller(ZappPopoverController* c) {
    if (!c) return;
    if (c.popover.isShown) [c.popover performClose:nil];
    if (c.webview) zapp_teardown_pane_webview(c.webview);
    zapp_clear_pane_slot(c.popoverSlot);
    c.popover.delegate = nil;
    [zapp_popovers removeObjectForKey:c.popoverId];
}

void darwin_popover_destroy(const char* popover_id) {
    if (!popover_id || !zapp_popovers) return;
    NSCAssert([NSThread isMainThread], @"zapp popover destroy is main-thread-only");
    zapp_popover_destroy_controller(zapp_popovers[[NSString stringWithUTF8String:popover_id]]);
}

// Called from darwin_window_destroy: destroy every popover owned by the
// window being torn down.
void zapp_popover_unregister_window(void* window_ptr) {
    if (!window_ptr || !zapp_popovers) return;
    NSMutableArray<ZappPopoverController*>* doomed = [NSMutableArray array];
    for (NSString* key in zapp_popovers) {
        ZappPopoverController* c = zapp_popovers[key];
        if (c.hostWindowPtr == window_ptr) [doomed addObject:c];
    }
    for (ZappPopoverController* c in doomed) zapp_popover_destroy_controller(c);
}
```

- [ ] **Step 4: Create native/platform/ios/popover.m:**

```objc
// iOS stubs — NSPopover is AppKit-only; the iOS analogue
// (UIPopoverPresentationController) is a future cycle. router.zc references
// darwin_popover_* under #ifdef __APPLE__, which is true on iOS too, so
// these stubs are REQUIRED for the iOS link (the #281 parity-gate class).
#include <stdint.h>

void darwin_popover_create(void* window_ptr, const char* popover_id,
                           const char* url, int32_t width, int32_t height,
                           const char* behavior, int32_t host_slot, int32_t popover_slot) {
    (void)window_ptr; (void)popover_id; (void)url; (void)width; (void)height;
    (void)behavior; (void)host_slot; (void)popover_slot;
}

void darwin_popover_show(const char* popover_id, const char* args_json) {
    (void)popover_id; (void)args_json;
}

void darwin_popover_hide(const char* popover_id) { (void)popover_id; }
void darwin_popover_destroy(const char* popover_id) { (void)popover_id; }
void zapp_popover_unregister_window(void* window_ptr) { (void)window_ptr; }
```

(Also check `ios/window.m` for a `darwin_window_get_by_numeric_id` definition
— it exists from the panel cycle; the route also calls
`darwin_window_numeric_id_for_string` and `dispatch_invoke_response`, both
already defined on iOS. If the iOS link reports anything else missing, stub
it in ios/popover.m the same way.)

- [ ] **Step 5: cli/src/native.ts** — add `path.join(darwinDir, "popover.m"),`
next to the darwin toolbar.m entry, and `path.join(iosDir, "popover.m"),`
next to the ios toolbar.m entry.

- [ ] **Step 6: Gates**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build`
Expected: LAST line `[zapp] build complete: .../bin/hello-world (<size>)` — popover.m compiles into the binary (uncalled until Task 4 wires the routes).

Run: `cd /Users/zach/code/zapp && bun run test` — all pass (incl. ios parity).

Run: `cd hello-world && bun run build --platform ios-simulator`
Expected: LAST line `[zapp] build complete: <ios app path>`.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/webview.m native/platform/darwin/window.m \
        native/platform/darwin/popover.m native/platform/ios/popover.m \
        cli/src/native.ts
git commit -m "feat(native): NSPopover module — persistent host-twin pane, anchor show paths, pane_role refactor

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Zen-C + router — alloc_slot, __popover:create invoke, popover:* actions

**Files:**
- Modify: `native/window/window.zc` (`WindowManager` impl, next to `fn create` ~line 747)
- Modify: `native/app/router.zc` (invoke section near the `__window:create` block ~line 180; windowAction handler after the sidebar block ~line 643)

- [ ] **Step 1: window.zc — slot allocator** — in the `WindowManager` impl,
after `fn create(...)`'s closing brace:

```zc
    // Draw one dispatch slot from the same monotonic id-space windows and
    // sidebar panes use (never a parallel allocator — collisions impossible).
    // Used by the router's __popover:create route.
    fn alloc_slot(self) -> int {
        let id = self.next_id;
        self.next_id += 1;
        return id;
    }
```

- [ ] **Step 2: router.zc — __popover:create invoke route** — in the INVOKE
section, directly after the `__window:create` block's `return;`:

```zc
        // __popover:create — persistent popover owned by a window. Resolves
        // the payload windowId (attachModal pattern, sender-slot fallback),
        // allocates the pane's dispatch slot, returns {"popoverId":"pop-<n>"}.
        let is_popover_create: bool = false;
        is_popover_create = parsed.method == "__popover:create";
        if is_popover_create {
            let target = window_id;
            let url_s: string = "";
            let behavior_s: string = "transient";
            let pw = 320;
            let ph = 400;
            if parsed.has_args {
                let wid_opt = parsed.args.get_string("windowId");
                if wid_opt.is_some() {
                    raw {
                        #ifdef __APPLE__
                        extern int32_t darwin_window_numeric_id_for_string(const char* wid);
                        int32_t resolved = darwin_window_numeric_id_for_string((const char*)wid_opt.val);
                        if (resolved >= 0) target = resolved;
                        #endif
                    }
                }
                let url_opt = parsed.args.get_string("url");
                if url_opt.is_some() { url_s = url_opt.unwrap(); }
                let b_opt = parsed.args.get_string("behavior");
                if b_opt.is_some() { behavior_s = b_opt.unwrap(); }
                let pw_opt = parsed.args.get_int("width");
                if pw_opt.is_some() { pw = pw_opt.unwrap(); }
                let ph_opt = parsed.args.get_int("height");
                if ph_opt.is_some() { ph = ph_opt.unwrap(); }
            }
            let slot = app.window.alloc_slot();
            raw {
                #ifdef __APPLE__
                extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
                extern void darwin_popover_create(void* window_ptr, const char* popover_id,
                                                  const char* url, int32_t width, int32_t height,
                                                  const char* behavior, int32_t host_slot,
                                                  int32_t popover_slot);
                void* host = darwin_window_get_by_numeric_id((int32_t)target);
                if (host) {
                    char pid[32];
                    snprintf(pid, sizeof(pid), "pop-%d", slot);
                    darwin_popover_create(host, pid, (const char*)url_s, (int32_t)pw, (int32_t)ph,
                                          (const char*)behavior_s, (int32_t)target, (int32_t)slot);
                }
                #endif
            }
            raw {
                char resp[64];
                snprintf(resp, sizeof(resp), "{\"popoverId\":\"pop-%d\"}", slot);
                dispatch_invoke_response(window_id, parsed.request_id, true, resp);
            }
            return;
        }
```

- [ ] **Step 3: router.zc — popover:* windowActions** — in
`router_handle_window_action`, directly after the sidebar block's closing
`return;`:

```zc
    // Popover actions — keyed by popoverId (popover.m registry). show passes
    // the raw args subtree through: popover.m parses anchor/edge itself
    // (tray-style payload-driven extraction).
    let is_pop_show = action == "popover:show";
    let is_pop_hide = action == "popover:hide";
    let is_pop_destroy = action == "popover:destroy";
    if is_pop_show || is_pop_hide || is_pop_destroy {
        let pid_opt = pre_args.get_string("popoverId");
        if !pid_opt.is_some() { return; }
        let pid: string = pid_opt.unwrap();
        raw {
            #ifdef __APPLE__
            extern void darwin_popover_show(const char* popover_id, const char* args_json);
            extern void darwin_popover_hide(const char* popover_id);
            extern void darwin_popover_destroy(const char* popover_id);
            extern const char* darwin_dialog_extract_args(const char* full_json);
            if (is_pop_show) {
                const char* args_json = darwin_dialog_extract_args((const char*)payload);
                darwin_popover_show((const char*)pid, args_json);
            } else if (is_pop_hide) {
                darwin_popover_hide((const char*)pid);
            } else {
                darwin_popover_destroy((const char*)pid);
            }
            #endif
        }
        return;
    }
```

(Check the actual parameter name of the payload argument in
`router_handle_window_action`'s signature — the call site is
`router_handle_window_action(app, parsed.method, parsed.payload, window_id, parsed.args, parsed.has_args)`;
use whatever the function names that second argument.)

- [ ] **Step 4: Build gates** — Task 3 already created `darwin_popover_*`
(both platforms), so everything links now:

Run: `cd /Users/zach/code/zapp/hello-world && bun run build`
Expected: LAST line `[zapp] build complete: .../bin/hello-world (<size>)`.

Run: `bun run test` — all pass.

Run: `cd hello-world && bun run build --platform ios-simulator`
Expected: LAST line `[zapp] build complete: <ios app path>` (the route's
`darwin_popover_*` externs resolve against the ios/popover.m stubs).

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/window/window.zc native/app/router.zc
git commit -m "feat(router): __popover:create invoke + popover:* actions + WindowManager.alloc_slot

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: toolbar.m — NSMenuToolbarItem for menu: items

**Files:**
- Modify: `native/platform/darwin/toolbar.m` (`itemForItemIdentifier:` custom-button branch)

- [ ] **Step 1: extern + menu branch.** Add near the other externs at the top:

```objc
// menu.m: builds a retained NSMenu from a MenuItemDef JSON array; clicks
// ride the existing __menu:click broadcast (zero new plumbing here).
extern void* darwin_menu_build_from_items_json(const char* items_json);
```

In `toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:`, in the custom
button branch, AFTER `NSDictionary* def = self.buttonsById[identifier]; if (!def) return nil;`
insert (before the plain NSToolbarItem construction):

```objc
    // Pull-down menu item (Mail's filter button). The runtime stripped the
    // action callbacks; this re-serializes the cleaned MenuItemDef array for
    // menu.m's JSON builder. Clicks dispatch via __menu:click as usual.
    NSArray* menuItems = [def[@"menu"] isKindOfClass:[NSArray class]] ? def[@"menu"] : nil;
    if (menuItems.count) {
        if (@available(macOS 10.15, *)) {
            NSMenuToolbarItem* mitem = [[NSMenuToolbarItem alloc] initWithItemIdentifier:identifier];
            NSString* mlabel = [def[@"label"] isKindOfClass:[NSString class]] ? def[@"label"] : @"";
            mitem.label = mlabel;
            mitem.paletteLabel = mlabel.length ? mlabel : identifier;
            mitem.toolTip = mlabel;
            NSString* micon = [def[@"icon"] isKindOfClass:[NSString class]] ? def[@"icon"] : @"";
            if (micon.length) {
                mitem.image = zapp_resolve_icon(micon, 18.0, 1);
            }
            NSData* mdata = [NSJSONSerialization dataWithJSONObject:menuItems options:0 error:nil];
            NSString* mjson = mdata ? [[NSString alloc] initWithData:mdata encoding:NSUTF8StringEncoding] : nil;
            NSMenu* menu = mjson ? (__bridge_transfer NSMenu*)darwin_menu_build_from_items_json([mjson UTF8String]) : nil;
            if (menu) mitem.menu = menu;
            mitem.showsIndicator = YES; // the chevron
            return mitem;
        }
        // < 10.15: fall through to a plain button (clicks still broadcast).
    }
```

- [ ] **Step 2: Gates**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build` — LAST line
`[zapp] build complete: ...`.
Run: `cd /Users/zach/code/zapp && bun run test` — all pass.

- [ ] **Step 3: Commit**

```bash
git add native/platform/darwin/toolbar.m
git commit -m "feat(toolbar): NSMenuToolbarItem for menu: pull-down items

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Docs + hello-world demo (demo stays UNCOMMITTED) + full gates

**Files:**
- Modify: `docs/api-reference.md` (after the Toolbar section)
- Modify: `docs/patterns.md` (only if a natural home exists — optional)
- Modify: `hello-world/src/main.ts` — **user WIP: edit but NEVER stage/commit**

- [ ] **Step 1: api-reference — Popover section + menu: item + surface table.**
Insert after the Toolbar section's final paragraph ("v1 is create-time
only…"):

````markdown

### Popovers (macOS)

A real `NSPopover` — bubble chrome, anchor arrow, transient auto-dismissal —
hosting your app's web content as a trusted pane (full bridge, identifies as
its window, Events crosses panes; `Window.isPopover()`-style detection via
`Symbol.for('zapp.isPopover')`). Persistent: the page loads once at create
and stays warm across show/hide, so state survives.

```ts
const pop = await win.createPopover({ url: "#filter-panel", width: 320, height: 400 });

pop.show(buttonElement);                 // anchored to a DOM element
pop.show({ toolbarItem: "compose" });    // anchored to a toolbar button (macOS 14+)
pop.show(mouseEvent);                    // at the click point
pop.show({ x: 40, y: 90, width: 120, height: 20 }, { edge: "right" });
pop.hide();                              // dismiss — webview stays warm
pop.destroy();                           // teardown + slot freed

win.on(WindowEvent.POPOVER_CLOSED, ({ popoverId }) => { ... }); // hide() AND transient dismissal
```

`behavior` controls dismissal: `"transient"` (default — outside click
closes), `"semitransient"`, `"applicationDefined"` (only your code closes
it). Element/MouseEvent anchors are measured in the calling pane, so call
`show(element)` from the pane that owns the element. Each live popover
costs one dispatch slot (same 64-slot pool as windows).

### Pull-down toolbar menus

A `menu:` array on a toolbar button builds a real `NSMenuToolbarItem`
(Mail's filter button) — same `MenuItemDef` as `Menu`/`ContextMenu`/`Tray`,
same `action` callbacks:

```ts
{ id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
  menu: [
    { id: "all", label: "All", action: () => setFilter("all") },
    { id: "unread", label: "Unread", action: () => setFilter("unread") },
  ] }
```

### Pick your surface

| You want | Use |
| --- | --- |
| Native menu items at a point (right-click, dropdown button) | `ContextMenu.show(items, { anchor })` |
| Native menu items from a toolbar button | toolbar item `menu:` |
| Your own web UI in a native bubble, anchored to anything | `win.createPopover` |

`ContextMenu.show`'s `anchor` and `popover.show` share the same `Anchor`
vocabulary (Element / `{x, y, width?, height?}` / MouseEvent).
````

- [ ] **Step 2: hello-world demo (EDIT, never stage).** In the sidebar-demo
`Window.create` call's toolbar items, replace the filter item with:

```ts
        { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
          menu: [
            { id: "flt-all", label: "All", action: () => log("filter menu: All") },
            { id: "flt-unread", label: "Unread", action: () => log("filter menu: Unread") },
            { id: "flt-flagged", label: "Flagged", action: () => log("filter menu: Flagged") },
          ] },
```

In the pane-override **main-pane** branch, after the TOOLBAR_CLICKED
listener, add:

```ts
    // Popover demos: one anchored to the compose toolbar button, one to a
    // DOM element. Created lazily on first use, reused after (persistent —
    // the counter in the popover page proves state survives hide/show).
    let tbPopover: any, elPopover: any;
    document.querySelector("#sb-popover-btn")!.addEventListener("click", async (e) => {
      elPopover ??= await win.createPopover({ url: "#popover-pane", width: 280, height: 180 });
      elPopover.show(e.currentTarget as Element);
    });
    document.querySelector("#sb-popover-tb")!.addEventListener("click", async () => {
      tbPopover ??= await win.createPopover({ url: "#popover-pane", width: 280, height: 180 });
      tbPopover.show({ toolbarItem: "compose" });
    });
    win.on(WindowEvent.POPOVER_CLOSED, (p: any) => console.log(`[main pane] popover closed: ${p.popoverId}`));
```

And add the two buttons to the main-pane HTML (next to `#sb-toggle`):

```html
        <button id="sb-popover-btn" style="margin-top:12px">Popover (this button)</button>
        <button id="sb-popover-tb" style="margin-top:12px">Popover (compose toolbar item)</button>
```

Add a popover pane override — extend the pane-hash condition to include
`#popover-pane` and add a branch:

```ts
  } else if (location.hash === "#popover-pane") {
    let n = 0;
    app.innerHTML = `
      <div style="padding:14px;font:13px -apple-system">
        <div style="font-weight:600;margin-bottom:8px">Web content in an NSPopover</div>
        <button id="pp-count">Count: 0</button>
        <button id="pp-emit">Events.emit → main pane</button>
      </div>`;
    document.querySelector("#pp-count")!.addEventListener("click", (e) => {
      (e.currentTarget as HTMLElement).textContent = `Count: ${++n}`;  // survives hide/show
    });
    document.querySelector("#pp-emit")!.addEventListener("click", () => {
      Events.emit("sb:nav", { item: "from-popover" });                 // crosses panes
    });
  }
```

(The outer `if (location.hash === "#sidebar-pane" || location.hash === "#main-pane")`
condition must gain `|| location.hash === "#popover-pane"`.)

- [ ] **Step 3: Full gates**

Run: `cd /Users/zach/code/zapp && bun run test:all` — all bun tests + native
PASS + tsc clean.
Run: `cd hello-world && bun run build` — LAST line `[zapp] build complete: ...`.

- [ ] **Step 4: Commit docs ONLY**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "docs(api): Popovers + pull-down toolbar menus + pick-your-surface table

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Verify main.ts NOT staged**

Run: `git status --short hello-world/src/main.ts` → ` M hello-world/src/main.ts`.
`git show --stat HEAD` lists ONLY docs/api-reference.md.

---

## Final verification (controller, after all tasks)

1. `bun run test:all` green; macOS + ios-simulator builds end `[zapp] build complete:`.
2. Launch hello-world → "New Window (sidebar)":
   - Filter toolbar button shows a chevron; clicking opens the native menu; picking "Unread" logs `filter menu: Unread` in the launcher (creator-context action via `__menu:click`).
   - "Popover (this button)" opens a bubble with arrow pointing at the button; counter increments; dismiss by clicking outside (transient) → `[main pane] popover closed: pop-<n>` in the console; re-open → counter RETAINED (warm pane).
   - "Popover (compose toolbar item)" anchors the bubble to the compose button in the titlebar.
   - "Events.emit → main pane" inside the popover updates the main pane's `#sb-selection` to `from-popover` (bridge + bus cross panes).
3. USER visual smoke (macOS 26): bubble chrome/material, arrow placement, transient dismissal feel, menu chevron.
