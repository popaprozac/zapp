# iOS Symbol-Parity Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Catch the `#ifdef __APPLE__` iOS-link-error class automatically — a `bun test` that fails when a `darwin_*` function referenced from cross-platform `.zc` is defined in `native/platform/darwin/` but missing from `native/platform/ios/` — plus document the full ios-simulator build as the pre-merge backstop.

**Architecture:** A pure-TS lint test in `cli/src/` (rides the existing `bun test cli/src` suite) reads `native/**/*.zc` for referenced `darwin_*` symbols and the two platform dirs for their definitions, then asserts iOS parity. A short docs section explains why and points contributors at the broader manual backstop.

**Tech Stack:** Bun (`bun:test`, `Bun.Glob`), `node:fs`, TypeScript. No native build changes.

**Branch:** `feat/ios-symbol-parity-gate` (already created, spec committed).

**Spec:** `docs/superpowers/specs/2026-06-03-ios-symbol-parity-gate-design.md`

**Conventions:**
- Stage ONLY the files each task names. Do NOT `git add -A`. Never stage `vendor/bare`, `vendor/txiki.js`, `native/worker/engines/zjs-cross-eval-test.c`, `hello-world/src/main.ts`, or `hello-world/zapp.config.ts` (pre-existing working-tree dirt).
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Current tree is clean under this rule (124 `darwin_*` symbols referenced in `.zc`, 0 missing on iOS), so the test passes immediately — the meaningful verification is the deliberate red-on-removal proof in Task 1.

---

## Task 1: iOS symbol-parity lint test

**Files:**
- Create: `cli/src/ios-platform-parity.test.ts`

- [ ] **Step 1: Write the test**

Create `cli/src/ios-platform-parity.test.ts` with exactly this content:

```ts
import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

// This file lives at <repo>/cli/src/ios-platform-parity.test.ts
const ROOT = path.resolve(import.meta.dir, "..", "..");

// Every `darwin_*` token referenced anywhere in the cross-platform Zen-C
// sources (`.zc`). These compile into ALL targets, including iOS, so any
// darwin_* they call under `#ifdef __APPLE__` (which is true on iOS too)
// must have an iOS definition or the iOS link fails.
function darwinSymbolsReferencedInZc(): Set<string> {
  const syms = new Set<string>();
  const glob = new Bun.Glob("native/**/*.zc");
  for (const rel of glob.scanSync({ cwd: ROOT })) {
    const src = readFileSync(path.join(ROOT, rel), "utf8");
    for (const m of src.matchAll(/\bdarwin_[A-Za-z0-9_]+/g)) syms.add(m[0]);
  }
  return syms;
}

// Which of `candidates` have a C function DEFINITION (a body — `name(...) {`,
// not a `;` declaration or a call) somewhere in the `.m` files of a platform
// dir. `[^;{]*` for the param list stops the match from straddling a prior
// statement; `\s*\{` allows the brace on the next line.
function definedSymbolsIn(relDir: string, candidates: Set<string>): Set<string> {
  const glob = new Bun.Glob("*.m");
  const blob = [...glob.scanSync({ cwd: path.join(ROOT, relDir) })]
    .map((f) => readFileSync(path.join(ROOT, relDir, f), "utf8"))
    .join("\n");
  const defined = new Set<string>();
  for (const name of candidates) {
    const re = new RegExp(String.raw`\b${name}\s*\([^;{]*\)\s*\{`);
    if (re.test(blob)) defined.add(name);
  }
  return defined;
}

test("every darwin_* used in .zc and defined in darwin/ also has an iOS definition", () => {
  const referenced = darwinSymbolsReferencedInZc();
  const definedDarwin = definedSymbolsIn("native/platform/darwin", referenced);
  const definedIos = definedSymbolsIn("native/platform/ios", referenced);

  // Only check symbols that are REAL macOS functions (defined in darwin/).
  // A darwin_* in darwin/ but missing in ios/ — and referenced from .zc —
  // is exactly the link bug: ios compiles ios/*.m, not darwin/*.m.
  const violations = [...referenced]
    .filter((s) => definedDarwin.has(s) && !definedIos.has(s))
    .sort();

  if (violations.length > 0) {
    throw new Error(
      "iOS symbol-parity: these darwin_* functions are referenced from .zc and " +
        "defined in native/platform/darwin/ but MISSING in native/platform/ios/ " +
        "(the iOS target will fail to link). Add no-op stubs to ios/*.m:\n  - " +
        violations.join("\n  - "),
    );
  }
  expect(violations).toEqual([]);
});

test("the lint actually sees the darwin_* surface (sanity: non-empty)", () => {
  // Guards against a glob/path regression silently making the parity test
  // vacuously pass (empty referenced set → no violations possible).
  expect(darwinSymbolsReferencedInZc().size).toBeGreaterThan(50);
});
```

- [ ] **Step 2: Run the test — expect PASS (tree is currently clean)**

Run: `cd /Users/zach/code/zapp && bun test ./cli/src/ios-platform-parity.test.ts`
Expected: `2 pass, 0 fail`. (Unlike normal TDD, a guard test passes on a clean tree — Step 3 proves it actually detects the bug.)

- [ ] **Step 3: Prove red-on-removal — temporarily delete an iOS stub**

Open `native/platform/ios/window.m`, find the line `void darwin_window_focus(void* handle) { (void)handle; }`, and **comment it out** (prefix with `// `). Save.

