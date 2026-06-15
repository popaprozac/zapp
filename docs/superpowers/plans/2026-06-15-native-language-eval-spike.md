# Native Orchestration Language Evaluation Spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **NOTE — this is a research spike, not feature TDD.** The "test" of each probe task is: it builds in size-optimized mode, runs (opens a window for ~1s, exits 0), and a binary-size + interop-friction finding is recorded. The *findings* are the deliverable. The per-language probe CODE for the less-documented toolchains (C3/Odin) is intentionally written by the executing agent — that authoring experience IS a graded data point — against the fully-specified contract + a fully-worked Zig/Nim reference below. Do NOT fabricate stdlib APIs; if an incantation is wrong, iterate and record what worked.

**Goal:** Produce an evidence-based scorecard + recommendation on whether to replace Zapp's ~7,500-line Zen-C orchestration layer with Zig, Nim, C3, Odin, or plain C (or stay on Zen-C).

**Architecture:** A throwaway `spikes/lang-eval/` tree (never touches the real native build). One shared ObjC C-ABI wrapper (representative of Zapp's `darwin/*.m` pattern) that every candidate links against. Phase 1 = a fixed interop+size probe per candidate (kill gate). Phase 2 = a vertical slice on the 1–2 survivors. A `SCORECARD.md` accrues findings → recommendation.

**Tech Stack:** Zig, Nim, C3 (`c3c`), Odin, clang/C; macOS/Cocoa; the spec at `docs/superpowers/specs/2026-06-15-native-language-eval-spike-design.md`.

---

## Working rules (read first)

- **Branch:** all work on `spike/native-language-eval` (already cut). Never commit to main.
- **Isolation:** everything lives under `spikes/lang-eval/`. **Do NOT touch** the real native build — `native/`, `cli/src/native.ts`, `cli/src/build-config.ts`, `build.zc`, `hello-world/`. This spike adds no dependency the real build sees.
- **NEVER stage user-WIP:** `hello-world/src/*`, `hello-world/zapp.config.ts`, `vendor/bare`, `kitchen-sink/`, `native/worker/engines/zjs-cross-eval-test.c`, `vendor/txiki.js/`. Stage by explicit path only.
- **Commit trailer (exact):** end every commit with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Always Bun, never Node (only relevant if any helper script is written).
- **Probe "pass"** = builds in size mode + the binary runs and exits 0 (window appears ~1s) + its stripped size is recorded in `SCORECARD.md`. A candidate that can't link the ObjC wrapper or produces a multi-MB binary is recorded as a Phase-1 failure (still record the finding).
- macOS has no `timeout`; run a probe with the python-subprocess pattern (Popen → wait a few s → it self-exits) when you need a bounded run.

## File map

| Path | Responsibility |
| --- | --- |
| `spikes/lang-eval/shared/probe_cocoa.m` | The ObjC C-ABI wrapper (opens an NSWindow ~1s) — the thing every candidate calls; mirrors Zapp's `darwin/*.m` pattern |
| `spikes/lang-eval/shared/probe.h` | C header declaring the two wrapper fns (the "consume a C header" test) |
| `spikes/lang-eval/shared/probe_stub.c` | Windows-path stub (`spike_print_windows` + no-op window) for cross-compile builds that can't link Cocoa |
| `spikes/lang-eval/shared/sample.json` | `{"w":640,"h":480,"title":"zapp-spike"}` — the JSON-parse test input |
| `spikes/lang-eval/shared/probe_cocoa.o` | Prebuilt object (every candidate links the SAME one, isolating the variable to the language) |
| `spikes/lang-eval/{zig,nim,c3,odin,c}/` | One candidate each: the probe source + built `probe` binary |
| `spikes/lang-eval/SCORECARD.md` | The accruing findings table + (final) recommendation |

**Task order:** Phase 0 (toolchains) → Phase 1 Task 1 (harness) → Tasks 2–6 (probes, parallelizable) → GATE (controller picks survivors) → Phase 2 (slice per survivor) → final scorecard/recommendation.

---

## Phase 0

### Task 0: Install toolchains + scaffold

**Files:** none (environment + dirs).

- [ ] **Step 1: Install the compilers**

```bash
brew install zig nim odin
# c3c: brew may lack it; fall back to the official release if so.
brew install c3c 2>/dev/null || echo "c3c not in brew — install from https://github.com/c3lang/c3c/releases (or build); record the version used"
```

- [ ] **Step 2: Verify versions (record them — version matters for API drift)**

```bash
zig version; nim --version | head -1; odin version; c3c --version 2>/dev/null; clang --version | head -1
```
Expected: each prints a version. Note any that failed to install (a finding: toolchain availability is part of "adoption risk").

- [ ] **Step 3: Scaffold dirs + branch check**

```bash
cd /Users/zach/code/zapp
git rev-parse --abbrev-ref HEAD   # must be spike/native-language-eval
mkdir -p spikes/lang-eval/shared spikes/lang-eval/zig spikes/lang-eval/nim spikes/lang-eval/c3 spikes/lang-eval/odin spikes/lang-eval/c
```

- [ ] **Step 4: Commit the scaffold**

```bash
cd /Users/zach/code/zapp
printf '%s\n' "# lang-eval spike — throwaway. Never wired into the real build." > spikes/lang-eval/README.md
git add spikes/lang-eval/README.md
git commit -m "$(cat <<'EOF'
chore(spike): scaffold spikes/lang-eval/ + record toolchain versions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```
Record the toolchain versions from Step 2 in the commit body or the README.

---

## Phase 1 — interop + size probe (kill gate)

### Task 1: Shared harness (the fixed probe contract)

**Files:**
- Create: `spikes/lang-eval/shared/probe_cocoa.m`
- Create: `spikes/lang-eval/shared/probe.h`
- Create: `spikes/lang-eval/shared/probe_stub.c`
- Create: `spikes/lang-eval/shared/sample.json`
- Create: `spikes/lang-eval/SCORECARD.md`

- [ ] **Step 1: Write `probe.h`**

```c
#ifndef ZAPP_SPIKE_PROBE_H
#define ZAPP_SPIKE_PROBE_H
// Representative of Zapp's darwin/*.m C-ABI surface: ObjC behind plain C.
void spike_cocoa_open_window(int w, int h, const char* title);
void spike_print_windows(void);
#endif
```

- [ ] **Step 2: Write `probe_cocoa.m`**

```objc
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include "probe.h"

// Minimal stand-in for window.m: opens a real NSWindow, pumps the run loop
// ~1s so it's visibly shown, then returns (non-blocking probe — the binary
// launches, shows a window, exits 0). The interop mechanism being measured
// (orchestration lang -> C ABI -> ObjC) is identical to the real layer.
void spike_cocoa_open_window(int w, int h, const char* title) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow* win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, w, h)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                        backing:NSBackingStoreBuffered defer:NO];
        win.title = title ? [NSString stringWithUTF8String:title] : @"spike";
        [win center];
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        NSDate* until = [NSDate dateWithTimeIntervalSinceNow:1.0];
        for (;;) {
            NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until
                                               inMode:NSDefaultRunLoopMode dequeue:YES];
            if (!e) break;
            [NSApp sendEvent:e];
        }
        (void)fprintf(stdout, "[spike] cocoa window opened %dx%d '%s'\n", w, h, title ? title : "");
    }
}

void spike_print_windows(void) {
    (void)fprintf(stdout, "[spike] windows path (stub)\n");
}
```

- [ ] **Step 3: Write `probe_stub.c`** (for cross-compile builds that can't link Cocoa)

```c
#include <stdio.h>
#include "probe.h"
void spike_cocoa_open_window(int w, int h, const char* title) {
    (void)w; (void)h; (void)title;
    (void)fprintf(stdout, "[spike] cocoa stub (non-darwin build)\n");
}
void spike_print_windows(void) {
    (void)fprintf(stdout, "[spike] windows path (stub)\n");
}
```

- [ ] **Step 4: Write `sample.json`**

```json
{"w":640,"h":480,"title":"zapp-spike"}
```

- [ ] **Step 5: Precompile the shared object + sanity-check it links from C**

```bash
cd /Users/zach/code/zapp/spikes/lang-eval/shared
clang -c probe_cocoa.m -o probe_cocoa.o
# sanity: a 3-line C driver links + runs
printf '%s\n' '#include "probe.h"' 'int main(void){spike_cocoa_open_window(640,480,"sanity");return 0;}' > /tmp/spike_sanity.c
clang -Os /tmp/spike_sanity.c probe_cocoa.o -framework Cocoa -o /tmp/spike_sanity && /tmp/spike_sanity && echo "HARNESS OK"
```
Expected: a window flashes ~1s, `[spike] cocoa window opened 640x480 'sanity'`, `HARNESS OK`.

- [ ] **Step 6: Write the `SCORECARD.md` skeleton**

```markdown
# Native Language Eval — Scorecard

Baseline: Zen-C hello-world ~708 KB. Probe links the SAME prebuilt
`probe_cocoa.o`, so size deltas reflect the language's runtime/stdlib overhead.

## Phase 1 — interop + size probe (macOS)

| Lang | Stripped size | Opens window? | JSON parse | C-header consume | Platform branch | Cross-compile | Authoring friction (vs Zen-C inventory) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Zig  |  |  |  |  |  |  |  |
| Nim  |  |  |  |  |  |  |  |
| C3   |  |  |  |  |  |  |  |
| Odin |  |  |  |  |  |  |  |
| C    |  |  |  |  |  |  |  |

## Gate decision
(survivors + why — filled at the gate)

## Phase 2 — vertical slice (survivors)
(filled in Phase 2)

## Recommendation
(filled at the end — covers adopt-X / stay-Zen-C / drop-to-C)
```

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add spikes/lang-eval/shared/probe_cocoa.m spikes/lang-eval/shared/probe.h spikes/lang-eval/shared/probe_stub.c spikes/lang-eval/shared/sample.json spikes/lang-eval/SCORECARD.md
git commit -m "$(cat <<'EOF'
spike(harness): shared ObjC C-ABI wrapper + probe contract + scorecard

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```
(Do not commit `probe_cocoa.o` — it's a build artifact; add `spikes/lang-eval/**/*.o` and `spikes/lang-eval/**/probe` to `.gitignore` in this commit, or just don't stage them.)

### The probe contract (every Phase-1 candidate must do exactly this)

1. Read/parse the JSON `{"w":640,"h":480,"title":"zapp-spike"}` with the language's **stdlib JSON** (record the API + ergonomics; if the lang has no stdlib JSON, that's a finding — hardcode and note it).
2. A **compile-time platform branch**: on macOS → `spike_cocoa_open_window(w, h, title)`; else → `spike_print_windows()`.
3. Build **size-optimized + stripped**; record the byte size.
4. Run on macOS → window appears ~1s, exits 0.
5. Record the row in `SCORECARD.md` + a one-paragraph **authoring-friction** note graded against the Zen-C friction inventory (const/cast pain, platform-branch ergonomics, interop verbosity, stdlib quality).

### Task 2: Zig probe (fully-worked reference)

**Files:** Create `spikes/lang-eval/zig/main.zig`

- [ ] **Step 1: Write `main.zig`**

```zig
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("probe.h");
});

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text = try std.fs.cwd().readFileAlloc(
        a, "spikes/lang-eval/shared/sample.json", 1 << 16);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    const obj = parsed.value.object;
    const w: c_int = @intCast(obj.get("w").?.integer);
    const h: c_int = @intCast(obj.get("h").?.integer);
    // C wants NUL-terminated; std.json strings are slices — dupeZ.
    const title = try a.dupeZ(u8, obj.get("title").?.string);

    if (builtin.os.tag == .macos) {
        c.spike_cocoa_open_window(w, h, title.ptr);
    } else {
        c.spike_print_windows();
    }
}
```

- [ ] **Step 2: Build size-optimized (NOTE: Zig's CLI flags drift by version — if `build-exe` flags differ in the installed version, adapt and record what worked)**

```bash
cd /Users/zach/code/zapp
zig build-exe spikes/lang-eval/zig/main.zig \
  -I spikes/lang-eval/shared \
  spikes/lang-eval/shared/probe_cocoa.o \
  -framework Cocoa -lobjc \
  -O ReleaseSmall -femit-bin=spikes/lang-eval/zig/probe
