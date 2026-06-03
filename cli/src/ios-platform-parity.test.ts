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
    // Broad token scan — may include non-function tokens (e.g. a Zen-C import
    // alias like `darwin_cb`). Those are harmless: they never match a C function
    // definition in the next step and are silently filtered out.
    for (const m of src.matchAll(/\bdarwin_[A-Za-z0-9_]+/g)) syms.add(m[0]);
  }
  return syms;
}

// Which of `candidates` have a C function DEFINITION (a body — `name(...) {`,
// not a `;` declaration or a call) somewhere in the `.m` files of a platform
// dir. `[^;{]*` for the param list stops the match from straddling a prior
// statement; `\s*\{` allows the brace on the next line.
//
// NOTE: matches the raw file text — a commented-out definition still counts as
// "defined". Acceptable: the real bug class is a stub that was NEVER added
// (symbol totally absent), which IS caught. Don't try to prove red-on-removal
// by commenting a stub out — rename or delete it instead.
function definedSymbolsIn(relDir: string, candidates: Set<string>): Set<string> {
  // **/*.m recurses into subdirectories (future-proofs against a platform subdir).
  const glob = new Bun.Glob("**/*.m");
  const blob = [...glob.scanSync({ cwd: path.join(ROOT, relDir) })]
    .map((f) => readFileSync(path.join(ROOT, relDir, f), "utf8"))
    .join("\n");
  const defined = new Set<string>();
  for (const name of candidates) {
    // A real C function DEFINITION: line-anchored, an optional `static`, a
    // return type on the same line (word chars / spaces / `*`, NOT newlines),
    // then the name, params, and an opening brace. The same-line type prefix
    // is what rejects call contexts like `if (!darwin_x(a) || !b) {` — there
    // the name is preceded by `!`/`(`, not a type, so it won't match.
    const re = new RegExp(
      String.raw`(?:^|\n)[ \t]*(?:static[ \t]+)?[A-Za-z_][\w *\t]*\b${name}\s*\([^;{]*\)\s*\{`,
    );
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
