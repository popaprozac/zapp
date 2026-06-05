import { test, expect } from "bun:test";
import { xmlEscape, renderValue } from "./entitlements";

test("xmlEscape escapes the XML-mandatory characters", () => {
  expect(xmlEscape("a & b")).toContain("&amp;");
  expect(xmlEscape("x < y")).toContain("&lt;");
  expect(xmlEscape("x > y")).toContain("&gt;");
  expect(xmlEscape("plain")).toBe("plain");
});
test("xmlEscape does not escape quotes (only &, <, >)", () => {
  expect(xmlEscape(`say "hi"`)).toBe(`say "hi"`);
  expect(xmlEscape("it's")).toBe("it's");
});
test("xmlEscape full round-trip", () => {
  expect(xmlEscape("a & b < c > d")).toBe("a &amp; b &lt; c &gt; d");
});
test("renderValue: string → <string> with escaped content", () => {
  const out = renderValue("a&b");
  expect(out).toContain("<string>");
  expect(out).toContain("&amp;");
});
test("renderValue: plain string → exact format", () => {
  expect(renderValue("hello")).toBe("<string>hello</string>");
});
test("renderValue: string[] → entries for each item", () => {
  const out = renderValue(["one", "two"]);
  expect(out).toContain("one");
  expect(out).toContain("two");
});
test("renderValue: string[] → <array> wrapper", () => {
  const out = renderValue(["a", "b"]);
  expect(out).toContain("<array>");
  expect(out).toContain("</array>");
  expect(out).toContain("<string>a</string>");
  expect(out).toContain("<string>b</string>");
});
test("renderValue: boolean true → <true/>", () => {
  expect(renderValue(true)).toBe("<true/>");
});
test("renderValue: boolean false → <false/>", () => {
  expect(renderValue(false)).toBe("<false/>");
});
test("renderValue: integer → <integer>N</integer>", () => {
  expect(renderValue(42)).toBe("<integer>42</integer>");
  expect(renderValue(0)).toBe("<integer>0</integer>");
  expect(renderValue(-1)).toBe("<integer>-1</integer>");
});
test("renderValue: float → <real>N</real>", () => {
  expect(renderValue(3.14)).toBe("<real>3.14</real>");
});