strip spikes/lang-eval/zig/probe
ls -l spikes/lang-eval/zig/probe | awk '{print $5" bytes"}'
```
Expected: builds; size recorded.

- [ ] **Step 3: Run**

```bash
./spikes/lang-eval/zig/probe
```
Expected: window ~1s, `[spike] cocoa window opened 640x480 'zapp-spike'`, exit 0.

- [ ] **Step 4: Cross-compile probe (Zig's standout — build the windows path FROM macOS)**

```bash
cd /Users/zach/code/zapp
zig build-exe spikes/lang-eval/zig/main.zig \
  -I spikes/lang-eval/shared \
  spikes/lang-eval/shared/probe_stub.c \
  -target x86_64-windows -O ReleaseSmall \
  -femit-bin=spikes/lang-eval/zig/probe.exe
file spikes/lang-eval/zig/probe.exe
```
Expected: produces a PE/Windows executable from the Mac (`file` reports PE32+). Record success/failure — this is the cross-compile column + a major differentiator.

- [ ] **Step 5: Record + commit**

Fill the Zig row in `SCORECARD.md` (size, window=yes, JSON=`std.json` good, header=`@cImport` clean, platform branch=`builtin.os.tag` comptime, cross-compile=result, friction note). Then:
```bash
cd /Users/zach/code/zapp
git add spikes/lang-eval/zig/main.zig spikes/lang-eval/SCORECARD.md
git commit -m "$(cat <<'EOF'
spike(zig): interop+size probe + cross-compile result

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 3: Nim probe (worked reference)

