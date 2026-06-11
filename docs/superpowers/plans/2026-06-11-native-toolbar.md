# Native Toolbar (macOS v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Real `NSToolbar` on Zapp windows — system sidebar-toggle + tracking separator + declarative SF-symbol buttons with menu-pattern click delivery.

**Architecture:** `Window.create({ toolbar: { style, items } })` → runtime validates/strips actions and sends a pre-stringified `toolbarJson` → window.zc stores it on WindowOptions → window.m calls `darwin_toolbar_attach` (new `toolbar.m` registry module, sidebar.m's shape) after construction. Custom-button clicks broadcast `window:toolbar-clicked {windowId, id}` to all webviews+workers (menu.m's emit pattern); the handle's existing `on()` windowId filter and a creator-side action map both consume that one emit.

**Tech Stack:** TypeScript (runtime, bun:test), Zen-C (window.zc), Objective-C (toolbar.m, NSToolbar/NSToolbarDelegate, macOS 11+ APIs behind `@available`).

**Spec:** `docs/superpowers/specs/2026-06-11-native-toolbar-design.md`. One approved-design refinement: the native broadcast uses the event name `window:toolbar-clicked` directly (not `__toolbar:click` + runtime re-dispatch) — the generic `WindowHandle.on()` path then works unmodified, because it already subscribes by name and filters `payload.windowId` (runtime/window.ts `createWindowHandle`). Same single emit, two surfaces, less code. A second refinement: the runtime pre-stringifies the toolbar JSON (`toolbarJson` string field on the create payload) so window.zc only needs a `get_string` — no JsonValue subtree serialization.

**Working rules for every task:**
- Branch: `feat/native-toolbar` (already created, spec committed).
- Build success = the LAST line is `[zapp] build complete: <path>` (Vite's `✓ built` alone is NOT success).
- `bun run build` does NOT type-check; `bun run check` (tsc) does.
- NEVER stage `hello-world/src/main.ts`, `hello-world/src/worker.ts`, `hello-world/zapp.config.ts`, `vendor/*`, `kitchen-sink/`, `native/worker/engines/zjs-cross-eval-test.c` — user WIP.
- Commit trailer (exact): `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Runtime — TOOLBAR_CLICKED event + toolbar types + normalizeToolbar (TDD) + create() wiring

**Files:**
- Modify: `runtime/events.ts` (WindowEvent enum ends at `SIDEBAR_RESIZED = 14`, ~line 44; `windowEventNames` map ~line 70)
- Modify: `runtime/window.ts` (types near `SidebarOptions` ~line 198; `Window.create` ~line 444)
- Test: `runtime/toolbar.test.ts` (new)

- [ ] **Step 1: Write the failing tests**

Create `runtime/toolbar.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { normalizeToolbar, type ToolbarOptions } from "./window";

describe("normalizeToolbar", () => {
  test("strips actions and stringifies items in declared order", () => {
    let hit = 0;
    const tb: ToolbarOptions = {
      items: [
        { type: "toggleSidebar" },
        { type: "trackingSeparator" },
        { id: "compose", icon: "sf:square.and.pencil", label: "Compose", action: () => { hit++; } },
        { type: "flexibleSpace" },
        { id: "filter", icon: "sf:line.3.horizontal.decrease" },
      ],
    };
    const { json, actions } = normalizeToolbar(tb, true);
    const parsed = JSON.parse(json);
    expect(parsed.style).toBe("unified"); // default
    expect(parsed.items).toEqual([
      { type: "toggleSidebar" },
      { type: "trackingSeparator" },
      { type: "button", id: "compose", label: "Compose", icon: "sf:square.and.pencil" },
      { type: "flexibleSpace" },
      { type: "button", id: "filter", label: "", icon: "sf:line.3.horizontal.decrease" },
    ]);
    expect(json).not.toContain("action");
    expect(actions.size).toBe(1);
    actions.get("compose")!();
    expect(hit).toBe(1);
  });

  test("passes style through", () => {
    const { json } = normalizeToolbar({ style: "expanded", items: [{ id: "a" }] }, false);
    expect(JSON.parse(json).style).toBe("expanded");
  });

  test("button without id throws", () => {
    expect(() => normalizeToolbar({ items: [{ label: "Nope" }] }, false))
      .toThrow(/require an "id"/);
  });

  test("duplicate button ids throw", () => {
    expect(() => normalizeToolbar({ items: [{ id: "x" }, { id: "x" }] }, false))
      .toThrow(/duplicate/);
  });

  test("sidebar-dependent items are dropped (with remaining items kept) when window has no sidebar", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "toggleSidebar" }, { type: "trackingSeparator" }, { id: "a" }] },
      false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "button", id: "a", label: "", icon: "" }]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts`
Expected: FAIL — `normalizeToolbar` is not exported from `./window`.

- [ ] **Step 3: Add TOOLBAR_CLICKED to runtime/events.ts**

In the `WindowEvent` enum, after `SIDEBAR_RESIZED = 14,`:

```ts
  /** Fires when a custom toolbar button is clicked. Broadcast to ALL
   * webviews + workers (menu pattern) — the creator's `action` callbacks
   * and any pane's `win.on(...)` both consume the same emit.
   * Payload: `{ windowId, id }`. */
  TOOLBAR_CLICKED = 15,
