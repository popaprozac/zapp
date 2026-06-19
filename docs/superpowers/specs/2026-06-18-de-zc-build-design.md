# De-zc the Nim build — design

**Date:** 2026-06-18
**Branch:** `feat/nim-native`
**Roadmap:** gap #2 of `docs/nim-migration-roadmap.md` ("de-zc the build")
**Status:** approved, ready for implementation plan

## Goal

Remove the **per-build `zc transpile` dependency** from the Nim build. Today
`buildNativeNim` shells out to `zc transpile` on *every* Nim build (the
JsonValue provider); this gap eliminates that call so day-to-day Nim builds need
no `zc` on a machine that already has the prebuilt zjs artifact.

**Scope note (2026-06-18):** the gap originally bundled a second piece —
vendoring a prebuilt zjs artifact so a *clean clone on a zc-less machine* could
build. That piece is **deferred** (see "Piece B — deferred"): the Nim build
already links a prebuilt `libzjs.dylib` without invoking `zc`, so zjs is not a
per-build zc dependency. Committing a binary / churning the submodule to support
a multi-machine future is premature while Zapp is single-developer alpha.

## Background

The Nim native layer is built additively alongside the Zen-C layer (`zc` is the
default; Nim is opt-in via `ZAPP_NATIVE_LANG=nim`; the north-star decision is to
*replace* zc, not coexist). The Nim path is already self-sufficient except for
two residual `zc transpile` dependencies:

1. **The JsonValue provider.** `native/nim/zjson_provider.zc` is a 4-line shim
   that forces `zc` to emit C implementations of three Zen-C JSON modules
   (`std/json.zc`, `bridge/json_safe.zc`, `bridge/json_builder.zc`) into
   `.zapp/zjson_provider.o`, which is linked into the Nim build via `--passL`.
   It exists so the worker engine glue `native/worker/engines/zjs.c` (C) can
   build the JSON-tree argument values it passes to the Nim service registry.

2. **The zjs runtime.** `vendor/zjs/build/libzjs.dylib` is produced by zjs's own
   Makefile (`make -C vendor/zjs lib`), which internally runs
   `zc transpile src/lib.zc`. The Nim build links the resulting library.