**Files:** Create `spikes/lang-eval/nim/main.nim`

- [ ] **Step 1: Write `main.nim`**

```nim
import std/json

{.passC: "-I spikes/lang-eval/shared".}
{.passL: "spikes/lang-eval/shared/probe_cocoa.o -framework Cocoa -lobjc".}

proc spike_cocoa_open_window(w, h: cint, title: cstring) {.importc, cdecl.}
proc spike_print_windows() {.importc, cdecl.}

let cfg = parseFile("spikes/lang-eval/shared/sample.json")
let w = cfg["w"].getInt.cint
let h = cfg["h"].getInt.cint
let title = cfg["title"].getStr

when defined(macosx):
  spike_cocoa_open_window(w, h, title.cstring)
else:
  spike_print_windows()
```

- [ ] **Step 2: Build size-optimized (Nim compiles to C → links the .o via passL)**

```bash
cd /Users/zach/code/zapp
nim c -d:release --opt:size --passC:"-I spikes/lang-eval/shared" \
  -o:spikes/lang-eval/nim/probe spikes/lang-eval/nim/main.nim
strip spikes/lang-eval/nim/probe
ls -l spikes/lang-eval/nim/probe | awk '{print $5" bytes"}'
```
Note Nim's default GC: try `--mm:orc` (default) and also `--mm:none` if it builds; record whether GC adds meaningful size. Expected: builds; size recorded.

