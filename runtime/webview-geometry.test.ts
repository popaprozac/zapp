import { test, expect } from "bun:test";
import { toNativeRect, rectsEqual, isVisibleRect } from "./webview-geometry";

test("toNativeRect flips top-left CSS to bottom-left native", () => {
  // contentHeight 600; element top=100 height=200 → native y = 600-100-200 = 300
  expect(toNativeRect({ left: 50, top: 100, width: 300, height: 200 }, 600))
    .toEqual({ x: 50, y: 300, w: 300, h: 200 });
});
test("element at top of viewport sits at native y = contentHeight - height", () => {
  expect(toNativeRect({ left: 0, top: 0, width: 100, height: 100 }, 600).y).toBe(500);
});
test("toNativeRect rounds subpixel values to whole points", () => {
  expect(toNativeRect({ left: 50.4, top: 100.6, width: 300.5, height: 200.2 }, 600))
    .toEqual({ x: 50, y: 299, w: 301, h: 200 });
});
test("rectsEqual compares all fields and handles null", () => {
  const a = { x: 1, y: 2, w: 3, h: 4 };
  expect(rectsEqual(a, { x: 1, y: 2, w: 3, h: 4 })).toBe(true);
  expect(rectsEqual(a, { x: 1, y: 2, w: 3, h: 5 })).toBe(false);
  expect(rectsEqual(null, null)).toBe(true);
  expect(rectsEqual(a, null)).toBe(false);
});
test("isVisibleRect is false for zero-area (display:none) rects", () => {
  expect(isVisibleRect({ width: 10, height: 10 })).toBe(true);
  expect(isVisibleRect({ width: 0, height: 10 })).toBe(false);
  expect(isVisibleRect({ width: 10, height: 0 })).toBe(false);
});
