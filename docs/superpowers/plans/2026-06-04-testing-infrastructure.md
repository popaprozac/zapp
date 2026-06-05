# Testing Infrastructure (First Slice) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a unified test entrypoint, a TS pure-logic proof batch, and a native Zen-C test runner (with a proof test) — locking in *how* each layer is tested.

**Architecture:** A root `package.json` with `test`/`test:native`/`test:all` scripts; `bun:test` for the TS layer (co-located `*.test.ts`); a `cli/src/test-native.ts` runner that `zc run`s `native/tests/*_test.zc` and gates on the exit code (Zen-C exits with the failure count). macOS/ObjC remain build+smoke. The `tsc` gate is backlogged.

**Tech Stack:** Bun (`bun:test`, `Bun.Glob`, `Bun.which`, `Bun.spawnSync`), TypeScript, Zen-C (`test "…" { assert }` / `zc run`).

**Branch:** `feat/testing-infrastructure` (created, spec committed).

**Spec:** `docs/superpowers/specs/2026-06-04-testing-infrastructure-design.md`

**Conventions:**
- Stage ONLY the files each task names. Never `git add -A`. Never stage `vendor/*`, `native/worker/engines/zjs-cross-eval-test.c`, `hello-world/*`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Transient `bun test` `EMFILE`/`Cannot find module` = fd exhaustion; re-run fresh (`ulimit -n 4096`).
- Note: the explorer's `toIdent` candidate does NOT exist and the `service-types.ts` functions are already tested — this plan uses real untested helpers instead.

---

## Task 1: Root test entrypoint

**Files:**
- Create: `package.json` (repo root — none exists today)

- [ ] **Step 1: Create the root `package.json`**

```json
{
  "name": "zapp-monorepo",
  "private": true,
  "scripts": {
    "test": "bun test cli/src runtime",
    "test:native": "bun run cli/src/test-native.ts",
    "test:all": "bun run test && bun run test:native"
  }
}
```
(`test:native` points at the runner created in Task 3 — the script string existing first is fine.)

- [ ] **Step 2: Verify the TS entrypoint runs green**

Run: `cd /Users/zach/code/zapp && bun run test 2>&1 | tail -4`
Expected: the existing suite passes (≈42 tests across `cli/src` + `runtime`), with NO `vendor/`/EMFILE error (the explicit dirs scope the scan).

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add package.json
git commit -m "$(cat <<'EOF'
chore(test): root package.json test entrypoint

`bun run test` runs cli/src + runtime (explicit dirs avoid the vendor/
scan + EMFILE that breaks bare `bun test`). test:native / test:all wired
for the native runner (next).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: TS pure-logic proof batch (TDD)

**Files:**
- Create: `cli/src/native.test.ts`
- Create: `cli/src/workers.test.ts`
- Create: `cli/src/entitlements.test.ts`
- Modify: `cli/src/workers.ts` (export `WORKER_PATTERN`)
- Modify: `cli/src/entitlements.ts` (export `xmlEscape`, `renderValue`)

- [ ] **Step 1: Write `native.test.ts`** (`detectTarget`/`isIOSTarget` are already exported)

Create `cli/src/native.test.ts`:
```ts
import { test, expect } from "bun:test";
import { detectTarget, isIOSTarget } from "./native";

test("detectTarget: --platform ios → ios-simulator", () => {
  expect(detectTarget(["--platform", "ios"])).toBe("ios-simulator");
});
test("detectTarget: --platform ios-simulator", () => {
  expect(detectTarget(["--platform", "ios-simulator"])).toBe("ios-simulator");
});
test("detectTarget: --platform ios-device", () => {
  expect(detectTarget(["--platform", "ios-device"])).toBe("ios-device");
});
test("detectTarget: --platform macos", () => {
  expect(detectTarget(["--platform", "macos"])).toBe("macos");
});
test("detectTarget: unknown --platform throws", () => {
  expect(() => detectTarget(["--platform", "bogus"])).toThrow();
});
test("isIOSTarget classifies the iOS variants", () => {
  expect(isIOSTarget("ios-simulator")).toBe(true);
  expect(isIOSTarget("ios-device")).toBe(true);
  expect(isIOSTarget("macos")).toBe(false);
  expect(isIOSTarget("windows")).toBe(false);
});
```

