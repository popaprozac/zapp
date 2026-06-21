# SwiftUI-backed accessories — Sub-cycle 1 (macOS pane layout) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS 14+, accessory'd windows (sidebar and/or inspector) build their pane arrangement via a SwiftUI `NavigationSplitView`/`.inspector` layout hosting Zapp's real webviews, selected automatically, with today's AppKit `NSSplitViewController` as the fallback.

**Architecture:** A new `native/platform/darwin/swift/panes.swift` exposes `@_cdecl zapp_swift_panes_create(content, sidebar, inspector, showInspector)` that wraps *pre-built, webview-populated* `NSView` containers in a SwiftUI pane layout and returns an `NSHostingView`. `window.m`'s accessory'd-window construction forks: when capable + not opted out it builds the containers, hands them to the Swift entry, sets the result as `contentView`, then creates the webviews *into those containers* exactly as today (so each pane's config-level bridge + `zapp_register_webview` routing survive). SwiftUI owns only the content subtree; `NSApp`/`NSWindow`/title bar/`NSToolbar`/tray are untouched.

**Tech Stack:** Swift (SwiftUI/WebKit, `swiftc` — the existing build step globs `native/platform/darwin/swift/*.swift`), Objective-C (`window.m`), Nim build (unchanged). macOS 14 floor (`.inspector`/`NavigationSplitView`).

**Branch:** `feat/nim-native` (do not merge to main). **Commit trailer (every commit):**
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

**Spec:** `docs/superpowers/specs/2026-06-20-swiftui-accessories-subcycle1-macos-design.md`
**References:** `spikes/swiftui-webview-inspector/Probe.swift` (proven representable + `NavigationSplitView`/`.inspector` shape), `native/platform/darwin/swift/native_surface.swift` (`@_cdecl` + `NSHostingView` + retain/`__bridge_transfer`), `native/platform/darwin/window.m:778-1013` (current accessory'd-window construction: containers, `darwin_webview_create_ext`, `zapp_register_webview`, `zapp_set_sidebar_slot`/`zapp_set_inspector_slot`, `zapp_sidebar_register`/`zapp_inspector_register`).

---

## Verification model (read first)

No unit tests for native UI — verification is **build-succeeds + human visual smoke** (the repo's established gate; see the native-surface cycle). The build-complete signal is the **last line `[zapp] build complete: …`** (Vite's `✓ built` is NOT success).

**Risk-isolating order (per the spec):** wire + visually verify the **content pane alone** first (Task 1 — the scary "does the real webview survive the SwiftUI host in-app" gate), then add the **sidebar** (Task 2), then the **inspector** (Task 3). Each task leaves a working, smokeable build; the kitchen-sink window is temporarily content-only after Task 1 and regains sidebar/inspector in Tasks 2–3.

**Build command (from `kitchen-sink/`):** `bun run build` (macOS). The smoke requires **macOS 14+** (host is macOS 26 — fine).

**Critical invariant (from window.m):** a `WKWebView` must be **created into its final container and never re-parented** — re-parenting resets its content process and breaks the bridge. The SwiftUI path wraps the *container* (via the representable), and creates the webview into that container with the same `darwin_webview_create_ext` call as today. The representable holds the container by a strong `let` (so SwiftUI/ARC keeps it alive).

---

## File Structure

**Create:**
- `native/platform/darwin/swift/panes.swift` — the `PaneHost` representable, the `PaneLayout` SwiftUI view, and the `@_cdecl zapp_swift_panes_create` entry. Auto-compiled by the existing `swiftc` step (no build-config change).

**Modify:**
- `native/platform/darwin/window.m` — fork the accessory'd-window construction (`window.m:778`): a SwiftUI-panes branch alongside the existing `NSSplitViewController` branch.
- `docs/native-ui-strategy.md` — mark Sub-cycle 1 status (Task 4).

---

## Task 1 (RISK GATE): content pane in a SwiftUI host

Prove the real content webview survives being hosted by a SwiftUI representable *inside an accessory'd Zapp window*. The window is temporarily **content-only** (sidebar/inspector return in Tasks 2–3).

**Files:**
- Create: `native/platform/darwin/swift/panes.swift`
- Modify: `native/platform/darwin/window.m` (the `if (useSidebar || useInspector || useNativeSurface)` block at ~778)

- [ ] **Step 1: Write `panes.swift` (content-only)**

```swift
import SwiftUI
import WebKit

// Wraps a pre-built NSView (a container that ALREADY holds a Zapp WKWebView)
// inside SwiftUI WITHOUT re-parenting the webview — we only wrap the container.
// The strong `let view` keeps the container (and its webview) alive under ARC.
struct PaneHost: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

@available(macOS 14.0, *)
struct PaneLayout: View {
  let content: NSView
  var body: some View {
    PaneHost(view: content).ignoresSafeArea()
  }
}

// Returns a +1-retained NSHostingView; ObjC consumes it with __bridge_transfer.
// `content` is an NSView* passed from ObjC (the populated content container).
@_cdecl("zapp_swift_panes_create")
public func zapp_swift_panes_create(_ content: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.0, *) else { return nil }
  let contentView = Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue()
  let host = NSHostingView(rootView: PaneLayout(content: contentView))
  return Unmanaged.passRetained(host).toOpaque()
}
```

(Tasks 2–3 widen the signature to add sidebar/inspector — see those tasks. Keeping it content-only here isolates the risk.)

- [ ] **Step 2: Fork `window.m` for the content-only SwiftUI path**

In `window.m`, find the accessory'd block `if (useSidebar || useInspector || useNativeSurface) {` (~778). Near the other `extern` decls at the top of the file, add:

```objc
#ifdef ZAPP_HAS_SWIFTUI
extern void* zapp_swift_panes_create(void* content);
#endif
```

Then, immediately inside that block (before the `if (tbs == 3)` chrome setup), compute the gate, and branch. The cleanest structure: keep ALL the existing container-building + chrome code, and only swap how the panes are *assembled into the window* (splitVC vs SwiftUI host) + which accessory registries run. Concretely, after the existing content/sidebar/inspector **containers** are built (the `NSView`s: `mainContainer`, and for Tasks 2–3 `sidebarContainer`/`inspectorContainer`), decide:

```objc
        bool useSwiftUIPanes = false;
#ifdef ZAPP_HAS_SWIFTUI
        // Sub-cycle 1: sidebar/inspector accessory'd windows use the SwiftUI pane
        // layout on macOS 14+. native-surface windows keep the AppKit split for now.
        if ((useSidebar || useInspector) && !useNativeSurface) {
            if (@available(macOS 14.0, *)) useSwiftUIPanes = true;
        }
#endif
        if (getenv("ZAPP_LOG")) {
            NSLog(@"[zapp] window panes: %s", useSwiftUIPanes ? "swiftui" : "appkit");
        }
```

For Task 1 only, scope the SwiftUI branch to the **content pane** (ignore sidebar/inspector temporarily). Replace the `window.contentViewController = splitVC;` assembly with a fork. The simplest Task-1 shape:

```objc
        if (useSwiftUIPanes) {
            // Task 1: content pane only (sidebar/inspector added in Tasks 2-3).
            // 1) Install the SwiftUI host (wrapping the empty content container)
            //    as the window's contentView FIRST, so the container is in the
            //    window before the webview is created into it (mirrors the AppKit
            //    ordering where splitVC is the root before _ext runs).
            NSView* host = (__bridge_transfer NSView*)zapp_swift_panes_create((__bridge void*)mainContainer);
            window.contentView = host;
            // 2) Create the content webview INTO mainContainer (same call as the
            //    AppKit path; never re-parented). pane_role=0, host_has_* = false
            //    for Task 1 (no accessories yet wired into this path).
            darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                      custom_url, host_slot, useVibrancy,
                                      (__bridge void*)mainContainer, -1, 0,
                                      false, false);
            // 3) Register the content webview (routing/bridge essential).
            NSString* hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot];
            for (NSView* sub in mainContainer.subviews) {
                if ([sub isKindOfClass:[WKWebView class]]) {
                    mainWebviewRef = (WKWebView*)sub;
                    zapp_register_webview(host_slot, mainWebviewRef, hostWindowId);
                    break;
                }
            }
        } else {
            // ... the ENTIRE existing NSSplitViewController construction, unchanged ...
        }
```

Wrap the existing splitVC construction (the chrome `if (tbs==3)`, the splitVC build, `addSplitViewItem`s, `window.contentViewController = splitVC`, geometry, the `_ext` webview creations, registrations, fan-out + accessory registries — `window.m:790-1013`) in the `else`. Keep it byte-for-byte; only indent it.

IMPLEMENTER NOTE (the risk gate): the load-bearing uncertainty is the representable lifecycle — whether `mainContainer` is in the window + laid out when `darwin_webview_create_ext` adds the webview, so the webview renders. The structure above installs the host (and thus the container) before `_ext`. If at the visual gate the content webview does **not** render (blank), the likely cause is the container not yet being in the view hierarchy when `_ext` runs; try forcing layout (`[host layoutSubtreeIfNeeded]`) after `window.contentView = host`, or create the webview into `mainContainer` *before* `zapp_swift_panes_create` and confirm SwiftUI doesn't re-parent it. If neither resolves it, STOP and report BLOCKED with what you observed — do not thrash.

- [ ] **Step 3: Build (macOS)**

Run: `cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..`
Expected last line: `[zapp] build complete: …`. Then confirm the symbol linked: `nm kitchen-sink/bin/kitchen-sink | grep -c zapp_swift_panes_create` → `1`.

- [ ] **Step 4: GATE — human visual smoke (macOS 14), PAUSE for the user**

Run: `cd kitchen-sink && ./bin/kitchen-sink &` (the kitchen-sink window is accessory'd → takes the SwiftUI path). Ask the user to confirm:
1. The window's **content webview renders** the app (assets load via the `zapp://` scheme handler).
2. A **real Zapp service call round-trips** — e.g. the Home/greet interaction works (bridge intact inside the SwiftUI host).
3. **Devtools** open (right-click → Inspect Element, or the app's devtools affordance).
4. Title bar / traffic lights / resize all normal.
(Sidebar + inspector are expected ABSENT this task — they return in Tasks 2–3.)
Then `pkill -f "kitchen-sink/bin/kitchen-sink"`.

**If the content webview is blank or the bridge is dead → this is the risk-gate failure:** apply the IMPLEMENTER NOTE remedies; if still failing, report BLOCKED (it informs whether the whole approach needs rethinking).

- [ ] **Step 5: Commit**

```bash
git add native/platform/darwin/swift/panes.swift native/platform/darwin/window.m
git commit -m "feat(darwin): SwiftUI pane host — content pane (Sub-cycle 1 risk gate)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: add the sidebar pane (`NavigationSplitView`)

**Files:**
- Modify: `native/platform/darwin/swift/panes.swift`
- Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: Widen `panes.swift` to take a sidebar**

Replace `PaneLayout` + the `@_cdecl` with:

```swift
@available(macOS 14.0, *)
struct PaneLayout: View {
  let content: NSView
  let sidebar: NSView?
  var body: some View {
    if let sidebar {
      NavigationSplitView {
        PaneHost(view: sidebar).ignoresSafeArea()
      } detail: {
        PaneHost(view: content).ignoresSafeArea()
      }
    } else {
      PaneHost(view: content).ignoresSafeArea()
    }
  }
}

@_cdecl("zapp_swift_panes_create")
public func zapp_swift_panes_create(_ content: UnsafeMutableRawPointer,
                                    _ sidebar: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.0, *) else { return nil }
  let contentView = Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue()
  let sidebarView = sidebar.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let host = NSHostingView(rootView: PaneLayout(content: contentView, sidebar: sidebarView))
  return Unmanaged.passRetained(host).toOpaque()
}
```

- [ ] **Step 2: Thread the sidebar through the `window.m` SwiftUI branch**

Update the extern decl: `extern void* zapp_swift_panes_create(void* content, void* sidebar);`.
In the SwiftUI branch, build the **sidebar container** using the EXISTING sidebar-container code from the AppKit branch (`window.m:815-847` — the `sideVC.view` NSView, material/bg handling) — extract just the container `NSView` (call it `sidebarContainer`), no `NSSplitViewItem`. Pass it in, create its webview, register + fan-out:

```objc
            NSView* sidebarContainer = nil;
            if (useSidebar) {
                // (build sidebarContainer exactly as the AppKit branch does:
                //  NSView sized to sidebar_width × height, with material-override
                //  vfx or backgroundColor — copy window.m:816-847, minus NSSplitViewItem)
            }
            NSView* host = (__bridge_transfer NSView*)zapp_swift_panes_create(
                (__bridge void*)mainContainer, (__bridge void*)sidebarContainer);  // sidebarContainer may be nil
            window.contentView = host;

            // content webview (host_has_sidebar = useSidebar now)
            darwin_webview_create_ext(..., (__bridge void*)mainContainer, -1, 0, useSidebar, false);
            // sidebar webview (pane_role=1, HOST identity, own slot)
            if (useSidebar) {
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          sidebarUrl, sidebar_slot, true,
                                          (__bridge void*)sidebarContainer, host_slot, 1,
                                          useSidebar, false);
            }
            // register content (as Task 1) + sidebar, then fan-out slot table
            // (mirror window.m:964-991 + zapp_set_sidebar_slot at :1000)
            if (useSidebar && sidebarContainer) {
                for (NSView* sub in sidebarContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { sidebarWebviewRef = (WKWebView*)sub; break; }
                }
                if (sidebarWebviewRef) zapp_register_webview(sidebar_slot, sidebarWebviewRef, hostWindowId);
                zapp_set_sidebar_slot(host_slot, sidebar_slot);   // event fan-out
            }
```

**Do NOT call `zapp_sidebar_register`** (it takes the `splitVC` + `NSSplitViewItem` for runtime collapse/resize — a Sub-cycle-1 non-goal; there's no split item in the SwiftUI path). Event delivery uses `zapp_set_sidebar_slot`, which we DO call.

- [ ] **Step 3: Build**

`cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → `build complete`.

- [ ] **Step 4: GATE — human visual (PAUSE)**

Launch kitchen-sink. Confirm: a **sidebar column** (web content) + the **content** pane both render via SwiftUI; the sidebar's nav (`ks:nav`) drives the content pane (both bridges work). Then kill it.

- [ ] **Step 5: Commit**

```bash
git add native/platform/darwin/swift/panes.swift native/platform/darwin/window.m
git commit -m "feat(darwin): SwiftUI pane host — sidebar via NavigationSplitView

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: add the inspector pane (`.inspector`)

**Files:**
- Modify: `native/platform/darwin/swift/panes.swift`
- Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: Widen `panes.swift` to take an inspector + initial visibility**

```swift
@available(macOS 14.0, *)
struct PaneLayout: View {
  let content: NSView
  let sidebar: NSView?
  let inspector: NSView?
  @State private var showInspector: Bool

  init(content: NSView, sidebar: NSView?, inspector: NSView?, showInspector: Bool) {
    self.content = content; self.sidebar = sidebar; self.inspector = inspector
    _showInspector = State(initialValue: showInspector)
  }

  var body: some View {
    if let sidebar {
      NavigationSplitView { PaneHost(view: sidebar).ignoresSafeArea() } detail: { detail }
    } else { detail }
  }

  @ViewBuilder private var detail: some View {
    PaneHost(view: content)
      .ignoresSafeArea()
      .inspector(isPresented: $showInspector) {
        if let inspector { PaneHost(view: inspector).ignoresSafeArea() }
      }
  }
}

@_cdecl("zapp_swift_panes_create")
public func zapp_swift_panes_create(_ content: UnsafeMutableRawPointer,
                                    _ sidebar: UnsafeMutableRawPointer?,
                                    _ inspector: UnsafeMutableRawPointer?,
                                    _ showInspector: Bool) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.0, *) else { return nil }
  let c = Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue()
  let s = sidebar.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let i = inspector.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let host = NSHostingView(rootView: PaneLayout(content: c, sidebar: s, inspector: i, showInspector: showInspector))
  return Unmanaged.passRetained(host).toOpaque()
}
```

- [ ] **Step 2: Thread the inspector through `window.m`**

Update the extern: `extern void* zapp_swift_panes_create(void* content, void* sidebar, void* inspector, bool showInspector);`.
Build the **inspector container** from the AppKit branch's inspector-container code (`window.m:863-886`, minus `NSSplitViewItem`). Initial visibility = NOT collapsed: `bool showInspector = useInspector && !wopts_inspector_collapsed(opts);`. Pass it; create + register its webview; set the fan-out slot:

```objc
            NSView* inspectorContainer = nil;
            if (useInspector) { /* build as window.m:863-886, container only */ }
            bool showInspector = useInspector && !wopts_inspector_collapsed(opts);
            NSView* host = (__bridge_transfer NSView*)zapp_swift_panes_create(
                (__bridge void*)mainContainer, (__bridge void*)sidebarContainer,
                (__bridge void*)inspectorContainer, showInspector);
            window.contentView = host;
            // content _ext now passes host_has_inspector = useInspector:
            darwin_webview_create_ext(..., (__bridge void*)mainContainer, -1, 0, useSidebar, useInspector);
            // ... sidebar _ext (as Task 2, with useInspector passed for has* flags) ...
            if (useInspector) {
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          inspectorUrl, inspector_slot, true,
                                          (__bridge void*)inspectorContainer, host_slot, 3,
                                          useSidebar, useInspector);
                for (NSView* sub in inspectorContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { inspectorWebviewRef = (WKWebView*)sub; break; }
                }
                if (inspectorWebviewRef) zapp_register_webview(inspector_slot, inspectorWebviewRef, hostWindowId);
                zapp_set_inspector_slot(host_slot, inspector_slot);   // event fan-out
            }
