# Service-codegen Type Inference (T2.A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit real per-service `XxxArgs`/`XxxResult` types from Zapp's service-codegen — inferring arg types from the Zen-C handler body and taking return types from a `// @zapp:returns { … }` annotation — replacing today's `(args?: Record<string, unknown>) => Promise<unknown>`.

**Architecture:** A new pure-function module `cli/src/service-types.ts` (handler extraction + arg inference + annotation parsing + type resolution) feeds the existing `cli/src/generate.ts` emitter. `runtime/services.ts`'s `invoke` is widened to `<TReturn, TArgs>`. The pure functions get the repo's first `bun test` unit tests; wiring is build-verified end-to-end via hello-world.

**Tech Stack:** TypeScript, Bun (runtime + built-in `bun test`), regex string parsing. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-06-02-service-type-inference-design.md`

---

## File Structure

| File | Responsibility | Type |
|---|---|---|
| `cli/src/service-types.ts` | Pure functions: `inferArgs`, `parseAnnotation`, `extractHandler`, `resolveServiceTypes` + helpers. No I/O. | Create |
| `cli/src/service-types.test.ts` | `bun test` unit tests for the pure functions. | Create |
| `cli/src/generate.ts` | Orchestrator — call `resolveServiceTypes` per binding; emit typed wrappers + type re-exports in the barrel. | Modify |
| `cli/package.json` | Add a `"test": "bun test"` script. | Modify |
| `runtime/services.ts` | Widen `invoke` generic to `<TReturn, TArgs>`. | Modify |
| `hello-world/zapp/app.zc` | Add `// @zapp:returns { greeting: string }` above `greet` (verification). | Modify |

**Conventions to follow:** `cli/` uses Bun and ES modules. `service-types.ts` exports plain functions (no classes). Match the existing comment density in `generate.ts`.

---

## Task 1: `inferArgs` — infer arg fields from a handler body

**Files:**
- Create: `cli/src/service-types.ts`
- Create: `cli/src/service-types.test.ts`
- Modify: `cli/package.json`

- [ ] **Step 1: Add the test script to `cli/package.json`**

In `cli/package.json`, inside `"scripts"`, add a `"test"` entry (keep the existing `prepack`/`postpack`):

```json
  "scripts": {
    "test": "bun test",
    "prepack": "bun build src/config.ts --outdir dist --format esm --target node && cp -r ../native ./native && cp -r ../bootstrap ./bootstrap && cp -r ../assets ./assets && mkdir -p ./vendor && cp -r ../vendor/webview2 ./vendor/webview2",
    "postpack": "rm -rf ./native ./bootstrap ./assets ./vendor"
  },
```

- [ ] **Step 2: Write the failing test**

Create `cli/src/service-types.test.ts`:

```ts
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: FAIL — `Cannot find module './service-types'` (the module doesn't exist yet).

- [ ] **Step 4: Implement `inferArgs`**

Create `cli/src/service-types.ts`:

```ts
// Pure helpers that turn a Zen-C service handler into TypeScript types for
// the generated wrapper. No I/O — every function takes strings and returns
// data, so they are unit-testable in isolation (see service-types.test.ts).

export interface ArgField {
  name: string;
  tsType: string; // "string" | "number" | "boolean" | "unknown"
}

const TYPE_MAP: Record<string, string> = {
  string: "string",
  int: "number",
  float: "number",
  bool: "boolean",
};

