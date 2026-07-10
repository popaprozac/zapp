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

// ---------------------------------------------------------------------------
// Nim-layer cross-link parity (added when the M1 iOS build gate landed).
//
// The `darwin_*`/.m parity above catches one bug class: a darwin_* defined in
// darwin/*.m but missing in ios/*.m. The iOS Nim build surfaced a SECOND class:
// an `ios/*.m` file `extern`-references a C symbol that is NOT defined in ANY
// `.m` — it's provided by the Nim layer's `{.exportc.}` (e.g. `wopts_sheet_*`
// from window.nim, `fs_grant_path` from fs.nim). On macOS the equivalent
// darwin/*.m doesn't reference those iOS-only features, so the macOS link never
// needs them and a missing Nim `{.exportc.}` goes unnoticed — until the iOS link
// fails with "Undefined symbols". This lint asserts every such cross-layer
// extern in ios/*.m is satisfied by either an `.m` definition OR a Nim
// `{.exportc.}` (the Nim port forgetting to export it is the exact regression).
// ---------------------------------------------------------------------------

// `extern` declarations whose name is actually a C preprocessor/attribute token,
// not a real cross-layer symbol (regex noise — e.g. `extern "C"` blocks or an
// `__attribute__((...))` that follows an `extern` return type).
const EXTERN_NOISE = new Set(["__attribute__"]);

