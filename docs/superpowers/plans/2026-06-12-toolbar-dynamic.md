# Dynamic Toolbar Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Toolbar v2 lifecycle — an always-present `win.toolbar` handle with `setItems` (attach-or-replace), `updateItem` (in-place patch, the moving-checkmark case), and `remove` (destroy + chrome-metrics shrink), plus `enabled`/`indicator` item fields.

**Architecture:** Runtime validates/strips patches into wire JSON (pure TDD functions) and keeps per-window action-registry hygiene; three new `toolbar:*` windowActions ride the existing t:4 path with payload-`windowId` resolution; native toolbar.m gains three entry points that reconcile the SAME NSToolbar instance via the existing registry/delegate.

**Spec:** `docs/superpowers/specs/2026-06-12-toolbar-dynamic-design.md` (approved, committed `341878e`)

**Tech Stack:** TypeScript (runtime, bun:test), Objective-C (toolbar.m), Zen-C (router.zc), Bun CLI gates.

---

## Working rules (read first)

- **Branch:** all work on `feat/toolbar-dynamic` (already cut from main). Never commit to main.
- **NEVER stage user-WIP files:** `hello-world/src/main.ts`, `hello-world/src/worker.ts`, `hello-world/zapp.config.ts`, `vendor/bare`, `kitchen-sink/`, `native/worker/engines/zjs-cross-eval-test.c`. Stage files by explicit path (`git add <path>`), never `git add -A`/`-u`/`.`.
- **Commit trailer (exact):** end every commit message with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Build success** = the LAST line of build output is `[zapp] build complete: <path>` AND the binary mtime is fresh. Vite's `✓ built in XXms` is NOT success.
- **`bun run build` does NOT type-check.** Type gate is `bun run check` (root), part of `bun run test:all`.
- Always Bun, never Node.
- Hello-world demo edits are fine but are NEVER committed (T4 demo step edits `hello-world/src/main.ts` — leave it dirty).

## File map

| Path | Change |
| --- | --- |
| `runtime/window.ts` | `ToolbarItemPatch`/`ToolbarHandle` types; `enabled`/`indicator` on `ToolbarItemDef`; `normalizeToolbar` gains `menuIdsByItem` in its return; new `normalizeToolbarPatch` + purge/record helpers; `toolbar` property on every `WindowHandle`; `Window.create` records menu-id bookkeeping |
| `runtime/toolbar.test.ts` | new test blocks: `normalizeToolbarPatch`, registry purge helpers, `enabled`/`indicator` wire shape |
| `native/platform/darwin/toolbar.m` | `zapp_toolbar_on_main` helper; `zapp_toolbar_parse_items` extraction; `validateToolbarItem:`; `enabled`/`indicator` honored at build; `darwin_toolbar_set_items` / `darwin_toolbar_update_item` / `darwin_toolbar_remove`; `inject_metrics` toolbar-height→0 fix |
| `native/platform/ios/toolbar.m` | 3 new no-op stubs |
| `native/app/router.zc` | `toolbar:setItems` / `toolbar:updateItem` / `toolbar:remove` action block (Apple-gated, payload-windowId resolution) |
| `docs/api-reference.md` | Toolbar section: dynamic API subsection, `enabled`/`indicator`, drop the "v1 is create-time only" line |

Task order is load-bearing: T1 (runtime) is self-contained; T2 (native) builds green uncalled; T3 (router) references T2's symbols so every commit boundary links; T4 is docs + demo + gates.

---

### Task 1: Runtime — patch normalization, registry hygiene, ToolbarHandle

**Files:**
- Modify: `runtime/window.ts` (toolbar block ~lines 218–247, 316–407; `WindowHandle` interface ~line 425; `createWindowHandle` ~line 557; `Window.create` ~line 684)
- Test: `runtime/toolbar.test.ts`

- [ ] **Step 1: Write the failing tests**

Append to `runtime/toolbar.test.ts` (note the widened import list — `normalizeToolbarPatch`, `purgeWindowToolbarActions`, `purgeItemToolbarMenuActions`, `recordToolbarMenuIds` come from `./window`):

