import { describe, expect, it, test } from "bun:test";
import { normalizeToolbar, assertToolbarItemsNonEmpty, type ToolbarOptions } from "./window";
import { eventName, WindowEvent } from "./events";

describe("normalizeToolbar", () => {
  test("strips actions and stringifies items in declared order", () => {
    let hit = 0;
    const tb: ToolbarOptions = {
      items: [
        { type: "toggleSidebar" },
        { type: "trackingSeparator" },
        { id: "compose", icon: "sf:square.and.pencil", label: "Compose", action: () => { hit++; } },
        { type: "flexibleSpace" },
        { type: "space" },
        { id: "filter", icon: "sf:line.3.horizontal.decrease" },
      ],
    };
    const { json, actions } = normalizeToolbar(tb, true, false);
    const parsed = JSON.parse(json);
    expect(parsed.style).toBe("unified"); // default
    expect(parsed.items).toEqual([
      { type: "toggleSidebar" },
      { type: "trackingSeparator", pane: "sidebar" },
      { type: "button", id: "compose", label: "Compose", icon: "sf:square.and.pencil" },
      { type: "flexibleSpace" },
      { type: "space" },
      { type: "button", id: "filter", label: "", icon: "sf:line.3.horizontal.decrease" },
    ]);
    expect(json).not.toContain("action");
    expect(actions.size).toBe(1);
    actions.get("compose")!();
    expect(hit).toBe(1);
  });

  test("passes style through", () => {
    const { json } = normalizeToolbar({ style: "expanded", items: [{ id: "a" }] }, false, false);
    expect(JSON.parse(json).style).toBe("expanded");
  });

  test("button without id throws", () => {
    expect(() => normalizeToolbar({ items: [{ label: "Nope" }] }, false, false))
      .toThrow(/require an "id"/);
  });

  test("duplicate button ids throw", () => {
    expect(() => normalizeToolbar({ items: [{ id: "x" }, { id: "x" }] }, false, false))
      .toThrow(/duplicate/);
  });

  test("sidebar-dependent items are dropped (with remaining items kept) when window has no sidebar", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "toggleSidebar" }, { type: "trackingSeparator" }, { id: "a" }] },
      false,
      false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "button", id: "a", label: "", icon: "" }]);
  });

  test("ids with unsafe characters throw", () => {
    expect(() => normalizeToolbar({ items: [{ id: 'a"b' }] }, false, false)).toThrow(/invalid item id/);
    expect(() => normalizeToolbar({ items: [{ id: "a\\b" }] }, false, false)).toThrow(/invalid item id/);
    expect(() => normalizeToolbar({ items: [{ id: "a b" }] }, false, false)).toThrow(/invalid item id/);
  });

  test("reserved id prefixes throw", () => {
    expect(() => normalizeToolbar({ items: [{ id: "zapp.trackingSeparator" }] }, false, false)).toThrow(/reserved/);
    expect(() => normalizeToolbar({ items: [{ id: "NSToolbarFlexibleSpaceItem" }] }, false, false)).toThrow(/reserved/);
  });

  test("button with both action and menu throws", () => {
    expect(() => normalizeToolbar({ items: [{ id: "x", action: () => {}, menu: [] }] }, false, false))
      .toThrow(/both "action" and "menu"/);
  });

  test("TOOLBAR_CLICKED maps to the window:toolbar-clicked wire name", () => {
    expect(eventName(WindowEvent.TOOLBAR_CLICKED)).toBe("window:toolbar-clicked");
  });
});

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
    }, false, false);
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
    }, false, false);
    const autoId = JSON.parse(json).items[0].menu[0].id;
    expect(autoId).toMatch(/^__tbmenu_\d+$/);
    expect(menuActions.has(autoId)).toBe(true);
  });

  test("submenus are walked", () => {
    const { menuActions } = normalizeToolbar({
      items: [{ id: "f", menu: [{ label: "More", submenu: [{ id: "deep", label: "D", action: () => {} }] }] }],
    }, false, false);
    expect(menuActions.has("deep")).toBe(true);
  });

  test("menu on non-button types throws", () => {
    expect(() => normalizeToolbar({ items: [{ type: "flexibleSpace", menu: [] } as any] }, false, false))
      .toThrow(/only valid on button/);
  });
});

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
    }, false, false);
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
    }, false, false);
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

  test("empty icon strings are stripped (icons swap, never clear)", () => {
    const { json } = normalizeToolbarPatch("x", { icon: "", label: "Keep" });
    expect(JSON.parse(json)).toEqual({ id: "x", label: "Keep" });
    // icon-only "" patch leaves nothing to send — hits the empty-patch guard
    expect(() => normalizeToolbarPatch("x", { icon: "" })).toThrow(/empty patch/);
  });
});

