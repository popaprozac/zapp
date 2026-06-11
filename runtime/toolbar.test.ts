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