// Matches `args.get_string("k")` / `get_int` / `get_float` / `get_bool`, OR
// the generic nested accessor `args.get("k")`. Group 1 = the primitive
// accessor suffix (undefined for the generic get); group 2 = key for the
// primitive form; group 3 = key for the generic form.
const ACCESSOR_RE =
  /\.get_(string|int|float|bool)\s*\(\s*"([^"]+)"\s*\)|\.get\s*\(\s*"([^"]+)"\s*\)/g;

// Scan a handler body for arg accessors → ordered, de-duplicated fields.
// First occurrence of a key wins; a conflicting later type warns and is dropped.
export function inferArgs(body: string): ArgField[] {
  const fields = new Map<string, string>();
  ACCESSOR_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = ACCESSOR_RE.exec(body)) !== null) {
    const accessor = m[1]; // undefined for the generic `.get(...)`
    const key = m[2] ?? m[3];
    const tsType = accessor ? TYPE_MAP[accessor] : "unknown";
    const existing = fields.get(key);
    if (existing === undefined) {
      fields.set(key, tsType);
    } else if (existing !== tsType) {
      console.warn(
        `[zapp] service arg "${key}" is read as both ${existing} and ${tsType}; keeping ${existing}.`
      );
    }
  }
  return [...fields].map(([name, tsType]) => ({ name, tsType }));
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: PASS — 4 pass, 0 fail.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/service-types.ts cli/src/service-types.test.ts cli/package.json
git commit -m "$(cat <<'EOF'
feat(cli): inferArgs — infer service arg types from handler body

New pure module cli/src/service-types.ts with inferArgs(): maps
args.get_string/int/float/bool("k") -> typed fields and args.get("k") ->
unknown, de-duping by key. First bun test unit tests in the repo +
a cli "test" script.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `parseAnnotation` — extract `@zapp:returns` / `@zapp:args` fragments

**Files:**
- Modify: `cli/src/service-types.ts`
- Modify: `cli/src/service-types.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `cli/src/service-types.test.ts`:

```ts
import { parseAnnotation } from "./service-types";

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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: FAIL — `parseAnnotation` is not exported / not a function.

- [ ] **Step 3: Implement `parseAnnotation`**

Append to `cli/src/service-types.ts`:

```ts
export interface Annotation {
  argsFragment?: string;
  returnsFragment?: string;
}

// Extract the balanced-brace { … } fragment that follows `keyword` in `text`.
// Returns undefined if the keyword is absent or its braces are unbalanced.
function extractFragment(text: string, keyword: string): string | undefined {
  const at = text.indexOf(keyword);
  if (at === -1) return undefined;
  const after = text.slice(at + keyword.length);
  const open = after.indexOf("{");
  if (open === -1) return undefined;
  let depth = 0;
  for (let i = open; i < after.length; i++) {
    if (after[i] === "{") depth++;
    else if (after[i] === "}") {
      depth--;
      if (depth === 0) return after.slice(open, i + 1).trim();
    }
  }
  return undefined; // unbalanced
}

// Parse the comment block above a handler for @zapp:args / @zapp:returns.
// Line-comment markers are stripped first so the brace scan ignores them.
export function parseAnnotation(commentBlock: string): Annotation {
  const text = commentBlock.replace(/^\s*\/\/+/gm, " ");
  const result: Annotation = {};
  const returns = extractFragment(text, "@zapp:returns");
  const args = extractFragment(text, "@zapp:args");
  if (returns !== undefined) result.returnsFragment = returns;
  if (args !== undefined) result.argsFragment = args;
  return result;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: PASS — all tests (Task 1 + Task 2) pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/service-types.ts cli/src/service-types.test.ts
git commit -m "$(cat <<'EOF'
feat(cli): parseAnnotation — extract @zapp:returns/@zapp:args fragments

Balanced-brace extraction of inline TS-fragment annotations from a
handler's comment block; nested braces handled, unbalanced/absent
fragments return undefined (no throw).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `extractHandler` — locate a handler's comment block + body in source

**Files:**
- Modify: `cli/src/service-types.ts`
- Modify: `cli/src/service-types.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `cli/src/service-types.test.ts`:

