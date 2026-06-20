# SwiftUI → Nim interop spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get a go/no-go verdict on calling Swift/SwiftUI from Zapp's Nim layer — prove a Swift `@_cdecl` entry point (and then a SwiftUI view) links into a `nim c --cc:clang` build and runs, measuring the binary-size cost, all in a standalone throwaway harness.

**Architecture:** A self-contained `spikes/swiftui-nim/` harness. `swiftc` compiles a `.swift` (with `@_cdecl` C-ABI entry points) into a static lib; `nim c --cc:clang … --passL` links it (plus the Swift runtime + system frameworks); a tiny `probe.nim` calls the entry points via `{.importc, cdecl.}`. Two **sequential gates**: gate 1 = pure-Swift bridge (the runtime-linking rough-edge zone); gate 2 = a real `NSHostingView(SwiftUI)` window — attempted ONLY if gate 1 passes.

**Tech Stack:** Swift 6.3 (`swiftc`), Nim 2.2.10 (`nim c --cc:clang --mm:orc`), AppKit + SwiftUI system frameworks. macOS only.

**Spec:** `docs/superpowers/specs/2026-06-20-swiftui-nim-interop-spike-design.md`

**Standing constraints:** branch `feat/nim-native` (do NOT merge to main); commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Everything lives under `spikes/swiftui-nim/` — touch NOTHING in `cli/`, `native/`, or any app.

**This is a spike, not TDD feature work.** The "tests" are the two gates: build + run (gate 1) and build + human-visual (gate 2). There are no unit tests. The deliverable is `FINDINGS.md`. A gate-1 FAILURE is a legitimate, valuable outcome (a no-go verdict) — record it and stop; do not thrash trying to force it.

---

## File Structure

- `spikes/swiftui-nim/probe.swift` — the Swift side: `@_cdecl` C-ABI entry points (gate-1 bridge fns; gate-2 SwiftUI window).
- `spikes/swiftui-nim/probe.nim` — the Nim side: `{.importc, cdecl.}` decls + a `main` that calls them.
- `spikes/swiftui-nim/build.sh` — the build incantation: `swiftc` → static lib, then `nim c --cc:clang … --passL`. The authoritative record of what links.
- `spikes/swiftui-nim/FINDINGS.md` — the deliverable scorecard (verdict + sizes + incantation).
- `spikes/swiftui-nim/.gitignore` — ignore build artifacts (`*.a`, `*.o`, the `probe` binary, `.build/`, nimcache).

---

## Task 1: Harness skeleton + a nim-only size baseline

Establishes the directory, a nim-only binary (the size baseline for later deltas), and confirms the basic `nim c --cc:clang` invocation works in this dir before any Swift is involved.

**Files:**
- Create: `spikes/swiftui-nim/probe.nim`
- Create: `spikes/swiftui-nim/build.sh`
- Create: `spikes/swiftui-nim/.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```
# spikes/swiftui-nim/.gitignore — build artifacts only; sources + FINDINGS tracked
probe
*.a
*.o
*.swiftmodule
*.swiftdoc
nimcache/
.build/
```

- [ ] **Step 2: Create a nim-only `probe.nim` (no Swift yet)**

`spikes/swiftui-nim/probe.nim`:
```nim
## SwiftUI → Nim interop spike harness.
## Task 1 baseline: pure Nim, no Swift linked yet.
echo "nim-only baseline ok"
```

- [ ] **Step 3: Create `build.sh` with a nim-only baseline target**

`spikes/swiftui-nim/build.sh`:
```bash
#!/usr/bin/env bash
# SwiftUI → Nim interop spike build. Usage: ./build.sh [baseline|bridge|swiftui]
# Each stage prints the resulting binary size so FINDINGS.md can record deltas.
set -euo pipefail
cd "$(dirname "$0")"
STAGE="${1:-baseline}"

nim_build() {
  # $1 = extra --passL flags (may be empty)
  nim c --cc:clang --mm:orc -d:release --opt:size --hints:off \
    ${1:+--passL:"$1"} -o:probe probe.nim
}

case "$STAGE" in
  baseline)
    nim_build ""
    ;;
  *)
    echo "stage '$STAGE' not implemented until later tasks"; exit 2
    ;;
esac

