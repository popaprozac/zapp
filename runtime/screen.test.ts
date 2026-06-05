import { test, expect } from "bun:test";
import { findPrimary, findById, type Display } from "./screen";

const d = (id: string, isPrimary = false): Display => ({
  id, name: id, bounds: { x: 0, y: 0, width: 100, height: 100 },
  workArea: { x: 0, y: 0, width: 100, height: 100 },
  scaleFactor: 2, isPrimary, rotation: 0,
});

test("findPrimary returns the isPrimary display", () => {
  const list = [d("a"), d("b", true), d("c")];
  expect(findPrimary(list)?.id).toBe("b");
});
test("findPrimary falls back to the first display if none flagged", () => {
  expect(findPrimary([d("a"), d("b")])?.id).toBe("a");
});
test("findPrimary returns null for an empty list", () => {
  expect(findPrimary([])).toBeNull();
});
test("findById matches by id, null when absent", () => {
  const list = [d("a"), d("b", true)];
  expect(findById(list, "b")?.id).toBe("b");
  expect(findById(list, "zzz")).toBeNull();
});