```ts
import {
  normalizeToolbarPatch,
  purgeWindowToolbarActions,
  purgeItemToolbarMenuActions,
  recordToolbarMenuIds,
} from "./window";

describe("normalizeToolbar enabled/indicator wire shape", () => {
  test("enabled and indicator pass through only when explicitly set", () => {
    const { json } = normalizeToolbar({
      items: [
        { id: "compose", enabled: false },
        { id: "filter", indicator: false, menu: [{ id: "all", label: "All" }] },
        { id: "plain" },
      ],
    }, false);
    const items = JSON.parse(json).items;
    expect(items[0].enabled).toBe(false);
    expect(items[1].indicator).toBe(false);
    expect("enabled" in items[2]).toBe(false);
    expect("indicator" in items[2]).toBe(false);
  });

  test("menuIdsByItem groups registered menu-action ids per item", () => {
    const { menuIdsByItem } = normalizeToolbar({
      items: [
        { id: "filter", menu: [
          { id: "all", label: "All", action: () => {} },
          { id: "unread", label: "Unread" },           // no action — not registered
        ] },
        { id: "plain" },                               // no menu — no entry
      ],
    }, false);
    expect(menuIdsByItem.get("filter")).toEqual(new Set(["all"]));
    expect(menuIdsByItem.has("plain")).toBe(false);
  });
});

describe("normalizeToolbarPatch", () => {
  test("builds wire json with only patched keys plus id", () => {
    const { json } = normalizeToolbarPatch("compose", { label: "New", enabled: false });
    expect(JSON.parse(json)).toEqual({ id: "compose", label: "New", enabled: false });
  });

  test("empty patch throws", () => {
    expect(() => normalizeToolbarPatch("compose", {})).toThrow(/empty patch/);
  });

  test("unknown patch keys throw", () => {
    expect(() => normalizeToolbarPatch("compose", { tooltip: "x" } as any))
      .toThrow(/unknown patch key "tooltip"/);
  });

  test("invalid id throws", () => {
    expect(() => normalizeToolbarPatch('a"b', { label: "x" })).toThrow(/invalid item id/);
    expect(() => normalizeToolbarPatch("zapp.x", { label: "x" })).toThrow(/invalid item id/);
  });

  test("action and menu together throw", () => {
    expect(() => normalizeToolbarPatch("x", { action: () => {}, menu: [] }))
      .toThrow(/both "action" and "menu"/);
  });

  test("action is returned, not serialized", () => {
    const fn = () => {};
    const { json, action } = normalizeToolbarPatch("x", { action: fn });
    expect(action).toBe(fn);
    expect(json).not.toContain("action");
    expect(JSON.parse(json)).toEqual({ id: "x" });
  });

  test("menu actions stripped + collected, indicator passes through", () => {
    let hit = "";
    const { json, menuActions } = normalizeToolbarPatch("filter", {
      indicator: false,
      menu: [
        { id: "all", label: "All", checked: true, action: () => { hit = "all"; } },
        { id: "unread", label: "Unread" },
      ],
    });
    const wire = JSON.parse(json);
    expect(wire.indicator).toBe(false);
    expect(wire.menu).toEqual([
      { id: "all", label: "All", checked: true },
      { id: "unread", label: "Unread" },
    ]);
    expect(menuActions.size).toBe(1);
    menuActions.get("all")!();
    expect(hit).toBe("all");
  });

  test("action-bearing menu items without id get auto-ids", () => {
    const { json, menuActions } = normalizeToolbarPatch("f", {
      menu: [{ label: "X", action: () => {} }],
    });
    const autoId = JSON.parse(json).menu[0].id;
    expect(autoId).toMatch(/^__tbmenu_\d+$/);
    expect(menuActions.has(autoId)).toBe(true);
  });
});

describe("toolbar registry hygiene helpers", () => {
  test("purgeWindowToolbarActions removes button keys by prefix and all menu ids", () => {
    const actions = new Map<string, () => void>([
      ["win-1:compose", () => {}],
      ["win-1:filter", () => {}],
      ["win-2:compose", () => {}],
    ]);
    const menuActions = new Map<string, () => void>([
      ["all", () => {}], ["unread", () => {}], ["other-window", () => {}],
    ]);
    const byWindow = new Map<string, Map<string, Set<string>>>([
      ["win-1", new Map([["filter", new Set(["all", "unread"])]])],
      ["win-2", new Map([["f2", new Set(["other-window"])]])],
    ]);
    purgeWindowToolbarActions("win-1", actions, menuActions, byWindow);
    expect([...actions.keys()]).toEqual(["win-2:compose"]);
    expect([...menuActions.keys()]).toEqual(["other-window"]);
    expect(byWindow.has("win-1")).toBe(false);
    expect(byWindow.has("win-2")).toBe(true);
  });

  test("purgeItemToolbarMenuActions removes only that item's menu ids", () => {
    const menuActions = new Map<string, () => void>([["all", () => {}], ["keep", () => {}]]);
    const byWindow = new Map<string, Map<string, Set<string>>>([
      ["win-1", new Map([["filter", new Set(["all"])], ["other", new Set(["keep"])]])],
    ]);
    purgeItemToolbarMenuActions("win-1", "filter", menuActions, byWindow);
    expect([...menuActions.keys()]).toEqual(["keep"]);
    expect(byWindow.get("win-1")!.has("filter")).toBe(false);
    expect(byWindow.get("win-1")!.has("other")).toBe(true);
  });

  test("purgeItemToolbarMenuActions no-ops on unknown window/item", () => {
    const menuActions = new Map<string, () => void>([["all", () => {}]]);
    const byWindow = new Map<string, Map<string, Set<string>>>();
    purgeItemToolbarMenuActions("nope", "filter", menuActions, byWindow);
    expect(menuActions.size).toBe(1);
  });

  test("recordToolbarMenuIds nests per-item under the window", () => {
    const byWindow = new Map<string, Map<string, Set<string>>>();
    recordToolbarMenuIds("win-1", new Map([["filter", new Set(["all"])]]), byWindow);
    recordToolbarMenuIds("win-1", new Map([["other", new Set(["x"])]]), byWindow);
    expect(byWindow.get("win-1")!.get("filter")).toEqual(new Set(["all"]));
    expect(byWindow.get("win-1")!.get("other")).toEqual(new Set(["x"]));
  });

  test("recordToolbarMenuIds with empty map adds nothing", () => {
    const byWindow = new Map<string, Map<string, Set<string>>>();
    recordToolbarMenuIds("win-1", new Map(), byWindow);
    expect(byWindow.size).toBe(0);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts`