describe("assertToolbarItemsNonEmpty", () => {
  test("assertToolbarItemsNonEmpty throws on empty items", () => {
    expect(() => assertToolbarItemsNonEmpty('{"style":"unified","items":[]}'))
      .toThrow(/use toolbar.remove\(\)/);
    expect(() => assertToolbarItemsNonEmpty('{"items":[{"type":"button","id":"a"}]}'))
      .not.toThrow();
  });

  test("sidebar-dependent-only item sets normalize to empty (the guard's input case)", () => {
    const { json } = normalizeToolbar({ items: [{ type: "toggleSidebar" }] }, false, false);
    expect(JSON.parse(json).items).toEqual([]);
  });
});

describe("normalizeToolbarPatch explicit-undefined guard", () => {
  test("patch of only explicit-undefined values throws empty patch", () => {
    expect(() => normalizeToolbarPatch("x", { label: undefined })).toThrow(/empty patch/);
  });

  test("action-only patch is valid (action is not in wire, but is a real change)", () => {
    const fn = () => {};
    expect(() => normalizeToolbarPatch("x", { action: fn })).not.toThrow();
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

describe("normalizeToolbar segmented (grouping)", () => {
  it("emits a segmented group with segments, selectionMode, selected[], controlRepresentation", () => {
    const { json } = normalizeToolbar({ items: [{
      type: "segmented", id: "view", selectionMode: "one", selected: 1,
      controlRepresentation: "automatic",
      segments: [{ id: "grid", icon: "sf:square.grid.2x2" }, { id: "list", icon: "sf:list.bullet" }],
    }] }, false, false);
    const it0 = JSON.parse(json).items[0];
    expect(it0.type).toBe("segmented");
    expect(it0.id).toBe("view");
    expect(it0.selectionMode).toBe("one");
    expect(it0.selected).toEqual([1]);              // number → [number]
    expect(it0.controlRepresentation).toBe("automatic");
    expect(it0.segments).toEqual([{ id: "grid", icon: "sf:square.grid.2x2" }, { id: "list", icon: "sf:list.bullet" }]);
  });
  it("defaults selectionMode omitted; selected[] passthrough for selectAny", () => {
    const it0 = JSON.parse(normalizeToolbar({ items: [{
      type: "segmented", id: "fmt", selectionMode: "any", selected: [0, 2],
      segments: [{ label: "B" }, { label: "I" }, { label: "U" }],
    }] }, false, false).json).items[0];
    expect(it0.selected).toEqual([0, 2]);
    expect(it0.selectionMode).toBe("any");
  });
  it("registers per-segment actions and returns them", () => {
    const fn = () => {};
    const { actions } = normalizeToolbar({ items: [{
      type: "segmented", id: "view",
      segments: [{ id: "grid", icon: "sf:a", action: fn }, { id: "list", icon: "sf:b" }],
    }] }, false, false);
    expect(actions.get("view:0")).toBe(fn);          // keyed groupId:index
  });
  it("rejects a segmented item with no segments / no id", () => {
    expect(() => normalizeToolbar({ items: [{ type: "segmented", segments: [{ label: "x" }] } as any] }, false, false)).toThrow(/id/);
    expect(() => normalizeToolbar({ items: [{ type: "segmented", id: "x", segments: [] }] }, false, false)).toThrow(/segment/);
  });
});

describe("normalizeToolbarPatch selection (grouping)", () => {
  it("emits selected[] and controlRepresentation", () => {
    const p = JSON.parse(normalizeToolbarPatch("view", { selected: 2 }).json);
    expect(p.selected).toEqual([2]);
    const p2 = JSON.parse(normalizeToolbarPatch("view", { controlRepresentation: "collapsed" }).json);
    expect(p2.controlRepresentation).toBe("collapsed");
  });
});

describe("normalizeToolbar inspector integration", () => {
  test("toggleInspector kept when window has an inspector", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "toggleInspector" }] } as any, false, true,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "toggleInspector" }]);
  });

  test("toggleInspector dropped + warned when no inspector", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "toggleInspector" }, { id: "a" }] } as any, false, false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "button", id: "a", label: "", icon: "" }]);
  });

  test("trackingSeparator pane defaults to sidebar", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "trackingSeparator" }] }, true, false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "trackingSeparator", pane: "sidebar" }]);
  });

  test("inspector trackingSeparator kept when window has an inspector", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "trackingSeparator", pane: "inspector" }] } as any, false, true,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "trackingSeparator", pane: "inspector" }]);
  });

  test("inspector trackingSeparator dropped when no inspector", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "trackingSeparator", pane: "inspector" }, { id: "a" }] } as any, false, false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "button", id: "a", label: "", icon: "" }]);
  });

  test("sidebar trackingSeparator still requires a sidebar", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "trackingSeparator" }, { id: "a" }] }, false, false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "button", id: "a", label: "", icon: "" }]);
  });
});

