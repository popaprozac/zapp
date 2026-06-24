# Remove the macOS SwiftUI Pane Path — Design

**Status:** Approved (design) — pending spec review
**Branch:** `feat/nim-native` (keep UNMERGED)
**Date:** 2026-06-23
**Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
**Supersedes the in-flight cycle:** #656 (SUIA2c). Closes/moots a stack of SwiftUI-pane-only follow-ups (see "Follow-ups closed").

---

## Background

macOS sidebar/inspector/toolbar chrome currently has two implementations behind
`native.swiftui`:

- **SwiftUI pane path** (default on macOS 14+): `NavigationSplitView` + `.inspector` +
  SwiftUI `.toolbar`, hosted in an `NSHostingController` set as an imperative
  `NSWindow`'s `contentViewController` (`panes.swift`, `toolbar.swift`).
- **AppKit path** (`native.swiftui: false`): a real `NSSplitViewController` +
  `NSToolbar`.

The SwiftUI path has never been durable. `NavigationSplitView` **re-derives** its
column geometry (collapse state, width, `canCollapse`) on every relayout — including
content-only relayouts (route changes) and window resizes — and re-asserts its own
defaults over any imperative control we apply. We chased this across an entire cycle:

- #665 (divider-drag collapse gating via AppKit `canCollapse` lock),
- #668 (app-rendered toggle to fix grey-out/escape-hatch/overflow),
- #670/#671 (chrome metrics + initial width),
- #672 (resize-lock regression),
- #673 (collapse decay on route change, patched via `canCollapse` KVO),
- #644 (real SwiftUI scene host — proven architecturally incompatible: Zapp creates
  windows imperatively via `darwin_window_create` + a numeric-id registry + worker-spawned
  windows; there is no `WindowGroup`/Scene to host them in).

Each fix held one trigger and reopened another. The latest symptom — sidebar collapse
state not holding across **window resize** — is the same re-derivation, just from a
different trigger. This is inherent to hosting `NavigationSplitView` in an imperative
`NSWindow`; it is not a bug we can finish fixing.

The AppKit path (`NSSplitViewController`) has **no re-derivation** and has been the
rock-solid control every cycle verified against. The entire SwiftUI pane effort was
trying to reach *parity* with it, never to exceed it.

## Decision

Retire the macOS SwiftUI pane chrome. Specifically:

1. **macOS chrome = AppKit only.** Delete the SwiftUI pane path; the existing AppKit
   `#else` branch (`NSSplitViewController` sidebar/inspector + `NSToolbar`) becomes the
   sole macOS path.
2. **No Swift in default framework builds.** Remove the entire Swift toolchain step and
   the `native.swiftui` config option. `swiftc` never runs; `ZAPP_HAS_SWIFTUI` /
   `-d:zappSwiftUI` are never defined.