```

Ensure the `host_has_sidebar`/`host_has_inspector` flags in ALL three `_ext` calls now reflect the real `useSidebar`/`useInspector` (so `Window.current().sidebar`/`.inspector` handles wire up in JS). **Do NOT call `zapp_inspector_register`** (split-item collapse/resize — non-goal). Also set the delegate's `inspectorWebview`/`sidebarWebview`/`mainWebview` refs (as `window.m:1042-1044`) in the SwiftUI branch so teardown still reaches the panes.

- [ ] **Step 3: Build**

`cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → `build complete`.

- [ ] **Step 4: GATE — human visual (PAUSE)**

Launch kitchen-sink. Confirm full parity via SwiftUI: **sidebar + content + inspector** all render; the inspector is a **resizable trailing column**; the kitchen-sink **Inspector section's toggle** shows/hides it (the inspector toggle action still routes — if toggle is a non-goal here, at minimum it renders in its create-time state); all three webviews' bridges work; title bar / traffic lights / toolbar intact. Then kill it.
(Note: runtime collapse/resize/width *control* parity is a Sub-cycle-3 non-goal — basic render + create-time state is the bar here.)

- [ ] **Step 5: Commit**

```bash
git add native/platform/darwin/swift/panes.swift native/platform/darwin/window.m
git commit -m "feat(darwin): SwiftUI pane host — inspector via .inspector (full macOS parity)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: gate matrix + docs + final review

**Files:**
- Modify: `docs/native-ui-strategy.md`

- [ ] **Step 1: Opted-out build links clean with NO Swift panes**

Temporarily add `native: { swiftui: false },` to `kitchen-sink/zapp.config.ts`, then:
```bash
cd kitchen-sink && bun run build 2>&1 | tail -2
nm bin/kitchen-sink | grep -c zapp_swift_panes_create   # expect 0 (not compiled in)
cd ..
```
Expected: `build complete`; symbol count `0` (the `#ifdef ZAPP_HAS_SWIFTUI` branch compiled out → AppKit path). Then **revert** the edit (`git checkout kitchen-sink/zapp.config.ts`) and confirm `git status --short kitchen-sink/zapp.config.ts` is empty.