Expected: FAIL — `normalizeToolbarPatch` etc. are not exported (SyntaxError/undefined), plus the two new normalizeToolbar assertions fail.

- [ ] **Step 3: Implement the runtime changes**

All edits in `runtime/window.ts`.

**3a — `ToolbarItemDef` gains `enabled`/`indicator`** (after the `menu?` member, ~line 239):

```ts
  /** Buttons: enabled state. Default true. AppKit-validated, so it sticks
   *  across revalidation. Patchable via win.toolbar.updateItem. */
  enabled?: boolean;
  /** Menu buttons: show the pull-down chevron. Default true; false is the
   *  Messages-app no-chevron look. */
  indicator?: boolean;
```

**3b — new types after `ToolbarOptions`** (~line 247):

```ts
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
```

**3c — registry hygiene helpers + per-window menu-id bookkeeping.** Replace the doc comment above `toolbarActions` (~lines 316–318) with:

```ts
/** Toolbar action callbacks keyed "<windowId>:<itemId>" — Menu.build's
 * collect/strip/listen shape (runtime/menu.ts), but per-window.
 * Hygiene: setItems/remove purge the window's entries; updateItem swaps
 * one entry. Only windows that never touch their toolbar again keep
 * entries for the app lifetime (create-time-only apps — the v1 behavior). */
```

Then after `stripMenuActions` (~line 362) add:

```ts
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
```

**3d — `normalizeToolbar`: `enabled`/`indicator` passthrough + `menuIdsByItem`.** Change the signature/return (~line 366):

```ts
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
```

and the button wire block (~lines 401–404) becomes:

```ts
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
```

and the return gains the new map:

```ts
  return { json: JSON.stringify({ style: toolbar.style ?? "unified", items }), actions, menuActions, menuIdsByItem };
```

**3e — `normalizeToolbarPatch`** (new, directly after `normalizeToolbar`):

```ts
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
  return { json: JSON.stringify(wire), action: patch.action, menuActions };
}
```

**3f — `WindowHandle` gains the handle** (interface, after the `sidebar` member ~line 428):

```ts
  /** Lifecycle handle for this window's native toolbar (macOS). Always
   *  present — setItems attaches when no toolbar exists. */
  readonly toolbar: ToolbarHandle;
```

**3g — implement in `createWindowHandle`** (add after the `sidebar:` property, ~line 603; `windowId` and `sidebarOpts` are in scope):

```ts
    toolbar: {
      setItems(items: ToolbarItemDef[], setOpts?: { style?: "unified" | "unifiedCompact" | "expanded" }) {
        const { json, actions, menuActions, menuIdsByItem } =
          normalizeToolbar({ items, style: setOpts?.style }, sidebarOpts !== undefined);
        // Only send style when the caller set one — native warns when style
        // arrives for an already-attached toolbar, and normalizeToolbar
        // always defaults it.
        let wireJson = json;
        if (setOpts?.style === undefined) {
          const parsed = JSON.parse(json);
          delete parsed.style;
          wireJson = JSON.stringify(parsed);
        }
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
```

**3h — `Window.create` bookkeeping.** The toolbar block (~lines 687–702) destructures the new map and records it once the windowId is known:

```ts
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts && bun test runtime/`
Expected: PASS (all pre-existing toolbar/popover/window tests stay green — the `normalizeToolbar` return-shape change is additive).

- [ ] **Step 5: Type-check**

Run: `cd /Users/zach/code/zapp && bun run check`
Expected: clean (the always-present `toolbar` property is provided by `createWindowHandle`, the only `WindowHandle` constructor).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/window.ts runtime/toolbar.test.ts
git commit -m "$(cat <<'EOF'
feat(runtime): ToolbarHandle (setItems/updateItem/remove) + patch normalization

Always-present win.toolbar on every WindowHandle. normalizeToolbarPatch
validates patch keys and strips action/menu callbacks; per-window
registry hygiene (purge/record helpers, unit-tested) shrinks the v1
"entries persist for app lifetime" leak to create-time-only apps.
ToolbarItemDef gains enabled/indicator (wire passthrough only when set).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Native — toolbar.m set_items/update_item/remove + enabled/indicator + iOS stubs

**Files:**
- Modify: `native/platform/darwin/toolbar.m`
- Modify: `native/platform/ios/toolbar.m`

No bun tests here (ObjC); the gates are a clean macOS build (Task 4) and the iOS parity test. Reference state of toolbar.m before this task: registry `zapp_toolbars` keyed by window ptr; `darwin_toolbar_attach` at line 167; `zapp_toolbar_inject_metrics` at line 256; `zapp_toolbar_unregister` at line 316.

- [ ] **Step 1: Add the on-main helper and parse-items extraction**