- [ ] **Step 3: Run + record + commit**

```bash
./spikes/lang-eval/nim/probe
```
Expected: window ~1s + cocoa log, exit 0. Fill the Nim row (note `importc`+`emit` raw-C analogue to `raw` blocks, `when defined()` platform branch, GC finding, the compiles-to-C parallel with Zen-C). Then:
```bash
cd /Users/zach/code/zapp
git add spikes/lang-eval/nim/main.nim spikes/lang-eval/SCORECARD.md
git commit -m "$(cat <<'EOF'
spike(nim): interop+size probe (compiles-to-C, importc, GC finding)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 4: C3 probe (skeleton + contract — implement idiomatically, record friction)

**Files:** Create `spikes/lang-eval/c3/main.c3`

- [ ] **Step 1: Write the probe to the contract.** Confident parts (use as-is): the externs + the call.

```c3
module spike;

extern fn void spike_cocoa_open_window(int w, int h, char* title);
extern fn void spike_print_windows();
```

Then implement, idiomatically in C3 (these APIs you must confirm against the installed `c3c` — do NOT guess silently; iterate and record what worked):
- Parse `spikes/lang-eval/shared/sample.json` with C3's stdlib JSON (`std::encoding::json` or current equivalent) → `w`, `h`, `title`. If C3's JSON is absent/immature, hardcode and **record that as a finding**.
- Platform branch via C3's compile-time OS check (`$if env::OS_TYPE == ...` / `$os` — confirm the exact form) → call `spike_cocoa_open_window` on Darwin else `spike_print_windows`.
- `main` calls it.

- [ ] **Step 2: Build size-optimized + link the shared object + Cocoa.** Starting point (confirm `c3c` flag names against the installed version):

```bash
cd /Users/zach/code/zapp
c3c compile -O5 spikes/lang-eval/c3/main.c3 \
  spikes/lang-eval/shared/probe_cocoa.o \
  -z -framework -z Cocoa -z -lobjc \
  -o spikes/lang-eval/c3/probe 2>&1 | tail -20