```

In the `windowEventNames` map, after the `SIDEBAR_RESIZED` entry:

```ts
  [WindowEvent.TOOLBAR_CLICKED]: "window:toolbar-clicked",
```

- [ ] **Step 4: Add types + normalizeToolbar + click wiring to runtime/window.ts**

After the `SidebarOptions` interface (~line 213), add:

```ts
/** One toolbar item. `type` defaults to "button". */
export interface ToolbarItemDef {
  /** Identifier for custom buttons — REQUIRED for type "button" (keys
   *  click routing). Ignored for system types. */
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
}

/** Options for a native toolbar (NSToolbar) attached at Window.create. */
export interface ToolbarOptions {
  items: ToolbarItemDef[];
  /** NSWindow.toolbarStyle. Default "unified". macOS only. */
  style?: "unified" | "unifiedCompact" | "expanded";
}

/** Toolbar action callbacks keyed "<windowId>:<itemId>" — Menu.build's
 * collect/strip/listen shape (runtime/menu.ts), but per-window. */
const toolbarActions = new Map<string, () => void>();
let toolbarClickWired = false;

function wireToolbarClicks(): void {
  if (toolbarClickWired) return;
  toolbarClickWired = true;
  getBridge().on("window:toolbar-clicked", (payload: any) => {
    const fn = toolbarActions.get(`${payload?.windowId}:${payload?.id}`);
    if (fn) fn();
  });
}

/** Validate a ToolbarOptions and split it into the wire JSON (actions
 * stripped, defaults applied) and the action map. Pure — unit-tested. */
export function normalizeToolbar(
  toolbar: ToolbarOptions,
  hasSidebar: boolean,
): { json: string; actions: Map<string, () => void> } {
  const actions = new Map<string, () => void>();
  const seen = new Set<string>();
  const items: Record<string, unknown>[] = [];
  for (const item of toolbar.items ?? []) {
    const type = item.type ?? "button";
    if (type === "toggleSidebar" || type === "trackingSeparator") {
      if (!hasSidebar) {
        console.warn(`[zapp] toolbar: "${type}" requires the window to have a sidebar — item dropped`);
        continue;
      }
      items.push({ type });
      continue;
    }
    if (type === "space" || type === "flexibleSpace") {
      items.push({ type });
      continue;
    }
    if (!item.id) throw new Error('[zapp] toolbar: button items require an "id"');
    if (seen.has(item.id)) throw new Error(`[zapp] toolbar: duplicate item id "${item.id}"`);
    seen.add(item.id);
    if (item.action) actions.set(item.id, item.action);
    items.push({ type: "button", id: item.id, label: item.label ?? "", icon: item.icon ?? "" });
  }
  return { json: JSON.stringify({ style: toolbar.style ?? "unified", items }), actions };
}
```

Add to the `WindowOptions` interface (next to `sidebar?: SidebarOptions;` ~line 195):

```ts
  /** Attach a native toolbar (NSToolbar). macOS only; no-op elsewhere. */
  toolbar?: ToolbarOptions;
