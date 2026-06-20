# zc→nim Cycle 7a — Flip the Default to Nim — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Nim the default native build on every target (`ZAPP_NATIVE_LANG=zc` becomes the opt-out escape hatch), remove the superseded `hello-world` sample, and flip `zapp init` to scaffold Nim-first — leaving the Zen-C layer present but dormant for the separate Cycle 7b.

**Architecture:** A single `useNimNative()` helper (`process.env.ZAPP_NATIVE_LANG !== "zc"`) replaces the two `=== "nim"` env gates so the default can't go inconsistent. hello-world is deleted (kitchen-sink is the showcase + smoke vehicle). `zapp init` stops scaffolding `app.zc`/`build.zc`. Docs flip best-effort (full audit is a later spike). zc sources/emitters/build-path are untouched (7b).

**Tech Stack:** TypeScript (Bun) CLI; bun:test; Nim build (`buildNativeNim`); macOS + iOS-Simulator builds as gates.

**Spec:** `docs/superpowers/specs/2026-06-20-zc-nim-default-flip-design.md`

**Standing constraints:** branch `feat/nim-native` (do NOT merge to main); commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Build/verify commands (reference):**
- CLI tests: `cd /Users/zach/code/zapp && bun test cli/src`
- Type-check: `cd /Users/zach/code/zapp && bun run check`
- macOS build on the **default** (no env var): `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
- iOS-sim build on the default: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios`
- A build is successful ONLY when the final line is `[zapp] build complete: ...` (Vite's `✓ built` is not sufficient).

---

## File Structure

- `cli/src/native-lang.ts` — **new**, single responsibility: the `useNimNative()` gate.
- `cli/src/native-lang.test.ts` — **new**, unit test for the gate.
- `cli/src/native.ts` — modify the build gate (line ~1308) to use `useNimNative()`.
- `cli/src/zapp-cli.ts` — modify the asset-emitter gate (line ~584) to use `useNimNative()`.
- `cli/src/init.ts` — stop scaffolding `app.zc`/`build.zc`; make `app.nim` the documented primary.
- `hello-world/` — **deleted**.
- Live docs (`README.md`, `cli/README.md`, `WINDOWS_PORTING.md`, `SKILLS.md`, `docs/api-reference.md`, `docs/architecture.md`, `docs/nim-migration-roadmap.md`) — hello-world reference sweep + default-flip framing.
- `benchmarks/binary-size-matrix.md` — mark the hello-world Zapp size row stale/pending.

---

## Task 1: `useNimNative()` helper + flip the two env gates (TDD)

**Files:**
- Create: `cli/src/native-lang.ts`
- Create: `cli/src/native-lang.test.ts`
- Modify: `cli/src/native.ts` (~1308)
- Modify: `cli/src/zapp-cli.ts` (~584)

- [ ] **Step 1: Write the failing test**

Create `cli/src/native-lang.test.ts`:

```ts
import { describe, it, expect, afterEach } from "bun:test";
import { useNimNative } from "./native-lang";

describe("useNimNative", () => {
  const orig = process.env.ZAPP_NATIVE_LANG;
  afterEach(() => {
    if (orig === undefined) delete process.env.ZAPP_NATIVE_LANG;
    else process.env.ZAPP_NATIVE_LANG = orig;
  });

  it("defaults to Nim when unset", () => {
    delete process.env.ZAPP_NATIVE_LANG;
    expect(useNimNative()).toBe(true);
  });

  it("opts out to zc when ZAPP_NATIVE_LANG=zc", () => {
    process.env.ZAPP_NATIVE_LANG = "zc";
    expect(useNimNative()).toBe(false);
  });

  it("stays Nim for ZAPP_NATIVE_LANG=nim", () => {
    process.env.ZAPP_NATIVE_LANG = "nim";
    expect(useNimNative()).toBe(true);
  });

  it("stays Nim (fail-open) for any other value", () => {
    process.env.ZAPP_NATIVE_LANG = "rust";
    expect(useNimNative()).toBe(true);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp && bun test cli/src/native-lang.test.ts`
Expected: FAIL — `Cannot find module './native-lang'` (file doesn't exist yet).

- [ ] **Step 3: Create the helper**

Create `cli/src/native-lang.ts`:

```ts
/**
 * Native build language gate.
 *
 * Nim is the DEFAULT native build on every target. `ZAPP_NATIVE_LANG=zc`
 * opts out to the legacy Zen-C build — a transitional escape hatch (e.g. the
 * Windows path until the Nim-Windows sprint lands). Any other value (unset,
 * "nim", anything else) resolves to Nim, so the default is fail-open.
 *
 * This is the single source of truth: every place that chose zc-vs-nim must
 * route through here so the default can never go inconsistent across the
 * build / asset-emitter / dev / package paths.
 */
export function useNimNative(): boolean {
  return process.env.ZAPP_NATIVE_LANG !== "zc";
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp && bun test cli/src/native-lang.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Flip the build gate in `native.ts`**

In `cli/src/native.ts`, add the import near the other local imports at the top of the file:

```ts
import { useNimNative } from "./native-lang";
```

Then replace the gate at ~line 1305-1308. Current:

```ts
  // Opt-in Nim build path. Branches before any zc setup so the Nim driver owns
  // the whole compile; the caller still emits the canonical "build complete"
  // line. The zc path below stays the untouched default.
  if (process.env.ZAPP_NATIVE_LANG === "nim") {
```

Replace with:

```ts
  // Default Nim build path. Branches before any zc setup so the Nim driver owns
  // the whole compile; the caller still emits the canonical "build complete"
  // line. `ZAPP_NATIVE_LANG=zc` opts out to the legacy zc path below.
  if (useNimNative()) {
```

- [ ] **Step 6: Flip the asset-emitter gate in `zapp-cli.ts`**

In `cli/src/zapp-cli.ts`, add the import near the top with the other `./` imports:

```ts
import { useNimNative } from "./native-lang";
```

Then replace the gate at ~line 584. Current:

```ts
  if (process.env.ZAPP_NATIVE_LANG === "nim") {
    clog(1, "embedding assets with brotli (Nim emitter, in native build)...");
  } else {
```

Replace with:

```ts
  if (useNimNative()) {
    clog(1, "embedding assets with brotli (Nim emitter, in native build)...");
  } else {
```

- [ ] **Step 7: Grep-verify no stray functional gate remains**

Run: `cd /Users/zach/code/zapp && grep -rn "ZAPP_NATIVE_LANG" cli/src`
Expected: the only matches are (a) `native-lang.ts` (the helper + its doc comment), (b) `native-lang.test.ts`, and (c) doc-comment mentions in `native.ts`/`init.ts`. There must be **no** remaining `process.env.ZAPP_NATIVE_LANG === "nim"` (or `=== "zc"`) used as a control-flow gate outside `native-lang.ts`. If grep shows any other functional gate, route it through `useNimNative()` too.

- [ ] **Step 8: Run the full CLI test suite + type-check**

Run: `cd /Users/zach/code/zapp && bun test cli/src && bun run check`
Expected: all pass; no type errors.

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/native-lang.ts cli/src/native-lang.test.ts cli/src/native.ts cli/src/zapp-cli.ts
git commit -m "feat(cli): flip native default to Nim via useNimNative() (ZAPP_NATIVE_LANG=zc opts out)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Remove `hello-world` + reference sweep

**Files:**
- Delete: `hello-world/`
- Modify: live docs that reference hello-world (see Step 2)
- Modify: `benchmarks/binary-size-matrix.md`

- [ ] **Step 1: Delete the directory**

Run:
```bash
cd /Users/zach/code/zapp
git rm -r hello-world
```
Expected: git stages the deletion of all `hello-world/**` files.

- [ ] **Step 2: Sweep live references**

Run: `cd /Users/zach/code/zapp && grep -rIln "hello-world" README.md cli/README.md WINDOWS_PORTING.md SKILLS.md docs/api-reference.md docs/architecture.md docs/nim-migration-roadmap.md 2>/dev/null`

For each file that matches, open it and update each `hello-world` reference: if it's a runnable-example reference (e.g. "see `hello-world/`", "`cd hello-world && bun run dev`"), repoint it to `kitchen-sink`; if it's an incidental mention that no longer makes sense, remove that clause. Keep edits minimal and factual — this is best-effort, not a full audit (the full `.md` audit is a separate future spike).

Do NOT touch `docs/superpowers/plans/*` (archival history) or `docs/superpowers/specs/*`.

- [ ] **Step 3: Mark the binary-size benchmark row stale**

In `benchmarks/binary-size-matrix.md`, the apps list (~line 10) and the table (~line 20) reference `hello-world/` as the Zapp size data point. Update the `hello-world` bullet/row to note it's been removed and the Zapp size benchmark is pending rehoming. Replace the bullet at ~line 10 (`- **hello-world** (\`hello-world/\`) — the canonical small-app shape, single...`) with:

```markdown
- **hello-world** — REMOVED 2026-06-20 (superseded by kitchen-sink; the
  default-flip cycle). The Zapp binary-size data point is pending rehoming to
  a `benchmarks/apps/` sample — tracked under the "revisit benchmarks" follow-up.
```

And in the size table, change the `**hello-world today**` row's number cell to `_(pending — sample removed)_` so the matrix isn't silently wrong. Leave the cross-framework rows (electron/tauri/wails/electrobun) and `bench-host-bridge` untouched.

- [ ] **Step 4: Check for stray code-comment references**

Run: `cd /Users/zach/code/zapp && grep -rIn "hello-world" native/nim/zapp.nim native/platform/ios/dialog.m 2>/dev/null`
For any match, if it's a comment referencing hello-world as the example app, update it to `kitchen-sink` or drop the mention. (These are expected to be doc comments, not code.) If there are no matches, skip.

- [ ] **Step 5: Verify nothing references the deleted dir in scripts**

Run: `cd /Users/zach/code/zapp && grep -rIn "hello-world" package.json cli/package.json 2>/dev/null`
Expected: no matches (root + CLI package.json don't reference it). If a match appears, remove that script/line.

- [ ] **Step 6: Type-check + CLI tests still green**

Run: `cd /Users/zach/code/zapp && bun test cli/src && bun run check`
Expected: all pass (removing hello-world + doc edits shouldn't affect either).

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add -A
git commit -m "chore: remove hello-world (superseded by kitchen-sink) + reference sweep

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: `zapp init` scaffolds Nim-first

**Files:**
- Modify: `cli/src/init.ts` (~160-248)

- [ ] **Step 1: Remove the `app.zc` scaffold write**

In `cli/src/init.ts`, delete the entire `await Bun.write(path.join(zappDir, "app.zc"), ...)` block (currently ~lines 164-192, the `import "app/app.zc"; fn greet(...) ... fn run_app() -> int {...}` template).

- [ ] **Step 2: Remove the `build.zc` scaffold write**

Delete the entire `await Bun.write(path.join(zappDir, "build.zc"), ...)` block (currently ~lines 194-211, the `import "app.zc"; fn main() -> int { return run_app(); }` template).

- [ ] **Step 3: Update the `app.nim` scaffold comment to reflect Nim-as-default**

The `app.nim` write block remains. Update its preceding comment (currently ~lines 213-218) and the in-file doc header (currently ~lines 219-223) so they no longer say "opt-in via ZAPP_NATIVE_LANG=nim" / "the default zc build uses app.zc". Replace the comment block at ~213-218 with:

```ts
  // 2b. Add zapp/app.nim — the app's native entry (Nim, the default build).
  // One file, no build.nim (the entry is `quit(runApp())` at top level). Power
  // users link/include native libs here with Nim pragmas ({.passL.},
  // {.compile.}); everyone else drives frameworks/links declaratively via
  // `native:` in zapp.config.ts. (Legacy Zen-C builds are opt-out via
  // ZAPP_NATIVE_LANG=zc and are not scaffolded.)
```

And replace the in-template doc header (the `## Your app's native entry...` through `## string\`, reachable...` lines, ~219-223 inside the template literal) with:

```ts
  await Bun.write(path.join(zappDir, "app.nim"), `## Your app's native entry, authored in Nim — the default native build.
## \`import zapp\` re-exports the app surface (newApp, registerService,
## WindowOptions, createWindow, …). Service handlers are \`proc(args: JsonNode):
## string\`, reachable from the webview via \`Services.invoke("name", …)\`.
import zapp
```

(Leave the rest of the app.nim template body — `proc greet`, `proc onReady`, `proc runApp`, `quit(runApp())` — unchanged.)

- [ ] **Step 4: Grep-verify no zc scaffolding remains in init.ts**

Run: `cd /Users/zach/code/zapp && grep -n "app.zc\|build.zc" cli/src/init.ts`
Expected: **no matches** (both `.zc` writes removed; the only remaining native scaffolds are `app.nim` and `nim.cfg`). If `app/app.zc` or any other `.zc` write appears, remove it too.

- [ ] **Step 5: Type-check**

Run: `cd /Users/zach/code/zapp && bun run check`
Expected: PASS.

- [ ] **Step 6: Init smoke — scaffold a throwaway project and inspect**

Run:
```bash
cd /tmp && rm -rf zapp-init-smoke && mkdir zapp-init-smoke && cd zapp-init-smoke
bun run /Users/zach/code/zapp/cli/src/zapp-cli.ts init . -y --no-install 2>&1 | tail -5
echo "--- zapp/ contents ---"
ls zapp/
```
Expected: `zapp/` contains `app.nim` + `nim.cfg` and **no** `app.zc` / `build.zc`. (If the init command's exact flags differ, adjust per `zapp init --help`; the assertion is the same — Nim entry present, zc entries absent.)

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/init.ts
git commit -m "feat(cli): zapp init scaffolds Nim-first (drop app.zc/build.zc)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Docs flip (best-effort)

**Files:**
- Modify: `README.md`, `cli/README.md`, `docs/architecture.md`, `docs/nim-migration-roadmap.md`, `WINDOWS_PORTING.md`

- [ ] **Step 1: Find the "zc default / Nim opt-in" framing**

Run: `cd /Users/zach/code/zapp && grep -rIn "ZAPP_NATIVE_LANG\|opt-in\|Zen-C\|zc build\|default.*zc\|nim" README.md cli/README.md docs/architecture.md docs/nim-migration-roadmap.md WINDOWS_PORTING.md | grep -iv "node_modules" | head -40`

- [ ] **Step 2: Flip the framing**

For each spot that describes the native build language, update the wording from "zc is the default, Nim is opt-in via `ZAPP_NATIVE_LANG=nim`" to this factual framing (adapt phrasing to each doc's voice; keep it short):

> The native layer builds with **Nim by default** on every platform. The legacy Zen-C build is opt-out via `ZAPP_NATIVE_LANG=zc` — a transitional escape hatch. **Windows-on-Nim is in progress**; until that sprint lands, build Windows with `ZAPP_NATIVE_LANG=zc`.

In `docs/nim-migration-roadmap.md`, also note that the default-flip (gap #7a) has landed and that deleting the zc layer (7b) is gated on the Nim-Windows sprint. Keep this best-effort — do not attempt to fix every stale sentence in these docs (the full `.md` audit is a separate future spike).

- [ ] **Step 3: Type-check (docs don't affect it, but confirm nothing else changed)**

Run: `cd /Users/zach/code/zapp && bun run check`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add README.md cli/README.md docs/architecture.md docs/nim-migration-roadmap.md WINDOWS_PORTING.md
git commit -m "docs: flip framing to Nim-default native build (ZAPP_NATIVE_LANG=zc opt-out)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Full gates + default-path builds + smoke handoff

**Files:** none (verification only)

- [ ] **Step 1: CLI tests + type-check**

Run: `cd /Users/zach/code/zapp && bun test cli/src && bun run check`
Expected: all pass.

- [ ] **Step 2: Build kitchen-sink on the DEFAULT (no env var) — macOS**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -3`
Expected: final line `[zapp] build complete: .../kitchen-sink (… KB)`. (Critically: **no `ZAPP_NATIVE_LANG` set** — this proves Nim is the default.)

- [ ] **Step 3: Build kitchen-sink on the default — iOS Simulator**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios 2>&1 | tail -3`
Expected: final line `[zapp] build complete: .../kitchen-sink.app/kitchen-sink (… KB)`.

- [ ] **Step 4: Confirm the zc escape hatch still works**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=zc bun run build 2>&1 | tail -3`
Expected: final line `[zapp] build complete: ...` (the legacy zc path still builds — the Windows escape hatch is intact). If kitchen-sink's zc build has a pre-existing unrelated break, note it but don't fix it here (zc is dormant/7b).

- [ ] **Step 5: iOS-platform-parity lint**

Run: `cd /Users/zach/code/zapp && bun test cli/src` (already covered in Step 1; the parity test lives there). Confirm green.

- [ ] **Step 6: HUMAN SMOKE (gate)**

Hand to the user. On macOS, **with no env var**: `cd /Users/zach/code/zapp/kitchen-sink && bun run dev` → the window opens, `greet` works, sidebar + inspector work (proving Nim is the default end-to-end). Optionally confirm a fresh `zapp init` project builds on the default. Record the kitchen-sink default binary size for the (pending) benchmark rehome.

---

## Final review

- [ ] After smoke passes, dispatch a code-reviewer over the cycle diff (`git log` for this cycle) checking: every `ZAPP_NATIVE_LANG` functional read routes through `useNimNative()` (no stragglers); hello-world fully removed with no dangling references in live docs/scripts; init scaffolds Nim-only (no `.zc`); the zc build path + zc emitters + `.zc` sources are **untouched** (that's 7b); commit trailer correct on all commits.

---

## Self-review notes (plan author)

- **Spec coverage:** §1 (flip)→Task 1; §2 (remove hello-world)→Task 2; §3 (init Nim-first)→Task 3; §4 (docs flip)→Task 4; testing/gates→Task 5; non-goals (delete zc / Windows-on-Nim / benchmark rehome / SwiftUI) are explicitly out and asserted untouched in the Final review. All spec sections map.
- **Placeholder scan:** none — every code step shows exact before/after; doc steps give the exact framing sentence + grep-driven targets (doc prose is inherently find/replace, not a single code block).
- **Type/name consistency:** `useNimNative()` defined in Task 1 Step 3, used identically in Steps 5–6 and referenced in Task 5 / Final review. Semantics fixed: `!== "zc"` → Nim (unset/"nim"/other = Nim; only "zc" opts out).
- **Known soft spots (explicit verify-steps, not placeholders):** the grep-verify in Task 1 Step 7 (catch any env read the plan didn't enumerate — only 2 are known), Task 3 Step 4 (catch any other `.zc` scaffold write), and Task 2 Step 4/5 (stray comment/script refs). Each says exactly what to check and the fix.
