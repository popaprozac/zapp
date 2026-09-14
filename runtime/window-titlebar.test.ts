import { expect, test } from "bun:test";
import { checkedTitleBar } from "./window-titlebar";
import { createWindow, type TitleBarOptions } from "./window-api";

test("title visibility is independent in all presets and options are snapshotted", () => {
  expect(checkedTitleBar(undefined)).toBeUndefined();
  expect(checkedTitleBar({})).toEqual({ style: "default", titleVisible: true });
  for (const style of ["default", "hidden", "hiddenInset"] as const) {
    expect(checkedTitleBar({ style })).toEqual({ style, titleVisible: true });
    for (const titleVisible of [true, false]) {
      const input = { style, titleVisible }, result = checkedTitleBar(input);
      expect(result).toEqual(input);
      input.titleVisible = !titleVisible;
      expect(result?.titleVisible).toBe(titleVisible);
    }
  }
});

test("invalid titlebar facts are rejected before host creation", async () => {
  const old = (globalThis as any).__zappBridge;
  let calls = 0;
  (globalThis as any).__zappBridge = { createWindow() { calls++; return { windowId: "test" }; } };
  try {
    for (const input of [null, [], "hidden", 0, { style: "frameless" }, { style: null },
      { titleVisible: 0 }, { titleVisible: "false" }, { titleVisible: null }, { titleVisibile: false },
      { style: "default", controls: false }]) {
      await expect(createWindow({ titleBar: input as TitleBarOptions })).rejects.toBeInstanceOf(TypeError);
    }
    expect(calls).toBe(0);
    await createWindow({ titleBar: { style: "hidden" } });
    expect(calls).toBe(1);
  } finally { (globalThis as any).__zappBridge = old; }
});