```

In `Window.create` (~line 444), after the `asSheetOf` normalization block and
before the worker-context branch, add:

```ts
    // Toolbar: validate, strip actions, pre-stringify (window.zc stores the
    // raw JSON; toolbar.m parses it). Actions register post-create once the
    // windowId is known.
    let pendingToolbarActions: Map<string, () => void> | undefined;
    if (opts?.toolbar) {
      const { json, actions } = normalizeToolbar(opts.toolbar, opts.sidebar !== undefined);
      (normalized as any).toolbarJson = json;
      delete (normalized as any).toolbar;
      if (actions.size > 0) pendingToolbarActions = actions;
    }
    const registerToolbarActions = (windowId: string) => {
      if (!pendingToolbarActions) return;
      wireToolbarClicks();
      for (const [id, fn] of pendingToolbarActions) toolbarActions.set(`${windowId}:${id}`, fn);
    };
```

Then call it in BOTH return paths:

```ts
    if (host?.createWindow) {
      const r = host.createWindow(normalized) as { windowId: string };
      registerToolbarActions(r.windowId);
      return createWindowHandle(r.windowId, opts?.sidebar);
    }
    const result = await getBridge().invoke("__window:create", normalized) as { windowId: string };
    registerToolbarActions(result.windowId);
    return createWindowHandle(result.windowId, opts?.sidebar);
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bun test runtime/toolbar.test.ts`
Expected: 5 pass, 0 fail.

- [ ] **Step 6: Type-check + full test suite**

Run: `bun run check && bun run test`
Expected: tsc clean; 104 tests pass (99 existing + 5 new), 0 fail.

- [ ] **Step 7: Commit**

```bash
git add runtime/events.ts runtime/window.ts runtime/toolbar.test.ts
git commit -m "feat(runtime): toolbar option types, normalizeToolbar, TOOLBAR_CLICKED (15)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: window.zc — toolbarJson field, accessor, apply_json, free

**Files:**
- Modify: `native/window/window.zc` — struct fields (~line 112, after `sidebarNumericId`), defaults (~line 202), accessors (~line 237), `window_opts_apply_json` (after the sidebar block ending ~line 396), `window_opts_free`

- [ ] **Step 1: Add the struct fields**

In the `WindowOptions` struct, after `sidebarNumericId: int;`:

```zc
    // Toolbar (native NSToolbar; macOS only). Pre-stringified JSON
    // {style, items} from the runtime — opaque here, parsed by toolbar.m.
    toolbarJson: string;       // empty = no toolbar
    _toolbarJson_heap: bool;
```

- [ ] **Step 2: Add the defaults**

In `WindowOptions::create`'s initializer, after `sidebarNumericId: -1,`:

```zc
            toolbarJson: "",
            _toolbarJson_heap: false,
```

- [ ] **Step 3: Add the accessor**

Next to `fn wopts_sidebar_numeric_id` (~line 237):

```zc
fn wopts_toolbar_json(opts: WindowOptions*) -> string { return opts.toolbarJson; }
```

- [ ] **Step 4: Parse it in window_opts_apply_json**

After the sidebar block (closing brace at ~line 396), add:

