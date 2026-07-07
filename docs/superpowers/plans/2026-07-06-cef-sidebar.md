# CEF Sidebar (Sub-Cycle C1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A chromium (`webEngine:"chromium"`) window with a sidebar renders BOTH the host pane and the sidebar pane on CEF, with collapse/expand events reaching both panes and clean per-pane teardown.

**Architecture:** The `NSSplitViewController` split builder (`window.m:927-1179`) is engine-agnostic; today it mounts a `WKWebView` into each pane container. C1 adds a `#ifdef ZAPP_HAS_CEF` branch in the pane-mounting so each pane gets `zapp_cef_create_browser_in_view` (sub-cycle B) into its container instead. The sidebar event registry (`zapp_sidebar_register`) + its emission (`darwin_window_eval_js(slot)`, which already has a `ZAPP_HAS_CEF` branch) + B's per-slot teardown are reused unchanged — the only new native code is the pane-mount CEF branch + a per-pane teardown extension.

**Tech Stack:** Objective-C/C (`native/platform/darwin/window.m`), CEF C-API via sub-cycle B (`zapp_cef_create_browser_in_view` / `zapp_cef_teardown_browser_for_slot`), Nim `SidebarOptions`, TypeScript fixture (`examples/cef-hello`), `zapp` CLI.

## Global Constraints

- **Branch:** `feat/cef-native-chrome` (off `feat/nim-native @ 389e9b6`). **Do NOT merge to `nim-native` without asking** (Windows handoff target).
- **Platform:** macOS-only, opt-in behind `webEngine:"chromium"` → `ZAPP_HAS_CEF`.
- **Byte-identical `system` builds:** the new CEF branch is inside `#ifdef ZAPP_HAS_CEF` in the pane-mounting; the WKWebView pane path is the unchanged `#else`. A `webEngine:"system"` build is unaffected.
- **Reuse, don't reinvent:** the CEF browser per pane is `zapp_cef_create_browser_in_view(parent_view, url, slot, window_id, owner_id)` (B); pane teardown is `zapp_cef_teardown_browser_for_slot(slot)` (B); the split builder, `zapp_sidebar_register`, and the event emission are engine-agnostic and UNCHANGED.
- **CEF panes are opaque:** mount into `contentVC.view` (`mainContainer`, window.m:949) / `sidebarContainer` directly; no vibrancy `svfx` wrapper (a non-OSR Alloy CEF browser renders its own background — vibrancy-on-CEF is a non-goal).
- **Pane JS identity = host id** (`win-<host_slot>`), mirroring the WK path's `zapp_register_webview(sidebar_slot, wv, hostWindowId)`. Transport routes by slot.
- **Engine-switch clean build:** `rm -rf ~/.cache/nim/app_r` before every `bun run build`.
- **Canonical gate:** root `bun run check` + `bun run test`. NOT per-example `bunx tsc` (pre-existingly fails — see `reference_example_app_tsc_gate`).
- **Inclusive language:** allowlist/blocklist.
- **Scope:** C1 = SIDEBAR only. Inspector-on-CEF is C2 (leave the inspector pane path WK-only / note it); toolbar is C3.

---

### Task 1: Mount CEF browsers in the sidebar split panes + fixture

Add the `ZAPP_HAS_CEF` branch in the pane-mounting so a chromium window with a sidebar hosts a CEF browser in the host AND sidebar pane containers, and extend the `cef-hello` fixture so window 1 has a sidebar (window 2 stays plain). Deliverable: both panes render on Chromium and receive worker/collapse events. Interim: teardown still only covers the host slot (Task 2 adds the sidebar slot) — this task's gate does not CLOSE the window.

**Files:**
- Modify: `native/platform/darwin/window.m` (the pane-mounting block, ~1101-1157)
- Modify: `examples/cef-hello/zapp/app.nim` (window 1 gains `sidebar`)
- Modify: `examples/cef-hello/src/main.ts` (render host-vs-sidebar by route + both subscribe to `tick`)

**Interfaces:**
- Consumes (from B): `void zapp_cef_create_browser_in_view(void* parent_view, const char* url, int32_t window_slot, const char* window_id, const char* owner_id)`; `NSURL* zapp_resolve_url(const char* url_cstr)`; the `zapp_cef_browsers[]` registry (auto-populated in `on_after_created`); `zapp_window_ids[]` (window.m).
- Produces (for Task 2): CEF browsers registered at `host_slot` AND `sidebar_slot` for a sidebar window; the delegate's `sidebarNumericId` = `sidebar_slot`.

