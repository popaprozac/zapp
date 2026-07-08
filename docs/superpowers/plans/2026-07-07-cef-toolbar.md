# CEF Toolbar (sub-cycle C3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a native `NSToolbar` render and behave correctly on a `webEngine:"chromium"` (CEF) window — panes fill under the toolbar, `trackingSeparator` tracks the sidebar divider, and chrome-metrics reach the panes.

**Architecture:** The toolbar is native chrome and mostly engine-agnostic (attach, clicks, toggles already work on CEF — established by the spike, commit `1c83c9c`). C3 fixes three CEF-specific defects: (A) CEF browser views don't re-fill after the toolbar shrinks the content-layout rect; (B) the `trackingSeparator` mis-tracks (likely the same root cause as A); (C) `zapp_toolbar_inject_metrics` is WK-only. Task 1 is a **systematic-debugging investigation** (A+B share a suspected root cause); Task 2 is a known-shape injection fix. All CEF code gated so a `webEngine:"system"` build is byte-identical.

**Tech Stack:** Objective-C (`native/platform/darwin/cef/zapp_cef_host.m`, `window.m`, `toolbar.m`), CEF C-API, the `cef-hello` fixture (Nim/TS/HTML).

## Global Constraints

- **macOS-only, opt-in, gated:** every new CEF line inside `#ifdef ZAPP_HAS_CEF`. A `webEngine:"system"` build MUST be byte-identical — the WK toolbar/metrics path is UNCHANGED.
- **Task 1 (A/B) is diagnose-first:** use `superpowers:systematic-debugging` — reproduce → instrument → root cause → **minimal** fix → gate. The hypotheses below are starting points to CONFIRM, not code to transcribe. Do NOT fabricate a fix; find the real cause first.
- **Verification is native build + human R0 gate** (GUI/native code, no unit-test harness — same as C1/C2). Do NOT write unit tests that assert nothing.
- **Fixture:** the spike fixture (`cef-hello` window 1 has a toolbar + a `toolbar click:` readout + a `--zapp-toolbar-height:` readout, commit `1c83c9c`) IS the C3 fixture. Refine only if a gate needs it.
- **Engine flip:** before a chromium build, `rm -rf ~/.cache/nim/app_r`.
- **Canonical typecheck:** root `bun run check`.
- **Branch:** `feat/cef-toolbar` off `feat/nim-native`. NO merge to `nim-native` without asking.
- **Inclusive language:** allowlist/blocklist.

---

### Task 1: Diagnose + fix CEF pane layout under the toolbar (gates A + B)

**Files:**
- Investigate/modify: `native/platform/darwin/cef/zapp_cef_host.m` (CEF browser view sizing, ~200-260)
- Possibly modify: `native/platform/darwin/cef/zapp_cef_client.c` (life-span `on_after_created` — where the browser view first exists) and/or `native/platform/darwin/window.m` (toolbar attach ~1403; CEF pane re-layout)
- Possibly modify: `native/platform/darwin/toolbar.m` (only if B is a distinct `trackingSeparator` cause, ~230-250)

**Interfaces:**
- Consumes: `zapp_cef_browser_for_slot(int32_t)`, `get_host`/`get_window_handle` (the SetAsChild NSView), `zapp_cef_window_for_slot` (C1). The toolbar attaches at `window.m:1403` one runloop tick after pane create.
- Produces: CEF panes that fill their containers after the toolbar attaches; a correctly-tracking `trackingSeparator`. No new cross-file symbols expected (an in-place layout fix), but if one is added, name it in the report.

**Starting hypothesis (CONFIRM, do not assume):** the CEF browser view is created SetAsChild sized to `parent.bounds` at create time (`zapp_cef_host.m:207`). The comment at `zapp_cef_host.m:211-214` *claims* CEF sets a width/height-sizable autoresizing mask on its browser view so it tracks the parent — but the toolbar attaches a tick LATER (`window.m:1403`), shrinking `contentLayoutRect`; the spike shows the CEF view does NOT re-fill (dark band, A), and the resulting mis-sized panes throw off the split divider the `trackingSeparator` follows (B). Likely fix: explicitly set `NSViewWidthSizable | NSViewHeightSizable` on the CEF browser view (via `get_window_handle`) once it exists, and/or re-layout the CEF panes after the toolbar attaches.

- [ ] **Step 1: Reproduce + instrument**

Build the spike fixture and confirm the defects, then instrument the CEF view geometry.
```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Add a TEMPORARY diagnostic (remove before commit): after the toolbar attaches (`window.m:1403` block, inside `#ifdef ZAPP_HAS_CEF`), for the host slot log the CEF browser view's frame + autoresizingMask vs its superview's bounds — resolve the view via `zapp_cef_browser_for_slot(host_slot)` → `get_host` → `get_window_handle` (release the host ref once, like `zapp_cef_window_for_slot` at `zapp_cef_host.m:329`). Run and read: is the CEF view's frame smaller than / offset from its superview after the toolbar attaches? Is the autoresizing mask actually set? This is Phase-1 evidence — do NOT fix yet.

