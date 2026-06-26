import { test, expect } from "bun:test";
import type { ToolbarItemDef } from "./window";

test("discriminated ToolbarItemDef accepts valid shapes, rejects invalid", () => {
  const ok: ToolbarItemDef[] = [
    { id: "save", icon: "sf:tray", label: "Save", action: () => {} }, // button (type optional)
    { type: "space" },
    { type: "flexibleSpace" },
    { type: "trackingSeparator", pane: "inspector" },
    { type: "segmented", id: "view", segments: [{ id: "g", icon: "sf:square" }] },
    { type: "group", id: "nav", items: [{ id: "back", icon: "sf:chevron.left" }] },
  ];
  expect(ok.length).toBe(6);

  // @ts-expect-error — a system item must not allow an action.
  const bad1: ToolbarItemDef = { type: "space", action: () => {} };
  // @ts-expect-error — a button requires an id.
  const bad2: ToolbarItemDef = { icon: "sf:tray", label: "No id" };
  // @ts-expect-error — a separator must not carry a badge.
  const bad3: ToolbarItemDef = { type: "trackingSeparator", badge: { dot: true } };
  void bad1; void bad2; void bad3;
});

test("ToolbarItemDef accepts a label item, rejects a label without text", () => {
  const ok: ToolbarItemDef = { type: "label", text: "Synced" };
  expect(ok.type).toBe("label");
  // @ts-expect-error — a label requires `text`.
  const bad: ToolbarItemDef = { type: "label" };
  void bad;
});