```zc
    // Toolbar: pre-stringified by the runtime (actions already stripped).
    // Stored as an opaque string — toolbar.m parses it at attach time.
    let tb_opt = args.get_string("toolbarJson");
    if tb_opt.is_some() {
        let src = tb_opt.unwrap();
        raw {
            if (opts->_toolbarJson_heap && opts->toolbarJson) free((void*)opts->toolbarJson);
            opts->toolbarJson = strdup((const char*)src);
            opts->_toolbarJson_heap = 1;
        }
    }
```

- [ ] **Step 5: Free it in window_opts_free**

Inside `window_opts_free`'s raw block, after the `_sidebarUrl_heap` entry
(follow the exact shape of the existing entries):

```c
        if (opts->_toolbarJson_heap && opts->toolbarJson) {
            free((void*)opts->toolbarJson);
            opts->toolbarJson = "";
            opts->_toolbarJson_heap = 0;
        }
```

(Note: `window_opts_free` also has a `_sidebarMaterial_heap` entry — place
the toolbar entry after whichever sidebar entry is last, order doesn't
matter, just keep them grouped.)

- [ ] **Step 6: Verify the Zen-C compiles via the macOS build**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build`
Expected: LAST line is `[zapp] build complete: /Users/zach/code/zapp/hello-world/bin/hello-world (<size>)`.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/window/window.zc
git commit -m "feat(window.zc): toolbarJson WindowOptions field + accessor

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: toolbar.m (registry + delegate) + window.m wiring + iOS stubs + source registration

**Files:**
- Create: `native/platform/darwin/toolbar.m`
- Create: `native/platform/ios/toolbar.m`
- Modify: `native/platform/darwin/window.m` (extern decls ~line 28–41; construction before `return (__bridge_retained void*)window;` ~line 766; `darwin_window_destroy` next to `zapp_sidebar_unregister(handle)` at ~line 847)
- Modify: `native/platform/darwin/menu.m` (de-static `zapp_resolve_icon`, line 141)
- Modify: `cli/src/native.ts` (darwin list ~line 64, ios list ~line 96)

- [ ] **Step 1: De-static the icon resolver in menu.m**

`zapp_resolve_icon` (menu.m:141) is `static` — toolbar.m needs it. Change:

```objc
static NSImage* zapp_resolve_icon(NSString* spec, CGFloat size, int templateMode) {
```

to:

```objc
// Shared with toolbar.m (declared extern there). sf:/file-path/data-URL.
NSImage* zapp_resolve_icon(NSString* spec, CGFloat size, int templateMode) {
```

(If menu.m has a separate `static` forward declaration of the same function
near the top, remove `static` there too — grep `zapp_resolve_icon` within
menu.m to check.)

- [ ] **Step 2: Create native/platform/darwin/toolbar.m**

```objc
// macOS native toolbar (NSToolbar) — registry + delegate module.
// Shape mirrors sidebar.m: a dictionary keyed by the host NSWindow,
// attach called from window.m construction, unregister from destroy.
//
// Click delivery: custom-button clicks broadcast the window-event name
// `window:toolbar-clicked` {"windowId":"win-<n>","id":"<itemId>"} to ALL
// webviews + workers via bridge._onEvent (menu.m's __menu:click pattern;
// per-window, hence the windowId field). One emit feeds both surfaces:
// the creator's action map and any pane's win.on(TOOLBAR_CLICKED).

#import <Cocoa/Cocoa.h>

extern void darwin_webview_eval_all(const char* js);
extern void worker_broadcast_eval_js(char* js);
// menu.m (de-static'ed): sf:/file-path/data-URL icon resolver.
extern NSImage* zapp_resolve_icon(NSString* spec, CGFloat size, int templateMode);

// Tracking separator's private identifier (never user-visible).
static NSString* const kZappTrackingSeparatorId = @"zapp.trackingSeparator";

@interface ZappToolbarController : NSObject <NSToolbarDelegate>
@property (nonatomic, weak) NSWindow* window;
@property (nonatomic, assign) int32_t windowNumericId;
@property (nonatomic, strong) NSArray<NSToolbarItemIdentifier>* identifiers;
@property (nonatomic, strong) NSDictionary<NSString*, NSDictionary*>* buttonsById;
@end

static NSMutableDictionary<NSValue*, ZappToolbarController*>* zapp_toolbars = nil;

@implementation ZappToolbarController

- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar {
    (void)toolbar;
    return self.identifiers;
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar {
    (void)toolbar;
    return self.identifiers;
}

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar
        itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
    willBeInsertedIntoToolbar:(BOOL)flag {
    (void)toolbar; (void)flag;

    if ([identifier isEqualToString:kZappTrackingSeparatorId]) {
        // Divider tracks the sidebar split. The split view lives on the
        // window's NSSplitViewController root (sidebar construction path).
        if (@available(macOS 11.0, *)) {
            NSViewController* vc = self.window.contentViewController;
            if ([vc isKindOfClass:[NSSplitViewController class]]) {
                NSSplitView* sv = ((NSSplitViewController*)vc).splitView;
                return [NSTrackingSeparatorToolbarItem
                    trackingSeparatorToolbarItemWithIdentifier:identifier
                                                     splitView:sv
                                                  dividerIndex:0];
            }
        }
        return nil;
    }

    // Custom button (system identifiers never reach this callback —
    // AppKit builds toggle/space items itself).
    NSDictionary* def = self.buttonsById[identifier];
    if (!def) return nil;

    NSToolbarItem* item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    NSString* label = [def[@"label"] isKindOfClass:[NSString class]] ? def[@"label"] : @"";
    item.label = label;
    item.paletteLabel = label.length ? label : identifier;
    item.toolTip = label;
    NSString* icon = [def[@"icon"] isKindOfClass:[NSString class]] ? def[@"icon"] : @"";
    if (icon.length) {
        // templateMode 1 = force template — toolbar glyphs must be template
        // images to pick up the bar's tint/vibrancy.
        item.image = zapp_resolve_icon(icon, 18.0, 1);
    }
    item.target = self;
    item.action = @selector(zappToolbarItemClicked:);
    if (@available(macOS 10.15, *)) {
        item.bordered = YES; // modern pill-button look in unified styles
    }
    return item;
}

- (void)zappToolbarItemClicked:(NSToolbarItem*)sender {
    NSString* itemId = sender.itemIdentifier;
    if (!itemId.length) return;
    int32_t numericId = self.windowNumericId;
    // Escape for JS string embedding (same trio as menu.m's click emit).
    NSString* escaped = [itemId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('window:toolbar-clicked',"
            "'{\"windowId\":\"win-%d\",\"id\":\"%@\"}');})();",
            numericId, escaped];
        darwin_webview_eval_all([js UTF8String]);
        worker_broadcast_eval_js((char*)[js UTF8String]);
    });
}

@end

void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id) {
    if (!window_ptr || !toolbar_json || !toolbar_json[0]) return;
    NSWindow* window = (__bridge NSWindow*)window_ptr;

    NSData* data = [NSData dataWithBytes:toolbar_json length:strlen(toolbar_json)];
    NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return;
    NSArray* items = root[@"items"];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return;

    NSMutableArray<NSToolbarItemIdentifier>* ids = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSDictionary*>* buttons = [NSMutableDictionary dictionary];
    for (NSDictionary* def in items) {
        if (![def isKindOfClass:[NSDictionary class]]) continue;
        NSString* type = [def[@"type"] isKindOfClass:[NSString class]] ? def[@"type"] : @"button";
        if ([type isEqualToString:@"toggleSidebar"]) {
            // System item: AppKit supplies icon/animation and routes the
            // action to the split view controller's toggleSidebar:. State
            // stays consistent with win.sidebar.* — both mutate the same
            // NSSplitViewItem.collapsed, so sidebar.m's KVO still emits
            // SIDEBAR_COLLAPSED/EXPANDED either way.
            [ids addObject:NSToolbarToggleSidebarItemIdentifier];
        } else if ([type isEqualToString:@"trackingSeparator"]) {
            [ids addObject:kZappTrackingSeparatorId];
        } else if ([type isEqualToString:@"space"]) {
            [ids addObject:NSToolbarSpaceItemIdentifier];
        } else if ([type isEqualToString:@"flexibleSpace"]) {
            [ids addObject:NSToolbarFlexibleSpaceItemIdentifier];
        } else {
            // Custom button. The runtime validated id presence/uniqueness;
            // belt-and-suspenders here because native Zen-C apps can set
            // toolbarJson directly.
            NSString* itemId = def[@"id"];
            if (![itemId isKindOfClass:[NSString class]] || itemId.length == 0) continue;
            if (buttons[itemId]) continue;
            [ids addObject:itemId];
            buttons[itemId] = def;
        }
    }
    if (ids.count == 0) return;

    ZappToolbarController* c = [[ZappToolbarController alloc] init];
    c.window = window;
    c.windowNumericId = window_numeric_id;
    c.identifiers = ids;
    c.buttonsById = buttons;

    NSToolbar* tb = [[NSToolbar alloc] initWithIdentifier:
        [NSString stringWithFormat:@"zapp-toolbar-%d", window_numeric_id]];
    tb.delegate = c;
    tb.allowsUserCustomization = NO;
    NSString* style = [root[@"style"] isKindOfClass:[NSString class]] ? root[@"style"] : @"unified";
    tb.displayMode = [style isEqualToString:@"expanded"]
        ? NSToolbarDisplayModeIconAndLabel
        : NSToolbarDisplayModeIconOnly;
    if (@available(macOS 11.0, *)) {
        if ([style isEqualToString:@"unifiedCompact"]) window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
        else if ([style isEqualToString:@"expanded"])  window.toolbarStyle = NSWindowToolbarStyleExpanded;
        else                                           window.toolbarStyle = NSWindowToolbarStyleUnified;
    }

    // Register BEFORE assigning window.toolbar — the assignment triggers
    // delegate callbacks synchronously, and the registry retains the
    // controller (NSToolbar.delegate is weak/unretained).
    if (!zapp_toolbars) zapp_toolbars = [NSMutableDictionary dictionary];
    zapp_toolbars[[NSValue valueWithPointer:window_ptr]] = c;
    window.toolbar = tb;
}

void zapp_toolbar_unregister(void* window_ptr) {
    if (!window_ptr || !zapp_toolbars) return;
    [zapp_toolbars removeObjectForKey:[NSValue valueWithPointer:window_ptr]];
}
```

- [ ] **Step 3: Create native/platform/ios/toolbar.m**

```objc
// iOS stubs — NSToolbar is AppKit-only; the iOS analogue (UINavigationBar)
// is a future cycle. These keep the shared window code linking on iOS
// (window.m's attach call compiles into the iOS build; see the
// ios-platform-parity gate in cli/src/ios-platform-parity.test.ts).
#include <stdint.h>

void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id) {
    (void)window_ptr; (void)toolbar_json; (void)window_numeric_id;
}

