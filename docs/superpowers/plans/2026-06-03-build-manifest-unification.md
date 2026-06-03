# Build-Manifest Unification (DX Part B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `zapp.config.ts` the single declarative build manifest (a typed `native: {}` block) and `build.zc` pure service code, by grouping the existing flat native-extra fields, eliminating the only visible generated twin (`_zapp_build_ios.zc`), and ensuring templates carry no platform directives.

**Architecture:** The framework ALREADY injects platform defaults (`.zapp/zapp_platform.zc`), derives engines from `config.headless[].engine` (`generateEngineOverlay`), and reads user native extras (`extraFrameworks`/`extraLinkFlags`/`nativeSources`). This plan: (1) moves `_zapp_build_ios.zc` from the visible `zapp/` to hidden `.zapp/`; (2) adds a grouped `native: { frameworks, linkFlags, sources }` config block resolving to the existing extras (flat fields kept as back-compat); (3) cleans the templates; (4) validates `native:`; (5) docs.

**Tech Stack:** TypeScript (cli/), Bun (test), Zen-C templates.

**Spec:** `docs/superpowers/specs/2026-06-02-dev-experience-design.md` (Part B). Part A (logging) already shipped (`ae0fa29`).

**Build-verify rule:** native builds succeed only when the LAST line is `[zapp] build complete: <path>` (per `feedback_verify_native_build`). Vite's `✓ built` is NOT sufficient. DISK NOTE: prefer the light zjs `bun run build` (530 KB); the iOS build is needed for Task 1's verification (it generates `_zapp_build_ios.zc`) but is heavier — check `df -h /` first.

---

## File Structure

| File | Responsibility | Type |
|---|---|---|
| `cli/src/build-config.ts:301` | `_zapp_build_ios.zc` output path → hidden `.zapp/` | Modify |
| `cli/src/zapp-cli.ts:~181,320,552` | call sites that pass/consume the iOS build file path | Modify |
| `cli/src/config.ts` | add `native?: { frameworks?, linkFlags?, sources? }` to `ZappConfig`; a `resolveNative(config, target)` that merges `native.*` with the legacy flat fields | Modify |
| `cli/src/config.test.ts` | `bun test` for `resolveNative` (grouping + back-compat) + `native:` validation | Create |
| `cli/src/build-config.ts` (consumers) | read native extras via `resolveNative` instead of the three flat resolves | Modify |
| `cli/src/init.ts` + `hello-world/zapp/build.zc` | templates: no `//>` platform directives / engine defines (pure service code) | Modify |
| `docs/api-reference.md` / `cli/README.md` | document `native: {}` + that `build.zc` is pure service code | Modify |

---

## Task 1: Move `_zapp_build_ios.zc` into the hidden `.zapp/` dir

**Files:**
- Modify: `cli/src/build-config.ts:214-304` (`generateIOSBuildFile` — the output path at ~line 301)
- Modify: `cli/src/zapp-cli.ts` (the dev `~181` + `~320` and build `~552` references)

- [ ] **Step 1: Read the current path + call sites**

Read `cli/src/build-config.ts:214-304`. The output path is currently (line ~301):
```ts
const iosBuildFile = path.join(path.dirname(originalBuildFile), "_zapp_build_ios.zc");
```
`path.dirname(originalBuildFile)` is the user's `zapp/` dir. Read how the path is RETURNED and consumed in `zapp-cli.ts` (dev ~181/205/320, build ~552-553). Also check `.gitignore` (hello-world `.gitignore:30` ignores `zapp/_zapp_build_*.zc`).

- [ ] **Step 2: Change the output to `.zapp/`**