In `native/platform/darwin/toolbar.m`, after the `kZappTrackingSeparatorId` definition (line 26), add (sidebar.m's pattern — router actions can arrive off-main from worker contexts):

```objc
static void zapp_toolbar_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}
```

Extract the items-parsing loop so attach and set_items can never drift. Add this static function ABOVE `darwin_toolbar_attach`:

```objc
// Parse the wire items array into the identifier list + custom-button defs.
// Shared by darwin_toolbar_attach and darwin_toolbar_set_items.
static NSArray<NSToolbarItemIdentifier>* zapp_toolbar_parse_items(
    NSArray* items, NSMutableDictionary<NSString*, NSDictionary*>* buttons) {
    NSMutableArray<NSToolbarItemIdentifier>* ids = [NSMutableArray array];
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
    return ids;
}
```

Then in `darwin_toolbar_attach`, replace the original loop (lines 183–212, from `NSMutableArray<NSToolbarItemIdentifier>* ids = ...` through `if (ids.count == 0) return;`) with:

```objc
    NSMutableDictionary<NSString*, NSDictionary*>* buttons = [NSMutableDictionary dictionary];
    NSArray<NSToolbarItemIdentifier>* ids = zapp_toolbar_parse_items(items, buttons);
    if (ids.count == 0) return;
```

- [ ] **Step 2: enabled via validateToolbarItem: + enabled/indicator at item build**

Add to `ZappToolbarController`'s `@implementation` (after `zappToolbarItemClicked:`):

```objc
// AppKit's canonical enabled mechanism for action items: the toolbar
// revalidates on its own schedule (key-window changes, event loop idle),
// overwriting any bare `.enabled` set — so the stored def is the source of
// truth and this answers every revalidation pass. Default YES.
- (BOOL)validateToolbarItem:(NSToolbarItem*)item {
    NSDictionary* def = self.buttonsById[item.itemIdentifier];
    NSNumber* en = [def[@"enabled"] isKindOfClass:[NSNumber class]] ? def[@"enabled"] : nil;
    return en ? en.boolValue : YES;
}
```

In `toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:`'s NSMenuToolbarItem branch, replace the hardcoded `mitem.showsIndicator = YES; // the chevron` line with:

```objc
            NSNumber* ind = [def[@"indicator"] isKindOfClass:[NSNumber class]] ? def[@"indicator"] : nil;
            mitem.showsIndicator = ind ? ind.boolValue : YES; // the chevron
            // No action → AppKit never validates this item; own .enabled
            // directly (mirrors validateToolbarItem: for action buttons).
            mitem.autovalidates = NO;
            NSNumber* men = [def[@"enabled"] isKindOfClass:[NSNumber class]] ? def[@"enabled"] : nil;
            mitem.enabled = men ? men.boolValue : YES;
```

(The plain-button branch needs no change — it has a target/action, so `validateToolbarItem:` governs it.)

- [ ] **Step 3: inject_metrics — report 0px when the toolbar is gone**

In `zapp_toolbar_inject_metrics`, the fallback `if (toolbarH <= 0) toolbarH = totalInset;` exists for the AppKit-renames-NSToolbarView case — but after `darwin_toolbar_remove` there IS no toolbar and the var must go to 0px. Replace that line with:

```objc
    // No NSToolbarView found: with a live toolbar that's the class-name-walk
    // fallback (treat the full band as the row, == unified behavior); with no
    // toolbar (post-remove re-inject) the row is genuinely gone — 0px.
    if (toolbarH <= 0) toolbarH = window.toolbar ? totalInset : 0;
```

- [ ] **Step 4: darwin_toolbar_set_items (reconcile-or-attach)**

Add after `darwin_toolbar_attach`:

```objc
// Replace the full item set. Registry hit: reconcile the SAME NSToolbar
// instance (the delegate serves the new defs). Registry miss: late-attach
// via darwin_toolbar_attach (style honored), then schedule this path's own
// metrics injection — window.m's construction-time injection already ran
// (toolbar-less) and stays unchanged.
void darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot) {
    if (!window_ptr || !toolbar_json || !toolbar_json[0]) return;
    NSString* json = [NSString stringWithUTF8String:toolbar_json];
    NSWindow* window = (__bridge NSWindow*)window_ptr;
    zapp_toolbar_on_main(^{
        NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSError* err = nil;
        NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![root isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[zapp] toolbar: invalid toolbarJson (%@) — setItems ignored",
                  err ? err.localizedDescription : @"not an object");
            return;
        }
        NSValue* key = [NSValue valueWithPointer:(__bridge void*)window];
        ZappToolbarController* c = zapp_toolbars ? zapp_toolbars[key] : nil;
        if (!c) {
            // Late attach. Style in the json is honored here (fresh attach).
            darwin_toolbar_attach((__bridge void*)window, [json UTF8String], host_slot);
            if (!zapp_toolbars || !zapp_toolbars[key]) return; // attach rejected (no items)
            // One tick so AppKit lays the band out before measuring;
            // add_user_script=true so reloads keep the value (attach parity).
            dispatch_async(dispatch_get_main_queue(), ^{
                zapp_toolbar_inject_metrics((__bridge void*)window, host_slot, true);
            });
            return;
        }
        if (root[@"style"]) {
            NSLog(@"[zapp] toolbar: style can only be set when attaching — ignored (toolbar already present)");
        }
        NSArray* items = [root[@"items"] isKindOfClass:[NSArray class]] ? root[@"items"] : @[];
        NSMutableDictionary<NSString*, NSDictionary*>* buttons = [NSMutableDictionary dictionary];
        NSArray<NSToolbarItemIdentifier>* ids = zapp_toolbar_parse_items(items, buttons);
        if (ids.count == 0) {
            NSLog(@"[zapp] toolbar: setItems with no items — use toolbar.remove() to destroy the toolbar");
            return;
        }
        NSToolbar* tb = window.toolbar;
        if (!tb) return; // registered but no toolbar — shouldn't happen; bail
        // New defs BEFORE reconcile — insertItemWithItemIdentifier: consults
        // the delegate (allowed list + item construction) synchronously.
        c.identifiers = ids;
        c.buttonsById = buttons;
        while (tb.items.count > 0) [tb removeItemAtIndex:0];
        for (NSUInteger i = 0; i < ids.count; i++) {
            [tb insertItemWithItemIdentifier:ids[i] atIndex:(NSInteger)i];
        }
        // The contentLayoutRect KVO catches band-height changes; this covers
        // the same-height case cheaply (no-op-skip cache absorbs it).
        zapp_toolbar_inject_metrics((__bridge void*)window, host_slot, false);
    });
}
```

- [ ] **Step 5: darwin_toolbar_update_item (in-place patch)**

Add after `darwin_toolbar_set_items`:

```objc
// Patch one item in place. item_json = {"id", ...only patched keys}.
// Merges into the stored def first (future delegate rebuilds must agree),
// then mutates the live NSToolbarItem. A shape change (menu added to a
// plain button, or removed) rebuilds that one item at its index instead —
// NSToolbarItem and NSMenuToolbarItem can't convert in place.
void darwin_toolbar_update_item(void* window_ptr, const char* item_json) {
    if (!window_ptr || !item_json || !item_json[0]) return;
    NSString* json = [NSString stringWithUTF8String:item_json];
    NSWindow* window = (__bridge NSWindow*)window_ptr;
    zapp_toolbar_on_main(^{
        NSValue* key = [NSValue valueWithPointer:(__bridge void*)window];
        ZappToolbarController* c = zapp_toolbars ? zapp_toolbars[key] : nil;
        if (!c || !window.toolbar) {
            NSLog(@"[zapp] toolbar: updateItem on a window without a toolbar — ignored");
            return;
        }
        NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* patch = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![patch isKindOfClass:[NSDictionary class]]) return;
        NSString* itemId = [patch[@"id"] isKindOfClass:[NSString class]] ? patch[@"id"] : nil;
        if (!itemId.length) return;
        NSDictionary* def = c.buttonsById[itemId];
        if (!def) {
            NSLog(@"[zapp] toolbar: updateItem unknown id \"%@\" — ignored", itemId);
            return;
        }

        // Merge patched keys into the stored def (source of truth for the
        // delegate and validateToolbarItem:).
        NSMutableDictionary* merged = [def mutableCopy];
        for (NSString* k in patch) {
            if (![k isEqualToString:@"id"]) merged[k] = patch[k];
        }
        NSMutableDictionary<NSString*, NSDictionary*>* buttons = [c.buttonsById mutableCopy];
        buttons[itemId] = merged;
        c.buttonsById = buttons;

        // Find the live item.
        NSToolbarItem* live = nil;
        NSInteger idx = -1;
        NSArray<NSToolbarItem*>* arr = window.toolbar.items;
        for (NSInteger i = 0; i < (NSInteger)arr.count; i++) {
            if ([arr[(NSUInteger)i].itemIdentifier isEqualToString:itemId]) {
                live = arr[(NSUInteger)i];
                idx = i;
                break;
            }
        }
        if (!live) return; // def updated; nothing displayed to mutate

        BOOL wantsMenu = [merged[@"menu"] isKindOfClass:[NSArray class]] && ((NSArray*)merged[@"menu"]).count > 0;
        BOOL isMenuItem = NO;
        if (@available(macOS 10.15, *)) isMenuItem = [live isKindOfClass:[NSMenuToolbarItem class]];
        if (wantsMenu != isMenuItem) {
            // Shape change: rebuild this one item — the delegate serves the
            // merged def (becomes/stops being an NSMenuToolbarItem).
            [window.toolbar removeItemAtIndex:idx];
            [window.toolbar insertItemWithItemIdentifier:itemId atIndex:idx];
            return;
        }

        if ([patch[@"label"] isKindOfClass:[NSString class]]) {
            NSString* label = patch[@"label"];
            live.label = label;
            live.paletteLabel = label.length ? label : itemId;
            live.toolTip = label;
        }
        if ([patch[@"icon"] isKindOfClass:[NSString class]] && ((NSString*)patch[@"icon"]).length) {
            live.image = zapp_resolve_icon(patch[@"icon"], 18.0, 1);
        }
        if (@available(macOS 10.15, *)) {
            if (isMenuItem) {
                NSMenuToolbarItem* mlive = (NSMenuToolbarItem*)live;
                if ([patch[@"menu"] isKindOfClass:[NSArray class]]) {
                    // Fresh NSMenu — the flicker-free checkmark refresh.
                    NSData* mdata = [NSJSONSerialization dataWithJSONObject:patch[@"menu"] options:0 error:nil];
                    NSString* mjson = mdata ? [[NSString alloc] initWithData:mdata encoding:NSUTF8StringEncoding] : nil;
                    NSMenu* menu = mjson ? (__bridge_transfer NSMenu*)darwin_menu_build_from_items_json([mjson UTF8String]) : nil;
                    if (menu) mlive.menu = menu;
                }
                if ([patch[@"indicator"] isKindOfClass:[NSNumber class]]) {
                    mlive.showsIndicator = [patch[@"indicator"] boolValue];
                }
                if ([patch[@"enabled"] isKindOfClass:[NSNumber class]]) {
                    mlive.enabled = [patch[@"enabled"] boolValue]; // autovalidates is NO
                }
            }
        }
        // Action buttons: enabled lives in the merged def; force a
        // validation pass so it applies now, not on the next idle.
        [window.toolbar validateVisibleItems];
    });
}
```

- [ ] **Step 6: darwin_toolbar_remove (ordered teardown)**

Add after `darwin_toolbar_update_item`:

```objc
// Destroy the toolbar. ORDER IS LOAD-BEARING:
//  1. remove the contentLayoutRect KVO observer — the controller is about
//     to lose its only strong ref (the registry), and the coalesced KVO
//     block holds it weakly: it would silently skip the final re-inject;
//  2. detach the NSToolbar;
//  3. one tick later, re-measure capturing the WINDOW + SLOT (not the
//     controller) — titlebar height shrinks back, toolbar-height → 0px;
//  4. drop the registry entry (controller deallocates).
// No-op when not registered.
void darwin_toolbar_remove(void* window_ptr) {
    if (!window_ptr) return;
    NSWindow* window = (__bridge NSWindow*)window_ptr;
    zapp_toolbar_on_main(^{
        NSValue* key = [NSValue valueWithPointer:(__bridge void*)window];
        ZappToolbarController* c = zapp_toolbars ? zapp_toolbars[key] : nil;
        if (!c) return;
        int32_t slot = c.windowNumericId;
        @try {
            [window removeObserver:c forKeyPath:@"contentLayoutRect"];
        } @catch (NSException* e) {
            (void)e; // not registered — harmless
        }
        window.toolbar = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Registry entry is gone by now → the no-op-skip cache is
            // bypassed and inject runs unconditionally (block captures the
            // window strongly through the tick).
            zapp_toolbar_inject_metrics((__bridge void*)window, slot, false);
        });
        [zapp_toolbars removeObjectForKey:key];
    });
}
```

- [ ] **Step 7: iOS stubs**

Append to `native/platform/ios/toolbar.m`:

```objc
void darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot) {
    (void)window_ptr; (void)toolbar_json; (void)host_slot;
}

void darwin_toolbar_update_item(void* window_ptr, const char* item_json) {
    (void)window_ptr; (void)item_json;
}

void darwin_toolbar_remove(void* window_ptr) {
    (void)window_ptr;
}
```

- [ ] **Step 8: Verify the macOS build still links (new code is uncalled but must compile)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build`
Expected: LAST line is `[zapp] build complete: <path>`. If it isn't, the build failed regardless of what Vite printed.

- [ ] **Step 9: iOS parity test**

Run: `cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts`
Expected: PASS (it only checks `.zc`-referenced symbols — the router doesn't reference these yet, but the stubs are in place for Task 3).

- [ ] **Step 10: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/toolbar.m native/platform/ios/toolbar.m
git commit -m "$(cat <<'EOF'
feat(native): toolbar set_items/update_item/remove + enabled/indicator

darwin_toolbar_set_items reconciles the SAME NSToolbar on registry hit
(remove-all + insert by identifier; style warn+ignore) and late-attaches
via darwin_toolbar_attach on miss (own one-tick metrics injection).
darwin_toolbar_update_item merges the patch into the stored def and
mutates the live item in place (fresh NSMenu = flicker-free checkmark);
shape changes rebuild the one item at its index. darwin_toolbar_remove
tears down in KVO→toolbar=nil→re-inject→registry order. enabled rides
validateToolbarItem: for action buttons (AppKit revalidation-proof) and
direct .enabled + autovalidates=NO for menu items; indicator maps to
showsIndicator. inject_metrics now reports 0px toolbar-height when the
toolbar is gone instead of the live-toolbar fallback.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Router — toolbar:setItems / toolbar:updateItem / toolbar:remove

**Files:**
- Modify: `native/app/router.zc` (insert after the popover action block, which ends at the `return;` near line 756, before the tray block)

- [ ] **Step 1: Add the action block**

Insert into `router_handle_window_action` in `native/app/router.zc`, directly after the popover block's closing `}` (after line ~756) and before the `// Tray actions` comment:

