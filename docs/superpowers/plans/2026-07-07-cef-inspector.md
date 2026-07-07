# CEF Inspector (sub-cycle C2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Host a CEF browser in an `NSSplitViewController` inspector pane on `webEngine:"chromium"` windows — a direct mirror of C1's sidebar arm — so a chromium window with an inspector renders + controls it, coexisting with a sidebar.

**Architecture:** Add one inspector arm (`pane_role=3`) to `window.m`'s existing `#ifdef ZAPP_HAS_CEF` pane-mount branch, mirroring the host/sidebar arms. Everything else is inherited unchanged from C1: the engine-agnostic split builder (already builds `inspectorContainer`), the window resolver (imperative inspector control on CEF), the shared bootstrap-carrier builder (`hasInspector`/`isInspector` Symbols), per-pane teardown (`inspectorNumericId`), and the inspector event registry + `inspector.m` events. Gated so a `webEngine:"system"` (WKWebView) build is byte-identical.

**Tech Stack:** Objective-C (`native/platform/darwin/window.m`), CEF C-API (sub-cycle B's `zapp_cef_create_browser_in_view`), Nim fixture (`examples/cef-hello/zapp/app.nim`), TypeScript + HTML fixture (`examples/cef-hello/src/main.ts`, `index.html`).

## Global Constraints

- **macOS-only, opt-in, gated:** every new CEF line goes inside `#ifdef ZAPP_HAS_CEF`. A `webEngine:"system"` build MUST be byte-identical — the WK `#else` inspector path is UNCHANGED.
- **Mirror, don't invent:** the inspector arm mirrors the existing sidebar arm (`window.m:1153-1169`) with `pane_role=3`. Do not add new APIs, do not touch the resolver/carriers/teardown/registries/events — all inherited from C1 and already inspector-aware.
- **Verification is native build + headless evidence + human R0 gate** (this is GUI/native code with no unit-test harness — same as C1). Do NOT write unit tests that assert nothing.
- **Engine flip:** before a chromium build, `rm -rf ~/.cache/nim/app_r` (stale Nim cache across engine change).
- **Canonical typecheck:** root `bun run check` (NOT per-example `bunx tsc`, which pre-existingly fails on runtime enums).
- **Branch:** `feat/cef-inspector` off `feat/nim-native`. NO merge to `nim-native` without asking.
- **Inclusive language:** allowlist/blocklist, never whitelist/blacklist.

---

### Task 1: Inspector arm in the CEF pane-mount branch + fixture

**Files:**
- Modify: `native/platform/darwin/window.m` (the `#ifdef ZAPP_HAS_CEF` pane-mount branch, after the sidebar arm ~line 1169)
- Modify: `examples/cef-hello/zapp/app.nim` (window 1 gains inspector opts)
- Modify: `examples/cef-hello/index.html` (a "toggle inspector" button)
- Modify: `examples/cef-hello/src/main.ts` (inspector-pane branch + toggle-inspector wiring)

**Interfaces:**
- Consumes (from sub-cycle B / C1, unchanged): `zapp_cef_create_browser_in_view(void* parent_view, const char* url, int32_t window_slot, const char* window_id, const char* owner_id, int pane_role, bool host_has_sidebar, bool host_has_inspector)`; `zapp_resolve_url(const char*)`; the in-scope locals `inspectorUrl`, `inspector_slot` (`= wopts_inspector_numeric_id(opts)`), `inspectorContainer`, `useInspector`, `useSidebar`, `hostWindowId`, `paneOwnerId`, `window`, `zapp_window_ids[]`.
- Produces: a CEF browser mounted in `inspectorContainer` registered at `zapp_cef_browsers[inspector_slot]`, carrying host identity, with `pane_role=3` (→ `zapp.isInspector` carrier).

- [ ] **Step 1: Add the inspector arm to the CEF pane-mount branch**

In `native/platform/darwin/window.m`, inside the `#ifdef ZAPP_HAS_CEF` pane-mount branch, immediately AFTER the sidebar arm's closing `}` (the block guarded by `if (useSidebar) { … }`, ending ~line 1169) and BEFORE the host-slot identity registration comment (`// Register the host's JS id string …`, ~line 1170), insert:

```objc
            if (useInspector) {
                NSURL* insNsUrl = zapp_resolve_url(inspectorUrl);
                const char* insCefUrl = insNsUrl ? [[insNsUrl absoluteString] UTF8String] : "zapp://index.html";
                if (!insCefUrl || insCefUrl[0] == '\0') insCefUrl = "zapp://index.html";
                // Inspector pane: pane_role=3 (zapp.isInspector) + the same
                // composition flags, so this pane's Window.current() resolves
                // .inspector and imperative toggle/collapse works on CEF
                // (inherits C1's resolver + shared-carrier fixes).
                zapp_cef_create_browser_in_view((__bridge void*)inspectorContainer, insCefUrl, inspector_slot,
                                                [hostWindowId UTF8String], [paneOwnerId UTF8String],
                                                3, useSidebar, useInspector);
                // Mirrors the WK path's zapp_register_webview(inspector_slot, ...,
                // hostWindowId) so Workers.create() from JS in the CEF inspector
                // pane resolves its owner (router.nim's darwin_window_id_string).
                if (inspector_slot >= 0 && inspector_slot < ZAPP_MAX_WINDOW_CALLBACKS)
                    zapp_window_ids[inspector_slot] = hostWindowId;
            }
```

Confirm before editing: `inspectorUrl` and `inspector_slot` are already declared above (the `useInspector` guard at ~`window.m:942-943` uses both), and `inspectorContainer` is built by the split builder at ~`window.m:1057-1073`. If any is NOT in scope in the CEF branch, STOP and report — do not invent a substitute.

Also update the CEF-branch comment at ~`window.m:1131` — it currently says "Inspector-on-CEF is sub-cycle C2 — a chromium app must not set an inspector pane yet (the fixture doesn't)." Change it to reflect that the inspector arm now exists:

```objc
            // are opaque (no vibrancy). Sidebar (C1) + inspector (C2) panes are
            // each hosted below by their own arm, mirroring the WK #else.
```

- [ ] **Step 2: Give window 1 an inspector (fixture — Nim)**

In `examples/cef-hello/zapp/app.nim`, add an `inspector` field to window 1's `WindowOptions`, right after the `sidebar:` field:

```nim
    sidebar: SidebarOptions(url: "#sidebar-pane", title: "CEF Sidebar",
                            width: 240, minWidth: 150, maxWidth: 320,
                            presentation: SidebarPresentation.Default),
    inspector: InspectorOptions(url: "#inspector-pane", title: "CEF Inspector",
                                width: 240, minWidth: 180, maxWidth: 320),
  ))