- [ ] **Step 2: Opted-out visual smoke (PAUSE)**

With the opt-out reverted, do a one-off opted-out run if desired, OR rely on Step 1 + this reasoning: the AppKit path is byte-unchanged (it's the untouched `else`). Minimum: confirm the default (SwiftUI) build from Task 3 still launches and a **plain** (non-accessory) window — if the app has one — is unaffected. (Plain windows never enter the fork.)

- [ ] **Step 3: iOS-sim still builds (macOS-only change)**

```bash
cd kitchen-sink && bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -2 ; cd ..
```
Expected last line: `build complete`. (`panes.swift` is `#if os(macOS)`-clean by construction — it imports AppKit-only `NSView`/`NSHostingView`; confirm the iOS build doesn't try to compile it. NOTE: the `swiftc` step only runs for the **macOS** target — `resolveSwiftUIBuild` returns `non-macos` for iOS — so `panes.swift` is never compiled for iOS. If the iOS build trips on it, that's a finding to report.)

- [ ] **Step 4: CLI tests green**

```bash
bun test cli/src 2>&1 | tail -3
```
Expected: all pass (no CLI surface changed; this guards against regressions).

- [ ] **Step 5: Docs — record Sub-cycle 1 status**

In `docs/native-ui-strategy.md`, update the roadmap row for "SwiftUI-backed accessories" to note Sub-cycle 1 (macOS pane layout) shipped, and that the selection is automatic (accessory'd + macOS 14 + `native.swiftui != false`) with the AppKit fallback. Keep it consistent with the doc's style.

- [ ] **Step 6: Commit**

```bash
git add docs/native-ui-strategy.md
git commit -m "docs: native-ui-strategy — Sub-cycle 1 (macOS SwiftUI pane layout) shipped

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Final cross-cutting review**

Re-read the diff. Confirm: (a) the AppKit `else` branch is byte-unchanged (the fallback); (b) every `_ext` call in the SwiftUI branch passes the correct `pane_role` + `host_has_sidebar`/`host_has_inspector`; (c) webviews are created into containers, never re-parented; (d) `zapp_register_webview` runs for every pane + `zapp_set_sidebar_slot`/`zapp_set_inspector_slot` for fan-out; (e) the split-item accessory registries (`zapp_sidebar_register`/`zapp_inspector_register`) are intentionally skipped (non-goal) — note this as the Sub-cycle-3 follow-up (runtime collapse/resize parity); (f) no public `WindowOptions` field / env flag added. Record follow-ups in memory.

---

## Self-Review (against the spec)

**Spec coverage:**
- "SwiftUI pane layout hosting real webviews on macOS" → Tasks 1–3 (`panes.swift` + window.m fork). ✓
- "Automatic selection: accessory'd + macOS 14 + native.swiftui != false" → Task 1 Step 2 gate (`(useSidebar||useInspector) && @available(macOS 14) && #ifdef ZAPP_HAS_SWIFTUI`). ✓
- "native.swiftui:false = only opt-out + compile gate" → Task 4 Step 1 (symbol count 0 when opted out). ✓
- "SwiftUI owns only content subtree; NSWindow/title bar/toolbar/tray unchanged" → fork sets `window.contentView`; chrome/styleMask code untouched; AppKit `else` byte-unchanged. ✓
- "panes.swift auto-compiled, no build change" → File Structure note; Task 1 Step 3 nm check. ✓
- "Risk-isolating order: content first, then sidebar, then inspector" → Tasks 1/2/3. ✓
- "Verification = build gates + human visual; no unit tests" → every task; Task 4 matrix. ✓
- Non-goals (iOS, trackingSeparator, chrome-metrics KVO, runtime collapse/resize) → not tasked; the skipped accessory registries are called out in Task 4 Step 7. ✓

**Placeholder scan:** The window.m SwiftUI-branch snippets reference "build the container as the AppKit branch does (window.m:NNN)" — this is a precise instruction to copy an exact, cited region (the container-construction code is long and identical to the AppKit branch; repeating it verbatim would be error-prone vs. citing the source lines). The novel logic (assembly via `zapp_swift_panes_create`, the `_ext` calls, registration, fan-out) is shown in full. The Task-1 IMPLEMENTER NOTE flags the one genuine lifecycle unknown as a BLOCKED-able risk gate rather than hand-waving it.

**Type/name consistency:** `zapp_swift_panes_create` grows by parameters across Tasks 1→2→3 (content; +sidebar; +inspector,+showInspector) — the extern decl in window.m is updated in lockstep each task (Task 1/2/3 Step 2). `PaneHost`/`PaneLayout` names stable. `useSwiftUIPanes`, `mainContainer`/`sidebarContainer`/`inspectorContainer`, `host_slot`, `zapp_register_webview`, `zapp_set_sidebar_slot`/`zapp_set_inspector_slot` all match window.m's real identifiers. ✓