void zapp_toolbar_unregister(void* window_ptr) {
    (void)window_ptr;
}
```

- [ ] **Step 4: Wire window.m**

(a) Extern decls near the sidebar externs (~line 28–41), after
`extern int32_t wopts_sidebar_numeric_id(void* opts);`:

```objc
// Toolbar (toolbar.m + window.zc accessor).
extern const char* wopts_toolbar_json(void* opts);
extern void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id);
extern void zapp_toolbar_unregister(void* window_ptr);
```

(b) In `darwin_window_create`, immediately after `[window setDelegate:delegate];`
and before `return (__bridge_retained void*)window;` (~line 766):

```objc
        // Native toolbar (toolbar.m). Attach AFTER split construction (the
        // tracking separator resolves the live NSSplitView through the
        // window's contentViewController) and after delegate setup.
        const char* toolbarJson = wopts_toolbar_json(opts);
        if (toolbarJson && toolbarJson[0]) {
            darwin_toolbar_attach((__bridge void*)window, toolbarJson, host_slot);
        }
```

(`host_slot` is the pre-allocated numeric id, in scope since line ~621:
`int32_t host_slot = wopts_numeric_id_pre_alloc(opts);` — it is the id the
click payload's `win-%d` must carry.)

(c) In `darwin_window_destroy`, next to `zapp_sidebar_unregister(handle);`
(~line 847):

```objc
        zapp_toolbar_unregister(handle);