```zc
    // Toolbar lifecycle — window ops on an existing window, ungated like
    // sidebar:* (docs/security.md). Payload-windowId resolution (sidebar
    // pattern) so handles work from the creator, either pane, anywhere;
    // fall back to the SENDER's slot. The numeric id doubles as the
    // host_slot for chrome-metrics injection (window.m slot == window id).
    let is_tb_set = action == "toolbar:setItems";
    let is_tb_update = action == "toolbar:updateItem";
    let is_tb_remove = action == "toolbar:remove";
    if is_tb_set || is_tb_update || is_tb_remove {
        let tb_target = window_id;
        let tb_wid_opt = pre_args.get_string("windowId");
        if tb_wid_opt.is_some() {
            raw {
                #ifdef __APPLE__
                extern int32_t darwin_window_numeric_id_for_string(const char* wid);
                int32_t tb_resolved = darwin_window_numeric_id_for_string((const char*)tb_wid_opt.val);
                if (tb_resolved >= 0) tb_target = tb_resolved;
                #endif
            }
        }
        let tb_json: string = "";
        if is_tb_set {
            let tj_opt = pre_args.get_string("toolbarJson");
            if !tj_opt.is_some() { return; }
            tb_json = tj_opt.unwrap();
        }
        if is_tb_update {
            let ij_opt = pre_args.get_string("itemJson");
            if !ij_opt.is_some() { return; }
            tb_json = ij_opt.unwrap();
        }
        raw {
            #ifdef __APPLE__
            extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
            extern void darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot);
            extern void darwin_toolbar_update_item(void* window_ptr, const char* item_json);
            extern void darwin_toolbar_remove(void* window_ptr);
            void* tb_wptr = darwin_window_get_by_numeric_id((int32_t)tb_target);
            if (tb_wptr) {
                if (is_tb_set) darwin_toolbar_set_items(tb_wptr, (const char*)tb_json, (int32_t)tb_target);
                else if (is_tb_update) darwin_toolbar_update_item(tb_wptr, (const char*)tb_json);
                else darwin_toolbar_remove(tb_wptr);
            }
            #endif
        }
        return;
    }
```

