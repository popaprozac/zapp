import { expect, test } from "bun:test";
import { inspectorPosition } from "./inspector-placement";

const inspector = { x: 0, y: 0, width: 440, height: 640 };
const workArea = { x: 0, y: 24, width: 1600, height: 976 };
test("inspector prefers right, then left, without changing owner placement", () => {
  expect(inspectorPosition({ x: 100.5, y: 80.25, width: 900, height: 640 }, inspector, workArea))
    .toEqual({ x: 1012.5, y: 80.25 });
  expect(inspectorPosition({ x: 600, y: 80, width: 900, height: 640 }, inspector, workArea))
    .toEqual({ x: 148, y: 80 });
});
test("inspector clamps both axes when neither side fits", () => {
  expect(inspectorPosition({ x: 10, y: 900, width: 1580, height: 640 }, inspector, workArea))
    .toEqual({ x: 1160, y: 360 });
});
test("negative desktops, fractional origins, and oversized inspectors stay accessible", () => {
  expect(inspectorPosition({ x: -1550, y: -90, width: 900, height: 640 }, inspector,
    { x: -1600, y: -100.5, width: 1600, height: 1000 })).toEqual({ x: -638, y: -90 });
  expect(inspectorPosition({ x: 10, y: -90, width: 900, height: 640 }, inspector,
    { x: 20.5, y: 30.25, width: 300, height: 400 })).toEqual({ x: 20.5, y: 30.25 });
});