```

(No `windowWillClose:` work — close stays reversible, matching the sidebar
contract; the registry entry only dies with the window.)

- [ ] **Step 5: Register the new sources in cli/src/native.ts**

`getPlatformSources` is the authoritative .m inventory. Add to the darwin
list (next to `path.join(darwinDir, "sidebar.m"),` ~line 64):

```ts
      path.join(darwinDir, "toolbar.m"),
```

And to the iOS list (next to `path.join(iosDir, "sidebar.m"),` ~line 96):

```ts
      path.join(iosDir, "toolbar.m"),
```

- [ ] **Step 6: macOS build gate**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build`
Expected: LAST line `[zapp] build complete: .../bin/hello-world (<size>)`.

- [ ] **Step 7: iOS parity + test suite**

Run: `cd /Users/zach/code/zapp && bun run test`
Expected: all pass (includes `cli/src/ios-platform-parity.test.ts`).

- [ ] **Step 8: iOS simulator compile gate**

`darwin_toolbar_attach` is called from window.m (an .m-only reference the
parity test does NOT cover) — the ios-sim build is the real gate:

Run: `cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator`
Expected: LAST line `[zapp] build complete: <path>` (the iOS .app path).

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/toolbar.m native/platform/ios/toolbar.m \
        native/platform/darwin/window.m native/platform/darwin/menu.m \
        cli/src/native.ts