- [ ] **Step 1: Read the exact pane-mounting block**

Read `native/platform/darwin/window.m:1101-1179`. Confirm: `mainContainer` (=`contentVC.view`, line 949), `sidebarContainer`, `host_slot`, `sidebar_slot`, `custom_url`, `sidebarUrl`, `useSidebar`, `useInspector`, and the `hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot]` (line 1130) are all in scope. The WK pane-mounting is lines 1107-1122; the WK registration is 1124-1157; the engine-agnostic registries are 1163-1179.

- [ ] **Step 2: Wrap the pane-mounting + registration in an engine branch**

Replace the WK pane-mounting + registration (window.m:1107-1157) so it runs only under `#else`, and add the CEF branch under `#ifdef ZAPP_HAS_CEF`. Move the `hostWindowId` declaration (currently line 1130) ABOVE the branch so both arms see it:

```objc
            NSString* hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot];
#ifdef ZAPP_HAS_CEF
            // C1: webEngine:"chromium" — host a CEF browser in EACH pane container
            // (sub-cycle B's create, per-pane slot, HOST js identity). The split
            // builder above + the sidebar registry below are engine-agnostic;
            // collapse/expand/resize events reach these panes via
            // darwin_window_eval_js's ZAPP_HAS_CEF branch (window.m:650). CEF panes
            // are opaque (no vibrancy). Inspector-on-CEF is sub-cycle C2.
            extern NSURL* zapp_resolve_url(const char* url_cstr);
            extern void zapp_cef_create_browser_in_view(void* parent_view, const char* url,
                                                        int32_t window_slot,
                                                        const char* window_id,
                                                        const char* owner_id);
            NSString* paneOwnerId = [NSString stringWithFormat:@"owner-%d", host_slot];
            {
                NSURL* hostNsUrl = zapp_resolve_url(custom_url);
                const char* hostCefUrl = hostNsUrl ? [[hostNsUrl absoluteString] UTF8String] : "zapp://index.html";
                if (!hostCefUrl || hostCefUrl[0] == '\0') hostCefUrl = "zapp://index.html";
                zapp_cef_create_browser_in_view((__bridge void*)mainContainer, hostCefUrl, host_slot,
                                                [hostWindowId UTF8String], [paneOwnerId UTF8String]);
            }
            if (useSidebar) {
                NSURL* sbNsUrl = zapp_resolve_url(sidebarUrl);
                const char* sbCefUrl = sbNsUrl ? [[sbNsUrl absoluteString] UTF8String] : "zapp://index.html";
                if (!sbCefUrl || sbCefUrl[0] == '\0') sbCefUrl = "zapp://index.html";
                zapp_cef_create_browser_in_view((__bridge void*)sidebarContainer, sbCefUrl, sidebar_slot,
                                                [hostWindowId UTF8String], [paneOwnerId UTF8String]);
            }
            // Inspector pane on CEF is sub-cycle C2; a chromium app must not set an
            // inspector pane yet (the fixture does not).
            // Register the host's JS id string so Window.current() round-trips
            // (mirrors the WK zapp_register_webview identity, without a WKWebView).
            if (host_slot >= 0 && host_slot < ZAPP_MAX_WINDOW_CALLBACKS)
                zapp_window_ids[host_slot] = hostWindowId;
#else
            // --- WKWebView pane path (unchanged; the original lines 1107-1157) ---
            darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                      custom_url, host_slot, useVibrancy,
                                      (__bridge void*)mainContainer, -1, 0,
                                      useSidebar, useInspector);
            if (useSidebar) {
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          sidebarUrl, sidebar_slot, true,
                                          (__bridge void*)sidebarContainer, host_slot, 1,
                                          useSidebar, useInspector);
            }
            if (useInspector) {
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          inspectorUrl, inspector_slot, true,
                                          (__bridge void*)inspectorContainer, host_slot, 3,
                                          useSidebar, useInspector);
            }
            for (NSView* sub in mainContainer.subviews) {
                if ([sub isKindOfClass:[WKWebView class]]) {
                    mainWebviewRef = (WKWebView*)sub;
                    zapp_register_webview(host_slot, mainWebviewRef, hostWindowId);
                    break;
                }
            }
            if (useSidebar) {
                for (NSView* sub in sidebarContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { sidebarWebviewRef = (WKWebView*)sub; break; }
                }
                if (sidebarWebviewRef) zapp_register_webview(sidebar_slot, sidebarWebviewRef, hostWindowId);
            }
            if (useInspector) {
                for (NSView* sub in inspectorContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { inspectorWebviewRef = (WKWebView*)sub; break; }
                }
                if (inspectorWebviewRef) zapp_register_webview(inspector_slot, inspectorWebviewRef, hostWindowId);
            }
#endif
```

