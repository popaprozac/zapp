import { test, expect } from "bun:test";
import { inferArgs, parseAnnotation } from "./service-types";

test("inferArgs maps each primitive accessor to its TS type", () => {
  const body = `{
    let n = args.get_string("name");
    let c = args.get_int("count");
    let r = args.get_float("ratio");
    let f = args.get_bool("flag");
  }`;
  expect(inferArgs(body)).toEqual([
    { name: "name", tsType: "string" },
    { name: "count", tsType: "number" },
    { name: "ratio", tsType: "number" },
    { name: "flag", tsType: "boolean" },
  ]);
});

test("inferArgs maps the generic get() accessor to unknown", () => {
  const body = `{ let items = args.get("items"); }`;
  expect(inferArgs(body)).toEqual([{ name: "items", tsType: "unknown" }]);
});

test("inferArgs collapses a key read multiple times with the same type", () => {
  const body = `{ args.get_string("name"); args.get_string("name"); }`;
  expect(inferArgs(body)).toEqual([{ name: "name", tsType: "string" }]);
});

test("inferArgs returns empty for a body with no accessors", () => {
  expect(inferArgs(`{ log("hi"); return ""; }`)).toEqual([]);
});

test("inferArgs ignores .get calls on receivers other than args", () => {
  const body = `{
    let real = args.get_string("name");
    let cached = myCache.get("foo");
    let items = args.get("items");
    let nested = items.get_string("inner");
  }`;
  expect(inferArgs(body)).toEqual([
    { name: "name", tsType: "string" },
    { name: "items", tsType: "unknown" },
  ]);
});

test("parseAnnotation extracts a returns fragment", () => {
  const block = `// @zapp:returns { greeting: string }`;
  expect(parseAnnotation(block)).toEqual({ returnsFragment: "{ greeting: string }" });
});

test("parseAnnotation extracts both args and returns", () => {
  const block = `// @zapp:returns { ok: boolean }
// @zapp:args { name: string; count?: number }`;
  expect(parseAnnotation(block)).toEqual({
    returnsFragment: "{ ok: boolean }",
    argsFragment: "{ name: string; count?: number }",
  });
});

test("parseAnnotation handles nested braces", () => {
  const block = `// @zapp:returns { user: { id: number; tags: string[] } }`;
  expect(parseAnnotation(block)).toEqual({
    returnsFragment: "{ user: { id: number; tags: string[] } }",
  });
});

test("parseAnnotation returns empty object when no annotations present", () => {
  expect(parseAnnotation(`// just a normal comment`)).toEqual({});
});

test("parseAnnotation ignores an unbalanced fragment (no throw)", () => {
  expect(parseAnnotation(`// @zapp:returns { greeting: string`)).toEqual({});
});