git commit -m "feat(native): NSToolbar module — attach/registry/delegate + click broadcast

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Docs + hello-world demo (demo stays UNCOMMITTED) + full gates

**Files:**
- Modify: `docs/api-reference.md` (after the SidebarHandle/identity-rules section, ~line 755)
- Modify: `hello-world/src/main.ts` — **user WIP: edit but NEVER stage/commit**

- [ ] **Step 1: Add the Toolbar section to docs/api-reference.md**

Insert after the sidebar "Identity rules" paragraph (~line 755):

````markdown
### Toolbar (macOS)

Pass `toolbar` in `Window.create` to attach a real `NSToolbar`. With
`style: "unified"` (the default) the toolbar merges into the titlebar next
to the traffic lights — the standard modern-macOS look. macOS only; the
option is a no-op elsewhere.

```ts
const win = await Window.create({
  url: "/",
  sidebar: { url: "/nav", width: 240 },
  toolbar: {
    style: "unified",        // "unified" | "unifiedCompact" | "expanded"
    items: [
      { type: "toggleSidebar" },      // system button — icon, animation, behavior supplied by macOS
      { type: "trackingSeparator" },  // toolbar divider tracks the sidebar split
      { id: "compose", icon: "sf:square.and.pencil", label: "Compose",
        action: () => console.log("compose clicked") },
      { type: "flexibleSpace" },
      { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter" },
    ],
  },
});
```

**Items.** `type` defaults to `"button"`. Buttons require an `id` (it keys
click routing; duplicates are an error), take an `icon`
(`sf:<symbol>` / file path / data URL — same resolver as menu icons), a
`label` (tooltip; visible text in the `expanded` style), and an optional
`action` callback. System types: `toggleSidebar`, `trackingSeparator`
(both require the window to have a `sidebar` — warned and dropped
otherwise), `space`, `flexibleSpace`.