echo "--- built: $(pwd)/probe ($(du -h probe | cut -f1)) ---"
```

- [ ] **Step 4: Run the baseline build + record its size**

Run:
```bash
chmod +x spikes/swiftui-nim/build.sh
cd /Users/zach/code/zapp/spikes/swiftui-nim && ./build.sh baseline && ./probe
```
Expected: prints `--- built: …/probe (NNNk) ---` then `nim-only baseline ok`. Note the size (the baseline for deltas).

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add spikes/swiftui-nim/probe.nim spikes/swiftui-nim/build.sh spikes/swiftui-nim/.gitignore
git commit -m "spike(swiftui-nim): harness skeleton + nim-only size baseline

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: GATE 1 — the Swift↔Nim bridge (the rough-edge zone)

Prove a `swiftc`-compiled Swift `@_cdecl` static lib links into the nim build and is callable from Nim. This is where the Swift-runtime link incantation gets discovered. **If this gate cannot be made to pass after reasonable effort, STOP — record the failure in FINDINGS.md (Task 4) as a no-go verdict.**

**Files:**
- Create: `spikes/swiftui-nim/probe.swift`
- Modify: `spikes/swiftui-nim/probe.nim`
- Modify: `spikes/swiftui-nim/build.sh`

- [ ] **Step 1: Create `probe.swift` with the bridge entry points**

`spikes/swiftui-nim/probe.swift`:
```swift
// SwiftUI → Nim interop spike — Swift side.
// Gate 1: pure-Swift @_cdecl bridge (no SwiftUI/AppKit yet) — isolates the
// "does the Swift runtime link into a nim/clang binary" question.
import Foundation

@_cdecl("zapp_swift_probe")
public func zapp_swift_probe() -> UnsafePointer<CChar>? {
  // strdup so the returned pointer outlives this call (Nim reads it; we leak
  // the few bytes — fine for a probe). Proves a Swift-built String crosses
  // the C ABI back to Nim.
  return UnsafePointer(strdup("hello from Swift 6.3"))
}

@_cdecl("zapp_swift_add")
public func zapp_swift_add(_ a: Int32, _ b: Int32) -> Int32 {
  return a + b
}
```

- [ ] **Step 2: Update `probe.nim` to call the bridge**

Replace `spikes/swiftui-nim/probe.nim` with:
```nim
## SwiftUI → Nim interop spike harness.
## Gate 1: call the Swift @_cdecl bridge via importc.
proc zappSwiftProbe(): cstring {.importc: "zapp_swift_probe", cdecl.}
proc zappSwiftAdd(a, b: int32): int32 {.importc: "zapp_swift_add", cdecl.}

let msg = zappSwiftProbe()
echo "swift says: ", (if msg.isNil: "<nil>" else: $msg)
echo "2 + 3 = ", zappSwiftAdd(2, 3)
```

- [ ] **Step 3: Add the `bridge` stage to `build.sh`**

Edit `spikes/swiftui-nim/build.sh` — replace the `case "$STAGE"` block with one that adds a `bridge` stage. The Swift-runtime link flags are the unknown to resolve; start with the candidate below and adjust until it links (record what worked):

```bash
SWIFT_LIBDIR="$(dirname "$(xcrun --find swiftc)")/../lib/swift/macosx"

build_swift_lib() {
  # Compile probe.swift → libzappswift.a (static). -enable-library-evolution
  # is NOT needed for a leaf lib. -static emits a .a; autolink hints for the
  # Swift runtime are embedded in the objects.
  swiftc -emit-library -static -O \
    -module-name zappswift \
    -o libzappswift.a probe.swift
}

# Candidate Swift-runtime link flags for the nim/clang final link. If the link
# fails with missing swift_* / _swift_* symbols, this is the line to iterate on.
swift_link_flags() {
  echo "-L. -lzappswift -L${SWIFT_LIBDIR} -lswiftCore -lswiftFoundation -Xlinker -rpath -Xlinker ${SWIFT_LIBDIR} -Xlinker -rpath -Xlinker /usr/lib/swift"
}

case "$STAGE" in
  baseline)
    nim_build ""
    ;;
  bridge)
    build_swift_lib
    nim_build "$(swift_link_flags)"
    ;;
  *)
    echo "stage '$STAGE' not implemented until later tasks"; exit 2
    ;;
