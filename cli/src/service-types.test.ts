import { test, expect } from "bun:test";
import { inferArgs } from "./service-types";

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
