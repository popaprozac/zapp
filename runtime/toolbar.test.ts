import { describe, expect, test } from "bun:test";
import { normalizeToolbar, type ToolbarOptions } from "./window";
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
    const { json, actions } = normalizeToolbar(tb, true);
    const parsed = JSON.parse(json);
    expect(parsed.style).toBe("unified"); // default
    expect(parsed.items).toEqual([
      { type: "toggleSidebar" },
      { type: "trackingSeparator" },
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

  test("ids with unsafe characters throw", () => {
    expect(() => normalizeToolbar({ items: [{ id: 'a"b' }] }, false)).toThrow(/invalid item id/);
    expect(() => normalizeToolbar({ items: [{ id: "a\\b" }] }, false)).toThrow(/invalid item id/);
    expect(() => normalizeToolbar({ items: [{ id: "a b" }] }, false)).toThrow(/invalid item id/);
  });

  test("reserved id prefixes throw", () => {
    expect(() => normalizeToolbar({ items: [{ id: "zapp.trackingSeparator" }] }, false)).toThrow(/reserved/);
    expect(() => normalizeToolbar({ items: [{ id: "NSToolbarFlexibleSpaceItem" }] }, false)).toThrow(/reserved/);
  });

  test("button with both action and menu throws", () => {
    expect(() => normalizeToolbar({ items: [{ id: "x", action: () => {}, menu: [] }] }, false))
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