Notes for the implementer:
- `pre_args` is the heap-allocating json_safe parser — no truncation risk for large `toolbarJson` (menus included).
- The externs are declared inside the `raw` block, `#ifdef __APPLE__`-gated — this compiles into the iOS binary too, which is exactly why Task 2 added the iOS stubs (the `#ifdef __APPLE__` is true on iOS; see docs/architecture.md "Verifying native changes").
- No permission gate: `toolbar:*` are window ops on an existing window, same class as `sidebar:*` (`permission_id_for_action` returns `""` for them already — no change needed there).

- [ ] **Step 2: macOS build (the real compile gate for .zc)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build`
Expected: LAST line `[zapp] build complete: <path>`, fresh binary mtime.

- [ ] **Step 3: iOS-simulator build (links the stubs)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator`
Expected: LAST line `[zapp] build complete: <path>`.

- [ ] **Step 4: iOS parity test (now that .zc references the symbols)**

Run: `cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts`
Expected: PASS — `darwin_toolbar_set_items`/`darwin_toolbar_update_item`/`darwin_toolbar_remove` are referenced from router.zc and defined in both `native/platform/darwin/` and `native/platform/ios/`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/app/router.zc
git commit -m "$(cat <<'EOF'
feat(router): toolbar:setItems/updateItem/remove window actions

