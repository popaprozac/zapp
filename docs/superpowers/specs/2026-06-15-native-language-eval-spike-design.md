# Native Orchestration Language — Evaluation Spike

**Date:** 2026-06-15
**Branch:** `spike/native-language-eval`
**Status:** Approved (design)

## Goal

Decide, with evidence, whether to migrate Zapp's native **orchestration layer**
off Zen-C — motivated by adoption / maturity risk (Zen-C is a very young,
effectively single-vendor language). The spike produces a per-candidate
scorecard + a recommendation. The actual go/no-go stays the user's.

## What's actually in question (measured from the tree)

- **Replaced:** the **43 `.zc` files / ~7,500 lines** of orchestration —
  router, window manager, bridge, services, fs, permissions, dock,
  notifications, events.
- **Untouched (language-agnostic):** the platform layer — **18 darwin `.m`
  (~8,000 lines) + 19 windows `.c`** — already C/ObjC behind a C ABI, called
  from the `.zc` layer. A migration keeps this and changes only the caller.
- **The bar a replacement must clear** (from the code): **221 `raw {}`**
  inline-C/ObjC blocks (mostly extern-C calls into `.m`/`.c`), **52 C header
  imports**, **179 `@cfg` platform-gates** (91 apple / 88 windows), **66
  struct/impl/enum** decls, a **JSON parser** (`std/json`, 7 sites — load-
  bearing for the bridge) + `std/map` + `std/result`, and a **~708 KB** binary
  baseline.

## Honest framing — Zen-C was NOT a free baseline

"Stay on Zen-C" carries documented, real tax that the comparison must credit
candidates for avoiding. The spike scores candidates against these **actual
friction points we hit**, not an idealized Zen-C:

- **const / cast wrangling** — getting `const`, `(void*)`/`(const char*)`
  casts, and struct-field constness to compile cleanly took experimentation.
- **Platform gating** — `@cfg` needed real experiments, and carries a live
  footgun: `@cfg(windows)` imports emit their `#include`s into **every**
  platform's generated TU (`@cfg` gates functions, not import emission), so
  all `windows/*.h` bodies must be `_WIN32`-guarded or they break the macOS
  build (the `ZappMenuItem` regression). Per-platform function bodies are also
  duplicated (`@cfg(apple) fn …` + `@cfg(windows) fn …`).
- **Local compiler patches** — a hand-patch to Zen-C `compat.h` dropping
  `Class:`/`SEL:` from the ObjC `_Generic` map, plus the `--objective-c`
  flag; both a version-pinning + maintenance tax even where later
  "eliminable."
- **Stdlib bugs we had to route around** — `std/json`'s 4 KB stack-buffer
  overflow (shipped a heap-allocating `json_safe.zc` replacement); a 3 KB
  dispatch-buffer truncation; a broader stack-buffer-truncation family across
  `router.zc`/`app.zc`.
- **Sharp edges** — bare `{` in a `.zc` string is f-string interpolation
  (escape `{{`/`}}`); `char* ==` is a pointer compare (use `strcmp`); an
  async-method-shorthand parser gap we waited on an upstream PR for.
- **Young-compiler tax** — pinning `vendor`/`zc`, upstreaming fixes, carrying
  workarounds.

So the decision is three-way, all live outcomes: **(a) stay on Zen-C**
(accept the above tax + adoption risk for its ergonomics), **(b) drop to
plain C** (zero adoption risk, perfect interop, tiny — but lose Option/
result/map, struct+impl, `@cfg`), or **(c) adopt a more mature ergonomic
lang** (Zig/Nim/C3/Odin) only if it clears tiny-binary + interop + a
*materially lower* adoption risk than Zen-C.

## Candidates

Five, evaluated with a plain-C baseline as the yardstick:

- **Zig** — top momentum/maturity of the new systems langs; `@cImport` reads C
  headers directly; `ReleaseSmall` → tiny; `zig cc` can also build the `.m`/
  `.c`. Platform-conditional via `comptime` + `@import("builtin").os.tag` +
  the build graph selecting files per target (no header-emit footgun). No
  inline ObjC → ObjC stays in `.m` behind C wrappers.
