# Safe native→JavaScript transport (finding #2, P0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No externally-controlled data can break out of the JS string context the native layer builds — every native→JS delivery routes through one dependency-free C encoder producing a provably-safe JS string literal, guarded by a lint rule.

**Architecture:** One C encoder (`native/shared/jslit.c` `zapp_js_lit_dup`) emits a complete double-quoted JS string literal (JSON-escaping + `U+2028`/`U+2029`). A Nim wrapper `jsLit` uses it on main-thread paths; the two worker-pthread paths call the C function directly (libc, gcsafe). All 7 call sites migrate; the three ad-hoc escapers are deleted. An adversarial `bun:ffi` test evals the real generated IIFE against a stub bridge; a lint test blocks future raw interpolation.

**Tech Stack:** C (`native/shared/`), Nim (`native/nim/`), Bun test + `bun:ffi`.

## Global Constraints

- **The encoder is the single source of truth** — no second escaper. `jsLit` (Nim) and the worker paths BOTH call the one C function `zapp_js_lit_dup`; do not reimplement the encoding in Nim.
- **Preserve each call site's current allocation model** — sites that build a Nim string (`&` concat) use `jsLit(s): string`; sites that use libc (`c_malloc`/`c_snprintf`, worker-pthread, gcsafe) call `zapp_js_lit_dup` directly and `c_free` each buffer. Do NOT introduce Nim GC allocation onto a gcsafe worker path.
- **Opaque payloads** — encode the payload string as-is; never parse + re-serialize its JSON. The literal carries its own quotes, so drop the manual `'…'` at every site.
- **Verification = our velocity gates** (NOT the full CI matrix, which is finding #8): `bun run check`, `bun run test` (incl. the new adversarial + lint tests), macOS Nim build (kitchen-sink WK + cef-hello CEF), human R0 smoke. Native tests run via `bun run test:native` (`nim r`).
- **Branch:** `feat/safe-js-transport` off `main @ bef5cc3`. NO merge without ask. Inclusive language. `rm -rf ~/.cache/nim/app_r` before a chromium build.

---

### Task 1: The encoder + binding + the adversarial security gate

**Files:**
- Create: `native/shared/jslit.c`, `native/shared/jslit.h`
- Create: `native/nim/jslit.nim`
- Modify: `native/nim/zapp.nim` (compile the .c)
- Create: `cli/src/jslit-transport.test.ts` (the adversarial `bun:ffi` gate)

**Interfaces:**
- Produces: `char* zapp_js_lit_dup(const char* utf8)` (C; malloc'd complete JS string literal, caller frees; NULL only on malloc failure); `proc jsLit*(s: string): string` (Nim; main-thread wrapper).

- [ ] **Step 1: Write the adversarial test FIRST (it fails — no encoder yet)**

`cli/src/jslit-transport.test.ts` — compile the C standalone, `bun:ffi` it, eval the REAL generated IIFE against a stub bridge:
```ts
import { test, expect, beforeAll } from "bun:test";
import { dlopen, FFIType, suffix, CString } from "bun:ffi";
import { $ } from "bun";

let encode: (s: string) => string;

beforeAll(async () => {
  const lib = `${process.env.TMPDIR ?? "/tmp"}/libjslit_test.${suffix}`;
  await $`cc -shared -fPIC -O2 -o ${lib} native/shared/jslit.c`.quiet();
  const { symbols } = dlopen(lib, {
    zapp_js_lit_dup: { args: [FFIType.cstring], returns: FFIType.ptr },
  });
  encode = (s: string) => {
    const buf = Buffer.from(s + "\0", "utf8");           // NUL-terminated C string in
    const ptr = symbols.zapp_js_lit_dup(buf);
    if (!ptr) throw new Error("encoder returned NULL");
    return new CString(ptr).toString();                  // read the complete literal
  };
});

// Build the ACTUAL native IIFE and eval it against a stub bridge; assert the
// payload round-trips exactly and NO injected side effect fired.
function deliverAndRecover(input: string): { recovered: string | undefined; compromised: boolean } {
  const litName = encode("evt:test");
  const litPayload = encode(input);                      // literals include their own quotes
  const iife =
    `(function(){var b=globalThis[Symbol.for('zapp.bridge')];` +
    `if(b&&b._onEvent)b._onEvent(${litName},${litPayload});})()`;
  let recovered: string | undefined;
  (globalThis as any)[Symbol.for("zapp.bridge")] = { _onEvent: (_n: string, p: string) => { recovered = p; } };
  (globalThis as any).__compromised = false;
  // eslint-disable-next-line no-eval
  (0, eval)(iife);
  return { recovered, compromised: (globalThis as any).__compromised === true };
}

const ADVERSARIAL = [
  "plain", "a'b", 'a"b', "a\\b", "line1\nline2", "cr\rhere", "tab\there",
  " sep", "para graph", "');globalThis.__compromised=true;//",
  '"});globalThis.__compromised=true;({"', "zapp://open?u='+({}).constructor",
  "Notification: it's here —   done", "not json at all { [ ", "\uD800lone-surrogate",
  "x".repeat(4096),
];

test.each(ADVERSARIAL)("round-trips exactly + no side effect: %j", (input) => {
  const { recovered, compromised } = deliverAndRecover(input);
  expect(compromised).toBe(false);
  expect(recovered).toBe(input);
});
```
Run: `bun test cli/src/jslit-transport.test.ts` → **FAILS** (`native/shared/jslit.c` doesn't exist / compile error). That's the red state.

- [ ] **Step 2: Implement `native/shared/jslit.c` + `.h`**

`native/shared/jslit.h`:
```c
#ifndef ZAPP_JSLIT_H
#define ZAPP_JSLIT_H
/* Encode a UTF-8 C string as a COMPLETE double-quoted JavaScript string literal
 * (quotes included) that evals back to exactly the input. malloc'd; caller
 * free()s. NULL only on malloc failure. Never fails on content. */
char* zapp_js_lit_dup(const char* utf8);
#endif
```
`native/shared/jslit.c`:
```c
#include "jslit.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

char* zapp_js_lit_dup(const char* utf8) {
  if (utf8 == NULL) utf8 = "";
  size_t n = strlen(utf8);
  /* worst case: every byte -> \u00XX (6) ; + 2 quotes + NUL */
  char* out = (char*)malloc(n * 6 + 3);
  if (out == NULL) return NULL;
  size_t j = 0;
  out[j++] = '"';
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)utf8[i];
    switch (c) {
      case '"':  out[j++]='\\'; out[j++]='"';  break;
      case '\\': out[j++]='\\'; out[j++]='\\'; break;
      case '\b': out[j++]='\\'; out[j++]='b';  break;
      case '\f': out[j++]='\\'; out[j++]='f';  break;
      case '\n': out[j++]='\\'; out[j++]='n';  break;
      case '\r': out[j++]='\\'; out[j++]='r';  break;
      case '\t': out[j++]='\\'; out[j++]='t';  break;
      default:
        if (c < 0x20) {
          out[j++]='\\'; out[j++]='u'; out[j++]='0'; out[j++]='0';
          static const char* hex = "0123456789abcdef";
          out[j++] = hex[(c >> 4) & 0xF];
          out[j++] = hex[c & 0xF];
        } else if (c == 0xE2 && i + 2 < n &&
                   (unsigned char)utf8[i+1] == 0x80 &&
                   ((unsigned char)utf8[i+2] == 0xA8 || (unsigned char)utf8[i+2] == 0xA9)) {
          /* U+2028 (E2 80 A8) / U+2029 (E2 80 A9) — legal in JSON, ILLEGAL raw in a JS string */
          const char* esc = ((unsigned char)utf8[i+2] == 0xA8) ? "\\u2028" : "\\u2029";
          memcpy(out + j, esc, 6); j += 6; i += 2;
        } else {
          out[j++] = (char)c;  /* pass UTF-8 through verbatim */
        }
    }
  }
  out[j++] = '"';
  out[j]   = '\0';
  return out;
}
```

- [ ] **Step 3: Nim binding `native/nim/jslit.nim` + wire the compile**

`native/nim/jslit.nim`:
```nim
## The ONE safe native->JS literal encoder (native/shared/jslit.c). Every path
## that embeds data into a JS string routes through this — see the lint guard.
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
proc zapp_js_lit_dup*(utf8: cstring): cstring {.importc, cdecl.}
  ## Complete double-quoted JS string literal; caller frees. Worker-pthread
  ## paths call this DIRECTLY (libc/gcsafe). NULL only on malloc failure.

proc jsLit*(s: string): string =
  ## Main-thread convenience wrapper — calls the ONE C encoder, no reimplementation.
  let c = zapp_js_lit_dup(s.cstring)
  if c == nil: return "\"\""          # OOM -> empty literal (still safe, never raw)
  result = $c
  c_free(c)
```
In `native/nim/zapp.nim`, add to the `{.compile.}` region (near the zjs.c line ~184; call-form, no special flags — dependency-free C):
```nim
{.compile("../shared/jslit.c").}
```

- [ ] **Step 4: Native encoder unit test** (`native/nim/tests/jslit_test.nim`)

Compile the C into the test and assert the escapes + a `std/json` round-trip (a valid JS literal here is also valid JSON, so `parseJson` recovers the exact string — proves well-formedness of the non-`U+2028` cases; the `bun:ffi` test covers the JS-eval-specific `U+2028`/`U+2029`):
```nim
{.compile("../../shared/jslit.c").}
import std/json
proc zapp_js_lit_dup(utf8: cstring): cstring {.importc, cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
proc lit(s: string): string =
  let c = zapp_js_lit_dup(s.cstring); result = $c; c_free(c)

doAssert lit("a'b") == "\"a'b\""
doAssert lit("a\"b") == "\"a\\\"b\""
doAssert lit("a\\b") == "\"a\\\\b\""
doAssert lit("x\ny") == "\"x\\ny\""
for s in ["plain", "a'b", "a\"b", "a\\b", "x\ny\tz", "');x//", "  spaces  "]:
  doAssert parseJson(lit(s)).getStr == s   # round-trips through JSON == exact input
echo "jslit_test OK"
```

- [ ] **Step 5: Green + build + commit**

```bash
bun test cli/src/jslit-transport.test.ts          # all adversarial cases PASS
bun run test:native                                # jslit_test OK + others
bun run check
```
Then a macOS build to confirm the compile wiring links (`cd kitchen-sink && rm -rf ~/.cache/nim/app_r && bun run build` → `build complete`). Commit:
```bash
git add native/shared/jslit.c native/shared/jslit.h native/nim/jslit.nim native/nim/zapp.nim \
        cli/src/jslit-transport.test.ts native/nim/tests/jslit_test.nim
git commit -m "feat(security): one safe native->JS literal encoder + adversarial gate (finding #2)"
```

---

### Task 2: Migrate all 7 call sites; delete the three escapers

**Files:** Modify `native/nim/app_events.nim`, `dispatch.nim`, `bridge.nim`, `worker_service.nim`, `worker.nim`, `callbacks.nim`.

**Interfaces:** Consumes `jsLit`/`zapp_js_lit_dup` from Task 1. `import jslit` where a Nim path uses `jsLit`.

- [ ] **Step 1: Main-thread Nim-string sites → `jsLit` (drop manual quotes)**

`app_events.nim` — Layer 2 (:94-96) and Layer 3 (:107), both raw today:
```nim
# Layer 2 (worker):
    let wjs = "(function(){var b=self.__zappBridge||globalThis.__zappBridge;" &
              "if(b&&b._dispatchAppEvent)b._dispatchAppEvent(" & $eventId &
              "," & jsLit(safeData) & ");})();"      # was: ,'" & safeData & "'
# Layer 3 (webview):
      let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
               "if(b&&b._onEvent)b._onEvent(" & jsLit(name) & "," & jsLit(safe) & ");})();"
```
`dispatch.nim` `dispatch_event_to_all` (:64-65): `b._onEvent(" & jsLit(name) & "," & jsLit(pl) & ");` — where `name`/`pl` are now the RAW `$eventName`/`$payload` (drop the `escapeJs(...)` calls). `bridge.nim` (:63-64): `b._onInvokeResult(" & $requestId & "," & okLit & "," & jsLit(payload) & ");`. `callbacks.nim` (:112): the payload is a hand-built all-integer JSON string `winPayload`; wrap it `... & jsLit(winPayload) & ...` and keep the fixed event-name a literal `"window:event"` → `jsLit("window:event")` (so the lint guard has no exception).

- [ ] **Step 2: Worker-pthread libc sites → `zapp_js_lit_dup` directly (gcsafe)**

`worker.nim` (`dispatchToWindow`, ~:134-160): replace the two `zapp_escape_dup` calls with `zapp_js_lit_dup`, and change the template's `'%s','%s'` → `%s,%s` (literals carry quotes). The `c_free(escWid)`/`c_free(escData)`/`c_free(js)` stay. `worker_service.nim` (:92-93): this path builds a Nim string (`&` concat) with `escapeJsSingleQuoted` — it's the Nim-string model, so use `jsLit(payload)` (import jslit) and drop the manual `'…'`: `... & $reqId.int & "," & (if ok:"true" else:"false") & "," & jsLit(payload) & ");}})();"`. (Confirm this path is not on a stricter gcsafe boundary than its current Nim-string use implies; if a compile error surfaces `jsLit` as GC-unsafe there, switch that one site to `zapp_js_lit_dup` + libc buffer like worker.nim.)

- [ ] **Step 3: Delete the three escapers**

Remove `proc escapeJs*` (dispatch.nim), `proc escapeJsSingleQuoted*` (bridge.nim), and the `zapp_escape_dup` importc + all its uses (worker.nim). Grep to confirm zero remaining references: `grep -rn "escapeJs\b\|escapeJsSingleQuoted\|zapp_escape_dup" native/nim/*.nim` → only comments/history, no live calls.

- [ ] **Step 4: Green + build + commit**

```bash
bun run check && bun run test && bun run test:native
```
Expected: the Task-1 adversarial test still green; the `dispatch_test.nim`/`callbacks_test.nim` still pass (update any that asserted the OLD escaped output — they should now assert the `jsLit` output; a valid parity improvement, not a regression). Then `cd kitchen-sink && rm -rf ~/.cache/nim/app_r && bun run build` and `cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build` — both `build complete`. Commit:
```bash
git add native/nim/app_events.nim native/nim/dispatch.nim native/nim/bridge.nim \
        native/nim/worker_service.nim native/nim/worker.nim native/nim/callbacks.nim
git commit -m "feat(security): route all 7 native->JS sites through jsLit; delete 3 escapers (finding #2)"
```

---

### Task 3: Lint guard + docs + R0

**Files:** Create `cli/src/js-transport-lint.test.ts`; modify a docs file (spec close / FINDINGS-style note).

- [ ] **Step 1: The lint guard test**

`cli/src/js-transport-lint.test.ts` — read every `native/nim/*.nim` (except `jslit.nim` + tests), and FAIL if a line constructs a dynamic `_onEvent(` / `_dispatchAppEvent(` / `_onInvokeResult(` / `_onWorkerMessage(` / `_dispatchAppEvent(` / `_resolveInvoke(` call whose interpolated argument (a `&`-built or `%s` slot fed by anything other than an integer literal) is NOT produced by `jsLit(` or `zapp_js_lit_dup(`. Concretely: flag any line matching one of those call tokens that also contains a `& ` string interpolation but does NOT contain `jsLit(` or `zapp_js_lit_dup(`.
```ts
import { test, expect } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
test("no raw interpolation into native->JS delivery calls", () => {
  const dir = "native/nim";
  const encoderOk = /jsLit\(|zapp_js_lit_dup\(/;
  const calls = /(_onEvent|_dispatchAppEvent|_onInvokeResult|_onWorkerMessage|_resolveInvoke)\s*\(/;
  const offenders: string[] = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".nim") || f === "jslit.nim") continue;
    readFileSync(`${dir}/${f}`, "utf8").split("\n").forEach((line, i) => {
      if (calls.test(line) && line.includes("& ") && !encoderOk.test(line)) {
        // allow the all-integer window-event JSON builder only if it has NO string interpolation of external data
        offenders.push(`${f}:${i + 1}: ${line.trim()}`);
      }
    });
  }
  expect(offenders, offenders.join("\n")).toEqual([]);
});
```
Run: `bun test cli/src/js-transport-lint.test.ts` → PASS (after Task 2). If a legitimate all-integer builder trips it, refactor that line to route its final string through `jsLit` (Task 2 Step 1 already did this for `callbacks.nim`) so the rule needs no exceptions.

- [ ] **Step 2: Docs**

Add a short section to `docs/superpowers/specs/2026-07-13-safe-js-transport-design.md` (or a FINDINGS-style note) recording: shipped — one encoder (`native/shared/jslit.c`), all 7 sites migrated, 3 escapers deleted, lint guard live; the adversarial matrix is the gate; approach (b) structured messaging remains the future follow-up.

- [ ] **Step 3: Full green + commit**

```bash
bun run check && bun run test && bun run test:native
```
Commit:
```bash
git add cli/src/js-transport-lint.test.ts docs/superpowers/specs/2026-07-13-safe-js-transport-design.md
git commit -m "test(security): lint guard vs raw native->JS interpolation + docs (finding #2)"
```

- [ ] **Step 4: Human R0 smoke** (controller runs WITH the user)

On a built app, deliver an externally-controlled value containing an apostrophe (and ideally `U+2028`) through each channel and confirm it arrives INTACT (not truncated, no console syntax error, no side effect):
- a **deep-link** URL with an apostrophe (app event → worker + webview),
- a **notification** body/title with an apostrophe (invoke/callback path),
- a **worker message** whose data contains `');x//` (worker→webview delivery).
Each should display the literal text; nothing should break or execute.

---

## Self-Review

**1. Spec coverage:** encoder (T1), Nim binding + compile wiring (T1), adversarial `bun:ffi` gate (T1 Step 1), native unit test (T1 Step 4), migrate all 7 sites + drop quotes + fix both raw `app_events` paths (T2 Steps 1-2), delete 3 escapers (T2 Step 3), lint guard (T3 Step 1), docs (T3 Step 2), R0 (T3 Step 4), our-velocity gates (Global Constraints + each task). Non-goals (b/zc/CI/fs) — untouched. ✅ all covered.

**2. Placeholder scan:** No TBD/TODO. The one "confirm" (worker_service.nim's gcsafe boundary in T2 Step 2) is a real per-site allocation-model check with a stated fallback, not a placeholder.

**3. Type consistency:** `zapp_js_lit_dup(cstring)->cstring` / `jsLit(string)->string` consistent across T1-T3; the C `char* zapp_js_lit_dup(const char*)` matches the Nim importc + the `bun:ffi` `{args:[cstring],returns:ptr}`; call tokens in the lint regex (`_onEvent`/`_dispatchAppEvent`/`_onInvokeResult`/`_onWorkerMessage`/`_resolveInvoke`) match the migrated sites.