# (the `-z <arg>` form passes raw args to the linker in c3c; verify. If linking
#  a .o + frameworks differs in your c3c, find the correct flags and record them.)
strip spikes/lang-eval/c3/probe 2>/dev/null || true
ls -l spikes/lang-eval/c3/probe | awk '{print $5" bytes"}'
```
Expected: builds; size recorded. If the link incantation fights you, that friction is itself a finding (record it).

- [ ] **Step 3: Run + record + commit**

```bash
./spikes/lang-eval/c3/probe
```
Fill the C3 row (size, window?, JSON API + maturity, `$if` platform branch ergonomics, link friction, community/maturity note). Then:
```bash
cd /Users/zach/code/zapp
git add spikes/lang-eval/c3/main.c3 spikes/lang-eval/SCORECARD.md
git commit -m "$(cat <<'EOF'
spike(c3): interop+size probe + authoring-friction finding

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 5: Odin probe (skeleton + contract — implement idiomatically, record friction)

**Files:** Create `spikes/lang-eval/odin/main.odin`

- [ ] **Step 1: Write the probe to the contract.** Confident parts: the foreign import + signatures + platform branch.

```odin
package main

import "core:fmt"
import "core:os"
import "core:strings"
// JSON: import "core:encoding/json"  // confirm API against installed Odin

foreign import probe "../shared/probe_cocoa.o"
foreign probe {
    spike_cocoa_open_window :: proc "c" (w, h: i32, title: cstring) ---
    spike_print_windows :: proc "c" () ---
}

main :: proc() {
    // Parse spikes/lang-eval/shared/sample.json with core:encoding/json →
    // w,h,title (confirm the exact API; record ergonomics). Hardcode + note
    // if the JSON API fights you.
    w: i32 = 640
    h: i32 = 480
    title := strings.clone_to_cstring("zapp-spike")
    when ODIN_OS == .Darwin {
        spike_cocoa_open_window(w, h, title)
    } else {
        spike_print_windows()
    }
}
```
Replace the hardcoded w/h/title with the real `core:encoding/json` parse of `sample.json` and record the API + friction.

