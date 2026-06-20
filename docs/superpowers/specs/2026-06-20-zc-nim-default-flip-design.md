# Finish zc→nim, Cycle 7a — flip the default to Nim — Design

**Date:** 2026-06-20
**Branch:** `feat/nim-native`
**Status:** Design (awaiting user review)

## Summary

Make **Nim the default native build on every target**, with `ZAPP_NATIVE_LANG=zc`
as the opt-*out* escape hatch. Retire the now-superseded `hello-world` sample and
flip `zapp init` to scaffold Nim-first. The Zen-C (`.zc`) layer stays present but
dormant — **deleting it is the separate Cycle 7b**, gated on the future
Nim-Windows sprint.

This is the first of two cycles that "finish zc→nim":
- **7a (this spec):** flip the default; macOS + iOS focus.
- **7b (later):** delete the 43 `.zc` sources + zc CLI emitters + zc build path +
  `build.zc` handling — after Windows passes on Nim.

## Context (verified current state)

- The native build **defaults to zc**; Nim is opt-in via `ZAPP_NATIVE_LANG=nim`
  (`cli/src/native.ts` `compileNative` ~1308; `cli/src/zapp-cli.ts` ~584; the dev
  and assets paths also branch on it).
- The Nim path is **fully self-contained** (gap #2 removed its last zc-compiled
  TU). Nim is at **macOS + iOS parity** (B1–B8 + WindowManager + the iOS
  sidebar/inspector cycle).
- **Windows on Nim is unverified** (a separate later sprint).
- `kitchen-sink` has `app.nim` and runs on Nim today. `hello-world` has only
  `app.zc` (no Nim entry) — and is superseded by kitchen-sink, slated for removal.

## Design

### 1. The flip — one decision helper, swept everywhere

The risk is flipping some env-var read sites and missing one → an inconsistent
default. Mitigation: a single source of truth.

- Add `useNimNative(): boolean` (in a shared CLI module, e.g. `cli/src/native.ts`
  or a small `cli/src/native-lang.ts`) returning
  `process.env.ZAPP_NATIVE_LANG !== "zc"`. So **no env var → Nim**; `=zc` → the
  legacy path; any other value → Nim (fail-open to the new default).
- **Sweep `cli/src` for every `ZAPP_NATIVE_LANG` read and every `"nim"` literal
  gate** (build path, dev path, assets emitter branch, package path) and route
  each through `useNimNative()`. Enumerate them in the plan from a fresh grep — do
  not trust this list to be complete: at least `native.ts` `compileNative`,
  `zapp-cli.ts` build + assets branches, and the dev/package flows.
- The `ZAPP_NATIVE_LANG` env var remains the override (now `=zc` to opt out).

### 2. Remove `hello-world`

hello-world is superseded by kitchen-sink and would break on the new default
(no `app.nim`). Remove it in 7a rather than port it — avoids a broken-default
sample, saves the port, shrinks 7b surface. Net effect at the eventual main-merge
is identical (hello-world gone), staged earlier on the branch.

- Delete the `hello-world/` directory.
- **Reference sweep (live targets only):** update `README.md`, `WINDOWS_PORTING.md`,
  `SKILLS.md`, `docs/api-reference.md`, `docs/nim-migration-roadmap.md`, and any
  root `package.json` / CI / build-gate script that builds or links hello-world.
  Check `native/nim/zapp.nim`, `native/platform/ios/dialog.m`, and
  `native/worker/engines/zjs-cross-eval-test.c` for stray hello-world mentions
  (likely comments — fix or drop). **Leave archival `docs/superpowers/plans/*`
  untouched** (historical record).
- **Binary-size benchmark:** `benchmarks/binary-size-matrix.md` cites
  `hello-world/` for the Zapp size row. Removing hello-world orphans that row.
  Rehoming it (to `benchmarks/apps/zapp-host-bridge`, already present, or a future
  `benchmarks/apps/zapp-hello-world`) is part of the **"revisit benchmarks"
  follow-up**, NOT a 7a blocker. In 7a, just mark that row stale/pending in the
  matrix so it isn't silently wrong.

### 3. `zapp init` — Nim-first scaffold

Flip new-project scaffolding so Nim is primary and the soon-to-be-deleted zc path
is not seeded into greenfield apps:

- `cli/src/init.ts`: write `zapp/app.nim` as the primary native entry + a
  `native:` block in `zapp.config.ts` (frameworks/sources/linkFlags live there,
  per the build-manifest unification) + the generated `zapp/nim.cfg`.
- **Stop scaffolding `zapp/app.zc` and `zapp/build.zc`** for new projects. (The
  `=zc` escape hatch serves *existing* mid-migration projects, not new ones; a new
  project targets the Nim default.)
- Update the init flow text / template docs accordingly.

### 4. Docs flip

Flip the framing in live docs from "zc default, Nim opt-in" → "**Nim default**;
`ZAPP_NATIVE_LANG=zc` is a transitional escape hatch; **Windows-on-Nim in
progress** (use `=zc` for Windows until its sprint)." Targets: `README.md`,
getting-started, `cli/README.md`, `docs/architecture.md`, `docs/nim-migration-
roadmap.md`. Keep it factual about the Windows interim.

## Data flow (the flip)

```
zapp build / dev / package  (no env var)
  → useNimNative() === true
    → buildNativeNim(...)            (macOS + iOS: real; Windows: not yet — see below)

zapp build --platform windows        (interim, until Nim-Windows sprint)
  → ZAPP_NATIVE_LANG=zc zapp build … → useNimNative() === false → legacy zc path
```

## Testing / gates

- `bun test cli/src` (CLI emitter + parity tests) green; `bun run check` clean.
- **Default** (no env var) macOS build of **kitchen-sink** → `[zapp] build
  complete:` last line; iOS-sim build of kitchen-sink → same.
- iOS-platform-parity lint green.
- `zapp init` a throwaway project → it scaffolds `app.nim` + `native:` (no
  `app.zc`/`build.zc`) and builds on the default.
- **Human smoke:** `cd kitchen-sink && bun run dev` with **no env var** → window +
  greet + sidebar/inspector all work (proving Nim is the default end-to-end).
  Optional: `ZAPP_NATIVE_LANG=zc` still builds kitchen-sink (escape hatch intact).

## Non-goals (explicitly out of 7a)

- Deleting any `.zc`, the zc CLI emitters, the zc build path, or `build.zc`
  handling — that is **7b**, gated on the Nim-Windows sprint.
- Making Windows pass on Nim — the **Windows sprint**.
- Rehoming the binary-size benchmark — the **revisit-benchmarks follow-up**.
- The SwiftUI→C→Nim track.

## Files touched

- `cli/src/native.ts` (or new `cli/src/native-lang.ts`) — `useNimNative()` + swept reads.
- `cli/src/zapp-cli.ts` — route build/assets/dev/package gates through `useNimNative()`.
- `cli/src/init.ts` — Nim-first scaffold; drop app.zc/build.zc.
- `hello-world/` — **removed**.
- `README.md`, `WINDOWS_PORTING.md`, `SKILLS.md`, `cli/README.md`,
  `docs/api-reference.md`, `docs/architecture.md`, `docs/nim-migration-roadmap.md`
  — docs flip + hello-world reference sweep.
- `benchmarks/binary-size-matrix.md` — mark the Zapp size row stale/pending.
- Possible stray-reference fixes: `native/nim/zapp.nim`, `native/platform/ios/dialog.m`.