Leave the registries below (window.m:1163-1179, `zapp_set_sidebar_slot` + `zapp_sidebar_register` + `zapp_set_inspector_slot` + `zapp_inspector_register`) OUTSIDE the branch — they are engine-agnostic and must run for CEF too. Preserve the original WK code EXACTLY in the `#else` (copy the current 1107-1157 verbatim; the block above reproduces it — verify against the file).

- [ ] **Step 3: Fixture — window 1 gets a sidebar**

In `examples/cef-hello/zapp/app.nim`, add a `sidebar` to window 1's `WindowOptions` (leave window 2 plain), mirroring kitchen-sink:

```nim
  let win = app.window.create(WindowOptions(
    title: "CEF Hello",
    visible: false,
    width: 640, height: 360,
    inspectable: Inspectable.Auto,
    sidebar: SidebarOptions(url: "#sidebar-pane", title: "CEF Sidebar",
                            width: 240, minWidth: 150, maxWidth: 320,
                            presentation: SidebarPresentation.Default),
  ))
```
(Widen the window to 640×360 so host + sidebar both have room. `SidebarOptions`/`SidebarPresentation` are already imported via `import zapp` — confirm; if not, add the import.)

- [ ] **Step 4: Fixture — render host vs sidebar by route + both subscribe to tick**

In `examples/cef-hello/src/main.ts`, distinguish the pane by `location.hash` and have BOTH subscribe to `tick` (proving the worker broadcast fans to both CEF panes). Replace the `#which` line:

```ts
const isSidebar = location.hash === "#sidebar-pane";
which.textContent = isSidebar
  ? `SIDEBAR pane (window ${Window.current().id})`
  : `HOST pane (window ${Window.current().id})`;
if (isSidebar) document.body.style.background = "#f0f4ff";
```
The existing `Events.on("tick", …)` stays — it runs in BOTH panes, so both `#tick` counters increment. (The sidebar pane loads `zapp://index.html#sidebar-pane`; the same bundle renders the sidebar variant.)

- [ ] **Step 5: Build + R0 render gate**

Run:
```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expect `[zapp] CEF app bundle:` + `[zapp] build complete:`. Then:
```bash
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
**R0 gate:** window 1 shows a **sidebar column + a host column, both on Chromium**, each with its `HOST pane`/`SIDEBAR pane` label and **both tick counters incrementing** (broadcast fans to both CEF panes). Collapsing/expanding the sidebar (drag the divider, or `sidebar:collapse`/`expand` if the fixture wires a button) — both panes stay live; window 2 is a plain single-pane CEF window. Do NOT close window 1 yet (Task 2). Ctrl-C.

Headless evidence: `… 2>&1 | grep -E "browser created \(slot"` — expect THREE `browser created (slot N)` (window 1 host + sidebar, window 2 host).

- [ ] **Step 6: Commit**

```bash
git add native/platform/darwin/window.m examples/cef-hello/zapp/app.nim examples/cef-hello/src/main.ts
git commit -m "feat(cef): host CEF browsers in sidebar split panes (C1) + fixture"
```

---

### Task 2: Per-pane teardown

B's `windowWillClose:` CEF teardown closes only the host slot. Extend it to tear down every pane's CEF browser (host + sidebar) so closing a sidebar window is leak-free.

**Files:**
- Modify: `native/platform/darwin/window.m` (the `windowWillClose:` `ZAPP_HAS_CEF` branch)

**Interfaces:**
- Consumes: `zapp_cef_teardown_browser_for_slot(int32_t)` (B); the delegate's `numericId` (host), `sidebarNumericId` (sidebar).

- [ ] **Step 1: Extend the windowWillClose CEF teardown to all panes**