- [ ] **Step 2: Build size-optimized + link Cocoa** (confirm Odin flags against the installed version):

```bash
cd /Users/zach/code/zapp/spikes/lang-eval/odin
odin build . -o:size -out:probe -extra-linker-flags:"-framework Cocoa -lobjc"
strip probe 2>/dev/null || true
ls -l probe | awk '{print $5" bytes"}'
```
Expected: builds; size recorded.

- [ ] **Step 3: Run + record + commit**

```bash
cd /Users/zach/code/zapp && ./spikes/lang-eval/odin/probe
```
Fill the Odin row (size, window?, JSON API, `when ODIN_OS` branch, `foreign import` ergonomics, community/maturity note). Then:
```bash
cd /Users/zach/code/zapp
git add spikes/lang-eval/odin/main.odin spikes/lang-eval/SCORECARD.md
git commit -m "$(cat <<'EOF'
spike(odin): interop+size probe + authoring-friction finding

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 6: plain-C baseline (the yardstick)

**Files:** Create `spikes/lang-eval/c/main.c`

- [ ] **Step 1: Write `main.c`**

```c
#include "probe.h"
#include <stdio.h>

int main(void) {
    // C has NO stdlib JSON — record that as a finding. Either hand-scan
    // sample.json or hardcode (the absence is the data point for "drop to C").
    int w = 640, h = 480;
    const char* title = "zapp-spike";
#ifdef __APPLE__
    spike_cocoa_open_window(w, h, title);
#else
    spike_print_windows();
#endif
    return 0;
}
```

- [ ] **Step 2: Build size-optimized + run**

```bash
cd /Users/zach/code/zapp
clang -Os spikes/lang-eval/c/main.c spikes/lang-eval/shared/probe_cocoa.o \
  -framework Cocoa -o spikes/lang-eval/c/probe
