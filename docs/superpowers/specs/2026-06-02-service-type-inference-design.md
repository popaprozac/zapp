# Service-codegen type inference (T2.A)

**Date:** 2026-06-02
**Branch:** `feat/service-type-inference`
**Tracks:** #165 — T2.A, Tier 2 Bet A of the competitive-teardown plan

## Goal

Replace the loosely-typed service wrappers Zapp generates today with real,
per-service argument and return types — closing the Tauri/Wails/zero-native
DX parity gap. A developer calling a service should get inferred arg types
and (when annotated) an inferred return type, with full editor
autocomplete, instead of `(args?: Record<string, unknown>) => Promise<unknown>`.

## Current state (verified)

The pipeline already exists — this tightens what it emits, it does not build
a new pipeline.

- `cli/src/generate.ts` regex-scans every `.zc` under `zapp/` for
  `.service.add("name", handler)` (`generate.ts:46`), capturing `name` +
  `handlerName` into a `ServiceBinding { name, handlerName, source }`
  (`generate.ts:8`). **`handlerName` is captured but never used today.**
- It emits one gitignored `.ts` per service into `src/zapp/` plus an
  `index.ts` barrel. The wrapper template (`generate.ts:115-127`) is
  hardcoded:
  ```ts
  import { Services } from "@zappdev/runtime";
  export async function greet(args?: Record<string, unknown>): Promise<unknown> {
    return Services.invoke("greet", args ?? {});
  }
  ```
- Called from `zapp-cli.ts` at dev (`:186`), build (`:470`), and explicit
  `zapp generate` (`:618`) — all `await generateBindings(root)` with no
  options.
- Handlers are **Zen-C**, signature `fn name(app: App*, args: JsonValue*) -> string`.
  They read args via `args.get_string("k")` / `get_int` / `get_float` /
  `get_bool` (the `Option`/`is_some` pattern) and return a JSON **string**
  built by `snprintf` (`hello-world/zapp/app.zc:15-31`).
- `runtime/services.ts` already has `invoke<T = unknown>(method, args?, opts?)`
  — return-generic, not arg-generic.
- No TypeScript-compiler-API use and no annotation/JSDoc parsing anywhere in
  the repo; codegen is pure regex.

## Approach: hybrid (infer args, annotate returns)

The two type directions split by how tractable they are in the actual code:

- **Argument types are inferred from the handler body.** The `get_*("key")`
  calls are a clean, regex-parseable pattern → zero developer burden, types
  appear on existing handlers immediately.
- **Return types come from an optional annotation.** Handlers return a
  `snprintf`'d JSON string; parsing that format is too fragile to trust
  (conditional/multi-branch/dynamic returns). A `// @zapp:returns { … }`
  comment above the handler supplies the return type instead.

An annotation can also **override** inferred args (`// @zapp:args { … }`) for
the cases inference can't see (dynamic keys, nested shapes).

This was chosen over annotation-only (zero typing until devs annotate) and
inference-only (fragile return inference with no escape hatch).

## Annotation form

Inline **TypeScript-fragment pass-through**, placed on the comment lines
directly above the handler `fn` (where arg inference already reads):

```zc
// @zapp:returns { greeting: string }
// @zapp:args { name: string; verbose?: boolean }   // optional — overrides inference
fn greet(_app: App*, args: JsonValue*) -> string { … }
```

- The generator extracts the `{ … }` (balanced-brace) fragment and emits it
  **verbatim** as the interface body. No type mini-language to design or
  parse; nested objects, arrays, unions, and optional `?` all work for free,
  and TypeScript itself validates the fragment in the generated file.
- `@zapp:returns` → the `XxxResult` body.
- `@zapp:args` → *replaces* the inferred `XxxArgs` body entirely.

## Inference rules

| Zen-C accessor | TS type |
|---|---|
| `args.get_string("k")` | `k?: string` |
| `args.get_int("k")` | `k?: number` |
| `args.get_float("k")` | `k?: number` |
| `args.get_bool("k")` | `k?: boolean` |

- Inferred args are **optional** (`k?:`) — handlers read them through the
  `Option`/`is_some` pattern, so optional is the accurate reflection.
- A field name read more than once collapses to a single field. If the same
  key is read via two different accessors (unlikely), the first wins and a
  warning is logged.
- Accessors beyond these four (e.g. `get_array`/`get_object` if they exist)
  are **not** inferred today — a handler using them with no `@zapp:args`
  falls back to the loose `Record<string, unknown>` arg type. Deferred to a
  later pass.

## Generated output shape

Named, exported interfaces per service, re-exported from the `index.ts`
barrel so callers can import and reuse the shapes.

Annotated `greet` →  `src/zapp/Greet.ts`:
```ts
import { Services } from "@zappdev/runtime";

export interface GreetArgs {
  name?: string;          // inferred from args.get_string("name")
}
export interface GreetResult {
  greeting: string;       // from // @zapp:returns
}
export async function greet(args?: GreetArgs): Promise<GreetResult> {
  return Services.invoke<GreetResult>("greet", args ?? {});
}
```