```

(`InspectorOptions` is exported by `import zapp`; note it has NO `presentation` field — that is sidebar-only. Defaults: width 280 / minWidth 180 / maxWidth 400.)

Also update the file's header comment: the line "Inspector-on-CEF is sub-cycle C2 — neither window sets one yet." should become "Sub-cycle C2: window 1 now ALSO has an `inspector`, so it is a 3-pane CEF window (sidebar + host + inspector). Window 2 stays plain/fullbleed."

- [ ] **Step 3: Add a "toggle inspector" button (fixture — HTML)**

In `examples/cef-hello/index.html`, add an inspector toggle button immediately after the existing `#toggle-sb` button:

```html
      <button id="toggle-sb">toggle sidebar</button>
      <button id="toggle-insp">toggle inspector</button>
```

- [ ] **Step 4: Inspector-pane branch + toggle wiring (fixture — TS)**

In `examples/cef-hello/src/main.ts`:

(a) After the `const isSidebar = …` line, add inspector detection and extend the `which` label + tint:

```ts
const isSidebar = location.hash === "#sidebar-pane";
const isInspector = location.hash === "#inspector-pane";
which.textContent = isInspector
  ? `INSPECTOR pane (window ${Window.current().id})`
  : isSidebar
    ? `SIDEBAR pane (window ${Window.current().id})`
    : `HOST pane (window ${Window.current().id})`;
if (isSidebar) document.body.style.background = "#f0f4ff";
if (isInspector) document.body.style.background = "#fff4f0"; // distinct tint from the sidebar
```

(b) Replace the existing host-pane toggle block (the `if (!isSidebar) { … Window.current().sidebar?.toggle() … }` at the end of the file) with a host-pane-only block that wires BOTH toggles:

```ts
// C1/C2 gate: HOST pane only (accessory panes don't toggle themselves). Each
// click -> darwin_window_get_by_numeric_id resolves the CEF window's NSWindow
// (C1's ZAPP_HAS_CEF resolver fallback) -> zapp_{sidebar,inspector}_for_slot
// finds the split registry -> the pane collapses/expands. Before C1's resolver
// these no-op'd on CEF; before C2's inspector arm there was no inspector pane.
if (!isSidebar && !isInspector) {
  document.querySelector<HTMLButtonElement>("#toggle-sb")!
    .addEventListener("click", () => Window.current().sidebar?.toggle());
  document.querySelector<HTMLButtonElement>("#toggle-insp")!
    .addEventListener("click", () => Window.current().inspector?.toggle());
}
```

- [ ] **Step 5: Typecheck**

Run: `bun run check`
Expected: `tsc --noEmit` clean (no new errors from the fixture change).

- [ ] **Step 6: Build (chromium)**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expected: both markers — a `[zapp] CEF app bundle:` line AND `[zapp] build complete: …/cef-hello (…KB)`; no `Undefined symbols` / `error:`.

- [ ] **Step 7: Headless evidence (browser count)**