- [ ] **Step 2: Run native.test.ts — expect PASS** (the functions already exist)

Run: `cd /Users/zach/code/zapp && bun test ./cli/src/native.test.ts`
Expected: PASS. (If importing `./native` throws due to a top-level side effect, report it — but it's a plain CLI module imported elsewhere, so it should load.)

- [ ] **Step 3: Export `WORKER_PATTERN` + write `workers.test.ts`**

In `cli/src/workers.ts`, change `const WORKER_PATTERN =` (line ~8) to `export const WORKER_PATTERN =`.

Create `cli/src/workers.test.ts`:
```ts
import { test, expect } from "bun:test";
import { WORKER_PATTERN } from "./workers";

// Mirror how workers.ts consumes the regex: reset lastIndex, exec, take group 1 (the
// `new URL(...)` form) or group 2 (the bare-string form).
function firstWorkerSpec(src: string): string | null {
  WORKER_PATTERN.lastIndex = 0;
  const m = WORKER_PATTERN.exec(src);
  return m ? (m[1] ?? m[2] ?? null) : null;
}

test("matches new Worker(\"./w.ts\")", () => {
  expect(firstWorkerSpec(`new Worker("./w.ts")`)).toBe("./w.ts");
});
test("matches single-quoted specifier", () => {
  expect(firstWorkerSpec(`new Worker('./a/b.ts')`)).toBe("./a/b.ts");
});
test("matches new URL(..., import.meta.url) form", () => {
  expect(firstWorkerSpec(`new Worker(new URL("./w.ts", import.meta.url))`)).toBe("./w.ts");
});
test("matches SharedWorker", () => {
  expect(firstWorkerSpec(`new SharedWorker("./s.ts")`)).toBe("./s.ts");
});
test("does not match unrelated constructors", () => {
  expect(firstWorkerSpec(`const x = new Foo("y")`)).toBeNull();
});
```

- [ ] **Step 4: Run workers.test.ts — verify pass**

Run: `bun test ./cli/src/workers.test.ts`
Expected: 5 pass. (If a case fails, the regex's real group layout differs — adjust the test to the actual `match[1]/match[2]` semantics used in `workers.ts`, i.e. make the test characterize the real behavior; do NOT change the regex.)

- [ ] **Step 5: Export the entitlements helpers + write `entitlements.test.ts`**

In `cli/src/entitlements.ts`: change `function xmlEscape(` (line ~18) to `export function xmlEscape(`, and `function renderValue(` (line ~25) to `export function renderValue(`. **Read both function bodies first** so the assertions below match the real output.

Create `cli/src/entitlements.test.ts`:
```ts
import { test, expect } from "bun:test";
import { xmlEscape, renderValue } from "./entitlements";

test("xmlEscape escapes the XML-mandatory characters", () => {
  // & < > are non-negotiable for valid XML/plist.
  expect(xmlEscape("a & b")).toContain("&amp;");
  expect(xmlEscape("x < y")).toContain("&lt;");
  expect(xmlEscape("x > y")).toContain("&gt;");
  expect(xmlEscape("plain")).toBe("plain");
});
test("renderValue: string → <string> with escaped content", () => {
  const out = renderValue("a&b");
  expect(out).toContain("<string>");
  expect(out).toContain("&amp;");
});
test("renderValue: string[] → <string> entries for each item", () => {
  const out = renderValue(["one", "two"]);
  expect(out).toContain("one");
  expect(out).toContain("two");
});
```
After reading the bodies, ADD assertions for the remaining `renderValue` branches (`number` and `boolean`) using their actual output (e.g. plist `<integer>` / `<true/>`/`<false/>`), and tighten the `xmlEscape` quote handling to whatever the body does. Keep every assertion matching the real implementation (characterization).

- [ ] **Step 6: Run the whole new batch + the existing CLI suite**

Run: `bun test ./cli/src/native.test.ts ./cli/src/workers.test.ts ./cli/src/entitlements.test.ts` then `bun run test`
Expected: the 3 new files pass; `bun run test` stays green overall.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/native.test.ts cli/src/workers.test.ts cli/src/workers.ts cli/src/entitlements.test.ts cli/src/entitlements.ts
git commit -m "$(cat <<'EOF'
test(cli): pure-logic batch — detectTarget/isIOSTarget, WORKER_PATTERN, xmlEscape

Characterization tests for previously-untested pure helpers; export
WORKER_PATTERN + xmlEscape/renderValue for testability. No behavior change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Native Zen-C test runner + proof

**Files:**
- Create: `cli/src/test-native.ts`
- Create: `native/tests/json_safe_test.zc`
- Modify: `package.json` (already has the scripts from Task 1 — no change needed; just confirm `test:native`/`test:all` point correctly)

- [ ] **Step 1: Write the proof test `native/tests/json_safe_test.zc`**

```zc
// Native unit tests for the heap JSON parser (native/bridge/json_safe.zc).
// Run via `zc run` (the cli/src/test-native.ts runner does this).
import "../bridge/json_safe.zc";

test "parses an object with an int and a string field" {
    let r = zapp_json_parse("{\"t\":1,\"m\":\"greet\"}");
    assert(!r.is_err(), "valid object should parse");
    let j = r.unwrap();
    let t = j.get_int("t");
    assert(t.is_some() && t.unwrap() == 1, "t should be 1");
    let m = j.get_string("m");
    assert(m.is_some() && m.unwrap() == "greet", "m should be 'greet'");
}

test "reports an error on malformed JSON" {
    let r = zapp_json_parse("{not valid json");
    assert(r.is_err(), "malformed input should error");
}
```

- [ ] **Step 2: Verify the proof runs with `zc run`**

Run: `cd /Users/zach/code/zapp && $(command -v zc || echo zc) run native/tests/json_safe_test.zc 2>&1 | tail -8; echo "exit=$?"`
Expected: `TEST: parses an object … OK`, `TEST: reports an error … OK`, `0 test(s) failed`, and the process exit is 0.
If `zc run` reports an unresolved import or link error, the fix is one of: (a) run from repo root (relative `../bridge/json_safe.zc` resolves there) — already the case; (b) add an include path `zc run -I native native/tests/json_safe_test.zc` if `json_safe.zc`'s own imports need it; (c) adjust the `JsonValue` accessor calls (`get_int`/`get_string`/`is_some`/`unwrap`) to match `std/json`'s real API by reading how `native/bridge/protocol.zc` uses the parse result. Make it green before continuing.

- [ ] **Step 3: Write the runner `cli/src/test-native.ts`**

```ts
// Runs Zen-C native unit tests (`test "..." { assert }` blocks) by invoking
// `zc run` on each native/tests/*_test.zc. Zen-C exits with the failure
// count (0 = all passed); we aggregate and exit non-zero if any file fails.
import { Glob } from "bun";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "..", ".."); // cli/src -> repo root
const zc = Bun.which("zc") ?? "zc";

const files = [...new Glob("native/tests/*_test.zc").scanSync({ cwd: ROOT })].sort();

if (files.length === 0) {
  console.log("[zapp] no native tests found (native/tests/*_test.zc)");
  process.exit(0);
}

let failed = 0;
for (const rel of files) {
  const proc = Bun.spawnSync([zc, "run", rel], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  const out =
    new TextDecoder().decode(proc.stdout) + new TextDecoder().decode(proc.stderr);
  const ok = proc.exitCode === 0;
  console.log(`${ok ? "PASS" : "FAIL"}  ${rel}`);
  if (!ok) {
    failed++;
    for (const line of out.split("\n")) {
      if (/TEST:|FAIL|error|failed/i.test(line)) console.log("    " + line.trimEnd());
    }
  }
}

console.log(`\n${failed === 0 ? "all native tests passed" : `${failed} native test file(s) failed`}`);
process.exit(failed === 0 ? 0 : 1);
```

- [ ] **Step 4: Run the runner — expect green**

Run: `cd /Users/zach/code/zapp && bun run test:native 2>&1 | tail -6; echo "exit=$?"`
Expected: `PASS  native/tests/json_safe_test.zc`, `all native tests passed`, exit 0.

- [ ] **Step 5: Prove the gate bites (red-on-break)**

Temporarily edit `native/tests/json_safe_test.zc` — change `t.unwrap() == 1` to `t.unwrap() == 999`. Run `bun run test:native; echo "exit=$?"` → expect `FAIL  native/tests/json_safe_test.zc` + a non-zero exit. Then **revert** the change (`git checkout native/tests/json_safe_test.zc`) and re-run → green. Confirm `git diff native/tests/json_safe_test.zc` is empty.

- [ ] **Step 6: Confirm `test:all` + the production build are unaffected**

Run:
```bash
cd /Users/zach/code/zapp && bun run test:all 2>&1 | tail -6
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1
```
Expected: `test:all` runs the TS suite then the native runner, both green; `[zapp] build complete: …` (the `native/tests/` file is not in the build's import graph, so the binary is unchanged).

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/test-native.ts native/tests/json_safe_test.zc
git commit -m "$(cat <<'EOF'
test(native): Zen-C test runner + json_safe proof

cli/src/test-native.ts runs native/tests/*_test.zc via `zc run` and gates
on the exit code (Zen-C exits with the failure count). json_safe_test.zc
exercises zapp_json_parse; proven red-on-break. Not in the build graph.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Docs

**Files:**
- Modify: `docs/architecture.md` (extend the "Verifying native changes" section)

- [ ] **Step 1: Add a "Running the tests" subsection**

In `docs/architecture.md`, in/after the "Verifying native changes" section (added in #281), insert:

```markdown
### Running the tests

- **`bun run test`** — the TypeScript suite (`cli/src` + `runtime`, via `bun:test`). TS tests live in `*.test.ts` next to the module they cover.
- **`bun run test:native`** — the native Zen-C tests. Each `native/tests/*_test.zc` uses Zen-C's built-in framework — `test "name" { assert(cond, msg); expect(cond, msg); }` — and is run via `zc run` (the binary exits with the failure count). Only pure-logic `.zc` (no Cocoa/UIKit) is unit-testable this way; platform `.m` code is build + manual smoke.
- **`bun run test:all`** — both.

Run `bun run test:all` before merging changes that touch `cli/`, `runtime/`, or pure-logic `native/` code. (ObjC `.m` and broader native behavior still rely on the build + the ios-simulator build + manual smoke described above.)
```

- [ ] **Step 2: Verify markdown + commit**

```bash
cd /Users/zach/code/zapp && grep -c '```' docs/architecture.md   # even (balanced fences)
git add docs/architecture.md
git commit -m "$(cat <<'EOF'
docs(architecture): document the test entrypoints (test / test:native / test:all)

How to run the TS (bun:test) and native Zen-C (test "..." { assert } via
zc run) suites, where tests live, and what's unit-testable vs smoke-only.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- §1 entrypoint (root package.json, explicit dirs) → Task 1. ✅
- §2 TS proof batch → Task 2 (detectTarget/isIOSTarget, WORKER_PATTERN, xmlEscape/renderValue — real untested helpers; `toIdent` dropped as nonexistent). ✅
- §3 native runner + `native/tests/` + json_safe proof + red-on-break → Task 3. ✅
- §4 docs → Task 4. ✅
- §5 backlog → in the spec (no task; it's the recommendation output). ✅ Memory update = controller-side at finish.
- Verification (`bun run test`/`test:native`/`test:all`, build unaffected) → Tasks 1/3. ✅
- Non-goals (no tsc gate, no bunfig, no ObjC tests, no `.zc` extraction) → respected. ✅

**Placeholder scan:** No TBD. The two "read the body / adjust to real behavior" notes (entitlements assertions, JsonValue accessor names) are inherent to characterization tests against existing code — each names the exact file to read and gives concrete starter assertions, not a vague "add tests."

**Type/name consistency:** `WORKER_PATTERN`, `xmlEscape`/`renderValue`, `detectTarget`/`isIOSTarget`, `zapp_json_parse`, the runner path `cli/src/test-native.ts`, the test dir `native/tests/`, and the scripts `test`/`test:native`/`test:all` are consistent across Tasks 1–4. The runner's `Bun.Glob("native/tests/*_test.zc")` matches the proof file's location.
