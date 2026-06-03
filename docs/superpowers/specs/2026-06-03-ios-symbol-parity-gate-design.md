# iOS symbol-parity gate (#281) — design

**Date:** 2026-06-03
**Branch:** `feat/ios-symbol-parity-gate`
**Surfaced by:** the background-app-readiness cycle, where macOS-only `bun run build` verification let an iOS link regression slip — 5 `darwin_*` functions called under `#ifdef __APPLE__` from shared Zen-C (`router.zc`) had no stubs in `native/platform/ios/platform.m`. macOS builds fine (it compiles `darwin/platform.m`); only the iOS link broke. A final cross-platform human review caught it. This makes that catch automatic.

## The failure class (precisely)

- `#ifdef __APPLE__` is defined on **both** macOS and iOS.
- `.zc` files (e.g. `native/app/router.zc`) compile into **both** the macOS and iOS binaries.
- The iOS target compiles `native/platform/ios/*.m` — **not** `native/platform/darwin/*.m`.
- So a `darwin_*` function that shared `.zc` calls under `#ifdef __APPLE__` must have a definition on the iOS side too, or the iOS link fails with `Undefined symbols`.

Windows is **not** susceptible to this exact class: `__APPLE__` is false on Windows, so `darwin_*` inside `#ifdef __APPLE__` is never compiled there. (Windows is its own track, #167.)

## Part A — static symbol-parity lint (`bun test`)

A new test, **`cli/src/ios-platform-parity.test.ts`**, that:

1. Reads every `native/**/*.zc` file (the cross-platform Zen-C compiled into all targets, including iOS).
2. Extracts the set of referenced `darwin_*` symbols (matches `darwin_[A-Za-z0-9_]+` — covers both `extern` declarations and calls inside `raw {}` blocks).
3. Builds the set of `darwin_*` symbols **defined** (function bodies, not just declared/called) in `native/platform/ios/*.m`, and the set defined in `native/platform/darwin/*.m`.
4. **Asserts:** every `darwin_*` referenced from a `.zc` that is **defined in `darwin/`** is **also defined in `ios/`**. A symbol defined in `darwin/` but missing in `ios/` (and referenced from `.zc`) fails the test, listing the offending symbol(s) — pointing straight at the missing iOS stub.

**Definition vs reference:** "defined" = a C function definition (matches a return-type + `darwin_name(...)` + `{`, i.e. not ending in `;`). "Referenced" in `.zc` = the bare symbol token appears (extern decl or call). This distinction prevents a `.zc` extern declaration or an `ios/` *call* from being mistaken for a definition.

**Scoping rule:** only symbols defined in `darwin/` are checked for an `ios/` counterpart. This avoids false positives from:
- `darwin_*` tokens that are purely local helpers defined elsewhere, and
- the (currently empty) case of a `.zc` referencing a symbol neither platform defines (a separate dangling-extern problem, out of scope here).

**No allowlist.** A scan of the current tree finds **124** `darwin_*` symbols referenced in `.zc` and **0** defined-in-`darwin/`-but-missing-in-`ios/`. The tree is clean, so the test is a straight assertion with no exemptions. If a legitimately macOS-only symbol ever needs to be exempt (e.g. guarded more narrowly than `__APPLE__`), add a small explicit `EXEMPT` set in the test at that time with a comment — not before (YAGNI).

**Failure output:** on violation, the test message lists each missing symbol and the `darwin/` file that defines it, e.g.:
```
iOS symbol-parity: 1 darwin_* symbol referenced from .zc is defined in
native/platform/darwin/ but missing in native/platform/ios/:
  - darwin_app_quit  (defined in darwin/platform.m; add a stub to ios/platform.m)
```

**TDD proof:** the test passes on the current tree; temporarily removing one `ios/` stub must turn it red, and restoring it green. (Implementation writes the test, confirms green, then verifies red-on-removal, then commits green.)

**Location rationale:** lives in `cli/src/` so it runs in the existing `bun test cli/src` suite (the one already invoked in finishing-a-branch gates). It reads `native/` source files but imports no CLI code — co-location is purely to keep it in the single suite we already run.

## Part B — document the full ios-sim build as the pre-merge backstop (C)

The lint catches the symbol-parity class but not every possible iOS divergence (a Cocoa-only API used in shared code, a macro mismatch, etc.). So:

- Add a short **"Verifying native changes"** note to a contributing/build doc (`docs/` — e.g. a `CONTRIBUTING`-style section or the existing native/build docs) stating:
  1. `bun test cli/src` runs the symbol-parity lint automatically.
  2. **Before merging changes that touch `native/`, also run `bun run build --platform ios-simulator`** and require its `[zapp] build complete:` line — this is the broader backstop the lint can't replace.
- Update the build-verify convention memory (`feedback_verify_native_build`) so the "macOS `[zapp] build complete:` is the gate" rule explicitly notes that native-touching changes additionally need the ios-simulator build + the lint.

## Verification

- `bun test cli/src/ios-platform-parity.test.ts` passes on the current tree.
- Manually confirm red-on-removal of one `ios/` stub (TDD step), then restore.
- The full `bun test cli/src` suite stays green (30+ tests).
- No native build change in this cycle (it's a test + docs), so no `bun run build` regression risk — but run it once to confirm nothing odd.

## Non-goals

- **Windows parity checking** — different mechanism (`__APPLE__` false on Windows), deferred to #167. The lint is written iOS-focused; extending to a hypothetical `windows_*`/`#ifdef _WIN32` parity check is a future add if ever needed.
- **A full iOS build in an automated gate** — there's no CI yet (#166 is the GitHub Action track). The ios-sim build is the documented manual backstop (Part B), not an automated step here.
- **Broader iOS-divergence linting** (Cocoa-API usage in shared code, etc.) — the full ios-sim build covers that; the lint deliberately targets only the symbol-parity class that actually bit us.
- **A new "stop-after-link" build mode** — considered (option B in brainstorming) and rejected as more plumbing than this warrants.

## Related

- [[project_background_app_readiness_cycle]] — the cycle that surfaced this (and the iOS-stub class).
- [[feedback_verify_native_build]] — the build-verify convention this extends.
- [[project_supervisor_restart_followups]] — the recurring "final cross-impl review catches structural gaps" lesson this partially automates.
- #167 (Windows parity), #166 (GitHub Action / CI) — adjacent tracks where this lint and the ios-sim backstop would later become CI steps.