The two dependencies are asymmetric: (1) is a *real transpile invoked on every
Zapp build*, while (2) is already a *prebuilt artifact linked without `zc`* (zjs
is the user's first-party from-scratch JS engine, inspired by QuickJS). They
differ in necessity — (1) is removed here; (2) is deferred (see Decisions).

### What the exploration proved

- `zjs.c` is **write-only** on `JsonValue`: it *builds* trees (constructors +
  `_owned` setters) to hand to `service_invoke_native`, and never reads one
  back. The pointer is an opaque token to `zjs.c`.
- The **read side** of `JsonValue` (struct layout, `Vec__JsonValuePtr` /
  `Map__JsonValuePtr` accessors, `JsonType` tags) is consumed **only by Nim**
  (`worker_service.nim`, walking `JsonValue*` → `JsonNode`).
- `zapp_json_parse` (the heap-safe parser in `json_safe.zc`) has **zero
  Nim-build callers** — every caller is zc (`app.zc`, `service.zc`,
  `permissions.zc`, tests). On the Nim path Nim uses its own `std/json`
  `parseJson`.
- The seam returns results as `const char*` (a JSON string). `JsonValue` is
  **args-only, one direction**.
- In the **zc build** there is no double-conversion: `zjs.c` builds a
  `JsonValue`, and the zc service layer reads *that same* `JsonValue` — because
  zc's `std/json` type *is* `JsonValue`. The `JsonValue → JsonNode` walk is debt
  the **first Nim port introduced** (NimPerf #387/#500) by reusing the zc
  provider instead of going native.

## Decisions

- **Piece A approach: P3+ — port the provider to Nim, unified on `JsonNode`.**
  Rather than introduce a bespoke Nim `JsonValue` type plus a walker (plain P3),
  the C-ABI constructors build a `std/json` `JsonNode` *directly*. This removes
  the walker the Nim port introduced and restores the zc build's single-tree
  efficiency in Nim terms.
- **Piece B: deferred.** zjs is already vendored as a prebuilt `libzjs.dylib`
  the Nim build links without `zc`; it is not a per-build zc dependency.
  Vendoring a committed artifact (for clean-clone / CI / shipping) is deferred
  until a machine without `zc` actually needs it (a second dev/CI host, the
  prod-packaging cycle, or gap #7's full zc removal).

## Piece A — JsonValue provider → Nim (unify on `JsonNode`)

### Architecture

The C-ABI seam between `zjs.c` (C) and the service layer stays exactly where it
is. Only the *implementation behind the write-side symbols* changes language,
and the *consumer-side type* changes from a bespoke `JsonValue` to Nim's native
`JsonNode`.

```
worker JS  --Services.invokeSync-->  zjs.c (C)
                                       |  builds args tree via C-ABI:
                                       |    JsonValue__object_ptr(), json_object_set_owned(), ...
                                       v
                          native/nim/jsonvalue.nim  ({.exportc, cdecl.} procs)
                                       |  each proc constructs/mutates a std/json JsonNode,
                                       |  returns it as an opaque `pointer`
                                       v
            service_invoke_native(app, method, args:pointer)   [worker_service.nim]
                                       |  cast(args) -> JsonNode  (NO walk, NO second tree)
                                       v
                              user service handler (JsonNode) -> string (JSON)
```

In the **zc build** the same symbols resolve to zc's `std/json` and the seam is
unchanged. The signature
`const char* service_invoke_native(void* app, const char* method, JsonValue* args)`
is byte-identical in both builds; only the Nim build reinterprets the opaque
pointer as a `JsonNode`. Parity is preserved by construction.

### Components

**New: `native/nim/jsonvalue.nim`** — the C-ABI write surface. Exactly the nine
symbols `zjs.c` externs, each `{.exportc, cdecl.}` with the existing C signature,
each operating on `std/json` `JsonNode`:

| C-ABI symbol (unchanged name) | Behavior |
|---|---|
| `JsonValue__null_ptr() -> pointer` | `newJNull()` |
| `JsonValue__bool_ptr(b: bool) -> pointer` | `newJBool(b)` |
| `JsonValue__number_ptr(n: cdouble) -> pointer` | integral-double → `newJInt`, else `newJFloat` |
| `JsonValue__string_ptr(s: cstring) -> pointer` | `newJString($s)` — **copies** `s` |
| `JsonValue__array_ptr() -> pointer` | `newJArray()` |
| `JsonValue__object_ptr() -> pointer` | `newJObject()` |
| `json_object_set_owned(obj, key: cstring, val: pointer)` | `obj[$key] = child` (copies key), then unref child's pin |
| `json_array_push_owned(arr, val: pointer)` | `arr.add child`, then unref child's pin |
| `json_free_tree(v: pointer)` | one `GC_unref` on the root |

**Ownership model** (mirrors the manual-C semantics `zjs.c` relies on):

- Constructors allocate a `JsonNode`, `GC_ref` it (so C can hold it across
  calls), and return `cast[pointer](node)`.
- `_owned` setters store the child into the parent (`obj[key] = child` /
  `arr.add child`) — the parent's object graph now keeps the child alive — and
  then `GC_unref(child)` to release the child's construction pin. Net result:
  only the root carries an external pin.
- `json_free_tree(root)` does a single `GC_unref(cast[JsonNode](root))`; ORC
  cascades the free through the graph, exactly matching the recursive
  `json_free_tree` it replaces.

All of these run on the **worker pthread**, where foreign-thread GC is already
initialized by `zapp_worker_thread_gc_init` before any of them is reachable, so
ORC alloc/free is safe.

**Copy semantics** (required — `zjs.c` passes transient buffers):

- `JsonValue__string_ptr` must copy its `char*` (`$s` into a Nim string). `zjs.c`
  passes a transient `tmp`.
- `json_object_set_owned` must copy the `key` (`$key`). `zjs.c` passes a stack
  `kbuf`. The `_owned` naming refers to the *value* ownership transfer, not the
  key.

**Modified: `native/nim/worker_service.nim`** — `service_invoke_native` casts the
incoming `pointer` straight to `JsonNode` and passes it to the handler. Delete:

- `jsonValueToNode` (the walker),
- the `{.emit.}` struct-layout block (the `JsonValue` / `Vec__JsonValuePtr` /
  `Map__JsonValuePtr` C declarations),
- the six `Vec/Map` accessor `importc` procs,
- the `JsonType` `const` block and the `CJsonValue*` opaque types.

A `nil` pointer must still map to `JNull` (covers the "no args" case).

**Modified: `cli/src/native.ts`** — delete the provider block (the
`zc transpile zjson_provider.zc → clang -c → .o` steps) and the
`--passL:${providerO}` flag. The Nim build no longer references
`zapp_json_parse`.

**Deleted: `native/nim/zjson_provider.zc`.**

**Modified: `native/nim/tests/worker_service_test.nim`** — drop the
`$HOME`-absolute `--passL` to the gitignored `.o`; link `jsonvalue.nim` directly.

**Unchanged: `native/worker/engines/zjs.c`** — zero edits. It externs the same
nine symbols and never dereferences the pointer.

### Tickets closed

- **#502** — the `{.emit.}` JsonValue mirror is deleted outright (no header
  needed; the consumer uses `JsonNode`).
- **#503** — the hardcoded `$HOME`-absolute provider `.o` `--passL` path is
  deleted with the `.o` itself.

## Piece B — deferred (was: vendored static zjs)

**Deferred 2026-06-18.** Originally this gap would commit a prebuilt static
`libzjs.a` so a clean clone on a zc-less machine could build. Descoped after
confirming it is not needed yet:

- The Nim build already links the **prebuilt `vendor/zjs/build/libzjs.dylib`**
  via `{.passL.}` and does **not** invoke `make -C vendor/zjs` (and thus not
  `zc`) per build. zjs is a *prebuilt-link* dependency, not a per-build zc one.
- `vendor/zjs` is a **git submodule** and `build/libzjs.a` is gitignored inside
  it, so "commit the artifact" means either committing build outputs into the
  zjs source repo (anti-pattern + submodule pointer churn) or copying a 2.4 MB
  binary into the main repo. Both are real costs.
- The only payoffs — clean-clone / CI without `zc`, and static-link-for-shipping
  — matter only with a second machine or the prod-packaging cycle, neither of
  which exists in single-developer alpha.

**When to revive:** the moment a zc-less machine must build Zapp (a second
dev/CI host, the prod-bundle/packaging cycle, or gap #7's full zc removal). At
that point decide `.a`-into-main-repo vs `.a`-into-submodule, and whether to
static-link for a self-contained `.app`. Until then the prebuilt `.dylib` stays.

## Testing

- **`jsonvalue.nim` unit test** (new): build a nested tree via the C-ABI
  functions (object containing string, integral number, float, bool, null, a
  nested array, and a nested object), cast the root to `JsonNode`, and assert the
  round-trip values + kinds (integral number → `JInt`, fractional → `JFloat`).
  Exercise `json_free_tree` and confirm no leak / double-free (e.g. build + free
  in a loop).
- **`worker_service_test.nim`** (modified): links `jsonvalue.nim` directly; the
  existing assertions on `service_invoke_native` continue to pass with the
  `JsonNode` path.
- **Integration gate:** kitchen-sink "greet from worker" synchronous invoke on
  the zjs engine, Nim build.
- **Definitive proof:** with the prebuilt `vendor/zjs/build/libzjs.dylib`
  already present (it is), a full `ZAPP_NATIVE_LANG=nim bun run build` with `zc`
  removed from `PATH` completes and produces a working binary — proving piece A
  removed the per-build `zc transpile`. Plus `bun test cli/src` and
  `bunx tsc --noEmit`.
- **Final cross-implementation review:** confirm the `jsonvalue.nim` `{.exportc.}`
  signatures match `zjs.c`'s `extern` declarations exactly, and that the seam
  signature is identical across the zc and Nim builds.

## Out of scope

- **Vendoring a committed zjs artifact for zc-less clean-clone / CI / shipping**
  — deferred (see "Piece B — deferred").
- **Primitives without a JSON tree** for hot typed service calls — a separate
  future perf cycle (the handler API is `JsonNode`-typed regardless).
- **The Nim rewrite of zjs** — a separate future spec.
- **Windows brotli / build de-zc** — gap #6 (#516).

## Risks

- **Handing a Nim `ref` (`JsonNode`) across the C-ABI as a raw pointer.**
  Mitigated by `GC_ref`/`GC_unref` pinning and same-thread (worker pthread,
  foreign-GC-initialized) construction/free. This is the *same* risk profile as
  plain P3 — no new risk introduced by unifying on `JsonNode`.
- **Parity drift.** Mitigated by the unchanged seam signature and the final
  cross-impl review.

## Roadmap context

Gaps after #2: #3 (deferred worker event fan-out), #4 (bare-* engines), #5
(iOS), #6 (Windows; #516 = Windows brotli decode), #7 (default-flip + zc
removal).
