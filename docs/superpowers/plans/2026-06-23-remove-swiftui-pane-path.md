# Remove the macOS SwiftUI Pane Path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the macOS SwiftUI pane chrome so AppKit (`NSSplitViewController`/`NSToolbar`) is the sole macOS chrome path, remove Swift from default framework builds (drop `native.swiftui`), remove the `nativeSurface` PoC feature, and preserve the Swift↔Nim bridge as a recipe-grade standalone example. iOS (UIKit) is untouched.

**Architecture:** The SwiftUI path was layered on top of a complete AppKit path behind `#ifdef ZAPP_HAS_SWIFTUI` / `else`. Removal = delete the SwiftUI branches + the Swift toolchain wiring, de-`#ifdef` the AppKit `else` as the unconditional path. `ZAPP_HAS_SWIFTUI` is only ever defined by the now-deleted `swiftc` build step, so after Task 1 every native SwiftUI block is already dead (compiled out); Tasks 2–4 delete the dead code so nothing rots.

**Tech Stack:** Bun + TypeScript (CLI), Nim + Objective-C (native macOS/iOS), `bun:test`. Build via `bun run build` (Nim path is default). Spec: `docs/superpowers/specs/2026-06-23-remove-swiftui-pane-path-design.md`.

**Branch:** `feat/nim-native` (keep UNMERGED). **Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Working-tree note:** `native/platform/darwin/window.m` has uncommitted edits from a prior session (a SwiftUI-path `applyAutoShowOnWindow:` deferred-show branch, `swiftUIPanePath`/`hostSlot` delegate props, and reduced sidebar-snap delays inside the `useSwiftUIPanes` fork). All of it lives in the delete set — it is removed by Task 2, not preserved. Do not try to keep it.

**CRITICAL — staging discipline:** the working tree also has UNRELATED pre-existing changes (`assets/`, `benchmarks/`, `vendor/`, `spikes/`, `kitchen-sink/zapp/app.nim`, `native/worker/engines/zjs-cross-eval-test.c`, plus untracked spike/doc files). **Never `git add -A` / `git add .`** — every commit stages ONLY the explicit files that task changed (the `git rm`/`git mv` in each task already stage their own deletions/moves). Do not touch the unrelated paths.

**Verify commands (used throughout):**
- Unit: `cd /Users/zach/code/zapp && bun test cli/src`
- macOS build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` — success = last line `[zapp] build complete: …` **and** a fresh `bin/kitchen-sink` mtime. Vite's `✓ built` is NOT success.
- iOS-sim build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios`
- Grep gate: see Task 6.

---

## Task 0: Baseline reference smoke (human, optional but recommended)

**Purpose:** kitchen-sink already runs `native: { swiftui: false }` (the AppKit path = the end state). Capture the reference behavior before any change so the final smoke has something to match.

- [ ] **Step 1: Build + run at HEAD**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build && bun run dev`
Confirm (human): sidebar/inspector collapse holds across route changes AND window resize; toolbar toggles work. This is the target behavior — note anything notable. No code changes in this task.

---

## Task 1: Remove the Swift toolchain + `native.swiftui` config (CLI/build layer)

**Files:**
- Modify: `cli/src/config.ts` (remove `native.swiftui` field + validation)
- Modify: `cli/src/config.test.ts` (remove the swiftui test)
- Delete: `cli/src/swiftui-build.ts`
- Delete: `cli/src/swiftui-build.test.ts`
- Modify: `cli/src/native.ts` (remove the `resolveSwiftUIBuild` import + `swiftc` step + `swiftPlan.nimArgs` injection; remove `nativesurface.m` from the macOS + iOS source lists)
- Modify: `kitchen-sink/zapp.config.ts` (remove the now-invalid `native: { swiftui: false }` line)

- [ ] **Step 1: Remove the `swiftui` field from `config.ts`**

In `cli/src/config.ts`, the `native?: { … }` object literal type (around line 756–768) currently ends with the `swiftui` field. Delete the JSDoc block + field so it reads:

```ts
  native?: {
    frameworks?: PlatformValue<string[]>;
    linkFlags?: PlatformValue<string[]>;
    sources?: PlatformValue<string[]>;
  };
}
```

- [ ] **Step 2: Remove the `swiftui` validation in `config.ts`**

In `validateNative` (around line 869–874), delete the swiftui check. After `checkField(n.sources, "sources");` the function ends — remove:

```ts
  if (n.swiftui !== undefined && typeof n.swiftui !== "boolean") {
    throw new Error(`[zapp] native.swiftui must be a boolean, got ${typeof n.swiftui}`);
  }