In `window.m`'s `windowWillClose:` `#ifdef ZAPP_HAS_CEF` branch (added in B — currently tears down `self.numericId` only), tear down the sidebar (and, forward-compat, inspector) pane slots too:

```objc
#ifdef ZAPP_HAS_CEF
    extern void zapp_cef_teardown_browser_for_slot(int32_t slot);
    if (self.numericId >= 0 && self.numericId < ZAPP_MAX_WINDOW_CALLBACKS)
        zapp_cef_teardown_browser_for_slot(self.numericId);        // host pane
    if (self.sidebarNumericId >= 0 && self.sidebarNumericId < ZAPP_MAX_WINDOW_CALLBACKS)
        zapp_cef_teardown_browser_for_slot(self.sidebarNumericId); // sidebar pane (C1)
    if (self.inspectorNumericId >= 0 && self.inspectorNumericId < ZAPP_MAX_WINDOW_CALLBACKS)
        zapp_cef_teardown_browser_for_slot(self.inspectorNumericId); // inspector pane (C2)
#endif
```
(`zapp_cef_teardown_browser_for_slot` no-ops when a slot has no CEF browser, so the host-only and inspector-absent cases are safe. Match the exact current branch shape in the file.)

- [ ] **Step 2: Build + R0 close gate**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
**R0 gate:** close window 1 (the sidebar window) → the console logs `teardown_browser` + `browser closed` for **BOTH** the host slot AND the sidebar slot (no leak); window 2 stays alive + ticking. Then close window 2 → clean quit. (Regression: window 1's two panes still render + tick before closing.)

- [ ] **Step 3: Commit**

```bash
git add native/platform/darwin/window.m
git commit -m "feat(cef): per-pane teardown for sidebar windows (host + sidebar slots)"
```

---

### Task 3: Docs

**Files:**
- Modify: `spikes/cef-macos/FINDINGS.md`
- Modify: `examples/cef-hello/SMOKE.md`

**Interfaces:** none (docs).

- [ ] **Step 1: FINDINGS**

Add a sub-cycle C1 section: sidebar-on-CEF CLOSED — CEF browsers hosted in the `NSSplitViewController` sidebar/host pane containers via B's `zapp_cef_create_browser_in_view`; the split builder + sidebar event registry + `darwin_window_eval_js` collapse/expand delivery are engine-agnostic (reused unchanged); per-pane teardown (host + sidebar slots). Note the **north star**: this is the first native-chrome element on CEF toward running full `kitchen-sink` on chromium; **C2 = inspector** (mirrors sidebar), **C3 = toolbar**. Note the CEF-panes-are-opaque (no vibrancy) limitation.

- [ ] **Step 2: SMOKE**

Add GATE rows (human-confirmed, dated): sidebar window renders host + sidebar on Chromium; worker broadcast reaches both panes; collapse/expand delivers events to both; per-pane teardown on close (host + sidebar `browser closed`); window 2 plain regression.

- [ ] **Step 3: Verify + commit**

Run (repo root): `bun run check && bun run test` — expect green/unchanged. Then:
```bash
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): close sub-cycle C1 sidebar-on-CEF + gates"
```

---

## Self-Review

**Spec coverage:** §1 route-through-split → Task 1 Step 2. §2 per-pane CEF create → Task 1 Step 2. §3 events (engine-agnostic, via `darwin_window_eval_js` CEF branch) → verified no code change needed; gated in Task 1 Step 5. §4 per-pane teardown → Task 2. §5 toggle (divider/existing API) → Task 1 Step 5 gate. Fixture (window 1 sidebar, window 2 plain) → Task 1 Steps 3-4. Non-goals (inspector C2, toolbar C3, vibrancy) → left WK-only / documented Task 3.

**Placeholder scan:** Task 1 Step 2's `#else` reproduces the current WK code — the step says to verify it verbatim against the file (not a placeholder; it's the real preservation requirement). No TBD/TODO. Every code step has complete code.

**Type/name consistency:** `zapp_cef_create_browser_in_view` / `zapp_cef_teardown_browser_for_slot` signatures match B; `host_slot`/`sidebar_slot`/`hostWindowId`/`mainContainer`/`sidebarContainer` match window.m's existing names; `sidebarNumericId`/`inspectorNumericId` match the delegate; `SidebarOptions` fields match kitchen-sink. `zapp_window_ids[host_slot]` write matches the existing table.
