# Testing infrastructure — first slice + strategy (#246) — design

**Date:** 2026-06-04
**Branch:** `feat/testing-infrastructure`
**Surfaced by:** the #246 repo-wide unit-testing spike. The repo has a `bun:test` suite (7 files / 42 tests, `cli/src` + `runtime`) but no unified entrypoint, no native-layer tests, and no `tsc` gate. This spike establishes *how* each layer is tested, proves it with a representative batch, and hands off a ranked backlog.

## Spike findings (the investigation, for the record)

- **TS:** `bun:test` works per-package (`bun test cli/src`, `bun test runtime`). Root `bun test` breaks — it scans `vendor/` (which has a stray `*.test.ts`) and hits **EMFILE** under parallel discovery. ~12 high-value, untested pure-logic units exist (ranked below).
- **Native Zen-C:** Zen-C **ships a first-class unit-test framework** — `test "name" { assert(cond, msg); expect(cond, msg); }` blocks inline in `.zc`, run via **`zc run <file>`**, which prints `TEST: … OK/FAIL` and **exits with the failure count** (0 = pass). Verified working with the repo's `zc` v0.4.4. No `main()` needed; tests coexist with production code. (The earlier "no framework" read was wrong — it looked for `zc test`, but tests run via `zc run`.)
- **Build safety:** the production build gathers native sources via explicit `.m`/`.c` lists (`getPlatformSources`) + the `.zc` import graph from `build.zc` — it does **not** glob `native/**/*.zc`. So test `.zc` files that nothing imports are never compiled into the app binary.
- **ObjC (`.m`):** not realistically unit-testable (Foundation/AppKit side effects) — build + manual smoke only. Out of scope.
- **tsc:** there's **no root `tsconfig.json`**, so `bunx tsc --noEmit` is noisy (~83 errors, mostly missing ambient `@types/node`/`@types/bun`). The real baseline is small once a proper tsconfig exists, plus ~2 genuine `NotificationResponse` union bugs in `runtime/notification.ts`. → its own backlog task.

## Scope (Q1 = A: spike + a both-layers first slice)

Implement the infrastructure + a proof batch for **both** layers; backlog the rest. The `tsc` gate is explicitly out of this slice.

## 1. One test entrypoint