// Every `extern <type> <name>(` C-function declaration in ios/*.m. These are the
// symbols ios/*.m reaches OUT to (provided by the Nim/zc layer or another .m).
function externFnsDeclaredInIosM(): Set<string> {
  const syms = new Set<string>();
  const glob = new Bun.Glob("**/*.m");
  const dir = path.join(ROOT, "native/platform/ios");
  for (const f of glob.scanSync({ cwd: dir })) {
    const src = readFileSync(path.join(dir, f), "utf8");
    // `extern` + a return type (word chars / spaces / `*`) + the name + `(`.
    for (const m of src.matchAll(/\bextern\s+[A-Za-z_][\w *]*\b([A-Za-z_]\w*)\s*\(/g)) {
      if (!EXTERN_NOISE.has(m[1])) syms.add(m[1]);
    }
  }
  return syms;
}

// All C symbol names provided by a Nim `{.exportc.}` — across the framework's
// `native/nim/**.nim` AND the CLI-generated Nim emitted from `build-config.ts`
// (zapp_build_config.nim / zapp_bootstrap.nim are rendered, never on disk, so a
// disk scan alone would miss zapp_build_* / zapp_webview_bootstrap_script).
//
// Nim proc signatures + pragmas span multiple lines, so a per-symbol same-line
// regex is too brittle (it false-negatives on `proc foo(a,\n b) {.exportc.}` and
// on long names whose pragma sits on a continuation line). Instead: parse the
// blob ONCE, walking every `{.…exportc…}` pragma block and attaching it to the
// nearest preceding `proc <name>`; also collect explicit `exportc: "<name>"`
// renames. Returns the full provided set; callers intersect with their candidates.
function nimExportcProvidedSymbols(): Set<string> {
  const provided = new Set<string>();
  const sources: string[] = [];
  const nimGlob = new Bun.Glob("native/nim/**/*.nim");
  for (const rel of nimGlob.scanSync({ cwd: ROOT })) {
    sources.push(readFileSync(path.join(ROOT, rel), "utf8"));
  }
  // The CLI-generated Nim modules' renderers (zapp_build_* + bootstrap getters).
  sources.push(readFileSync(path.join(ROOT, "cli/src/build-config.ts"), "utf8"));
  const blob = sources.join("\n");

  // Explicit C-name renames: `{.exportc: "the_c_name"...}`.
  for (const m of blob.matchAll(/exportc:\s*"([A-Za-z_]\w*)"/g)) provided.add(m[1]);

  // Default exportc (C name == proc name): find each `proc <name>` and, if an
  // `exportc` pragma appears before the proc BODY starts (`=` for a Nim def or
  // the `{.exportc.}` literal in the renderer templates), record <name>. We
  // scan a bounded window after the proc name so an unrelated later exportc
  // can't bleed in.
  for (const m of blob.matchAll(/\bproc\s+([A-Za-z_]\w*)\*?\s*\(/g)) {
    const name = m[1];
    const start = m.index ?? 0;
    // Window = up to the next `proc ` keyword or 400 chars, whichever first.
    const rest = blob.slice(start, start + 400);
    const nextProc = rest.indexOf("\nproc ", 1);
    const windowText = nextProc >= 0 ? rest.slice(0, nextProc) : rest;
    if (/\bexportc\b/.test(windowText)) provided.add(name);
  }
  return provided;
}

// Which of `candidates` are provided by a Nim `{.exportc.}`.
function nimExportcSymbols(candidates: Set<string>): Set<string> {
  const all = nimExportcProvidedSymbols();
  const found = new Set<string>();
  for (const name of candidates) if (all.has(name)) found.add(name);
  return found;
}

test("every cross-layer extern in ios/*.m is satisfied by an .m def or a Nim {.exportc.}", () => {
  const externs = externFnsDeclaredInIosM();
  const definedIos = definedSymbolsIn("native/platform/ios", externs);
  const definedDarwin = definedSymbolsIn("native/platform/darwin", externs);
  const fromNim = nimExportcSymbols(externs);

  // A cross-layer extern is unsatisfied when no .m defines it (ios or darwin —
  // darwin/ never compiles into the iOS link, but a same-named def there is a
  // strong signal it's an .m-owned symbol, not a Nim one) AND the Nim layer
  // doesn't {.exportc.} it. That's the iOS-link "Undefined symbols" bug.
  const violations = [...externs]
    .filter((s) => !definedIos.has(s) && !definedDarwin.has(s) && !fromNim.has(s))
    .sort();

  if (violations.length > 0) {
    throw new Error(
      "iOS Nim-link parity: these symbols are `extern`-referenced from " +
        "native/platform/ios/*.m but are defined NEITHER in any *.m NOR by a Nim " +
        "`{.exportc.}` — the iOS Nim build will fail to link. Add the missing Nim " +
        "`{.exportc.}` (mirror window.nim's wopts_* / fs.nim's fs_grant_path):\n  - " +
        violations.join("\n  - "),
    );
  }
  expect(violations).toEqual([]);
});

test("the Nim-link lint sees the ios/*.m extern surface (sanity: non-empty)", () => {
  // The fix that landed with this lint: wopts_sheet_* + fs_grant_path are
  // cross-layer externs now provided by Nim {.exportc.}. Assert they're seen so
  // a glob/regex regression can't make the lint vacuously pass.
  const externs = externFnsDeclaredInIosM();
  expect(externs.size).toBeGreaterThan(5);
  expect(externs.has("fs_grant_path")).toBe(true);
  expect(externs.has("wopts_sheet_presentation")).toBe(true);
  // And they ARE resolved by the Nim layer (the regression this gate guards).
  const fromNim = nimExportcSymbols(externs);
  expect(fromNim.has("fs_grant_path")).toBe(true);
  expect(fromNim.has("wopts_sheet_presentation")).toBe(true);
  expect(fromNim.has("wopts_sheet_detents")).toBe(true);
  expect(fromNim.has("wopts_sheet_grabber")).toBe(true);
});

// ---------------------------------------------------------------------------
// Nim importc darwin_* parity (#637)
//
// The Nim layer {.importc.}s darwin_* C functions (defined in darwin/*.m).
// Because ios/*.m is compiled instead of darwin/*.m on iOS, any darwin_* that
// is referenced by Nim AND defined only in darwin/*.m (no matching stub in
// ios/*.m) will cause the iOS link to fail with "Undefined symbols".
//
// Scanner strategy: a bare `{.importc.}` in Nim means the C name equals the
// Nim proc name. All darwin_* importc declarations in native/nim use this bare
// form (no explicit `importc: "darwin_..."` renames exist), so we match:
//   proc darwin_<name>(...) {.importc ...}
// and extract the proc name as the C symbol name.
// ---------------------------------------------------------------------------

// Every `darwin_*` C symbol that the Nim layer brings in via `{.importc.}`.
// Bare `{.importc.}` (no explicit C-name string) means C name == Nim proc name,
// so we match `proc darwin_<name>(` followed (within 400 chars) by `importc`.
// This mirrors `nimExportcProvidedSymbols`'s file-globbing + sync-read idiom.
function nimImportcDarwinSymbols(): Set<string> {
  const out = new Set<string>();
  const glob = new Bun.Glob("native/nim/**/*.nim");
  for (const rel of glob.scanSync({ cwd: ROOT })) {
    const src = readFileSync(path.join(ROOT, rel), "utf8");

    // Case 0: the platform-ABI seam (native/nim/nativeabi.nim). Bindings are
    // `{.importc: abiPrefix & "<suffix>".}` where abiPrefix is "darwin_" on Apple
    // (and "windows_" on Windows). Reconstruct the darwin_ C name from the suffix
    // so the iOS parity check still sees the full surface.
    for (const m of src.matchAll(/abiPrefix\s*&\s*"([A-Za-z0-9_]+)"/g)) {
      out.add("darwin_" + m[1]);
    }

    // Case 1: explicit C-name rename — `importc: "darwin_<name>"` anywhere.
    for (const m of src.matchAll(/importc:\s*"(darwin_[A-Za-z0-9_]+)"/g)) {
      out.add(m[1]);
    }

    // Case 2: bare importc — proc name IS the C name. Match `proc darwin_<name>`
    // and confirm an `importc` pragma appears in the bounded window after the
    // proc keyword (same 400-char window as nimExportcProvidedSymbols).
    for (const m of src.matchAll(/\bproc\s+(darwin_[A-Za-z0-9_]+)\s*\*/g)) {
      const name = m[1];
      const start = m.index ?? 0;
      const rest = src.slice(start, start + 400);
      const nextProc = rest.indexOf("\nproc ", 1);
      const windowText = nextProc >= 0 ? rest.slice(0, nextProc) : rest;
      if (/\bimportc\b/.test(windowText)) out.add(name);
    }
    // Also match procs without the export `*` marker.
    for (const m of src.matchAll(/\bproc\s+(darwin_[A-Za-z0-9_]+)\s*\(/g)) {
      const name = m[1];
      const start = m.index ?? 0;
      const rest = src.slice(start, start + 400);
      const nextProc = rest.indexOf("\nproc ", 1);
      const windowText = nextProc >= 0 ? rest.slice(0, nextProc) : rest;
      if (/\bimportc\b/.test(windowText)) out.add(name);
    }
  }
  return out;
}

test("every darwin_* {.importc.}'d in native/nim has an iOS definition (#637)", () => {
  const imported = nimImportcDarwinSymbols();
  const definedIos = definedSymbolsIn("native/platform/ios", imported);
  const definedDarwin = definedSymbolsIn("native/platform/darwin", imported);
  const violations = [...imported].filter((s) => definedDarwin.has(s) && !definedIos.has(s)).sort();
  expect(violations).toEqual([]);
});

test("the Nim importc scanner sees the darwin_* importc surface (sanity: non-empty, #637)", () => {
  // Guards against a glob/regex regression silently making the parity test
  // vacuously pass (empty imported set → no violations possible).
  const imported = nimImportcDarwinSymbols();
  expect(imported.size).toBeGreaterThan(10);
  // Known stable symbols from fs.nim and router.nim:
  expect(imported.has("darwin_fs_read_file")).toBe(true);
  expect(imported.has("darwin_window_show")).toBe(true);
});