Launch the binary from the project dir for ~6s then kill it (no `timeout` binary — background + wait + kill), and grep the output for `browser created \(slot`. Expect **FOUR** `browser created (slot N)` lines:
- window 1 host (slot 0), window 1 sidebar (slot 1), window 1 inspector (slot 2), window 2 host (slot 3).

(Slot numbers depend on allocation order; the count is what matters — window 1 is now 3 panes.)

- [ ] **Step 8: Commit**

```bash
git add native/platform/darwin/window.m examples/cef-hello/zapp/app.nim \
        examples/cef-hello/index.html examples/cef-hello/src/main.ts
git commit -m "feat(cef): host CEF browser in the inspector pane (C2) + fixture"
```

- [ ] **Step 9: Human R0 gates** (controller runs these WITH the user — not the implementer)

```bash
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
- **Renders + coexistence:** window 1 shows THREE panes on Chromium — sidebar (light-blue), host, inspector (light-orange `#fff4f0`) — all rendered, all three tick counters incrementing (worker broadcast fans to all 3). Window 2 (plain) still renders + ticks.
- **Collapse/expand:** drag the inspector divider → it collapses/expands, stays live; the sidebar still collapses independently.
- **Imperative control:** in the HOST pane click **toggle inspector** → the inspector collapses; click again → expands. **toggle sidebar** still works too.
- **Per-pane teardown:** close window 1 → `browser closed` for the host, sidebar, AND inspector slots (no leak); window 2 stays alive + ticking; closing window 2 (last) quits clean.

---

### Task 2: Docs — close sub-cycle C2

**Files:**
- Modify: `spikes/cef-macos/FINDINGS.md`
- Modify: `examples/cef-hello/SMOKE.md`

- [ ] **Step 1: FINDINGS — record C2 closed**

Append a sub-cycle C2 section to `spikes/cef-macos/FINDINGS.md` (match the existing FINDINGS structure/tone). Record:
- Inspector-on-CEF shipped as a direct mirror of C1's sidebar arm: one `pane_role=3` inspector arm in `window.m`'s CEF pane-mount branch. Everything else inherited from C1 unchanged (resolver, shared carriers `hasInspector`/`isInspector`, per-pane teardown of `inspectorNumericId`, split builder's `inspectorContainer`, inspector registry + events).
- Window 1 of `cef-hello` is now a 3-pane CEF window (sidebar + host + inspector) — proves sidebar+inspector coexistence on Chromium.
- Deferred (unchanged from spec): host-level window-event fan-out (`zapp_dispatch_event_to_js`) is WK-only → a foundational post-C2 follow-up affecting all CEF windows; vibrancy-on-CEF opacity (inspector panes opaque, same as sidebar); C3 toolbar; B's terminal-close applies per-pane.

- [ ] **Step 2: SMOKE — record the C2 gates**

Add the C2 gates to `examples/cef-hello/SMOKE.md` (match the existing GATE format): inspector renders + ticks on CEF; collapse/expand (drag); imperative `Window.current().inspector.toggle()`; sidebar+inspector coexistence (3 panes live, each independently collapsible); per-pane teardown of all 3 slots on close; window 2 plain regression.

- [ ] **Step 3: Verify + commit**

```bash
bun run check && bun run test
```
Expected: green (docs-only; 292 pass / 0 fail, unchanged).

```bash
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): close sub-cycle C2 inspector-on-CEF — findings + gates"
```

---

## Self-Review

**1. Spec coverage:**
- Inspector arm in the CEF pane-mount branch → Task 1 Step 1. ✅
- Fixture (win1 sidebar+inspector, win2 plain) → Task 1 Steps 2-4. ✅
- Gates (render, coexistence, collapse/expand, imperative toggle, per-pane teardown, win2 regression) → Task 1 Step 9. ✅
- Byte-identical (`#ifdef`-gated, WK `#else` untouched) → Global Constraints + Task 1 Step 1 (arm is inside the branch). ✅
- Inherited-unchanged (resolver/carriers/teardown/registries/events) → not touched by any task, called out in Global Constraints. ✅
- Docs (FINDINGS + SMOKE) → Task 2. ✅
- Deferred non-goals (host-event fan-out, vibrancy, C3) → documented in Task 2 Step 1. ✅

**2. Placeholder scan:** No TBD/TODO. Step 1's arm is complete code; Steps 2-4 show exact fixture edits. Docs steps (Task 2) describe content to write with the specific facts to record (acceptable for prose docs, not code).

**3. Type consistency:** `zapp_cef_create_browser_in_view`'s 8-arg signature matches its C1 declaration and the host/sidebar call sites; `pane_role=3` matches the WK `#else` inspector arm and the shared carrier builder's `isInspector` case; `InspectorOptions` fields (url/title/width/minWidth/maxWidth) match `native/nim/window.nim:140-151`; `Window.current().inspector?.toggle()` matches `runtime/window.ts` `InspectorHandle.toggle()`.