Other generated files live in `<root>/.zapp/` (e.g. `.zapp/zapp_platform.zc`, `.zapp/zapp_engine_overlay.zc`, worker bundles). Move the iOS build file there. In `generateIOSBuildFile`, change the path to the project's `.zapp/` dir. The function signature has `root` (or derive it) — mirror how `generatePlatformConfig` builds its `.zapp/` path. Replace line ~301:
```ts
// was: path.join(path.dirname(originalBuildFile), "_zapp_build_ios.zc")
const zappDir = path.join(root, ".zapp");
await mkdir(zappDir, { recursive: true });   // ensure it exists (mirror how generatePlatformConfig ensures .zapp/)
const iosBuildFile = path.join(zappDir, "_zapp_build_ios.zc");
```
(Confirm `root` is in scope in `generateIOSBuildFile` — its signature is `generateIOSBuildFile(root, originalBuildFile, config)` per the call sites. If `mkdir` isn't already imported, add it from `node:fs/promises` as the file does elsewhere. If `generatePlatformConfig` already guarantees `.zapp/` exists before this runs, the `mkdir` is belt-and-suspenders — keep it for safety.)

- [ ] **Step 3: Verify the consumers still resolve the path**

The call sites (`zapp-cli.ts`) use the RETURNED path, so moving the file is transparent IF they use the return value (not a hardcoded `zapp/_zapp_build_ios.zc`). Grep to be sure nothing hardcodes the old location:
```bash
grep -rn "_zapp_build_ios" cli/src/ hello-world/
```
Any hardcoded `zapp/_zapp_build_ios.zc` reference (outside the `.gitignore`) must be updated to use the returned path / `.zapp/`. Update the hello-world `.gitignore` line if it specifically ignored `zapp/_zapp_build_*.zc` — change it to also/instead cover `.zapp/` (the `.zapp/` dir is likely already gitignored; confirm — if `.zapp/` is ignored wholesale, the old `zapp/_zapp_build_*.zc` ignore line becomes dead and can be removed).

- [ ] **Step 4: Build verify — iOS, and the twin is gone from `zapp/`**

```bash
df -h / | tail -1   # ensure headroom for the iOS build
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -2
```
Expected: last line `[zapp] build complete: <ios path>`. Then:
```bash
ls /Users/zach/code/zapp/hello-world/zapp/ | grep _zapp_build_ios && echo "STILL IN zapp/ (bad)" || echo "gone from zapp/ (good)"
ls /Users/zach/code/zapp/hello-world/.zapp/ | grep _zapp_build_ios && echo "now in .zapp/ (good)"
```
Expected: NOT in `zapp/`, IS in `.zapp/`. Then a light macOS build to confirm no regression:
```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1
```
Expected: `[zapp] build complete:` (macOS). (macOS never generated the iOS file, so it's unaffected — just confirming.)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts cli/src/zapp-cli.ts hello-world/.gitignore
git commit -m "$(cat <<'EOF'
refactor(cli): generate _zapp_build_ios.zc into hidden .zapp/, not zapp/

The iOS build manifest was the only generated file written next to the
user's build.zc in the visible zapp/ dir — a confusing "twin". Move it to
.zapp/ alongside the other generated artifacts (zapp_platform.zc, engine
overlay, worker bundles) so zapp/ only ever shows the user's own files.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Grouped `native: {}` config block (TDD)

**Files:**
- Modify: `cli/src/config.ts` (add `native?` to `ZappConfig`; add `resolveNative`)
- Create: `cli/src/config.test.ts`

- [ ] **Step 1: Add the `native` field to `ZappConfig`**

In `cli/src/config.ts`, near the existing `nativeSources?`/`extraFrameworks?`/`extraLinkFlags?` fields (~665/682/700), add the grouped block. Keep the flat fields (mark them deprecated in a comment — back-compat):

```ts
  /**
   * Native build extras — the Tauri-style escape hatch for linking system
   * frameworks, raw linker flags, and extra native source files. Each value is
   * either an array (all targets) or a per-platform map (PlatformValue).
   */
  native?: {
    frameworks?: PlatformValue<string[]>;
    linkFlags?: PlatformValue<string[]>;
    sources?: PlatformValue<string[]>;
  };

  /** @deprecated use `native.frameworks` */
  extraFrameworks?: PlatformValue<string[]>;
  /** @deprecated use `native.linkFlags` */
  extraLinkFlags?: PlatformValue<string[]>;
  /** @deprecated use `native.sources` */
  nativeSources?: PlatformValue<string[]>;
```
(Adapt to the real `PlatformValue<T>` type name + the exact existing field declarations — read them first and keep their existing JSDoc/structure.)

- [ ] **Step 2: Write the failing test for `resolveNative`**

Create `cli/src/config.test.ts`:

```ts
import { test, expect } from "bun:test";
import { resolveNative } from "./config";

test("resolveNative reads the grouped native block", () => {
  const cfg = { native: { frameworks: ["CoreLocation"], linkFlags: ["-lfoo"], sources: ["a.m"] } } as any;
  expect(resolveNative(cfg, "macos")).toEqual({
    frameworks: ["CoreLocation"], linkFlags: ["-lfoo"], sources: ["a.m"],
  });
});

test("resolveNative falls back to the deprecated flat fields", () => {
  const cfg = { extraFrameworks: ["Contacts"], extraLinkFlags: ["-lbar"], nativeSources: ["b.c"] } as any;
  expect(resolveNative(cfg, "macos")).toEqual({
    frameworks: ["Contacts"], linkFlags: ["-lbar"], sources: ["b.c"],
  });
});

test("resolveNative merges grouped + flat (grouped first, then flat, deduped)", () => {
  const cfg = { native: { frameworks: ["A"] }, extraFrameworks: ["A", "B"] } as any;
  expect(resolveNative(cfg, "macos").frameworks).toEqual(["A", "B"]);
});

test("resolveNative resolves per-platform PlatformValue maps for the target", () => {
  const cfg = { native: { frameworks: { macos: ["MacFW"], ios: ["IosFW"] } } } as any;
  expect(resolveNative(cfg, "macos").frameworks).toEqual(["MacFW"]);
  expect(resolveNative(cfg, "ios-simulator").frameworks).toEqual(["IosFW"]);
});

test("resolveNative returns empty arrays when nothing is set", () => {
  expect(resolveNative({} as any, "macos")).toEqual({ frameworks: [], linkFlags: [], sources: [] });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd /Users/zach/code/zapp/cli && bun test src/config.test.ts`
Expected: FAIL — `resolveNative` not exported.

- [ ] **Step 4: Implement `resolveNative`**

In `cli/src/config.ts`, add (it composes the existing `resolvePlatformValue` at ~709). Merge grouped + flat, dedupe preserving order:

```ts
// Merge the grouped `native:` block with the deprecated flat fields
// (extraFrameworks/extraLinkFlags/nativeSources), resolved for `target`.
// Grouped values come first, then flat, de-duplicated.
export function resolveNative(
  config: ZappConfig,
  target: BuildTarget,
): { frameworks: string[]; linkFlags: string[]; sources: string[] } {
  const dedupe = (xs: string[]) => [...new Set(xs)];
  const merge = (
    grouped: PlatformValue<string[]> | undefined,
    flat: PlatformValue<string[]> | undefined,
  ) => dedupe([
    ...resolvePlatformValue(grouped, target),
    ...resolvePlatformValue(flat, target),
  ]);
  return {
    frameworks: merge(config.native?.frameworks, config.extraFrameworks),
    linkFlags: merge(config.native?.linkFlags, config.extraLinkFlags),
    sources: merge(config.native?.sources, config.nativeSources),
  };
}
```
(Use the real `BuildTarget` type + `resolvePlatformValue` signature from the file — read them. `resolvePlatformValue(undefined, target)` must return `[]` — confirm it handles undefined; if not, guard with `?? []`.)

- [ ] **Step 5: Run to verify it passes**

Run: `cd /Users/zach/code/zapp/cli && bun test src/config.test.ts`
Expected: PASS (5 tests). Then full suite: `bun test` — no regression (log.test + service-types.test + config.test).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/config.ts cli/src/config.test.ts
git commit -m "$(cat <<'EOF'
feat(config): grouped native:{frameworks,linkFlags,sources} + resolveNative

Adds the typed native: block to ZappConfig (the Tauri-style linking
surface) and resolveNative(config,target), which merges it with the now
-deprecated flat extraFrameworks/extraLinkFlags/nativeSources fields
(grouped first, then flat, deduped, per-target). Back-compat preserved;
unit-tested.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire the build to use `resolveNative`

**Files:**
- Modify: `cli/src/build-config.ts` (the sites at ~502-504, ~538-539, ~587-590 that resolve the three flat fields)

- [ ] **Step 1: Replace the three flat resolves with one `resolveNative`**

Read `cli/src/build-config.ts` around lines 500-540 (macOS) and 585-590 (iOS) where it currently calls `resolvePlatformValue(config.extraFrameworks, …)` / `extraLinkFlags` / `nativeSources` separately. Replace those with a single `resolveNative(config, target)` call and use `.frameworks` / `.linkFlags` / `.sources` from the result. Import `resolveNative` from `./config`.

Concretely, where the code currently builds (paraphrased):
```ts
const extraFrameworks = resolvePlatformValue(config.extraFrameworks, target);
const extraLinkFlags = resolvePlatformValue(config.extraLinkFlags, target);
const userSources = resolvePlatformValue(config.nativeSources, target);
```
replace with:
```ts
const { frameworks: extraFrameworks, linkFlags: extraLinkFlags, sources: userSources } =
  resolveNative(config, target);
```
Keep every downstream use of `extraFrameworks`/`extraLinkFlags`/`userSources` the same (they're now sourced from `resolveNative`, which includes BOTH the `native:` block and the legacy flat fields). Apply for both the macOS and iOS branches. Read the actual variable names and adapt.

- [ ] **Step 2: Build verify — `native:` flows through**

Add a temporary `native: { frameworks: ["CoreLocation"] }` to `hello-world/zapp.config.ts`, then confirm the framework is linked. Under `--debug`, the generated platform config / compiler invocation should reference `CoreLocation`:
```bash
cd /Users/zach/code/zapp/hello-world && bun run build --debug 2>&1 | grep -i "CoreLocation" | head -2
```
Expected: `CoreLocation` appears (in the generated `//> framework: CoreLocation` and/or the clang invocation). Also confirm the build still completes: `bun run build 2>&1 | tail -1` → `[zapp] build complete:`. **Then REVERT the temp `native:` block** (`git checkout hello-world/zapp.config.ts`) and confirm clean.

(If grepping the debug output for CoreLocation is unreliable, instead `cat hello-world/.zapp/zapp_platform.zc | grep CoreLocation` after the build — the directive must be emitted there.)

- [ ] **Step 3: Legacy flat field still works (back-compat)**

Temporarily add `extraFrameworks: ["CoreLocation"]` (the OLD flat field) to `hello-world/zapp.config.ts`, rebuild, confirm `CoreLocation` still flows (proves `resolveNative`'s back-compat). Revert.

- [ ] **Step 4: Full test + build**

```bash
cd /Users/zach/code/zapp/cli && bun test 2>&1 | tail -1
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1
```
Expected: tests green; `[zapp] build complete:`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts
git status   # confirm hello-world/zapp.config.ts is CLEAN (temp blocks reverted)
git commit -m "$(cat <<'EOF'
refactor(cli): build injector reads native extras via resolveNative

generatePlatformConfig now sources frameworks/link-flags/sources from
resolveNative(config,target) (the grouped native: block + legacy flat
fields), instead of resolving the three flat fields separately. Both the
new native: API and the deprecated flat fields feed the same injection.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Validate the `native:` block

**Files:**
- Modify: `cli/src/config.ts` (add `validateNative`, call it in `loadConfig` ~793)
- Modify: `cli/src/config.test.ts` (validation tests)

- [ ] **Step 1: Write the failing test**

Append to `cli/src/config.test.ts`:

```ts
import { validateNative } from "./config";

test("validateNative accepts arrays + per-platform maps", () => {
  expect(() => validateNative({ native: { frameworks: ["A"], linkFlags: ["-lx"] } } as any)).not.toThrow();
  expect(() => validateNative({ native: { frameworks: { macos: ["A"], ios: ["B"] } } } as any)).not.toThrow();
  expect(() => validateNative({} as any)).not.toThrow();
});

test("validateNative rejects a non-array / non-map value", () => {
  expect(() => validateNative({ native: { frameworks: "CoreLocation" } } as any)).toThrow(/native\.frameworks/);
});

test("validateNative rejects non-string array entries", () => {
  expect(() => validateNative({ native: { linkFlags: [1, 2] } } as any)).toThrow(/native\.linkFlags/);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/zach/code/zapp/cli && bun test src/config.test.ts`
Expected: FAIL — `validateNative` not exported.

- [ ] **Step 3: Implement `validateNative`**

In `cli/src/config.ts`:

```ts
// Validate the native: block — each of frameworks/linkFlags/sources must be a
// string[] or a per-platform map of string[]. Throws a clear error otherwise.
export function validateNative(config: ZappConfig): void {
  const n = config.native;
  if (!n) return;
  const checkList = (v: unknown, where: string) => {
    if (!Array.isArray(v)) throw new Error(`[zapp] ${where} must be a string[] (got ${typeof v})`);
    for (const item of v) {
      if (typeof item !== "string") throw new Error(`[zapp] ${where} entries must be strings (got ${typeof item})`);
    }
  };
  const checkField = (v: unknown, name: string) => {
    if (v === undefined) return;
    if (Array.isArray(v)) { checkList(v, `native.${name}`); return; }
    if (v && typeof v === "object") {
      // per-platform map: each value is a string[]
      for (const [plat, list] of Object.entries(v as Record<string, unknown>)) {
        checkList(list, `native.${name}.${plat}`);
      }
      return;
    }
    throw new Error(`[zapp] native.${name} must be a string[] or a per-platform map (got ${typeof v})`);
  };
  checkField(n.frameworks, "frameworks");
  checkField(n.linkFlags, "linkFlags");
  checkField(n.sources, "sources");
}
```

Then call it in `loadConfig` (config.ts ~793, alongside `validateWebEngine` / `rejectRemovedEngines`):
```ts
  validateNative(config);
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd /Users/zach/code/zapp/cli && bun test src/config.test.ts`
Expected: PASS (8 total: 5 resolveNative + 3 validateNative). Full suite green too.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/config.ts cli/src/config.test.ts
git commit -m "$(cat <<'EOF'
feat(config): validate the native: block in loadConfig

validateNative ensures native.frameworks/linkFlags/sources are string[]
(or per-platform maps of string[]); a malformed value produces a clear
"[zapp] native.X must be …" error at load time instead of a raw compiler
failure. Wired into loadConfig.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Pure `build.zc` templates + docs

**Files:**
- Modify: `cli/src/init.ts` (the `zapp init` build.zc template) and/or wherever the default `build.zc` is emitted
- Modify: `hello-world/zapp/build.zc` (if it carries legacy platform directives / engine defines)
- Modify: `docs/api-reference.md`, `cli/README.md`

- [ ] **Step 1: Inspect the current templates + hello-world build.zc**

```bash
cat /Users/zach/code/zapp/hello-world/zapp/build.zc
grep -rn "build.zc\|//> \|ZAPP_WORKER_ENGINE\|framework:\|link:" cli/src/init.ts | head -20
```
Identify whether the `zapp init` template and hello-world's `build.zc` emit `//> <platform>: framework:/link:` directives or `ZAPP_WORKER_ENGINE_*` defines. These are now injected (platform defaults via `.zapp/zapp_platform.zc`) / derived (engines from `config.headless`), so the user's `build.zc` should be PURE service code (imports + `app.service.add(...)` + handler fns).

- [ ] **Step 2: Remove platform directives / engine defines from the templates**

If `cli/src/init.ts`'s `build.zc` template (and/or `hello-world/zapp/build.zc`) contains `//> <platform>:` directives or `ZAPP_WORKER_ENGINE_*` defines, remove them — leaving only the service registrations + handler code + necessary imports. Keep any non-platform `//>` the build genuinely needs (e.g. if there's a required base `//> ` that isn't platform boilerplate — verify against a build). If hello-world's `build.zc` is ALREADY pure (no platform directives — the framework injects them), note that and only fix the `init.ts` template if IT emits them. **Do NOT remove the `import` lines or service registrations.**

- [ ] **Step 3: Build verify — a pure build.zc still builds**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1
```
Expected: `[zapp] build complete:` — proving the framework injects all platform boilerplate and the pure `build.zc` is sufficient. If the build now FAILS for a missing framework/flag, that means something the template provided ISN'T injected by the framework — STOP and report which (it may need adding to the injector's platform defaults, a small addition).

If `zapp init` is quick to run, optionally scaffold a throwaway app and confirm its generated `build.zc` is pure + builds:
```bash
cd /tmp && rm -rf _zapp_tmpl_test && bunx @zappdev/cli init _zapp_tmpl_test --template react-ts --no-interactive 2>&1 | tail -3 ; grep -c "//>" /tmp/_zapp_tmpl_test/zapp/build.zc 2>/dev/null || echo "(no build.zc or no directives — good)"; rm -rf /tmp/_zapp_tmpl_test
```
(Skip if `zapp init` pulls the network / is slow / disk-tight — the hello-world build is the authoritative check.)

- [ ] **Step 4: Docs**

In `docs/api-reference.md` (near the Services / build config sections) and `cli/README.md`:
- Document `zapp.config.ts` → `native: { frameworks?: string[]; linkFlags?: string[]; sources?: string[] }` (each also accepts a per-platform map) as the native-linking surface, with a 1-2 line example. Note the old `extraFrameworks`/`extraLinkFlags`/`nativeSources` are deprecated aliases.
- State that `build.zc` is your Zen-C service code — the framework injects platform frameworks/link flags/sysroot and derives engines from `zapp.config.ts`; raw `//> framework:`/`//> link:` directives remain a supported power-user escape hatch.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/init.ts hello-world/zapp/build.zc docs/api-reference.md cli/README.md
git status   # only the files you actually changed
git commit -m "$(cat <<'EOF'
feat(cli,docs): pure build.zc templates + document native: block

zapp init's build.zc template (and hello-world's) carry only service code
— no //> platform directives or engine defines (the framework injects
platform boilerplate and derives engines from zapp.config.ts). Documents
the native:{frameworks,linkFlags,sources} linking surface and that //>
directives remain a power-user escape hatch.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage (Part B):**
- B1 `native: {}` block → Task 2 (type) + Task 3 (wired) + Task 4 (validated). ✓
- B2 `build.zc` pure service code → Task 5 (templates). ✓ (raw `//>` escape hatch retained — confirmed in Task 5 docs + not removed from the injector.)
- B3 framework injects platform defaults + derives engines per target → **already exists** (`generatePlatformConfig` + `generateEngineOverlay`); this plan reuses it (Task 3 routes extras through it). The one missing injector piece — `-lz` — already shipped (`73720b5`). ✓
- B3 eliminate the visible `_zapp_build_ios.zc` twin → Task 1. ✓
- B4 back-compat (legacy flat fields + legacy `//>` directives keep working) → Task 2 (`resolveNative` merges flat) + Task 3 Step 3 (verified) + Task 5 (escape hatch). ✓
- B5 validate `native:` → Task 4. ✓
- Docs → Task 5. ✓

**Placeholder scan:** Task 1 Step 2 / Task 3 Step 1 / Task 5 Step 2 say "read the real names/structure and adapt" — these are deliberate "match existing code" instructions for in-situ specifics (the exact `PlatformValue`/`BuildTarget` names, variable names), each paired with concrete code + a build/test check. The pure functions (`resolveNative`, `validateNative`) and their tests are fully specified. No `TBD`/"handle errors"/"etc."

**Type consistency:** `resolveNative(config, target)` returns `{ frameworks, linkFlags, sources }` — consumed identically in Task 3. `native: { frameworks?, linkFlags?, sources? }` field names match `resolveNative`'s output keys and `validateNative`'s checks. `PlatformValue<string[]>` + `resolvePlatformValue` + `BuildTarget` reused from the existing file (not redefined). `_zapp_build_ios.zc` path change (Task 1) is transparent to consumers that use the returned path (verified in Task 1 Step 3).