describe("normalizeToolbar trio (W2)", () => {
  it("emits style, tintColor, bordered, and tagged badge", () => {
    const { json } = normalizeToolbar({
      items: [{ id: "go", label: "Go", style: "prominent", tintColor: "#aa3bff",
                bordered: false, badge: { count: 3 } }],
    }, false, false);
    const item = JSON.parse(json).items[0];
    expect(item.style).toBe("prominent");
    expect(item.tintColor).toBe("#aa3bff");
    expect(item.bordered).toBe(false);
    expect(item.badge).toEqual({ kind: "count", count: 3 });
  });
  it("maps badge variants (text, dot)", () => {
    const text = JSON.parse(normalizeToolbar({ items: [{ id: "a", badge: { text: "NEW" } }] }, false, false).json).items[0];
    expect(text.badge).toEqual({ kind: "text", text: "NEW" });
    const dot = JSON.parse(normalizeToolbar({ items: [{ id: "b", badge: { dot: true } }] }, false, false).json).items[0];
    expect(dot.badge).toEqual({ kind: "dot" });
  });
  it("omits trio keys when unset", () => {
    const item = JSON.parse(normalizeToolbar({ items: [{ id: "x" }] }, false, false).json).items[0];
    expect(item.style).toBeUndefined();
    expect(item.tintColor).toBeUndefined();
    expect(item.bordered).toBeUndefined();
    expect(item.badge).toBeUndefined();
  });
});

describe("normalizeToolbarPatch trio (W2)", () => {
  it("emits trio keys and clears badge with null", () => {
    const set = JSON.parse(normalizeToolbarPatch("compose", { style: "prominent", tintColor: "#fff", bordered: true, badge: { count: 5 } }).json);
    expect(set.style).toBe("prominent");
    expect(set.tintColor).toBe("#fff");
    expect(set.bordered).toBe(true);
    expect(set.badge).toEqual({ kind: "count", count: 5 });
    const cleared = JSON.parse(normalizeToolbarPatch("compose", { badge: null }).json);
    expect(cleared.badge).toEqual({ kind: "none" });
  });
});