```ts
import { extractHandler } from "./service-types";

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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: FAIL — `extractHandler` is not exported / not a function.

- [ ] **Step 3: Implement `extractHandler`**

Append to `cli/src/service-types.ts`:

```ts
export interface HandlerSlice {
  commentBlock: string; // contiguous // lines directly above the fn ("" if none)
  body: string;         // brace-matched function body, including the outer { }
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Locate `fn <handlerName>(` in Zen-C source. Returns its preceding comment
// block (contiguous // lines, blank lines between fn and comment tolerated)
// and its brace-matched body. Returns null if the handler isn't found.
export function extractHandler(content: string, handlerName: string): HandlerSlice | null {
  const fnRe = new RegExp(`\\bfn\\s+${escapeRegExp(handlerName)}\\s*\\(`, "g");
  const m = fnRe.exec(content);
  if (!m) return null;
  const fnStart = m.index;

  // Walk backwards over the lines before `fn`, collecting contiguous // lines.
  const lines = content.slice(0, fnStart).split("\n");
  const commentLines: string[] = [];
  for (let i = lines.length - 1; i >= 0; i--) {
    const t = lines[i].trim();
    if (t === "") {
      if (commentLines.length === 0) continue; // whitespace between fn and comment
      break; // blank line ends an earlier comment block
    }
    if (t.startsWith("//")) commentLines.unshift(lines[i]);
    else break;
  }
  const commentBlock = commentLines.join("\n");

  // Brace-match the body from the first { after the signature.
  let body = "";
  const open = content.indexOf("{", fnStart);
  if (open !== -1) {
    let depth = 0;
    for (let i = open; i < content.length; i++) {
      if (content[i] === "{") depth++;
      else if (content[i] === "}") {
        depth--;
        if (depth === 0) {
          body = content.slice(open, i + 1);
          break;
        }
      }
    }
  }
  return { commentBlock, body };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: PASS — all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/service-types.ts cli/src/service-types.test.ts
git commit -m "$(cat <<'EOF'
feat(cli): extractHandler — locate handler comment block + body in .zc

Brace-matched body extraction (does not bleed into the next fn) plus the
contiguous // comment block above the fn. Returns null when absent.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `resolveServiceTypes` — compose into emit-ready type declarations

**Files:**
- Modify: `cli/src/service-types.ts`
- Modify: `cli/src/service-types.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `cli/src/service-types.test.ts`:

```ts
import { resolveServiceTypes } from "./service-types";

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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: FAIL — `resolveServiceTypes` is not exported / not a function.

- [ ] **Step 3: Implement `resolveServiceTypes` + `fieldsToBody`**

Append to `cli/src/service-types.ts`:

```ts
export interface ServiceTypeDecls {
  argsDecl: string;   // full `export interface XxxArgs { … }` or `export type XxxArgs = …;`
  resultDecl: string; // full `export interface XxxResult { … }` or `export type XxxResult = …;`
  argsName: string;   // "XxxArgs"
  resultName: string; // "XxxResult"
}

function fieldsToBody(fields: ArgField[]): string {
  return "{ " + fields.map((f) => `${f.name}?: ${f.tsType}`).join("; ") + " }";
}

// Resolve the args + result type declarations for one service. `fileName` is
// the PascalCase base (e.g. "Greet"); `content` is the full .zc source the
// handler lives in; `handlerName` is the Zen-C fn name.
//
// Precedence — args: @zapp:args override > inferred fields > loose.
//              result: @zapp:returns annotation > loose (unknown).
export function resolveServiceTypes(
  fileName: string,
  content: string,
  handlerName: string
): ServiceTypeDecls {
  const argsName = `${fileName}Args`;
  const resultName = `${fileName}Result`;
  const slice = extractHandler(content, handlerName);
  const ann = slice ? parseAnnotation(slice.commentBlock) : {};

  let argsDecl: string;
  if (ann.argsFragment) {
    argsDecl = `export interface ${argsName} ${ann.argsFragment}`;
  } else {
    const fields = slice ? inferArgs(slice.body) : [];
    argsDecl =
      fields.length > 0
        ? `export interface ${argsName} ${fieldsToBody(fields)}`
        : `export type ${argsName} = Record<string, unknown>;`;
  }

  const resultDecl = ann.returnsFragment
    ? `export interface ${resultName} ${ann.returnsFragment}`
    : `export type ${resultName} = unknown;`;

  return { argsDecl, resultDecl, argsName, resultName };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: PASS — all tests (Tasks 1–4) pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/service-types.ts cli/src/service-types.test.ts
git commit -m "$(cat <<'EOF'
feat(cli): resolveServiceTypes — compose emit-ready type declarations

Resolves per-service args/result decls with precedence (@zapp:args >
inferred > loose; @zapp:returns > unknown), emitting named interfaces or
loose type aliases. Pure + table-tested.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire `resolveServiceTypes` into the generator

**Files:**
- Modify: `cli/src/generate.ts:101-141` (the `generateBindings` TS emit branch + barrel)

- [ ] **Step 1: Add the import**

At the top of `cli/src/generate.ts`, after the existing imports (the `existsSync` import on line 6), add:

```ts
import { resolveServiceTypes } from "./service-types";
```

- [ ] **Step 2: Read handler source + emit typed wrappers (TS branch only)**

Replace the body of the `if (bindings.length > 0) { … }` block in `generateBindings` (currently `generate.ts:109-136`) with the version below. It adds a per-file content cache, calls `resolveServiceTypes` for the TS branch, and re-exports the types from the barrel. The JS branch is unchanged (no types in JS output).

```ts
  if (bindings.length > 0) {
    await mkdir(outDir, { recursive: true });

    // Cache .zc source by path — several services can share one file.
    const sourceCache = new Map<string, string>();
    async function readSource(file: string): Promise<string> {
      let s = sourceCache.get(file);
      if (s === undefined) {
        s = await Bun.file(file).text();
        sourceCache.set(file, s);
      }
      return s;
    }

    for (const binding of bindings) {
      const fnName = toIdent(binding.name);
      const fileName = toFileName(binding.name);

      let content: string;
      if (typescript) {
        const src = await readSource(binding.source);
        const { argsDecl, resultDecl, argsName, resultName } = resolveServiceTypes(
          fileName,
          src,
          binding.handlerName
        );
        content = `import { Services } from "@zappdev/runtime";

${argsDecl}
${resultDecl}

export async function ${fnName}(args?: ${argsName}): Promise<${resultName}> {
    return Services.invoke<${resultName}>("${binding.name}", args ?? {});
}
`;
      } else {
        content = `import { Services } from "@zappdev/runtime";

export async function ${fnName}(args) {
    return Services.invoke("${binding.name}", args ?? {});
}
`;
      }

      await Bun.write(path.join(outDir, `${fileName}${ext}`), content);
      if (typescript) {
        const argsName = `${fileName}Args`;
        const resultName = `${fileName}Result`;
        exports.push(`export { ${fnName} } from "./${fileName}";`);
        exports.push(`export type { ${argsName}, ${resultName} } from "./${fileName}";`);
      } else {
        exports.push(`export { ${fnName} } from "./${fileName}";`);
      }
      keep.add(`${fileName}${ext}`);
    }

    await Bun.write(path.join(outDir, `index${ext}`), exports.join("\n") + "\n");
    keep.add(`index${ext}`);
  }
```

(The `argsName`/`resultName` recomputation in the barrel block mirrors `resolveServiceTypes`'s naming — `${fileName}Args` / `${fileName}Result` — so they stay in lockstep. Keep that exact convention.)

- [ ] **Step 3: Regenerate hello-world bindings and inspect output**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2
cat /Users/zach/code/zapp/hello-world/src/zapp/Greet.ts
cat /Users/zach/code/zapp/hello-world/src/zapp/index.ts
```

Expected: build last line is `[zapp] build complete: <path>`. `Greet.ts` shows (note: `greet` is NOT annotated yet — that's Task 7 — so `GreetResult` is still `unknown` here, but `GreetArgs` already infers `name`):
```ts
import { Services } from "@zappdev/runtime";

export interface GreetArgs { name?: string }
export type GreetResult = unknown;

export async function greet(args?: GreetArgs): Promise<GreetResult> {
    return Services.invoke<GreetResult>("greet", args ?? {});
}
```
`index.ts` includes both `export { greet } …` and `export type { GreetArgs, GreetResult } …`.

If `greet` reads more than `name` (check `hello-world/zapp/app.zc`), `GreetArgs` will list those fields too — that's correct.

- [ ] **Step 4: Run the unit tests (no regression)**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: PASS — still all green.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/generate.ts
git commit -m "$(cat <<'EOF'
feat(cli): emit typed service wrappers from resolveServiceTypes

generate.ts now emits per-service XxxArgs/XxxResult declarations and a
typed wrapper (args?: XxxArgs) => Promise<XxxResult>, re-exporting the
types from the barrel. JS output path unchanged. Source files are cached
per path to avoid re-reading shared .zc files.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Widen `Services.invoke` to `<TReturn, TArgs>`

**Files:**
- Modify: `runtime/services.ts` (the `invoke` signature)

- [ ] **Step 1: Read the current signature**

Run: `grep -n "invoke" /Users/zach/code/zapp/runtime/services.ts | head`
Read the `invoke` declaration. It is currently (approximately):
```ts
invoke<T = unknown>(method: string, args?: Record<string, unknown>, opts?: InvokeOptions): CancellablePromise<T> {
```

- [ ] **Step 2: Widen the generic**

Change the `invoke` signature to add an unconstrained `TArgs` generic and type `args` as `TArgs`, renaming `T` → `TReturn`. Update only the signature line; the body is unchanged (it already passes `args` through to the bridge). Result:

```ts
invoke<TReturn = unknown, TArgs = Record<string, unknown>>(
  method: string,
  args?: TArgs,
  opts?: InvokeOptions
): CancellablePromise<TReturn> {
```

If the body references the old type parameter `T` anywhere (e.g. a cast `as CancellablePromise<T>`), rename those to `TReturn` too. Do NOT add an `extends Record<string, unknown>` constraint on `TArgs` — a generated `interface XxxArgs` is not assignable to `Record<string, unknown>` (interfaces lack an implicit index signature), so the constraint would make the generated wrapper's own `invoke<XxxResult>(…)` call fail to typecheck (see the spec's escape-hatch note).

- [ ] **Step 3: Typecheck the runtime + the generated call site**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2
```
Expected: `[zapp] build complete: <path>`. The build type-checks the generated `src/zapp/*.ts` (which call `Services.invoke<GreetResult>(…)`) and the app's own `import { greet } from "./zapp"` call site. A failure here means the generic widening broke a call site — read the error and fix.

- [ ] **Step 4: Run the unit tests (no regression)**

Run: `cd /Users/zach/code/zapp/cli && bun test src/service-types.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/services.ts
git commit -m "$(cat <<'EOF'
feat(runtime): widen Services.invoke to <TReturn, TArgs>

Adds an unconstrained TArgs generic (defaults Record<string, unknown>) so
generated wrappers can pass typed interface args, and exposes a typed
escape hatch Services.invoke<Result, Args>(name, args). Return-generic
default preserved — existing invoke<T>() callers keep compiling.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: hello-world end-to-end — annotate `greet`, verify typed output

**Files:**
- Modify: `hello-world/zapp/app.zc` (annotate `greet`)

- [ ] **Step 1: Annotate the `greet` handler**

In `hello-world/zapp/app.zc`, find `fn greet(_app: App*, args: JsonValue*) -> string {` (around line 15). Add the annotation on the line directly above it:

```zc
// @zapp:returns { greeting: string }
fn greet(_app: App*, args: JsonValue*) -> string {
```

(Match the `greeting` key to what the handler actually returns — it builds `{"greeting":"hello, %s"}` via `snprintf`, so `{ greeting: string }` is correct.)

- [ ] **Step 2: Rebuild and inspect the generated wrapper**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2
cat /Users/zach/code/zapp/hello-world/src/zapp/Greet.ts
```
Expected: build last line `[zapp] build complete: <path>`. `Greet.ts` now shows the annotated return type:
```ts
export interface GreetArgs { name?: string }
export interface GreetResult { greeting: string }
export async function greet(args?: GreetArgs): Promise<GreetResult> {
    return Services.invoke<GreetResult>("greet", args ?? {});
}
```

- [ ] **Step 3: Verify the loose-fallback service stayed loose**

```bash
cat /Users/zach/code/zapp/hello-world/src/zapp/Noop.ts
```
Expected (no get_* reads, no annotation → fully loose):
```ts
export type NoopArgs = Record<string, unknown>;
export type NoopResult = unknown;
export async function noop(args?: NoopArgs): Promise<NoopResult> {
    return Services.invoke("noop", args ?? {});
}
```
(If hello-world has no `noop` service, instead confirm any other service that reads no args + has no annotation shows the loose aliases.)

- [ ] **Step 4: Confirm the app's call site type-checks against the tightened type**

`hello-world/src/main.ts` calls `await greet({ name: "World" })`. The build in Step 2 already type-checks this against the new `greet(args?: GreetArgs)` signature. Confirm the build was green (Step 2). If the build failed on the `greet(...)` call site, read the error — `{ name: "World" }` is assignable to `GreetArgs { name?: string }`, so a failure would indicate a mismatch to investigate.

- [ ] **Step 5: Full unit-test + build gate**

```bash
cd /Users/zach/code/zapp/cli && bun test
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2
```
Expected: `bun test` all green; build last line `[zapp] build complete: <path>`.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add hello-world/zapp/app.zc
git commit -m "$(cat <<'EOF'
test(hello-world): annotate greet return type (@zapp:returns)

Exercises the end-to-end type-inference path: greet now emits
GreetArgs { name?: string } (inferred) + GreetResult { greeting: string }
(annotated), and the main.ts greet({ name }) call site type-checks
against the tightened signature.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**1. Spec coverage:**
- Hybrid approach (infer args / annotate returns) → Tasks 1, 2, 4. ✓
- Accessor→TS mapping incl. `get()`→`unknown` → Task 1. ✓
- Optional inferred args (`?:`) → Task 1 `inferArgs` + Task 4 `fieldsToBody`. ✓
- `@zapp:returns` / `@zapp:args` fragment pass-through, `@zapp:args` overrides → Tasks 2, 4. ✓
- Named exported `XxxArgs`/`XxxResult` interfaces + barrel re-export → Tasks 4, 5. ✓
- Loose fallbacks (no handler / no args / no annotation) → Task 4 (tested) + Task 7 Step 3. ✓
- `invoke<TReturn, TArgs>` escape hatch, unconstrained TArgs → Task 6. ✓
- bun:test unit tests for `inferArgs`/`parseAnnotation` (+ `extractHandler`/`resolveServiceTypes`) → Tasks 1–4. ✓
- hello-world end-to-end verification → Task 7. ✓
- Three generator call sites untouched → confirmed (only the emit loop changes). ✓
- Non-goal: JS output path unchanged → Task 5 keeps the JS branch. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step has complete code. ✓

**3. Type consistency:** `ArgField {name,tsType}`, `Annotation {argsFragment?,returnsFragment?}`, `HandlerSlice {commentBlock,body}`, `ServiceTypeDecls {argsDecl,resultDecl,argsName,resultName}` are defined once and reused. Naming `${fileName}Args`/`${fileName}Result` is identical in `resolveServiceTypes` (Task 4) and the barrel block (Task 5). `inferArgs`/`parseAnnotation`/`extractHandler`/`resolveServiceTypes` signatures match between their tests and implementations. ✓
