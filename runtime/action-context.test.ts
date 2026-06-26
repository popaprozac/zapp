import { test, expect } from "bun:test";
import { patchMenuTree } from "./action-context";
import type { MenuItemDef } from "./menu";

test("patchMenuTree merges patch into the matching item, leaves others, deep-copies", () => {
  const tree: MenuItemDef[] = [
    { id: "all", label: "All", checked: true, action: () => {} },
    { id: "unread", label: "Unread", checked: false, action: () => {} },
  ];
  const next = patchMenuTree(tree, "unread", { checked: true });
  expect(next).not.toBe(tree); // new array
  expect(next[1].checked).toBe(true);
  expect(next[0].checked).toBe(true); // untouched
  expect(tree[1].checked).toBe(false); // original not mutated
  expect(next[1].action).toBe(tree[1].action); // action preserved by reference
});

test("patchMenuTree recurses into submenu", () => {
  const tree: MenuItemDef[] = [
    { label: "View", submenu: [{ id: "wrap", label: "Wrap", checked: false }] },
  ];
  const next = patchMenuTree(tree, "wrap", { checked: true });
  expect(next[0].submenu![0].checked).toBe(true);
  expect(tree[0].submenu![0].checked).toBe(false);
});

import type { ActionContext } from "./action-context";

// Type-level: a zero-arg closure must satisfy (ctx?) => void (non-breaking).
test("ActionContext callback accepts zero-arg closures", () => {
  const widened: (ctx?: ActionContext) => void = () => {};
  const ctxAware: (ctx?: ActionContext) => void = (ctx) => {
    ctx?.update({ checked: true });
  };
  expect(typeof widened).toBe("function");
  expect(typeof ctxAware).toBe("function");
});