Payload-windowId resolution with sender fallback (sidebar pattern);
numeric id doubles as host_slot. Ungated — window ops on an existing
window, same class as sidebar:*. Apple-gated raw block; iOS links via
the Task-2 stubs.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Docs, demo (never committed), full gates

**Files:**
- Modify: `docs/api-reference.md` (Toolbar section, lines 816–878)
- Modify (NEVER COMMIT): `hello-world/src/main.ts`

- [ ] **Step 1: Update the Toolbar docs**

In `docs/api-reference.md`:

**1a.** In the **Items** paragraph (~line 841), extend the button description — after "and an optional `action` callback." add:

```
Buttons also take `enabled?: boolean` (default `true`; greyed out and
unclickable when `false`) and — on menu buttons — `indicator?: boolean`
(default `true`; `false` hides the pull-down chevron, the Messages-app
look).
```

**1b.** Replace the final v1 line (~lines 877–878):

```
v1 is create-time only — no `setItems` after creation; no search field;
`allowsUserCustomization` is off.
```

with a new subsection:

```markdown
**Dynamic updates — `win.toolbar`.** Every `WindowHandle` carries a
`ToolbarHandle` (macOS; ops no-op elsewhere):

\```ts
const win = Window.current();

// Attach-or-replace the full item set. Attaches a toolbar when the window
// has none (late attach — style honored only then; warned + ignored on a
// live toolbar).
win.toolbar.setItems([
  { id: "compose", icon: "sf:square.and.pencil", label: "Compose",
    action: () => startCompose() },
  { type: "flexibleSpace" },
  { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
    indicator: false,
    menu: filterMenu("all") },
]);

// Patch one item in place — the moving-checkmark case. menu REPLACES the
// pull-down; label/icon/enabled/indicator patch individually; action
// replaces the creator callback. Unknown id → native warn, no-op.
win.toolbar.updateItem("filter", { menu: filterMenu("unread") });
win.toolbar.updateItem("compose", { enabled: false });

// Destroy. Chrome metrics re-inject: --zapp-titlebar-height shrinks back
// to the bare-titlebar inset and --zapp-toolbar-height goes to 0px.
win.toolbar.remove();
\```

`setItems` re-runs the create-time validation (ids, reserved prefixes,
action/menu exclusivity) and re-registers action callbacks in the calling
context, purging the window's previous registrations. No search field;
`allowsUserCustomization` is off.
```