esac
```

(Keep the `nim_build()` helper and the trailing `echo "--- built …"` line from Task 1.)

- [ ] **Step 4: Build + run the bridge — iterate the link flags until it passes**

Run:
```bash
cd /Users/zach/code/zapp/spikes/swiftui-nim && ./build.sh bridge && ./probe
```
Expected (PASS): prints `swift says: hello from Swift 6.3` and `2 + 3 = 5`.

If the LINK fails (undefined `swift_*`/`_swift_*` symbols, or runtime libs not found): iterate on `swift_link_flags()` — likely fixes, in order to try: (a) add `-lswiftCompatibility*` shims only if asked by the linker; (b) instead of hand-listing runtime libs, do the FINAL link via `swiftc` as the driver — i.e. let nim emit objects (`nim c --compileOnly` / `--genScript`) and link with `swiftc probe_objects… -o probe`; (c) add `-Xlinker -force_load -Xlinker libzappswift.a` if `@_cdecl` symbols get dead-stripped. Record EACH thing tried + the final working form in notes for FINDINGS.md.

If RUNTIME fails (links but crashes / dyld can't find swift libs at launch): the `-rpath` entries are the lever (point at `${SWIFT_LIBDIR}` and `/usr/lib/swift`). On macOS 12+ the OS Swift runtime in `/usr/lib/swift` should satisfy it.

**If, after a genuine effort, gate 1 cannot pass:** stop here. Proceed to Task 4 and write FINDINGS.md with a **NO-GO** verdict documenting the exact failure + everything tried. Do NOT attempt Task 3.

- [ ] **Step 5: Record the bridge binary size**

Run: `cd /Users/zach/code/zapp/spikes/swiftui-nim && du -h probe`
Note the size (delta vs the Task-1 baseline = the cost of the Swift bridge + any bundled runtime).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add spikes/swiftui-nim/probe.swift spikes/swiftui-nim/probe.nim spikes/swiftui-nim/build.sh
git commit -m "spike(swiftui-nim): GATE 1 — Swift @_cdecl bridge links + runs from Nim

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: GATE 2 — SwiftUI view renders (only if Gate 1 passed)

Add a real SwiftUI view shown in a window, created by a Swift `@_cdecl` entry called from Nim. **Skip this entire task if Gate 1 did not pass.**

**Files:**
- Modify: `spikes/swiftui-nim/probe.swift`
- Modify: `spikes/swiftui-nim/probe.nim`
- Modify: `spikes/swiftui-nim/build.sh`

- [ ] **Step 1: Add the SwiftUI window entry point to `probe.swift`**

Append to `spikes/swiftui-nim/probe.swift`:
```swift
import SwiftUI
import AppKit

struct ProbeView: View {
  var body: some View {
    VStack(spacing: 12) {
      Text("Hello from SwiftUI").font(.largeTitle)
      Text("driven from Nim via @_cdecl").foregroundStyle(.secondary)
    }
    .padding(40)
    .frame(width: 360, height: 200)
  }
}

@_cdecl("zapp_swift_show_window")
public func zapp_swift_show_window() {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let win = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
    styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  win.title = "Zapp SwiftUI Spike"
  win.contentView = NSHostingView(rootView: ProbeView())
  win.center()
  win.makeKeyAndOrderFront(nil)
  app.activate(ignoringOtherApps: true)
  app.run()  // blocks — the harness's Swift side owns the run loop
}
```

- [ ] **Step 2: Call it from `probe.nim`**

Replace `spikes/swiftui-nim/probe.nim` with:
```nim
## SwiftUI → Nim interop spike harness.
## Gate 2: Nim drives a SwiftUI window via the Swift @_cdecl entry.
proc zappSwiftProbe(): cstring {.importc: "zapp_swift_probe", cdecl.}
proc zappSwiftAdd(a, b: int32): int32 {.importc: "zapp_swift_add", cdecl.}
proc zappSwiftShowWindow() {.importc: "zapp_swift_show_window", cdecl.}

let msg = zappSwiftProbe()
echo "swift says: ", (if msg.isNil: "<nil>" else: $msg)
echo "2 + 3 = ", zappSwiftAdd(2, 3)
echo "opening SwiftUI window (close it to exit)…"
zappSwiftShowWindow()  # blocks in the AppKit run loop
```

- [ ] **Step 3: Add the `swiftui` stage to `build.sh`**

Edit `spikes/swiftui-nim/build.sh`: add a `swiftui` case that links the SwiftUI + AppKit system frameworks on top of the bridge flags. Add this case alongside `bridge`:
```bash
  swiftui)
    build_swift_lib
    nim_build "$(swift_link_flags) -framework SwiftUI -framework AppKit"
    ;;
