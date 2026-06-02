import { test, expect } from "bun:test";
import { inferArgs, parseAnnotation, extractHandler, resolveServiceTypes } from "./service-types";

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

const SAMPLE = `import "std/json.zc";

// @zapp:returns { greeting: string }
fn greet(_app: App*, args: JsonValue*) -> string {
    let name_opt = args.get_string("name");
    return "";
}

fn noop(_app: App*, _args: JsonValue*) -> string {
    return "{}";
}`;

test("extractHandler returns the comment block and body for a handler", () => {
  const slice = extractHandler(SAMPLE, "greet");
  expect(slice).not.toBeNull();
  expect(slice!.commentBlock).toContain("@zapp:returns { greeting: string }");
  expect(slice!.body).toContain(`args.get_string("name")`);
  // body is brace-matched — it must not bleed into the next fn
  expect(slice!.body).not.toContain("noop");
});

test("extractHandler returns empty comment block when there is none", () => {
  const slice = extractHandler(SAMPLE, "noop");
  expect(slice).not.toBeNull();
  expect(slice!.commentBlock).toBe("");
  expect(slice!.body).toContain(`return "{}"`);
});

test("extractHandler returns null when the handler is absent", () => {
  expect(extractHandler(SAMPLE, "missing")).toBeNull();
});

const SRC = `// @zapp:returns { greeting: string }
fn greet(_app: App*, args: JsonValue*) -> string {
    let n = args.get_string("name");
    return "";
}

fn noop(_app: App*, _args: JsonValue*) -> string { return "{}"; }

// @zapp:args { id: number }
fn lookup(_app: App*, args: JsonValue*) -> string {
    let raw = args.get_string("ignored");
    return "";
}`;

test("resolveServiceTypes: inferred args interface + annotated result interface", () => {
  const t = resolveServiceTypes("Greet", SRC, "greet");
  expect(t.argsName).toBe("GreetArgs");
  expect(t.resultName).toBe("GreetResult");
  expect(t.argsDecl).toBe("export interface GreetArgs { name?: string }");
  expect(t.resultDecl).toBe("export interface GreetResult { greeting: string }");
});

test("resolveServiceTypes: no args + no annotation falls back to loose aliases", () => {
  const t = resolveServiceTypes("Noop", SRC, "noop");
  expect(t.argsDecl).toBe("export type NoopArgs = Record<string, unknown>;");
  expect(t.resultDecl).toBe("export type NoopResult = unknown;");
});

test("resolveServiceTypes: @zapp:args overrides inference, no @zapp:returns -> unknown", () => {
  const t = resolveServiceTypes("Lookup", SRC, "lookup");
  expect(t.argsDecl).toBe("export interface LookupArgs { id: number }");
  expect(t.resultDecl).toBe("export type LookupResult = unknown;");
});

test("resolveServiceTypes: handler not found -> loose aliases", () => {
  const t = resolveServiceTypes("Gone", SRC, "gone");
  expect(t.argsDecl).toBe("export type GoneArgs = Record<string, unknown>;");
  expect(t.resultDecl).toBe("export type GoneResult = unknown;");
});