(Strip the backslashes before the inner code fence — they're only here to nest the fence in this plan.)

- [ ] **Step 2: Demo in hello-world (user-WIP — edit, NEVER stage)**

Add to the existing toolbar demo wiring in `hello-world/src/main.ts` (adapt to whatever the current WIP demo looks like — the window-with-sidebar+toolbar demo from the toolbar cycle). The demo must prove all four spec gates: moving checkmark, enable/disable grey-out, `indicator: false`, remove/attach with visible padding change. Self-contained snippet to adapt:

```ts
// --- dynamic toolbar demo (WIP — never commit) ---
let tbFilter = "all";
const filterMenu = () => [
  { id: "tbf-all", label: "All", checked: tbFilter === "all", action: () => setTbFilter("all") },
  { id: "tbf-unread", label: "Unread", checked: tbFilter === "unread", action: () => setTbFilter("unread") },
  { id: "tbf-flagged", label: "Flagged", checked: tbFilter === "flagged", action: () => setTbFilter("flagged") },
];
const setTbFilter = (f: string) => {
  tbFilter = f;
  console.log("[demo] filter →", f);
  Window.current().toolbar.updateItem("filter", { menu: filterMenu() }); // checkmark moves
};

const tbItems = () => [
  { type: "toggleSidebar" } as const,
  { type: "trackingSeparator" } as const,
  { id: "compose", icon: "sf:square.and.pencil", label: "Compose", action: () => console.log("[demo] compose") },
  { type: "flexibleSpace" } as const,
  { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter", indicator: false, menu: filterMenu() },
];

let composeEnabled = true;
// Wire three demo buttons in the page UI:
//   "Toggle compose enabled" →
(() => {
  composeEnabled = !composeEnabled;
  Window.current().toolbar.updateItem("compose", { enabled: composeEnabled });
})
//   "Remove toolbar" →  Window.current().toolbar.remove()
//   "Attach toolbar" →  Window.current().toolbar.setItems(tbItems())
// Pane padding already uses var(--zapp-titlebar-height) — remove/attach
// must visibly shrink/grow the content inset.
```

- [ ] **Step 3: Full test gate**

Run: `cd /Users/zach/code/zapp && bun run test:all`
Expected: PASS (bun tests + native .zc tests + tsc). ~10 pre-existing tsc baseline errors were fixed in the tsc-gate cycle — `bun run check` must be CLEAN; any new error is yours.

- [ ] **Step 4: Build gates**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator
```
Expected: each ends with `[zapp] build complete: <path>`.

- [ ] **Step 5: Runtime smoke (dev app)**

Run the dev app briefly and exercise the demo (macOS lacks `timeout`; use the established python-subprocess pattern or run interactively):

```bash
cd /Users/zach/code/zapp/hello-world && bun run dev
```

Verify in the app + console:
1. Filter pull-down opens with the checkmark on "All"; picking "Unread" logs `[demo] filter → unread` and REOPENING the menu shows the checkmark moved (no flicker, toolbar item itself untouched).
2. "Toggle compose enabled" greys the Compose button out; clicking the greyed button does nothing; toggling back re-enables.
3. The filter button shows NO chevron (`indicator: false`).
4. "Remove toolbar" detaches the band — content padding visibly shrinks (`--zapp-titlebar-height` drops, `--zapp-toolbar-height` → `0px`); "Attach toolbar" brings it back and padding grows.
5. No `[zapp]` warnings except any you intentionally trigger.

- [ ] **Step 6: Commit (docs only — hello-world stays dirty)**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "$(cat <<'EOF'
docs(api): dynamic toolbar — win.toolbar handle, enabled/indicator

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Final review checklist (cross-cutting, after all tasks)

- The 3-arg/2-arg/1-arg native signatures match across all three sites: toolbar.m definitions, ios/toolbar.m stubs, router.zc externs (`set_items(void*, const char*, int32_t)`, `update_item(void*, const char*)`, `remove(void*)`).
- `normalizeToolbar`'s widened return `{json, actions, menuActions, menuIdsByItem}` is destructured consistently in `Window.create` and `toolbar.setItems`.
- Wire key names agree end-to-end: `toolbarJson` / `itemJson` / `windowId` in runtime `windowAction` calls == `pre_args.get_string` keys in router.zc.
- `setItems` without `opts.style` must NOT warn natively (runtime strips the default style key; native warns only when a `style` key arrives for a live toolbar).
- User-WIP files unstaged: `git status --short hello-world/ | grep -v '??'` shows only unstaged modifications.

## Out of scope (do not build)

Badges/counts, runtime style switching, NSSearchToolbarItem, user customization, Windows/iOS toolbars, menuNeedsUpdate lazy pull, close-time registry sweep beyond what remove/setItems already purge.
