import { test, expect } from "bun:test";
import { toNativeRect, rectsEqual, isVisibleRect } from "./webview-geometry";

test("toNativeRect passes through top-left coords (native does the flip)", () => {
  expect(toNativeRect({ left: 50, top: 100, width: 300, height: 200 }))
    .toEqual({ x: 50, y: 100, w: 300, h: 200 });
});
test("toNativeRect rounds subpixel values to whole points", () => {
  expect(toNativeRect({ left: 50.4, top: 100.6, width: 300.5, height: 200.2 }))
    .toEqual({ x: 50, y: 101, w: 301, h: 200 });
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