3. **Remove the `nativeSurface` framework feature entirely** (not kept as an
   AppKit-only half-feature). Nothing in the framework or kitchen-sink uses it; it was
   the proof-of-concept for the SwiftUI tier and is explicitly deferred ("revisit
   later").
4. **Keep the Swift↔Nim bridge as a standalone, recipe-grade example.** `native_surface.swift`
   + a minimal host + a README recipe move to `examples/swift-nim-bridge/`. It is *not*
   a CI-gated build target.
5. **iOS is untouched.** iOS chrome is UIKit (`UISplitViewController`); it never
   compiled the SwiftUI pane code (`resolveSwiftUIBuild` bails on non-macOS and the
   `swiftc` step is macOS-gated).

### Why these specific calls
- macOS overlay-sidebar presentation (#646) was SwiftUI-only and is lost. Acceptable:
  the product pitch is *tiled* native sidebars ("native chrome you can't fake"); overlay
  is the iOS model.
- "SwiftUI on modern iPadOS" stays a clean future investigation (it would need its own
  due diligence: modern iPadOS toolbars/inspectors). The macOS re-derivation pain does
  not apply to iOS's single-pane presentation model.

## Goals

- macOS sidebar/inspector/toolbar are durable across route changes **and** window
  resize (the AppKit path already is).
- Default framework builds contain zero Swift; binary size drops accordingly (size
  tenet).
- No dead code, no orphaned references — the build is green with no `#ifdef
  ZAPP_HAS_SWIFTUI` blocks remaining.
- The Swift↔Nim bridge survives as a documented, followable example.
- The end-user runtime API (`SidebarHandle` / `InspectorHandle` / `ToolbarHandle` and
  their options) is **unchanged** — this is purely an implementation retreat.

## Non-goals

- No new chrome features. This is a removal + a docs/example reframe.
- No iOS changes.
- No attempt to make a buildable CI example or re-introduce a Swift build path for the
  example.
- No removal of the `native.frameworks` / `native.linkFlags` / `native.sources` escape
  hatches (those stay — the example recipe relies on them).

---

## Removal map

Line numbers below are indicative (current as of 2026-06-23) — the implementer locates
by symbol/token, since line numbers drift. Tokens to sweep: `ZAPP_HAS_SWIFTUI`,
`zappSwiftUI`, `swiftui`, `swiftPaneState`, `swiftToolbarState`, `*_register_swiftui`,
`*_bind_swiftui`, `*_note_swiftui_*`, `zapp_metrics_observe_swiftui`,
`zapp_window_uses_swiftui_toolbar`, `zapp_window_swiftui_toolbar_state`,
`zapp_swiftui_pane_changed`, `zapp_swiftui_toolbar_event`, `useSwiftUIPanes`,
`zapp_swift_panes_*`, `zapp_swift_toolbar_state_*`, `zapp_swift_module_set_string`,
`nativeSurface`, `native_surface`, `nativesurface`, `darwin_native_surface_*`,
`zapp_native_surface_emit`.

### A. DELETE — files (whole)
- `cli/src/swiftui-build.ts` (+ `cli/src/swiftui-build.test.ts`).
- `native/platform/darwin/swift/panes.swift`.
- `native/platform/darwin/swift/toolbar.swift`.

### B. DELETE — within files (SwiftUI pane chrome)
- **`cli/src/config.ts`** — the `native.swiftui?: boolean` field (+ its JSDoc) and the
  `validateNative` swiftui type-check.
- **`cli/src/config.test.ts`** — the "native.swiftui accepts a boolean…" test.
- **`cli/src/native.ts`** — the SwiftUI build block (`resolveSwiftUIBuild` import + call,
  the `swiftc` invocation, the swift-source scan, the `SwiftUI: …` log line, and the
  `...swiftPlan.nimArgs` injection into the `nim c` args). Leave the base `nim c` args
  intact.
- **`native/platform/darwin/window.m`** — every `#ifdef ZAPP_HAS_SWIFTUI` block and its
  contents:
  - the SwiftUI forward-declaration header block + `ZappSwiftStateCallback` /
    `ZappSwiftStringCallback` typedefs + `zapp_swift_panes_*` / `zapp_swift_toolbar_state_*`
    / `zapp_swift_module_set_string` / `zapp_sidebar|inspector_register_swiftui` /
    `*_note_swiftui_*` externs (≈ lines 78–166);
  - the `zapp_swiftui_pane_changed` and `zapp_swiftui_toolbar_event` dispatcher statics
    (≈ 127–165);
  - the `zapp_window_uses_swiftui_toolbar` + `zapp_window_swiftui_toolbar_state`
    resolver fns + the `#ifndef ZAPP_HAS_SWIFTUI` `zapp_swift_module_set_string` no-op
    stub (≈ 704–734);
  - the `swiftPaneState` / `swiftToolbarState` delegate `@property`s + the
    `swiftUIPanePath` / `hostSlot` `@property`s + their `init` lines;
  - the `applyAutoShowOnWindow:` SwiftUI branch (the recently-added deferred-show +
    metrics re-inject — reverts to the plain `makeKeyAndOrderFront`);
  - the `useSwiftUIPanes` gate + the entire `if (useSwiftUIPanes) { … }` pane-build fork
    (≈ 998–1257), leaving the AppKit `else` branch as the unconditional path;
  - the `swiftUIToolbar` gate + the `zapp_metrics_observe_swiftui` else-if (≈ 1568–1599)
    — the AppKit `darwin_toolbar_attach` + its existing metrics injection becomes
    unconditional;
  - the `#ifdef ZAPP_HAS_SWIFTUI` state-release block in the destroy path (≈ 1672–1681).
- **`native/platform/darwin/sidebar.m`** — `zapp_sidebar_bind_swiftui`,
  `zapp_sidebar_register_swiftui`, `zapp_sidebar_note_swiftui_visibility`,
  `zapp_sidebar_note_swiftui_width`, the `swiftPaneState` `@property`, every `#ifdef
  ZAPP_HAS_SWIFTUI if (c.swiftPaneState) { … return; }` early-return in
  `darwin_sidebar_toggle/collapse/expand/set_width/set_collapsible/set_resizable`, and
  the `!c.swiftPaneState` guard in `zapp_sidebar_unregister`. Keep all
  `ZappSidebarController` AppKit bodies + the `darwin_sidebar_*` AppKit reach-through.
- **`native/platform/darwin/inspector.m`** — the symmetric set:
  `zapp_inspector_bind_swiftui`, `zapp_inspector_register_swiftui`,
  `zapp_inspector_note_swiftui_*`, the `swiftPaneState` `@property`, the SwiftUI
  early-returns in `darwin_inspector_*`, and the unregister guard. Keep the AppKit
  bodies.
- **`native/platform/darwin/toolbar.m`** — `zapp_metrics_observe_swiftui` (the
  SwiftUI-only KVO registrar). Keep `ZappToolbarController`, `darwin_toolbar_attach`,
  `zapp_toolbar_inject_metrics`, and the `contentLayoutRect` KVO (used by the AppKit
  path).
- **`native/nim/router.nim`** — the SwiftUI-toolbar routing fork: the
  `zapp_window_uses_swiftui_toolbar` / `zapp_window_swiftui_toolbar_state` /
  `zapp_swift_module_set_string` `importc` decls (≈ 143–148) and the `swiftTb` / `tbState`
  branch in the toolbar routing arm (≈ 617–634). The NSToolbar path becomes
  unconditional.

### C. KEEP (becomes the sole path)
- The AppKit `#else` branch in `window.m` (NSSplitViewController split construction,
  geometry, registry, KVO) — de-`#ifdef` it.
- All `ZappSidebarController` / `ZappInspectorController` AppKit code + the
  `darwin_sidebar_*` / `darwin_inspector_*` reach-throughs (width via `setPosition`,
  collapse via `canCollapse`, resize-lock via min/max thickness).
- `ZappToolbarController` + `darwin_toolbar_attach` + `zapp_toolbar_inject_metrics` +
  `contentLayoutRect` KVO.
- `native.frameworks` / `native.linkFlags` / `native.sources` config + `resolveNative`.

### D. REMOVE — the `nativeSurface` framework feature
- **`native/nim/window.nim`** — the `nativeSurface` `WindowOptions` field,
  `wopts_native_surface`, the `darwin_native_surface_backing` import, `nativeSurfaceBacking`,
  the `nativeSurface` JSON parse, and `zapp_native_surface_emit`.
- **`native/platform/darwin/nativesurface.m`** — remove from the framework (its content
  moves to the example, see E).
- **`native/platform/ios/nativesurface.m`** — remove from the framework.
- **`cli/src/native.ts`** — the two `nativesurface.m` entries in the darwin + ios source
  lists.
- Any docs references to `WindowOptions.nativeSurface` / `nativeSurfaceBacking` (move to
  the example README).

### E. MOVE-TO-EXAMPLE — `examples/swift-nim-bridge/`
- `native_surface.swift` (the `@_cdecl` `NSHostingView` bridge).
- A minimal host (`nativesurface.m` trimmed to the bridge demonstration) + the Nim glue
  needed to call it.
- `README.md` — a **recipe**, not a CI target:
  1. compile the Swift to a static lib with `swiftc -emit-library -static`;
  2. link it into a Zapp Nim app via `native: { linkFlags, sources }`;
  3. call the `@_cdecl` entry from app/native code;
  4. document the `NSHostingView` hosting pattern and the **caveat**: layout-driving
     SwiftUI containers (`NavigationSplitView` et al.) have rough edges when hosted in an
     imperative `NSWindow` — this bridge is for self-contained, non-layout-owning SwiftUI
     views (a chart, a map, a custom control), not framework chrome. Link the rationale
     to this spec.

---

## Config migration

Removing `native.swiftui` is a breaking config change. kitchen-sink currently has an
**active** `native: { swiftui: false }` line (`kitchen-sink/zapp.config.ts:21`), which is
removed. We own all in-repo apps; any external app passing `native.swiftui` will fail TS
type-check (field gone) — acceptable for an alpha. No back-compat shim.

**De-risking note:** because kitchen-sink already sets `swiftui: false`, it already runs
the exact end state (the AppKit path) today. The post-removal behavior should be
visually identical to a build at HEAD with that line present — i.e. the human smoke gate
is verifying that the AppKit path (already the default kitchen-sink runs) is unchanged
once it's the *only* path, not a brand-new code path. Worth a baseline smoke at HEAD
(`swiftui: false`) before T1 to capture the reference behavior.

---

## Verification / gates

- **Unit:** `bun test cli/src` green (swiftui-build tests deleted; config test updated).
  No remaining importer of `resolveSwiftUIBuild`/`SwiftUIBuildPlan`.
- **Build matrix:**
  - Nim macOS default build ends with `[zapp] build complete: …` (last line) + fresh
    binary mtime — and the `SwiftUI: …` log line is gone.
  - iOS-sim build green (parity lint passes — no new `darwin_*`/`zapp_*` symbol referenced
    from shared code without an iOS def).
- **Grep gate:** zero hits for `ZAPP_HAS_SWIFTUI`, `swiftPaneState`, `panes.swift`,
  `toolbar.swift`, `resolveSwiftUIBuild`, `nativeSurface` across `cli/`, `native/`,
  `kitchen-sink/` (the example dir is exempt).
- **Human visual smoke (GATE):** kitchen-sink on the Nim macOS build —
  - sidebar/inspector collapse state holds across route changes **and** window resize;
  - resize-lock + collapsible + width all behave;
  - toolbar renders + toggles work;
  - i.e. the flaky behavior that motivated this is gone, and nothing regressed vs the
    AppKit path.
- **Final cross-impl review** before finishing the branch.

---

## Task breakdown (for the plan)

- **T1 — CLI/build layer.** Remove `native.swiftui` (config.ts + validation + test);
  delete `swiftui-build.ts` + test; strip the `swiftc` step + `swiftPlan` wiring from
  `native.ts`; remove the `nativesurface.m` source-list entries. After T1 the Swift code
  is no longer compiled (`ZAPP_HAS_SWIFTUI` undefined) and the build is green with the
  native SwiftUI blocks `#ifdef`'d out. Gate: `bun test cli/src` + a default build.
- **T2 — native macOS de-SwiftUI (window.m).** Delete the `#ifdef ZAPP_HAS_SWIFTUI`
  forks/props/dispatchers in `window.m`; de-`#ifdef` the AppKit branch as the sole path;
  revert `applyAutoShowOnWindow:`. Gate: macOS build complete + binary fresh.
- **T3 — native macOS de-SwiftUI (sidebar/inspector/toolbar + router).** Remove the
  SwiftUI fns/branches in `sidebar.m`, `inspector.m`, `toolbar.m`; remove the
  router.nim toolbar fork; delete `panes.swift` + `toolbar.swift`. Gate: macOS build +
  iOS-sim build.
- **T4 — remove `nativeSurface` + stand up the example.** Strip `nativeSurface` from
  `window.nim` + remove `nativesurface.m` (darwin + ios) from the framework; create
  `examples/swift-nim-bridge/` (native_surface.swift + minimal host + README recipe).
  Gate: macOS + iOS-sim builds; grep gate.
- **T5 — docs + kitchen-sink + final.** Rewrite `docs/native-ui-strategy.md` (macOS =
  AppKit, the SwiftUI pane retreat + rationale, the bridge-as-example posture);
  update/trim `docs/api-reference.md` (drop `nativeSurface` / `native.swiftui`); remove
  the kitchen-sink commented line; archive `docs/superpowers/swiftui-pane-followups-for-review.md`
  as historical; full build matrix + human visual smoke gate + final review + memory
  update.

## Follow-ups closed/mooted by this cycle
#636, #638, #643, #646, #647, #658, #666, #669, #621, #622 (all SwiftUI-pane-specific),
and the in-flight #656. Note these in the plan so they're marked when the cycle lands.

## Risks
- **Orphaned reference breaks the build.** Mitigated by the two-survey removal map + the
  grep gate + per-task builds.
- **AppKit path gaps surface once it's the only path.** Low — it's been the verified
  control every cycle; the human smoke gate is the backstop.
- **iOS link regression** from a shared-symbol removal. Mitigated by the iOS-sim build +
  the parity lint in T3/T4.
