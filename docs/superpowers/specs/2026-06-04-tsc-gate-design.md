# tsc gate — root type-check (#289) — design

**Date:** 2026-06-04
**Branch:** `feat/tsc-gate`
**Surfaced by:** the #246 testing-infrastructure spike (spec §5 backlog). `bun run build` does **not** type-check — esbuild strips types — so type regressions can land silently. This adds a real `tsc --noEmit` gate over the framework's TypeScript.

## Spike findings (the investigation, for the record)

- **No root `tsconfig.json` and no root `node_modules`.** App-level tsconfigs exist (`hello-world/tsconfig.json` is the style reference: `target ES2023`, `moduleResolution: bundler`, `strict`, `skipLibCheck`, `allowImportingTsExtensions`, `verbatimModuleSyntax`).
- **Framework TS surface is small:** `cli/src` (84 files), `runtime` (28), `vite/src/index.ts` (1), `bootstrap` (4).
- **Without ambient types installed, `bunx tsc` reports ~271 errors — but ~69% is pure noise:** `Cannot find name 'Bun'` (111) + `process`/`require`/`__dirname` (75) = 186, all of which vanish once bun/node types resolve. The rest is module-resolution noise (largely the same missing types, plus `vite/src` leaning on vite's own `node_modules`).
- **With `@types/bun` + `@types/node` resolved, the real baseline is just 8 errors across 6 files** (enumerated below). All tractable; this includes the 2 `NotificationResponse` bugs the spike flagged.
- **Environments differ:** `cli/src`/`vite` are Bun+node (no DOM); `runtime`/`bootstrap` are DOM/worker (no Bun). A single config uses a superset `lib` — accepted (see decisions); the only friction it creates is 2 ambient redeclarations in `worker-globals.ts` (fix #5–6).

## Decisions (from brainstorming)

1. **Structure — single root `tsconfig.json`, `vite/src` excluded.** Scope = `cli/src` + `runtime` + `bootstrap`. `vite/src` is a 1-file plugin leaning on vite's own `node_modules`; messy to resolve from root, so it gets its own check later (backlog). (Rejected: per-environment split configs — more precise but more machinery, YAGNI now.)
2. **Strictness — `strict: true`, correctness-only.** No `noUnusedLocals`/`noUnusedParameters` (style, not correctness; large churn; can be added later). `skipLibCheck` on. (Rejected: full strict matching hello-world; minimal/loose.)
3. **Wiring — `check` standalone + folded into `test:all`; build NOT blocked.** `test:all = test && test:native && check`. Keeps the dev/build loop fast (esbuild stays type-stripping). CI (#166) calls `test:all`. (Rejected: check-only-standalone; check-blocks-build.)

Also rejected as an overall approach: **baseline-suppress** (`ts-expect-error` the 8 errors to make `check` green without fixing them) — leaves real bugs (null-safety, the notification union) in place, defeating the gate. All 8 are fixed at the source.

## 1. Dependencies & config

Add root devDependencies and run `bun install`:
- `typescript`, `@types/bun`, `@types/node`. (`@types/bun` peer-depends on node types; both are needed for `Bun`, `process`, and `node:*` module resolution.)
- **No `@types/babel__core`** — the one `@babel/core` type error is fixed in source instead (fix #7), matching an existing codebase pattern.

`bun install` creates `node_modules` (already gitignored) and `bun.lock` (committed).

Create root `tsconfig.json`:
```jsonc
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "ESNext",
    "lib": ["ES2023", "DOM", "DOM.Iterable"],
    "types": ["bun", "node"],
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "verbatimModuleSyntax": true,
    "moduleDetection": "force",
    "noEmit": true,
    "strict": true,
    "baseUrl": ".",
    "paths": {
      "@zappdev/runtime": ["./runtime/index.ts"],
      "@zappdev/runtime/worker-globals": ["./runtime/worker-globals.ts"],
      "@zappdev/cli/config": ["./cli/src/config.ts"]
    }
  },
  "include": ["cli/src", "runtime", "bootstrap"],
  "exclude": ["**/*.test.ts", "**/node_modules"]
}
```

## 2. Scripts (root `package.json`)

```jsonc
"check":    "tsc --noEmit",
"test:all": "bun run test && bun run test:native && bun run check"
```
`build` is untouched.

## 3. The 8 real fixes (all at source → `check` reaches zero)

| # | File:line | Error (TS code) | Fix |
|---|---|---|---|
| 1 | `runtime/notification.ts:174` | TS2345 ×2 — calling a union-of-function-types `handler` forces args to the *intersection* `string & NotificationResponse` | Give `Notification.on()` proper **overloads**: `("response", (r: NotificationResponse) => void)` and `("click"\|"action", (id: string, actionId?: string) => void)`. Keep the union on the impl signature; cast `handler` to the right shape inside each branch. |
| 2 | `bootstrap/webview.ts:180` | TS2322 — `_syncPending` resolve typed `(v: string) => void` but the promise resolves `"notified"\|"timed-out"` | Tighten the field type to `resolve: (v: "notified" \| "timed-out") => void`. |
| 3 | `runtime/worker-globals/crypto.ts:54` | TS2322 — `out.buffer.slice(...)` is `ArrayBuffer \| SharedArrayBuffer`, expected `ArrayBuffer` | Return `... as ArrayBuffer` (a `Uint8Array` from `h.digest()` always has an `ArrayBuffer` backing). |
| 4 | `cli/src/native.ts:140` | TS2345 — `string \| null` passed where `string` (the `ext` value at `entry.name.endsWith(ext)`) | Tighten/guard so `ext` is `string` at the call (read the enclosing fn; narrow at the source of `ext`). |
| 5–6 | `runtime/worker-globals.ts:36,53` | TS2403 ×2 — ambient `var onmessage` / `var self` redeclared with types conflicting with `lib.dom`'s `Window` | Reconcile the two `declare global` vars with the DOM globals — minimal compatible form (e.g. defer to / align with the lib types), keeping the `__zappBridge` and function declarations intact. Exact form verified by `check` going green. |
| 7 | `cli/src/downlevel-bare-js.ts:65` | TS7016 — `@babel/core` has no declaration file | `await import("@babel/core" as string)` — the `as string` makes the specifier non-literal so TS skips resolution, **matching the existing pattern on line 68** (`"@babel/plugin-transform-classes" as string`). No new dependency. |

## 4. Docs

Extend the "Running the tests" subsection in `docs/architecture.md` (added in #246): add **`bun run check`** — type-checks `cli/src` + `runtime` + `bootstrap` via the root `tsconfig.json` (`vite/src` excluded for now); note that `test:all` now runs it too.

## Verification

- `bun run check` → **0 errors** (the ~263 ambient-noise errors never appear once types resolve).
- `bun run test:all` → TS suite + native runner + `check`, all green.
- `cd hello-world && bun run build` → last line `[zapp] build complete: …` (build path unchanged; type-check is independent).
- Confirm `node_modules` stays gitignored and only `bun.lock`, `package.json`, `tsconfig.json`, the 7 source fixes, and the doc are staged.

## Non-goals (backlog → #290 / #166)

- **`vite/src` type-checking** — needs its own config to resolve vite's `node_modules`.
- **Per-environment split configs** (precise Bun-vs-DOM separation).
- **`noUnusedLocals` / `noUnusedParameters`** (dead-code lint).
- **CI wiring** — rides #166 (the GitHub Action will call `test:all`).

## Related

- [[project_testing_infrastructure_cycle]] — the #246 slice that established `test`/`test:native`/`test:all` and backlogged this gate.
- [[project_service_type_inference_cycle]] — flagged that `bun run build` doesn't type-check (esbuild strips types); this closes that gap.
- [[feedback_verify_native_build]] — the verify convention; `test:all` (now incl. `check`) is the pre-merge gate.