```

- [ ] **Step 3: Remove the swiftui config test**

In `cli/src/config.test.ts`, delete the entire test (lines ~47–52):

```ts
test("native.swiftui accepts a boolean and rejects non-boolean", () => {
  expect(() => validateNative({ native: { swiftui: false } } as any)).not.toThrow();
  expect(() => validateNative({ native: { swiftui: true } } as any)).not.toThrow();
  expect(() => validateNative({} as any)).not.toThrow();
  expect(() => validateNative({ native: { swiftui: "yes" } } as any)).toThrow(/swiftui/);
});
```

- [ ] **Step 4: Delete the Swift build-plan files**

```bash
git rm cli/src/swiftui-build.ts cli/src/swiftui-build.test.ts
```

- [ ] **Step 5: Remove the `swiftc` step + plan wiring from `native.ts`**

In `cli/src/native.ts` (around lines 1295–1330), delete the entire SwiftUI block: the `const { resolveSwiftUIBuild } = await import("./swiftui-build");` import, the `swiftcPath`/`swiftPlan` resolution, the `if (swiftPlan.runSwiftc) { … swiftc … }` compile, and the `clog(1, \`SwiftUI: …\`)` line. Then remove `...swiftPlan.nimArgs` from the `args` array so it reads:

```ts
  const args = ["c", "--cc:clang", "--mm:orc", "--threads:on", "-d:release", "--opt:size",
                `--path:${zappDir}`, `--path:${nimFrameworkDir}`,
                ...iosArgs,
                `-o:${output}`, ...(verbose ? [] : ["--hints:off"]), nimRoot];
```

Leave everything above the SwiftUI block (the `iosArgs` setup) and the `nim c` spawn intact.

- [ ] **Step 6: Remove `nativesurface.m` from both source lists in `native.ts`**

In `getPlatformSources` (around lines 69–89 macOS, 105–125 iOS), delete the line `path.join(darwinDir, "nativesurface.m"),` from the macOS array and `path.join(iosDir, "nativesurface.m"),` from the iOS array.

- [ ] **Step 7: Remove the invalid config line from kitchen-sink**

In `kitchen-sink/zapp.config.ts`, delete the line `native: { swiftui: false },` (it's the last property before the closing `};`). Ensure the preceding `headless: { … },` block still has valid trailing syntax.

- [ ] **Step 8: Verify units + build**

Run: `cd /Users/zach/code/zapp && bun test cli/src`
Expected: PASS, no reference to `resolveSwiftUIBuild`/`SwiftUIBuildPlan` remaining (no import errors).

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: last line `[zapp] build complete: …`, fresh binary, **no** `SwiftUI: …` log line. (Native SwiftUI blocks are now compiled out via undefined `ZAPP_HAS_SWIFTUI`; `nativesurface.m` no longer compiled — its `darwin_native_surface_*` symbols are referenced from `window.nim`, which Task 4 removes. If the link fails on those symbols, that is expected ordering — proceed to confirm with the Nim TS/unit gate here and let Task 4 close the link. If `bun run build` must stay green at this task boundary, do Step 9.)

- [ ] **Step 9: (If build red on `darwin_native_surface_*`) temporarily keep `nativesurface.m` compiled**

If Step 8's native link fails because `window.nim` still imports `darwin_native_surface_backing`, revert ONLY the Step 6 source-list deletions (re-add the two `nativesurface.m` entries) so the build stays green; Task 4 removes both the Nim importer and the source entries together. Note this in the commit message. (Preferred: keep Step 6 and accept that Task 1's native build closes only after Task 4 — but the unit gate `bun test cli/src` must pass regardless.)

- [ ] **Step 10: Commit**

```bash
git add cli/src/config.ts cli/src/config.test.ts cli/src/native.ts kitchen-sink/zapp.config.ts
# (swiftui-build.ts + .test.ts deletions already staged by git rm in Step 4)
git commit -m "$(cat <<'EOF'
refactor(cli): drop native.swiftui + the swiftc build step

Remove the Swift toolchain wiring (resolveSwiftUIBuild, the swiftc
compile, the -d:zappSwiftUI/-DZAPP_HAS_SWIFTUI nim args) and the
native.swiftui config field + validation + test. Default builds no
longer compile any Swift; ZAPP_HAS_SWIFTUI is never defined.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Delete the SwiftUI pane fork in `window.m`

**Files:**
- Modify: `native/platform/darwin/window.m`

All edits remove `#ifdef ZAPP_HAS_SWIFTUI` blocks and SwiftUI-only members. Locate by token; the AppKit `else` branch and all non-SwiftUI code stays. Build after to confirm the AppKit path stands alone.

- [ ] **Step 1: Remove the SwiftUI extern/typedef/dispatcher header block**

Delete the top-of-file `#ifdef ZAPP_HAS_SWIFTUI … #endif` block (~lines 78–166) containing: `ZappSwiftStateCallback`/`ZappSwiftStringCallback` typedefs, the `ZAPP_PANE_KEY_*` enum, the `zapp_swift_panes_*` / `zapp_swift_toolbar_state_*` / `zapp_swift_module_set_string` / `zapp_sidebar|inspector_register_swiftui` / `zapp_sidebar|inspector_note_swiftui_*` externs, and the `zapp_swiftui_pane_changed` + `zapp_swiftui_toolbar_event` static dispatcher functions.

- [ ] **Step 2: Remove the SwiftUI-toolbar resolver fns + AppKit no-op stub**

Delete `zapp_window_uses_swiftui_toolbar` and `zapp_window_swiftui_toolbar_state` (the `#ifdef ZAPP_HAS_SWIFTUI` versions, ~lines 704–723) AND the matching `#ifndef ZAPP_HAS_SWIFTUI` `zapp_swift_module_set_string` no-op stub + the false/NULL stub variants (~lines 725–734). These were only called by `router.nim`'s toolbar fork, which Task 3 removes.

- [ ] **Step 3: Remove the SwiftUI delegate properties**

In `ZappWindowDelegate`'s `@interface`, delete `@property … swiftPaneState;`, `@property … swiftToolbarState;`, `@property … swiftUIPanePath;`, `@property … hostSlot;`. In `-init`, delete `_swiftUIPanePath = NO;` and `_hostSlot = -1;`.

- [ ] **Step 4: Revert `applyAutoShowOnWindow:` to the plain show**

Replace the method body so it has no SwiftUI branch (remove the entire `if (self.swiftUIPanePath) { … }` block including the `zapp_toolbar_inject_metrics` re-inject + `dispatch_after` deferred show):

```objc
- (void)applyAutoShowOnWindow:(NSWindow*)window {
    if (!self.shouldAutoShow || !window) return;
    self.shouldAutoShow = NO;
    [window makeKeyAndOrderFront:nil];
    if (self.fullscreenOnShow) {
        self.fullscreenOnShow = NO;
        [window toggleFullScreen:nil];
    }
}
```

- [ ] **Step 5: Remove the `useSwiftUIPanes` gate + the pane-build fork**

Delete `bool useSwiftUIPanes = false;` and its `#ifdef ZAPP_HAS_SWIFTUI … useSwiftUIPanes = true …` setter (~lines 998–1010), then delete the entire `#ifdef ZAPP_HAS_SWIFTUI if (useSwiftUIPanes) { … } else` fork (~through line 1257) so the former `else` body (the AppKit `NSSplitViewController` construction) becomes the unconditional code path. Verify brace balance: the AppKit branch must now run with no surrounding `if`. Also delete the two delegate assignments `delegate.swiftUIPanePath = …;` and `delegate.hostSlot = host_slot;`.

- [ ] **Step 6: Make the toolbar attach unconditional**

Delete the `bool swiftUIToolbar = …` gate and the `#ifdef ZAPP_HAS_SWIFTUI … else if (swiftUIToolbar) { zapp_metrics_observe_swiftui(…); }` branch (~lines 1568–1599). The AppKit `darwin_toolbar_attach(…)` + its existing `dispatch_async`/metrics injection becomes unconditional (drop the `if (!swiftUIToolbar)` guard).

- [ ] **Step 7: Remove the SwiftUI state-release block in teardown**

In the destroy path, delete the `#ifdef ZAPP_HAS_SWIFTUI … zapp_swift_panes_state_release / zapp_swift_toolbar_state_release …` block (~lines 1672–1681).

- [ ] **Step 8: Build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: `[zapp] build complete: …`, fresh binary. (Other files still reference SwiftUI symbols but they're all in `#ifdef ZAPP_HAS_SWIFTUI` blocks → compiled out; full deletion is Task 3.)

- [ ] **Step 9: Commit**

```bash
git add native/platform/darwin/window.m
git commit -m "$(cat <<'EOF'
refactor(macos): delete SwiftUI pane fork from window.m

Remove the #ifdef ZAPP_HAS_SWIFTUI pane-build fork, swift state
props/dispatchers, the SwiftUI-toolbar resolvers, and the deferred
metrics-settled auto-show. The AppKit NSSplitViewController/NSToolbar
branch is now the unconditional macOS chrome path.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Delete SwiftUI code in sidebar.m / inspector.m / toolbar.m / router.nim + the .swift files

**Files:**
- Modify: `native/platform/darwin/sidebar.m`
- Modify: `native/platform/darwin/inspector.m`
- Modify: `native/platform/darwin/toolbar.m`
- Modify: `native/nim/router.nim`
- Delete: `native/platform/darwin/swift/panes.swift`
- Delete: `native/platform/darwin/swift/toolbar.swift`

- [ ] **Step 1: Strip SwiftUI from `sidebar.m`**

Delete: the SwiftUI extern decl block (`#ifdef ZAPP_HAS_SWIFTUI` near top), the `@property … swiftPaneState;`, the functions `zapp_sidebar_bind_swiftui`, `zapp_sidebar_register_swiftui`, `zapp_sidebar_note_swiftui_visibility`, `zapp_sidebar_note_swiftui_width`, every `#ifdef ZAPP_HAS_SWIFTUI if (c.swiftPaneState) { … return; }` early-return inside `darwin_sidebar_toggle/collapse/expand/set_width/set_collapsible/set_resizable`, and the `if (!c.swiftPaneState)` guard wrapper in `zapp_sidebar_unregister` (keep the body unconditional). Keep all `ZappSidebarController` AppKit code and the `darwin_sidebar_*` AppKit bodies.

- [ ] **Step 2: Strip SwiftUI from `inspector.m`**

Symmetric to Step 1: delete the extern block, `swiftPaneState` property, `zapp_inspector_bind_swiftui`, `zapp_inspector_register_swiftui`, `zapp_inspector_note_swiftui_visibility`, `zapp_inspector_note_swiftui_width`, the SwiftUI early-returns in `darwin_inspector_*`, and the unregister guard. Keep the AppKit `ZappInspectorController` + `darwin_inspector_*` bodies + helpers (`zapp_inspector_divider_index`, `zapp_inspector_is_collapsible`).

- [ ] **Step 3: Remove `zapp_metrics_observe_swiftui` from `toolbar.m`**

Delete the `zapp_metrics_observe_swiftui` function (~lines 376–391). Keep `ZappToolbarController`, `darwin_toolbar_attach`, `zapp_toolbar_inject_metrics`, the `contentLayoutRect` KVO, and the registry.

- [ ] **Step 4: Remove the SwiftUI toolbar fork in `router.nim`**

Delete the three `importc` decls (`zapp_window_uses_swiftui_toolbar`, `zapp_window_swiftui_toolbar_state`, `zapp_swift_module_set_string`, ~lines 146–148) and their comment. In the toolbar routing arm (~lines 617–634), remove the `swiftTb` / `tbState` resolution and the `if swiftTb: zapp_swift_module_set_string(…)` calls so the NSToolbar path (`darwin_toolbar_*`) runs unconditionally. Keep the existing AppKit toolbar routing.

- [ ] **Step 5: Delete the SwiftUI .swift files**

```bash
git rm native/platform/darwin/swift/panes.swift native/platform/darwin/swift/toolbar.swift
```

- [ ] **Step 6: Build macOS + iOS-sim**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: `[zapp] build complete: …`, fresh binary.

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios`
Expected: iOS-sim build succeeds (parity lint passes — no orphaned `darwin_*`/`zapp_*` symbol referenced from shared Nim without an iOS def).

- [ ] **Step 7: Commit**

```bash
git add native/platform/darwin/sidebar.m native/platform/darwin/inspector.m native/platform/darwin/toolbar.m native/nim/router.nim
# (panes.swift + toolbar.swift deletions already staged by git rm in Step 5)
git commit -m "$(cat <<'EOF'
refactor(macos): delete SwiftUI pane/toolbar code (sidebar/inspector/toolbar/router)

Remove the *_register_swiftui / *_bind_swiftui / *_note_swiftui_* fns and
swiftPaneState branches from sidebar.m + inspector.m, zapp_metrics_observe_swiftui
from toolbar.m, the SwiftUI toolbar fork from router.nim, and panes.swift +
toolbar.swift. AppKit NSSplitViewController/NSToolbar is the sole macOS path.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Remove the `nativeSurface` feature + stand up the bridge example

**Files:**
- Modify: `native/nim/window.nim` (remove all `nativeSurface` surface)
- Delete (move): `native/platform/darwin/nativesurface.m`, `native/platform/ios/nativesurface.m`
- Delete: `native/platform/darwin/swift/native_surface.swift` (moves to example)
- Modify: `cli/src/native.ts` (remove the `nativesurface.m` source entries, if not already done in Task 1)
- Create: `examples/swift-nim-bridge/native_surface.swift`, `examples/swift-nim-bridge/nativesurface.m`, `examples/swift-nim-bridge/README.md`

- [ ] **Step 1: Remove `nativeSurface` from `window.nim`**

Delete: the `nativeSurface*: bool` field in `WindowOptions` (~line 151), `wopts_native_surface` (~253–254), the `darwin_native_surface_backing` `importc` (~276), `nativeSurfaceBacking*` (~353–356), the `if jHasBool(a, "nativeSurface"): …` parse line (~489), and the `zapp_native_surface_emit` callback export (~552–553). Sweep `nativeSurface`/`native_surface` to confirm none remain in `native/nim/`.

- [ ] **Step 2: Stage the example sources from git history, then remove from framework**

```bash
mkdir -p examples/swift-nim-bridge
git mv native/platform/darwin/swift/native_surface.swift examples/swift-nim-bridge/native_surface.swift
git mv native/platform/darwin/nativesurface.m examples/swift-nim-bridge/nativesurface.m
git rm native/platform/ios/nativesurface.m
```

(`native_surface.swift` + the darwin `nativesurface.m` move intact; the iOS stub is dropped — the example is macOS-only.)

- [ ] **Step 3: Ensure `native.ts` no longer lists `nativesurface.m`**

Confirm the two `path.join(*, "nativesurface.m")` source-list entries are gone (removed in Task 1 Step 6; if Step 9 of Task 1 re-added them, remove them now).

- [ ] **Step 4: Trim the example to a self-contained bridge demo + write the README**

Edit `examples/swift-nim-bridge/nativesurface.m` to drop the framework-coupled `darwin_native_surface_create`/`_backing`/`zapp_native_surface_emit` plumbing and keep only the minimal `NSHostingView` host that calls the Swift `@_cdecl` entry. Write `examples/swift-nim-bridge/README.md`:

```markdown
# Swift ↔ Nim bridge (example)

Demonstrates compiling a SwiftUI view to a static lib and calling it from a
Zapp app via an `@_cdecl` entry point. This is a **recipe**, not a CI-built
target.

## Why this is an example, not a framework feature
Zapp's macOS chrome (sidebar/inspector/toolbar) is AppKit
(`NSSplitViewController`/`NSToolbar`). Layout-owning SwiftUI containers
(`NavigationSplitView`, `.inspector`) re-derive their geometry when hosted in
an imperative `NSWindow` and fight runtime control — see
`docs/superpowers/specs/2026-06-23-remove-swiftui-pane-path-design.md`. This
bridge is for **self-contained** SwiftUI views (a chart, a map, a custom
control) that own their own subtree, not framework chrome.

## Recipe
1. Compile the Swift to a static lib:
   `swiftc -emit-library -static -O -module-name zappbridge -o libzappbridge.a native_surface.swift`
2. In your app's `zapp.config.ts`, link it + compile the ObjC host:
   ```ts
   native: {
     sources:   { macos: ["examples/swift-nim-bridge/nativesurface.m"] },
     linkFlags: { macos: ["-L<dir>", "-lzappbridge", "-lswiftCore", "-lswiftFoundation",
                          "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift", "-framework", "SwiftUI"] },
   }
   ```
3. Call the `@_cdecl` entry (`zapp_swift_native_surface_create`) from your
   native/Nim code and add the returned `NSView` to a window.
```

- [ ] **Step 5: Build macOS + iOS-sim**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete: …`, fresh binary.
Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios` → succeeds.

- [ ] **Step 6: Commit**

```bash
git add native/nim/window.nim cli/src/native.ts examples/swift-nim-bridge
# (nativesurface.m darwin->example + ios deletion + native_surface.swift move already staged by git mv/rm in Step 2)
git commit -m "$(cat <<'EOF'
refactor: remove nativeSurface feature; move Swift bridge to example

Strip nativeSurface from window.nim and drop nativesurface.m (darwin+ios)
from the framework. native_surface.swift + a trimmed ObjC host move to
examples/swift-nim-bridge/ as a recipe-grade demonstration of the
Swift<->Nim @_cdecl bridge (not a CI target).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Docs + grep gate + final smoke + memory

**Files:**
- Modify: `docs/native-ui-strategy.md`
- Modify: `docs/api-reference.md`
- Modify (archive): `docs/superpowers/swiftui-pane-followups-for-review.md`
- Modify: `/Users/zach/.claude/projects/-Users-zach-code-zapp/memory/reference_swiftui_pane_control_imperative_transient.md` + `MEMORY.md`

- [ ] **Step 1: Rewrite `docs/native-ui-strategy.md`**

Remove the SwiftUI-pane "What we shipped" / "Pane control" / "Toolbar coexistence" / "Sub-cycle" sections and the `panes.swift`/`toolbar.swift` rows. State the policy: macOS chrome = AppKit (`NSSplitViewController`/`NSToolbar`); iOS chrome = UIKit (`UISplitViewController`); SwiftUI is available to apps via the standalone Swift↔Nim bridge example for self-contained views, with the documented layout-fighting caveat; the macOS SwiftUI pane path was removed (link the spec) and may be revisited.

- [ ] **Step 2: Update `docs/api-reference.md`**

Remove the "Native surface pane" section + the `nativeSurface` / `nativeSurfaceBacking` / `native.swiftui` "Opt-out" subsections. If anything is worth keeping, point it at `examples/swift-nim-bridge/README.md`.

- [ ] **Step 3: Archive the followups doc**

Add a one-line header to `docs/superpowers/swiftui-pane-followups-for-review.md` marking it historical (superseded by the 2026-06-23 removal spec). Do not delete.

- [ ] **Step 4: Grep gate**

```bash
cd /Users/zach/code/zapp && rg -n "ZAPP_HAS_SWIFTUI|swiftPaneState|swiftToolbarState|resolveSwiftUIBuild|zappSwiftUI|nativeSurface|native_surface|zapp_metrics_observe_swiftui|panes\.swift|toolbar\.swift" cli/ native/ kitchen-sink/ docs/ | rg -v "examples/swift-nim-bridge|specs/2026-06-23-remove-swiftui|native-ui-strategy|swiftui-pane-followups"
```

Expected: **no output** (every remaining hit is in the example, the spec, or the docs that intentionally narrate the removal). Any other hit = orphaned reference; fix before proceeding.

- [ ] **Step 5: Full build matrix**

Run all three; all must pass:
- `cd /Users/zach/code/zapp && bun test cli/src`
- `cd /Users/zach/code/zapp/kitchen-sink && bun run build` (→ `[zapp] build complete:` + fresh binary)
- `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios`

- [ ] **Step 6: Human visual smoke (GATE — pause for the user)**

`cd /Users/zach/code/zapp/kitchen-sink && bun run dev`. Human confirms vs the Task 0 baseline: sidebar/inspector collapse holds across route changes AND window resize; resize-lock + collapsible + width behave; toolbar renders + toggles. The flaky behavior is gone; nothing regressed. **Do not finish the branch until the user signs off.**

- [ ] **Step 7: Update memory**

Update `reference_swiftui_pane_control_imperative_transient.md`: record that the macOS SwiftUI pane path was REMOVED (2026-06-23), macOS chrome = AppKit only, Swift dropped from default builds, bridge → `examples/swift-nim-bridge/`, the closed follow-ups, and that "revisit AppKit affordances to recover lost SwiftUI niceties" is the queued next cycle. Refresh the `MEMORY.md` one-liner.

- [ ] **Step 8: Commit**

```bash
git add docs/native-ui-strategy.md docs/api-reference.md docs/superpowers/swiftui-pane-followups-for-review.md
git commit -m "$(cat <<'EOF'
docs: macOS chrome = AppKit; SwiftUI pane path removed

native-ui-strategy + api-reference updated to the AppKit-only macOS
posture; nativeSurface/native.swiftui docs dropped; bridge documented as
the standalone example. Archives the SwiftUI-pane followups doc.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Final cross-impl review + close follow-ups

- [ ] **Step 1: Final review**

Dispatch a code-review pass over the full diff (`git diff main...feat/nim-native -- cli/ native/ docs/ kitchen-sink/ examples/`) focused on: no orphaned SwiftUI/nativeSurface references, brace/scope correctness where `#ifdef` forks were removed (esp. `window.m` Task 2 Step 5), the AppKit path is unconditional, and iOS is untouched.

- [ ] **Step 2: Mark closed follow-ups**

These tasks/issues are closed or mooted by this cycle — note them in the final report so they're marked done/won't-do: #656 (this cycle's predecessor), #636, #638, #643, #646, #647, #658, #666, #669, #621, #622.

---

## Self-Review (plan vs spec)

- **Spec coverage:** A (delete files) → T1 Step 4 + T3 Step 5; B (delete-within) → T1 (config/native.ts), T2 (window.m), T3 (sidebar/inspector/toolbar/router); C (keep AppKit) → preserved across T2/T3; D (remove nativeSurface) → T4; E (move-to-example) → T4. Config migration → T1 Step 7. Docs → T5. Gates (units/build/iOS/grep/smoke) → T1/T3/T5. Follow-ups closed → T6.
- **Ordering risk:** `nativesurface.m` symbols are referenced from `window.nim` until T4; T1 Step 8–9 documents the build-green ordering choice (keep the unit gate green at every boundary; native link closes at T4). Flagged explicitly, not hidden.
- **No placeholders:** every edit shows the exact field/block/token + verify command. Native deletions are specified by symbol + `#ifdef` boundary (line numbers indicative) because byte-copying 200-line forks into the plan is impractical and error-prone; the token + boundary is the actionable instruction.
- **Type/name consistency:** symbol names verified against the tree on 2026-06-23 (`zapp_metrics_observe_swiftui`, `zapp_window_uses_swiftui_toolbar`, `zapp_sidebar/inspector_*_swiftui`, `nativeSurface`, `resolveSwiftUIBuild`).