Create a root `package.json` (the repo has none — only per-package files) with `private: true` and:
```json
"scripts": {
  "test":        "bun test cli/src runtime",
  "test:native": "bun run cli/src/test-native.ts",
  "test:all":    "bun run test && bun run test:native"
}
```
Naming the dirs explicitly avoids the `vendor/` scan + EMFILE that breaks bare `bun test`. (No `bunfig.toml` — it can't cleanly exclude `vendor/`; the script is the reliable entrypoint.)

## 2. TS proof batch (`bun:test`, co-located `*.test.ts`)

Tests for ~4–6 top-ranked pure-logic units. Where a helper isn't exported, add an `export` (small, acceptable for testability):
- `toIdent` (`cli/src/service-types.ts`) — service-name → JS identifier.
- `detectTarget(argv)` + `isIOSTarget(t)` (`cli/src/native.ts`) — `--platform` parsing/classification.
- `WORKER_PATTERN` (`vite/src/index.ts`) — the `new Worker(...)` discovery regex (quote styles, `new URL(..., import.meta.url)`, spacing).
- A plist `xmlEscape` / value-render helper (`cli/src/entitlements.ts`) — XML entity escaping + type dispatch.

Characterization tests that lock in current correct behavior (and may surface real bugs). New `*.test.ts` co-located with the module, matching the existing convention.

## 3. Native Zen-C runner + proof test

- **Runner** `cli/src/test-native.ts` (bun script):
  1. Locate `zc` the same way the build does (reuse the existing resolution in `native.ts`/`paths.ts`; fall back to `zc` on PATH).
  2. Discover `native/tests/*_test.zc`.
  3. For each, run `zc run <file>` (cwd = repo root, so relative imports resolve), capture stdout + exit code.
  4. Print a per-file `OK/FAIL` summary; **exit non-zero if any file's exit code is non-zero** (Zen-C exits with the failure count).
  5. Surface each test binary's `TEST: … OK/FAIL` lines so a failure is actionable.
- **Test location:** a dedicated `native/tests/` dir (NOT co-located) so the files can never enter the production build's import graph. (Verified safe above; the dedicated dir removes any doubt.)
- **Proof** `native/tests/json_safe_test.zc`:
  ```zc
  import "../bridge/json_safe.zc";
  test "parses a simple object" {
      let r = zapp_json_parse("{\"k\":\"v\"}");
      assert(r.is_ok(), "should parse");
      // inspect the JsonValue per std/json's API (exact accessors pinned in the plan)
  }
  ```
  `json_safe.zc` imports only `std/json` / `string.h` / `stdlib.h`, so `zc run` compiles + links it standalone. Include a few cases (object, array, malformed → `is_err`). **Prove the gate bites:** temporarily break one `assert`, confirm `zc run` exits non-zero and the runner reports red, then restore.

## 4. Docs + convention

- A short **"Testing"** section — extend `docs/architecture.md` (near "Verifying native changes") or add a concise `CONTRIBUTING`-style note: how to run (`bun run test` / `test:native` / `test:all`), where tests live (`*.test.ts` beside TS source; `*_test.zc` in `native/tests/`), and the `test "…" { assert/expect }` idiom + `zc run`.
- Update the build-verify convention memory to include `bun run test:all` for the relevant layers.

## 5. Backlog (written into this spec as the spike's recommendation)

- **Remaining TS pure-logic candidates** (~6–8): plist helpers in `bundle.ts`/`package.ts`, `resolveNotarizeCredentials` (`notarize.ts`), the `downlevel-bare-js` hex/UTF-8 codec, `inheritAutoWorkerEngine` (`vite/src/index.ts`), icon-format dispatch in `icon.ts`.
- **More native `.zc` units:** `bridge_parse` (`protocol.zc`); `event_name_to_id` (in `router.zc` — needs extraction from the platform-entangled file before it's `zc run`-able standalone); `zapp_escape_dup` (`dispatch.zc`, if isolable).
- **The `tsc` gate** (own task): add a root `tsconfig.json` (bun types + `skipLibCheck` + lib), fix the ~2 real `NotificationResponse` type bugs, add a `bun run check` script.
- **CI wiring** (when #166 lands): `bun run test:all` + the ios-simulator build + the `ios-platform-parity` lint.

## Verification

- `bun run test` (root) → all TS green (existing 42 + the new batch). Confirms the entrypoint avoids the EMFILE/vendor breakage.
- `bun run test:native` → `json_safe_test.zc` green; proven red-on-break (a deliberately failing `assert` → runner exits non-zero) then restored.
- `bun run test:all` → both.
- macOS `bun run build` unaffected (no production source touched by the tests; `native/tests/` not in the build graph) — confirm `[zapp] build complete:`.

## Non-goals

- **ObjC `.m` unit tests** — not realistic; build + manual smoke.
- **Exhaustive coverage** — this is a first slice + patterns, not 100% of the ~12 TS / all `.zc` units (backlogged).
- **The `tsc` gate, a `tsconfig.json`, and fixing the baseline type errors** — backlogged as a separate focused task.
- **CI** — #166's track; this only makes `test:all` exist for CI to call later.
- **`bunfig.toml`** — the explicit-path script is the entrypoint.
- **Refactoring entangled `.zc`** (e.g. extracting `event_name_to_id` from `router.zc`) — backlogged.

## Related

- [[feedback_verify_native_build]] — the verify convention this extends with `test:all`.
- [[project_service_type_inference_cycle]] — added the repo's first `bun:test` suite + flagged this spike; notes `bun run build` doesn't type-check (the deferred tsc gate addresses that).
- [[reference_ios_symbol_parity_gate]] — an existing native-adjacent test (`cli/src/ios-platform-parity.test.ts`) that already rides `bun test cli/src`.
- #166 — CI (GitHub Action) that will call `test:all`.