- **Nim** — compiles to C like Zen-C → tiny binaries + native C/ObjC interop
  (`importc`, `{.emit.}` raw-C ≈ `raw` blocks), ~15 yrs mature. Platform
  via `when defined(macosx|windows)`. Probe its GC mode (ARC / `--mm:none`).
- **C3** — C-evolution, near-perfect C compat, LLVM → tiny. Platform via
  `$if`/`$os`. Caveat: younger/smaller community than Zig — weigh against the
  maturity goal.
- **Odin** — clean syntax, `foreign import` C interop, small binaries.
  Platform via `when ODIN_OS == .Darwin`. Niche community; 4th data point.
- **plain C (baseline)** — `#ifdef __APPLE__`/`_WIN32`; the zero-adoption-risk
  reference for both size and interop.

## Method — hybrid gate, macOS-focused

ObjC is the hard interop case → the spike targets macOS. Windows is plain C
(trivial for every candidate); iOS is the same ObjC story — both **out of the
probe**, flagged for the real migration.

**Phase 1 — probe, all 5 (kill gate).** A small program per candidate that:
1. calls our **existing `darwin/*.m` C-ABI wrappers** to open a real
   `NSWindow` (proves "keep ObjC in `.m`, orchestrate from the new lang");
2. consumes a **C header** from our tree;
3. parses a small **JSON** blob (the bridge's load-bearing need — use the
   lang's stdlib or a C lib, noting which);
4. exercises **one platform-conditional branch** (mac path vs a windows stub)
   to capture the "on-mac-do-X / on-windows-do-Y" ergonomics directly;
5. builds in release/size mode → **measure binary size**.
Any candidate that can't clear interop-or-size is eliminated here.

**Phase 2 — vertical slice, survivors only (1–2 langs).** Reimplement one real
path end-to-end: bridge **JSON parse → route → `window create`**, a
**`@cfg`-equivalent platform-gated** call, one **struct + methods**, a
**const-correctness** case (the kind that fought us in Zen-C), and an extern
that today lives in an **inline-ObjC `raw` block** (proves the "push ObjC to a
`.m` wrapper" pattern at a realistic site). Assess ergonomics against the
friction inventory + real binary size.

## Decision rubric (scorecard — thresholds adjustable)

| Axis | Bar |
|---|---|
| **Binary size** | within ~15–20% of **~708 KB**; hard-fail if multi-MB |
| **C/C++/ObjC interop** | clean call into `.m`/`.c` C-ABI + C-header consume + the `raw`→`.m`-wrapper pattern; no contortions for JSON / struct-impl |
| **Platform-conditional ergonomics** | express "mac vs windows" cleanly; **no** Zen-C-style emit-into-every-TU footgun or duplicated per-platform bodies |
| **General ergonomics vs the friction inventory** | const/cast handling, string handling, error/Option-style flow, stdlib quality — graded against the documented Zen-C pains above |
| **Maturity / adoption risk** | **materially lower than Zen-C** — release stability, ecosystem, community/contributor pool, longevity, hiring |
| **Migration cost** | qualitative, from the slice: rewriting `cli/src/native.ts` build + the `.zc`-emitting codegen + replacing `std/json`; team retraining |

A candidate must clear size + interop to be recommendable; the rest rank the
survivors against "stay on Zen-C" and "drop to plain C."

## Deliverable

- A throwaway `spikes/lang-eval/` area (per-candidate subdirs). **Does not
  touch the real native build.**
- A committed **scorecard doc** (`docs/superpowers/specs/` or `spikes/`) with
  per-candidate findings, the friction-inventory grading, binary-size table,
  and a recommendation that explicitly weighs all three outcomes (adopt-X /
  stay-Zen-C / drop-to-C).

## Prerequisites

Install the toolchains in the spike: `zig`, `nim`, `c3c`, `odin` (brew /
official installers). `zc` and a C compiler are already present.

## Out of scope

The actual migration; the CLI/codegen rewrite; Windows/iOS interop coverage
(lower-risk: plain C / same ObjC); performance benchmarking (all are native —
size + ergonomics + maturity are the deciders, not throughput).

## Effort

Phase 1 ≈ 1–2 days (parallelizable per-candidate). Phase 2 ≈ 1–2 days on
survivors. Plus the scorecard writeup. Bounded by the kill gate.