```

- [ ] **Step 4: Build + run — human-visual gate**

Run:
```bash
cd /Users/zach/code/zapp/spikes/swiftui-nim && ./build.sh swiftui && ./probe
```
Expected: prints the two bridge lines, then **a window appears titled "Zapp SwiftUI Spike" rendering "Hello from SwiftUI" + the subtitle**. PASS = the window renders the SwiftUI content. (Closing the window / Ctrl-C exits.)

This step needs a human to confirm the window renders. If running headless/automated, build success + launch-without-crash is the automatable part; flag the visual confirm for the user.

- [ ] **Step 5: Record the SwiftUI binary size**

Run: `cd /Users/zach/code/zapp/spikes/swiftui-nim && du -h probe`
Note the size (delta vs the Gate-1 bridge binary = the cost of adding SwiftUI/AppKit — expected small, since both are system frameworks).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add spikes/swiftui-nim/probe.swift spikes/swiftui-nim/probe.nim spikes/swiftui-nim/build.sh
git commit -m "spike(swiftui-nim): GATE 2 — SwiftUI NSHostingView window driven from Nim

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: FINDINGS.md — the verdict (always run)

Capture the scorecard regardless of outcome (go OR no-go). This is the deliverable that informs whether a SwiftUI feature cycle happens.

**Files:**
- Create: `spikes/swiftui-nim/FINDINGS.md`

- [ ] **Step 1: Write `FINDINGS.md`**

`spikes/swiftui-nim/FINDINGS.md` — fill every field from the actual results of Tasks 1–3 (do NOT leave blanks; if Gate 2 was skipped, say so and why):
```markdown
# SwiftUI → Nim interop spike — FINDINGS

**Date:** 2026-06-20 · **Toolchain:** Swift 6.3, Nim 2.2.10, nim c --cc:clang · macOS <version>

## Verdict: <GO | NO-GO>

<2-3 sentences: can Zapp drive SwiftUI from Nim, and should we build the feature cycle?>

## Scorecard
| Question | Result |
|---|---|
| Gate 1 — Swift `@_cdecl` bridge links + runs from Nim | <PASS/FAIL> |
| Gate 2 — SwiftUI view renders (NSHostingView from Nim) | <PASS/FAIL/SKIPPED> |
| Binary size — nim-only baseline | <NNN KB> |
| Binary size — + Swift bridge | <NNN KB> (Δ <…>) |
| Binary size — + SwiftUI/AppKit | <NNN KB> (Δ <…>) |
| Swift runtime bundled or OS-provided? | <observed> |

## The working incantation
<the exact swiftc + nim c --passL commands that linked — copy from build.sh,
plus any iteration notes: what failed first, what fixed it>

## Build-complexity notes
<extra toolchain steps, gotchas, dead-strip/force_load needs, rpath needs>

## If GO — what the feature cycle must solve
- Real Zapp build `--passL` coexistence (Swift runtime alongside Cocoa/Carbon/libzjs/frameworks in buildNativeNim).
- Hosting a SwiftUI view into Zapp's EXISTING AppKit window (not Swift-owns-the-runloop).
- iOS cross-compile (swiftc for arm64-apple-ios* + simulator).
- Compile-time OS-version gating (@available / availability) + clear messaging + graceful fallback to the UIKit/AppKit path.

## If NO-GO
<the exact failure mode + everything tried; what would need to change (toolchain, Nim version, link strategy) to revisit>
```

- [ ] **Step 2: Commit**

```bash
cd /Users/zach/code/zapp
git add spikes/swiftui-nim/FINDINGS.md
git commit -m "spike(swiftui-nim): FINDINGS scorecard + go/no-go verdict

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Present the verdict to the user**

Summarize the FINDINGS verdict + the three binary sizes + the go/no-go. If GO, note the feature-cycle prerequisites; if NO-GO, note the blocker. The user decides whether a SwiftUI feature cycle follows. (The `spikes/swiftui-nim/` harness stays in-tree as the reference artifact, like the language-eval spike — or is deletable; the user's call.)

---

## Self-review notes (plan author)

- **Spec coverage:** harness layout → Task 1; sub-gate 1 (bridge) → Task 2; sub-gate 2 (SwiftUI) → Task 3; FINDINGS deliverable → Task 4; macOS-only / standalone / no-real-build-wiring / Swift-owns-window honored throughout; "gates ARE the test, no unit tests" stated in the header + tasks; STOP-on-gate-1-failure encoded in Task 2 Step 4 + Task 4. All spec sections map.
- **Placeholder scan:** the only intentionally-open content is the Swift-runtime link flags in Task 2 Step 3/4 — that's the spike's explicit purpose (discover the incantation), not a plan placeholder; Step 4 gives concrete candidate fixes + the exact symbols/levers to iterate on. FINDINGS fields are `<…>`-marked as fill-from-results, with an explicit "do NOT leave blanks" instruction.
- **Name consistency:** `@_cdecl` symbol names (`zapp_swift_probe`, `zapp_swift_add`, `zapp_swift_show_window`) match exactly between probe.swift and the Nim `{.importc.}` decls across Tasks 2–3. `build.sh` stages (`baseline`/`bridge`/`swiftui`) consistent across Tasks 1–3. `build_swift_lib`/`swift_link_flags`/`nim_build` helper names consistent.
- **Throwaway hygiene:** `.gitignore` (Task 1) keeps build artifacts out; only sources + build.sh + FINDINGS are tracked. Nothing outside `spikes/swiftui-nim/`.