- [ ] **Step 2: Root cause**

From the evidence, state the cause in one sentence (e.g. "CEF's browser view has autoresizingMask=0, so it keeps its pre-toolbar frame when the container shrinks"). If the evidence contradicts the hypothesis (e.g. the mask IS set and the frame IS correct but a dark band persists — pointing at the container/split, not the CEF view), follow the evidence to the real cause. If A and B have DIFFERENT causes, note both.

- [ ] **Step 3: Minimal fix (A)**

Implement the smallest fix the root cause dictates, gated `#ifdef ZAPP_HAS_CEF`. If the cause is the autoresizing mask: once the browser exists (its NSView is only available after `on_after_created` — set it there via `zapp_cef_browser_for_slot`/`get_window_handle`, or in a post-attach re-layout pass), do:
```objc
NSView* cefView = /* (__bridge NSView*)get_window_handle(host) */;
cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
cefView.frame = cefView.superview.bounds;   // snap to current container bounds
```
(Adjust to the actual cause. If instead the containers/split don't fill `contentLayoutRect`, fix that layer.) Keep it CEF-only; do not touch the WK path.

- [ ] **Step 4: Build + verify A**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Remove the Step-1 diagnostic. Confirm the build markers. (Visual "no dark band" is the human R0 gate, Step 7.)

- [ ] **Step 5: Assess gate B (trackingSeparator)**

Re-check the `trackingSeparator` after the A fix. It resolves the split engine-agnostically (`toolbar.m:236-250`: `contentViewController` → `NSSplitViewController.splitView`, `dividerIndex` 0 for sidebar). If A's fix corrected the pane/divider geometry, B likely resolves — confirm at the R0 gate. If B persists (separator still mis-tracks with panes now filling), diagnose it separately: is the `trackingSeparator` created before the split is laid out (timing), or is the divider index wrong for a 3-pane split? Apply a minimal CEF-safe fix. Do NOT change WK behavior.

- [ ] **Step 6: Commit**

```bash
git add native/platform/darwin/cef/zapp_cef_host.m native/platform/darwin/window.m
# add zapp_cef_client.c / toolbar.m only if the fix touched them
git commit -m "fix(cef): CEF panes fill under the toolbar + trackingSeparator tracks (C3 A/B)"
```

- [ ] **Step 7: Human R0 gates A + B** (controller runs these WITH the user)

```bash
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
- **A** — window 1's toolbar sits flush above the panes, NO dark band; sidebar/host/inspector render up to the toolbar's bottom edge; resizing keeps them filling.
- **B** — the sidebar-toggle sits at the sidebar↔host divider; collapsing the sidebar moves the separator toward leading (tracking the divider), not sliding the wrong way.
- **Regression** — toolbar click still delivers `{id}` to the host pane; `toggleSidebar`/`toggleInspector` still work; window 2 toolbar-free; per-pane teardown clean.

---

### Task 2: Chrome-metrics injection for CEF (gate C)

**Files:**
- Modify: `native/platform/darwin/toolbar.m` (`zapp_toolbar_inject_metrics`, ~923-953)

**Interfaces:**
- Consumes: `darwin_window_eval_js(int32_t window_id, const char* js)` — the CEF-aware per-slot eval (has the `ZAPP_HAS_CEF` branch reaching the CEF browser at that slot; used by C1's sidebar events). `zapp_webview_for_slot(int32_t)` returns `WKWebView*` (nil for CEF).
- Produces: `--zapp-titlebar-height` / `--zapp-toolbar-height` (+ host safe-area vars) reaching CEF panes.

**Problem:** `zapp_toolbar_inject_metrics` builds the metrics JS (`toolbar.m:917-921` for `js`, `938-945` for host `saJs`) then injects per slot via `zapp_webview_for_slot(slots[i])` → `WKWebView` → `evaluateJavaScript`. For CEF, `zapp_webview_for_slot` is nil, so the loop's `if (!wv) continue;` (`toolbar.m:926`) SKIPS every CEF pane → the vars are never set (spike confirmed `--zapp-toolbar-height` empty on CEF).

- [ ] **Step 1: Route the pane-metrics loop through the CEF-aware eval**

In `zapp_toolbar_inject_metrics`'s slot loop (`toolbar.m:924-933`), when `zapp_webview_for_slot(slots[i])` is nil, fall back to the CEF-aware eval instead of skipping:
```objc
for (int i = 0; i < 3; i++) {
    if (slots[i] < 0) continue;
    WKWebView* wv = zapp_webview_for_slot(slots[i]);
    if (wv) {
        if (add_user_script) {
            [wv.configuration.userContentController addUserScript:
                [[WKUserScript alloc] initWithSource:js
                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
        }
        [wv evaluateJavaScript:js completionHandler:nil];
    }
#ifdef ZAPP_HAS_CEF
    else {
        // CEF pane: no WKWebView. Route through the CEF-aware per-slot eval
        // (darwin_window_eval_js's ZAPP_HAS_CEF branch reaches the CEF browser
        // at this slot). No WKUserScript equivalent on CEF — reload-persistence
        // is handled by re-injection on layout changes (KVO) + Step 2.
        extern void darwin_window_eval_js(int32_t window_id, const char* js);
        darwin_window_eval_js(slots[i], [js UTF8String]);
    }
#endif
}
```
Apply the same `#ifdef ZAPP_HAS_CEF` else-branch to the host `saJs` injection (`toolbar.m:946-953`): when `hostWv` is nil, `darwin_window_eval_js(host_slot, [saJs UTF8String])`. The WK arm is behaviorally unchanged (the `else` only runs when `wv`/`hostWv` is nil, which never happens on WK) → `system` build byte-identical.

- [ ] **Step 2: Reload-persistence note / re-inject**

WK uses `WKUserScript` so the vars survive a page reload; CEF has none. The KVO (`contentLayoutRect`) re-injects on layout changes but NOT on a plain reload. Check whether the CEF client has a load-end hook (grep `zapp_cef_client.c` for `on_load_end`/`OnLoadEnd`/load-state). If there's a clean hook, re-call the metrics injection for that window there (CEF-only). If there is NOT a clean hook this cycle, DOCUMENT it as a known limitation (CEF toolbar metrics re-apply on the next layout change, not instantly on a manual reload) — do not build new load-event plumbing just for this; note it for the docs task. State which path you took in the report.

- [ ] **Step 3: Build**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expected: both markers; no errors.

- [ ] **Step 4: Commit**

```bash
git add native/platform/darwin/toolbar.m
git commit -m "fix(cef): route toolbar chrome-metrics through the CEF-aware eval (C3 C)"
```

- [ ] **Step 5: Human R0 gate C** (controller runs with the user)

Run window 1; the `--zapp-toolbar-height:` readout shows a NON-EMPTY pixel value on the CEF panes (was empty in the spike). Switch the toolbar's Icon/Text display mode (toolbar context menu) → the value updates. WK regression: a `webEngine:"system"` toolbar app still gets its vars (unchanged path).

---

### Task 3: Docs — close sub-cycle C3

**Files:**
- Modify: `spikes/cef-macos/FINDINGS.md`
- Modify: `examples/cef-hello/SMOKE.md`

- [ ] **Step 1: FINDINGS — record C3 closed**

Append a C3 section (match the file's structure/tone). Record: the toolbar is native chrome, mostly engine-agnostic (attach/clicks/toggles inherited — spike `1c83c9c`); C3 fixed (A) CEF panes filling under the toolbar + (B) `trackingSeparator` tracking [state the actual root cause found in Task 1] and (C) routed chrome-metrics through the CEF-aware eval. Note the reload-persistence outcome from Task 2 Step 2. Deferred (unchanged): host-event fan-out (WK-only, post-C3 foundational); vibrancy-opacity; devtools (D).

- [ ] **Step 2: SMOKE — record the C3 gates**

Add the C3 gates (match the GATE format): panes fill under the toolbar (no dark band); `trackingSeparator` tracks the sidebar divider; `--zapp-toolbar-height` populated on CEF + updates on display-mode change; regression (click→host, toggles, window 2 toolbar-free, per-pane teardown).

- [ ] **Step 3: Verify + commit**

```bash
bun run check && bun run test
```
Expected: green (docs-only; 292 pass / 0 fail).
```bash
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): close sub-cycle C3 toolbar-on-CEF — findings + gates"
```

---

## Self-Review

**1. Spec coverage:**
- Fix 1 (A panes fill + B trackingSeparator) → Task 1 (diagnose-first, gates A + B). ✅
- Fix 2 (C chrome-metrics) → Task 2 (route through `darwin_window_eval_js`, gate C). ✅
- Byte-identical WK / `#ifdef` gating → Global Constraints + each task's CEF-only edits. ✅
- Regression gates (click, toggles, window 2, teardown) → Task 1 Step 7. ✅
- Fixture = spike `1c83c9c` → Global Constraints. ✅
- Docs + deferred non-goals → Task 3. ✅

**2. Placeholder scan:** Task 1 is intentionally diagnose-first (systematic-debugging) — its "fix" code is a clearly-labeled *likely* fix to confirm, not a fabricated final answer; this is correct for an undiagnosed native bug, not a placeholder. Task 2 has concrete code. No "TBD"/"handle edge cases"/assertion-free tests.

**3. Type consistency:** `darwin_window_eval_js(int32_t, const char*)` matches its C1 usage; `zapp_webview_for_slot`/`zapp_cef_browser_for_slot`/`get_window_handle` signatures match the existing call sites; `NSViewWidthSizable | NSViewHeightSizable` and the `slots[3]` loop match `toolbar.m`.