Run: `bun test ./cli/src/ios-platform-parity.test.ts`
Expected: **FAIL** — the first test throws listing `darwin_window_focus` as missing on iOS. This confirms the lint catches the exact regression class.

- [ ] **Step 4: Restore the stub — back to green**

Un-comment the `darwin_window_focus` line in `native/platform/ios/window.m` (restore it exactly).

Run: `bun test ./cli/src/ios-platform-parity.test.ts`
Expected: `2 pass, 0 fail`. Confirm `git status` shows `native/platform/ios/window.m` is unmodified (`git diff --stat native/platform/ios/window.m` → empty).

- [ ] **Step 5: Run the full CLI suite to confirm no interference**

Run: `bun test ./cli/src/config.test.ts ./cli/src/log.test.ts ./cli/src/service-types.test.ts ./cli/src/ios-platform-parity.test.ts`
Expected: all pass (the prior 29 + the new 2 = 31).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/ios-platform-parity.test.ts
git commit -m "$(cat <<'EOF'
test(ci): iOS symbol-parity lint for darwin_* in .zc

bun test that fails when a darwin_* referenced from cross-platform .zc is
defined in native/platform/darwin/ but missing in native/platform/ios/ —
the #ifdef __APPLE__ iOS-link class that the background-app-readiness
cycle hit. Proven red-on-removal of an ios/ stub. Tree currently clean
(124 symbols, 0 gaps).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Document the ios-simulator backstop

**Files:**
- Modify: `docs/architecture.md` (add a `### Verifying native changes` subsection at the end of the "Layer 1: native core" section, immediately before the `## Layer 2: bridge (bootstrap)` heading at line ~146)

- [ ] **Step 1: Add the docs section**

In `docs/architecture.md`, locate the `## Layer 2: bridge (bootstrap)` heading (around line 146). Immediately BEFORE it (i.e. at the end of the Layer 1 section), insert:

```markdown
### Verifying native changes

The iOS target compiles `native/platform/ios/*.m` — **not** `native/platform/darwin/*.m`. But the cross-platform Zen-C (`.zc`, e.g. `native/app/router.zc`) is compiled into *every* target, and its `#ifdef __APPLE__` blocks are active on iOS too (`__APPLE__` is defined on both macOS and iOS). So any `darwin_*` function the shared `.zc` calls must have a definition on the iOS side as well, or the iOS link fails with `Undefined symbols`.

Two checks guard this:

1. **Automatic:** `bun test cli/src` runs a symbol-parity lint (`cli/src/ios-platform-parity.test.ts`) that fails if a `darwin_*` referenced from `.zc` is defined in `darwin/` but missing in `ios/`. This catches the most common cross-platform regression for free on every test run.
2. **Before merging native changes:** also run a real iOS compile —

   ```sh
   bun run build --platform ios-simulator
   ```

   and require its `[zapp] build complete:` line. This is the broader backstop the lint can't replace (it catches Cocoa-only APIs used in shared code, macro mismatches, and other divergences — not just missing symbols). A passing macOS build alone is **not** sufficient verification for changes under `native/`.
```

- [ ] **Step 2: Verify the markdown renders cleanly**

Run: `cd /Users/zach/code/zapp && grep -c '```' docs/architecture.md`
Expected: an even number (all code fences balanced). Visually confirm the new section sits between the end of Layer 1 and the `## Layer 2` heading.

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add docs/architecture.md
git commit -m "$(cat <<'EOF'
docs(architecture): how to verify native changes (iOS parity)

Explain that iOS compiles ios/*.m not darwin/*.m while shared .zc compiles
everywhere, so darwin_* calls need iOS definitions. Points at the
symbol-parity lint (bun test cli/src) + `bun run build --platform
ios-simulator` as the pre-merge backstop; notes a macOS build alone is
insufficient for native changes.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the controller (not a task)

- After both tasks land, the **`feedback_verify_native_build` memory** should be updated so the "macOS `[zapp] build complete:` is the gate" rule explicitly adds: native-touching changes also need `bun test cli/src` (the parity lint) + `bun run build --platform ios-simulator`. This is a memory write (not a repo file), handled at finishing time — not a subagent task.

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- Part A lint (scan `.zc` → assert `darwin_*` parity in `ios/`, definition-vs-reference distinction, `darwin/`-defined scoping, no allowlist, `cli/src/` location, red-on-removal proof) → Task 1. ✅
- Part B docs backstop (`bun run build --platform ios-simulator` + "macOS build alone insufficient") → Task 2. ✅
- Memory update → controller note (non-repo action). ✅
- Scope/non-goals (iOS-only, no Windows, no stop-after-link mode, no CI) → respected; nothing tasked outside scope. ✅

**Placeholder scan:** No TBD/placeholders. All code is complete; commands have expected output; the doc file + insertion point are exact. ✅

**Type/name consistency:** Function names `darwinSymbolsReferencedInZc` / `definedSymbolsIn`, dir args `native/platform/darwin` & `native/platform/ios`, and the test file path `cli/src/ios-platform-parity.test.ts` are used consistently across tasks and commit messages. The red-on-removal target (`darwin_window_focus` in `ios/window.m`) matches the symbol added in the background-app-readiness cycle. ✅
