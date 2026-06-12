import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

// This file lives at <repo>/cli/src/windows-platform-parity.test.ts
//
// Windows analogue of ios-platform-parity.test.ts, with one structural
// difference: iOS checks darwin_* symbols against a SECOND platform dir,
// while Windows is its own symbol namespace — every `windows_*` token
// referenced from cross-platform Zen-C must be defined in
// native/platform/windows/*.c or the Windows link fails. (bare.c also
// references windows_sync_handle via its non-Apple fallback shims, so
// the scan covers native/**/*.c engine hosts too.)
const ROOT = path.resolve(import.meta.dir, "..", "..");

function windowsSymbolsReferencedInSources(): Set<string> {
  const syms = new Set<string>();
  for (const pattern of ["native/**/*.zc", "native/worker/**/*.c"]) {
    const glob = new Bun.Glob(pattern);
    for (const rel of glob.scanSync({ cwd: ROOT })) {
      const src = readFileSync(path.join(ROOT, rel), "utf8");
      // Broad token scan — import aliases like `win_window` don't match the
      // windows_ prefix, and non-function tokens are filtered by the
      // definition regex in the next step.
      for (const m of src.matchAll(/\bwindows_[A-Za-z0-9_]+/g)) syms.add(m[0]);
    }
  }
  return syms;
}

// Which of `candidates` have a C function DEFINITION (a body — `name(...) {`,
// not a `;` declaration or a call) in native/platform/windows/*.c. Same
// regex rationale as the iOS test: line-anchored, same-line return type,
// `[^;{]*` param list, brace allowed on the next line.
function definedSymbolsInWindows(candidates: Set<string>): Set<string> {
  const dir = path.join(ROOT, "native", "platform", "windows");
  const glob = new Bun.Glob("**/*.c");
  const blob = [...glob.scanSync({ cwd: dir })]
    .map((f) => readFileSync(path.join(dir, f), "utf8"))
    .join("\n");
  const defined = new Set<string>();
  for (const name of candidates) {
    const re = new RegExp(
      String.raw`(?:^|\n)[ \t]*(?:static[ \t]+)?[A-Za-z_][\w *\t]*\b${name}\s*\([^;{]*\)\s*\{`,
    );
    if (re.test(blob)) defined.add(name);
  }
  return defined;
}

test("every windows_* referenced from .zc / engine hosts is defined in platform/windows/", () => {
  const referenced = windowsSymbolsReferencedInSources();
  const defined = definedSymbolsInWindows(referenced);

  // Unlike the iOS test there's no "defined in the reference platform"
  // filter — any windows_-prefixed function token that lacks a definition
  // is a link error on the Windows target. Tokens that aren't function
  // calls (none today) would need an allowlist here, not a filter change.
  const violations = [...referenced].filter((s) => !defined.has(s)).sort();

  if (violations.length > 0) {
    throw new Error(
      "Windows symbol-parity: these windows_* functions are referenced from " +
        "Zen-C or engine-host sources but have no definition in " +
        "native/platform/windows/*.c (the Windows target will fail to link). " +
        "Add implementations or no-op stubs:\n  - " +
        violations.join("\n  - "),
    );
  }
  expect(violations).toEqual([]);
});

test("the lint actually sees the windows_* surface (sanity: non-empty)", () => {
  expect(windowsSymbolsReferencedInSources().size).toBeGreaterThan(30);
});