Handler with `get_*` reads but **no** `@zapp:returns` → typed args, loose
return (the zero-burden win lands without any annotation):
```ts
export interface FooArgs { x?: string }
export type FooResult = unknown;
export async function foo(args?: FooArgs): Promise<FooResult> {
  return Services.invoke<FooResult>("foo", args ?? {});
}
```

Un-inferrable, un-annotated service → fully loose (no regression):
```ts
export type NoopArgs = Record<string, unknown>;
export type NoopResult = unknown;
export async function noop(args?: NoopArgs): Promise<NoopResult> {
  return Services.invoke("noop", args ?? {});
}
```

## Architecture & components

The generator gains a per-binding **enrichment pass**. The three call sites
(dev/build/generate) are untouched — they still call `generateBindings(root)`.

1. **Scan** *(existing)* — regex → `{ name, handlerName, source }`.
2. **Locate handler** *(new)* — find `fn <handlerName>(` in `source`, capture
   its preceding comment block + body slice.
3. **`inferArgs(body)` → field list** *(new, pure fn)* — scan for the four
   `get_*("key")` accessors.
4. **`parseAnnotation(commentBlock)` → { argsFragment?, returnsFragment? }**
   *(new, pure fn)* — extract balanced-brace fragments after `@zapp:args` /
   `@zapp:returns`.
5. **Resolve** — args = `argsFragment` ?? inferred-fields ?? loose;
   result = `returnsFragment` ?? loose (`unknown`).
6. **Emit** *(extended template)* — `XxxArgs` + `XxxResult` + typed wrapper;
   barrel re-exports types and functions.

`inferArgs` and `parseAnnotation` are pure `string → data` functions, each
with one responsibility, independently testable without running the CLI.

### Typed escape hatch

Widen `runtime/services.ts`:
```ts
invoke<TReturn = unknown, TArgs = Record<string, unknown>>(
  method: string, args?: TArgs, opts?: InvokeOptions
): CancellablePromise<TReturn>
```
Generated wrappers call `invoke<GreetResult>(…)`. Advanced callers get a
typed hatch directly (`Services.invoke<Result, Args>("name", args)`). The
existing `invoke<T>` return-generic default is preserved, so current callers
keep compiling.

**`TArgs` is intentionally unconstrained** (not `extends Record<string,
unknown>`). A generated `interface GreetArgs { name?: string }` is *not*
assignable to `Record<string, unknown>` — interfaces have no implicit index
signature — so an `extends Record<string, unknown>` bound would make the
generated wrapper's own `invoke<GreetResult>("greet", args ?? {})` call fail
to typecheck. Leaving `TArgs` unconstrained (defaulting to
`Record<string, unknown>`) lets the wrapper pass a typed `interface` arg
cleanly while still defaulting sanely for untyped callers.

## Error handling & fallbacks (zero regression)

| Situation | Behavior |
|---|---|
| `handlerName` not located (handler in unscanned file, dynamic registration) | both args + return loose |
| handler has no `get_*` and no `@zapp:args` | `XxxArgs = Record<string, unknown>` |
| no `@zapp:returns` | `XxxResult = unknown` |
| malformed annotation (unbalanced braces, empty fragment) | `console.warn` + loose for that direction; build does not break |
| developer writes invalid TS in the fragment | tsc flags it in the generated file (their annotation, their error) — acceptable |

Every fallback degrades to today's loose shape, so no existing project regresses.

## Testing / verification

The repo has no unit-test harness, and `inferArgs`/`parseAnnotation` are pure
functions — unit-test-ready if a harness ever lands. For now, verify via the
hello-world generated output (matching repo culture):

1. Add `// @zapp:returns { greeting: string }` above `greet` in
   `hello-world/zapp/app.zc`; run `zapp generate` (or `bun run build`).
2. Confirm `hello-world/src/zapp/Greet.ts` shows `GreetArgs { name?: string }`
   + `GreetResult { greeting: string }` + the typed wrapper, and that the
   barrel re-exports both.
3. Confirm a deliberately un-annotated, no-arg service still emits the loose
   `Record<string, unknown>` / `unknown` shape.
4. Add an `@zapp:args { … }` override on one handler and confirm it replaces
   the inferred args.
5. Build-verify: the generated `src/zapp/*.ts` compiles (the app's own
   `import { greet } from "./zapp"` call site type-checks against the new
   signature), and `[zapp] build complete:` is the final build line.

## Non-goals

- No separate IDL/DSL file — Zen-C source stays the single source of truth.
- No return-type inference from `snprintf` format strings (too fragile).
- No inference of `get_array`/`get_object`/nested-object args in v1 (loose
  fallback; revisit later).
- No change to the three generator call sites or the runtime invoke wire
  protocol — types are a compile-time-only layer.

## Related

- Strategic plan `~/.claude/plans/polished-mapping-ullman.md` (Tier 2 Bet A).
- [[project_workers_list_cycle]] — same codegen/runtime surfaces just touched.
- `docs/zen-c-services.md` — handler arg/return conventions.