**Clicks — the menu pattern.** A button click broadcasts
`window:toolbar-clicked` with `{ windowId, id }` to every webview and
worker. Two ways to consume the same emit:

```ts
// 1. action callback — runs in the context that called Window.create
{ id: "compose", icon: "sf:square.and.pencil", action: () => { ... } }

// 2. window event — any pane of the window (or anyone holding a handle)
win.on(WindowEvent.TOOLBAR_CLICKED, ({ id }) => {
  if (id === "compose") startCompose();
});
```

The `toggleSidebar` button needs no wiring: macOS routes it to the split
view directly, and the existing `SIDEBAR_COLLAPSED` / `SIDEBAR_EXPANDED`
events still fire (same state as `win.sidebar.toggle()`).

v1 is create-time only — no `setItems` after creation; no search field;
`allowsUserCustomization` is off.
````

- [ ] **Step 2: Extend the hello-world sidebar demo (DO NOT STAGE THIS FILE)**

In `hello-world/src/main.ts`, find the `btn-new-window-sidebar` click
handler (search for `"Sidebar Demo"`). Add a `toolbar` option to the
`Window.create` call so it reads:

```ts
  lastSidebarWin = await Window.create({
    title: "Sidebar Demo", width: 900, height: 600,
    url: "#main-pane",
    sidebar: { url: "#sidebar-pane", width: 240, minWidth: 180, maxWidth: 360 },
    toolbar: {
      items: [
        { type: "toggleSidebar" },
        { type: "trackingSeparator" },
        { id: "compose", icon: "sf:square.and.pencil", label: "Compose",
          action: () => log("toolbar action: compose (creator callback)") },
        { type: "flexibleSpace" },
        { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter" },
      ],
    },
  });
```

Then in the pane-override block's **main-pane** branch (search for
`sb-toggle`), after the existing `sb-toggle` listener, add:

```ts
    // Toolbar clicks land here as a window event (same broadcast the
    // creator's action callback consumes).
    win.on(WindowEvent.TOOLBAR_CLICKED, (p: any) => {
      console.log(`[main pane] toolbar clicked: ${p.id}`);
      document.querySelector("#sb-status")!.textContent = `toolbar: ${p.id}`;
    });
```

- [ ] **Step 3: Full gates**

Run: `cd /Users/zach/code/zapp && bun run test:all`
Expected: all bun tests pass, native tests PASS, tsc clean.

Run: `cd hello-world && bun run build`
Expected: LAST line `[zapp] build complete: .../bin/hello-world (<size>)`.

- [ ] **Step 4: Commit (docs ONLY — main.ts stays uncommitted)**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "docs(api): Toolbar section — items, styles, click delivery

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Verify main.ts is NOT staged**

Run: `git status --short hello-world/src/main.ts`
Expected: ` M hello-world/src/main.ts` (unstaged modification only).

---

## Final verification (controller, after all tasks)

1. `bun run test:all` — green.
2. `cd hello-world && bun run build` ends `[zapp] build complete:` with fresh binary mtime.
3. `bun run build --platform ios-simulator` ends `[zapp] build complete:`.
4. Launch hello-world, click "New Window (sidebar)":
   - toolbar appears in the unified titlebar; sidebar-toggle button sits left of the tracking separator;
   - toggle button collapses/expands with the standard animation; `sidebar collapsed/expanded` status still updates in the main pane;
   - dragging the divider moves the toolbar separator with it;
   - clicking Compose logs `toolbar action: compose (creator callback)` in the LAUNCHER window log AND `[main pane] toolbar clicked: compose` in the demo window's main-pane console;
   - clicking Filter logs only the main-pane line (no action callback).
5. USER visual smoke (macOS 26): unified-style look, SF symbols render as template glyphs, expanded style if curious.
