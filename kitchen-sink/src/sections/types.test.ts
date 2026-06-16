import { test, expect } from "bun:test";
import { findSection, type Section } from "./types";

const fixtures: Section[] = [
  { id: "alpha", label: "Alpha", render() {} },
  { id: "beta", label: "Beta", render() {} },
];

test("findSection returns the matching section", () => {
  expect(findSection(fixtures, "beta")?.label).toBe("Beta");
});

test("findSection returns undefined for an unknown id", () => {
  expect(findSection(fixtures, "missing")).toBeUndefined();
});