strip spikes/lang-eval/c/probe
ls -l spikes/lang-eval/c/probe | awk '{print $5" bytes"}'
./spikes/lang-eval/c/probe
```
Expected: builds; window ~1s; smallest binary of the set (the size floor).

- [ ] **Step 3: Record + commit**

Fill the C row (size = the floor; window=yes; JSON=**none in stdlib** — the key ergonomic gap; `#ifdef` platform branch; interop=trivial/native; maturity=maximal). Then:
```bash
cd /Users/zach/code/zapp
git add spikes/lang-eval/c/main.c spikes/lang-eval/SCORECARD.md
git commit -m "$(cat <<'EOF'
spike(c): plain-C baseline (size floor; stdlib-JSON gap finding)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## GATE (controller decision — NOT a subagent task)

After Tasks 2–6, the controller reviews the filled Phase-1 table and picks the **1–2 survivors** for Phase 2 using the rubric:
- **Must clear:** links the ObjC wrapper (window opens) AND stripped size within ~15–20% of the ~708 KB baseline (probe-scale: not multi-MB).
- **Rank by:** interop cleanliness, platform-branch ergonomics, JSON/stdlib quality, cross-compile, maturity/adoption.

Record the survivor choice + reasoning in `SCORECARD.md` → "Gate decision". If the gate is unambiguous (e.g., only Zig clears everything convincingly), one survivor is fine. Plain C is always implicitly "in" as the baseline comparison even if not formally sliced.

---

## Phase 2 — vertical slice (per survivor; instantiate this task for each)

### Task 7 (template): vertical slice for survivor `<LANG>`

**Files:** Create `spikes/lang-eval/slice-<LANG>/` (its own dir; may add a second small `.m` wrapper if the slice needs a richer call).

The slice reimplements one real Zapp path to grade ergonomics on the patterns we actually use. It must include ALL of:

- [ ] **Step 1: Bridge JSON → route → "window create".** Parse a bridge-shaped message `{"t":4,"m":"window:create","a":{"w":700,"h":500,"title":"slice"}}` and dispatch on `m` to a handler that calls `spike_cocoa_open_window`. (Mirrors `router_handle_window_action`.)
- [ ] **Step 2: A platform-gated call.** Route a second action `{"m":"dock:bounce"}` to a macOS path (call a new `spike_cocoa_beep()` you add to `probe_cocoa.m` → `NSBeep()`) vs a windows-stub branch — using the language's compile-time OS mechanism. Grade vs Zen-C's `@cfg` + the emit-into-every-TU footgun.
- [ ] **Step 3: A struct + methods.** Model a tiny `WindowOptions`-like struct with a method (e.g., `apply()` that calls the wrapper) — grade struct/impl ergonomics vs Zen-C's `struct`/`impl`.
- [ ] **Step 4: A const-correctness case.** Pass a `const char*` from parsed JSON through the struct into the C wrapper without the cast wrangling Zen-C needed — record whether it's clean.
- [ ] **Step 5: The `raw`-block → `.m`-wrapper pattern.** Take one thing that's an inline-ObjC `raw` block in the real `.zc` (e.g., setting a window title via ObjC) and prove the target architecture: ObjC stays in `probe_cocoa.m` behind a C fn the survivor calls. Confirm no inline ObjC is needed in the orchestration lang.
- [ ] **Step 6: Build size-optimized + run + record.** Same build pattern as the Phase-1 probe for `<LANG>`; record the slice binary size + a paragraph grading each of Steps 1–5 against the Zen-C friction inventory.
- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add spikes/lang-eval/slice-<LANG> spikes/lang-eval/shared/probe_cocoa.m spikes/lang-eval/SCORECARD.md
git commit -m "$(cat <<'EOF'
spike(slice-<LANG>): vertical slice — router/cfg/struct/const/raw-to-wrapper

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

(Repeat Task 7 for each survivor. If two survivors, do both — they're independent.)

---

## Task 8: Scorecard + recommendation

**Files:** Modify `spikes/lang-eval/SCORECARD.md`

- [ ] **Step 1: Complete the scorecard.** Ensure every Phase-1 row + every Phase-2 slice is filled (size table, per-axis grades, cross-compile, maturity).
- [ ] **Step 2: Write the recommendation.** A clear call across the **three live outcomes**, each argued from the evidence:
  - **Adopt `<X>`** — only if it clears size + interop AND is materially lower adoption-risk than Zen-C AND the migration cost (rewriting `cli/src/native.ts` build + the `.zc`-emitting codegen + replacing `std/json`) is justified by the ergonomic + cross-compile wins.
  - **Stay on Zen-C** — if no candidate clearly beats it net of migration cost (weighed honestly against the documented Zen-C tax: patches, `@cfg` footgun, stdlib bugs).
  - **Drop to plain C** — if the ergonomic delta of the new langs doesn't justify ANY new-lang adoption risk over maximal-maturity C.
  Include a binary-size comparison table and a one-line "if we had to ship the decision today" verdict.
- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add spikes/lang-eval/SCORECARD.md
git commit -m "$(cat <<'EOF'
spike(scorecard): findings + recommendation (adopt-X / stay-Zen-C / drop-to-C)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (after execution, before presenting findings)

- Every candidate built with the SAME prebuilt `probe_cocoa.o` (size deltas attributable to the language, not the wrapper).
- Each probe actually opened a window (interop proven, not just compiled).
- Sizes are STRIPPED and recorded in bytes.
- The friction notes grade against the real Zen-C inventory (const/cast, `@cfg` footgun, stdlib bugs, raw-block→wrapper), not vibes.
- Cross-compile column filled for all (Zig especially; note which others can/can't).
- The recommendation argues all three outcomes from evidence, with migration cost named.
- Nothing under `native/`, `cli/`, `hello-world/`, `build.zc` was modified; spike is fully contained in `spikes/lang-eval/`.

## Out of scope (do not do)

Wiring any candidate into the real build; Windows/iOS probe coverage (cross-compile column captures the Windows-from-Mac signal); performance benchmarking; the actual migration.
