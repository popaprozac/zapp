# CEF embedded-webview fix (breakage #3, last) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Webview.create({ src })` (the `<zapp-webview>` custom element) tracks its host DOM box on a `webEngine:"chromium"` window — the embedded webview sits ON the element's rectangle instead of mis-positioning.

**Architecture:** The embedded webview is a "panel" (a child WKWebView over the page, `panel.m`), positioned from the DOM rect via a coordinate conversion `[hostWebview convertRect:… toView:contentView]`. `darwin_panel_create` captures the host reference webview via `darwin_window_get_webview` → nil on CEF → `panel.hostWebview` nil → `darwin_panel_set_bounds` takes the `else` fallback that assumes `contentView` IS the host viewport → on a PANED CEF window the panel offsets by the pane's origin. Fix (`#ifdef ZAPP_HAS_CEF`, one insert): set `panel.hostWebview` to `zapp_cef_view_for_slot(window_id)` (the helper from popover #1) when the WKWebView is nil; `set_bounds`'s `convertRect` path — UNCHANGED — then maps correctly.

**Tech Stack:** Objective-C (`native/platform/darwin/panel.m`), the `cef-hello` fixture (TypeScript).

## Global Constraints

- **Byte-identical `system` build:** the CEF change is a pure `#ifdef ZAPP_HAS_CEF` insert; `unifdef -UZAPP_HAS_CEF panel.m` must reproduce the original bytes. `darwin_panel_set_bounds` and the WK path are unchanged. (panel.m has no existing `#ifdef ZAPP_HAS_CEF` — this adds the first.)
- **Reuse, don't rebuild:** `zapp_cef_view_for_slot(int32_t slot) -> void*` (CEF pane NSView) already exists in `zapp_cef_host.m`/`zapp_cef.h` (merged from popover #1). Declare it `extern` inside the `#ifdef`; add no new helper.
- **`set_bounds` is UNCHANGED:** the only code change is in `darwin_panel_create`. `set_bounds`'s `convertRect`/`isFlipped` logic is engine-agnostic and already correct — it only needs a non-nil host reference.
- **Verification = native build + human R0 gate** (GUI). Engine flip → `rm -rf ~/.cache/nim/app_r` before a chromium build. Canonical typecheck: root `bun run check`.
- **Branch:** `feat/cef-embedded-webview` off `feat/nim-native @ 6bc9229`. NO merge without ask. Inclusive language.

---

### Task 1: embedded webview on CEF — host coordinate reference + fixture

**Files:**
- Modify: `native/platform/darwin/panel.m` (one gated insert in `darwin_panel_create`)
- Modify: `examples/cef-hello/src/main.ts` (a `<zapp-webview>` fixture)

**Interfaces:**
- Consumes: `zapp_cef_view_for_slot(int32_t slot) -> void*` (CEF pane NSView; `zapp_cef.h`); `darwin_window_get_webview(int32_t)`; `Webview.create(opts: { src: string }) -> ZappWebviewElement` (`runtime/webview.ts:216`).
- Produces: nothing new — a behavior fix.

- [ ] **Step 1: gated host-reference fallback (`darwin_panel_create`)**

The current host-capture block (panel.m:135-137):
```objc
        extern void* darwin_window_get_webview(int32_t window_id);
        void* hostWV = darwin_window_get_webview(window_id);
        if (hostWV) panel.hostWebview = (__bridge WKWebView*)hostWV;
```
becomes (a pure `#ifdef` INSERT after the existing assignment — nothing else changes):
```objc
        extern void* darwin_window_get_webview(int32_t window_id);
        void* hostWV = darwin_window_get_webview(window_id);
        if (hostWV) panel.hostWebview = (__bridge WKWebView*)hostWV;
#ifdef ZAPP_HAS_CEF
        // CEF host: no WKWebView in the registry. Use the CEF pane's NSView as
        // the coordinate reference so darwin_panel_set_bounds' convertRect maps
        // the DOM rect (host viewport) into the contentView correctly — a paned
        // window (sidebar/inspector) would otherwise offset the panel by the
        // pane's origin. Cast to WKWebView*: set_bounds uses only NSView API on
        // it (isFlipped / bounds / convertRect:toView:), same as popover's cast.
        extern void* zapp_cef_view_for_slot(int32_t slot);
        if (!hostWV) panel.hostWebview = (__bridge WKWebView*)zapp_cef_view_for_slot(window_id);
#endif
```
Do NOT touch `darwin_panel_set_bounds` (panel.m:164-197). Its `convertRect` path (panel.m:180-186) already runs when `panel.hostWebview` is non-nil, and `isFlipped`-guards the flip. Reason through `unifdef -UZAPP_HAS_CEF panel.m`: the inserted block vanishes → the file is byte-for-byte the original.

- [ ] **Step 2: cef-hello fixture — an embedded `<zapp-webview>`**

`examples/cef-hello/src/main.ts`, in the HOST-pane-only block (`if (!isSidebar && !isInspector && !isPopover) { … }`), add an embedded webview tracking a bordered frame (mirror kitchen-sink `src/sections/embedded-webview.ts:35-41`). Import `Webview` from `@zappdev/runtime` (add to the existing import line):
```ts
  // Breakage #3 gate: embedded <zapp-webview> positioning on CEF. The native
  // panel must track this bordered frame's box. Window 1 is PANED (sidebar +
  // inspector), so this exercises the inset case that was mis-positioning.
  const embedFrame = document.createElement("div");
  embedFrame.style.cssText =
    "width:220px; height:140px; margin-top:12px; border:2px solid #c33; border-radius:6px; overflow:hidden;";
  document.body.appendChild(embedFrame);
  const embedWv = Webview.create({
    src: "data:text/html,<body style='margin:0;background:%23148;color:%23fff;font:14px system-ui;display:grid;place-items:center'>embedded webview</body>",
  });
  embedWv.style.cssText = "width:100%; height:100%; display:block;";
  embedFrame.appendChild(embedWv);
```
The red-bordered frame + the distinctly-colored embedded page make "does the native webview sit inside the box" obvious at the gate. (Confirm `Webview.create({ src })` against `runtime/webview.ts:216`; if the data-URL `src` doesn't load in the sandboxed panel, substitute a simple `https://` page — the gate is about POSITION, not content.)

- [ ] **Step 3: typecheck + build**

```bash
bun run check
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expected: tsc clean; both markers (`[zapp] CEF app bundle:` + `[zapp] build complete:`); no `Undefined symbols`/`error:`.

- [ ] **Step 4: byte-identity + headless + commit**

```bash
unifdef -UZAPP_HAS_CEF native/platform/darwin/panel.m > /tmp/panel_u.m; git show HEAD:native/platform/darwin/panel.m > /tmp/panel_orig.m
diff -q /tmp/panel_u.m /tmp/panel_orig.m && echo BYTE-IDENTICAL || echo DIFFERS
```
Expected: `BYTE-IDENTICAL`. Then launch ~6s, kill, no crash (the embedded panel is created; a browser count of 4 + the panel WKWebView is fine). Commit:
```bash
git add native/platform/darwin/panel.m examples/cef-hello/src/main.ts
git commit -m "fix(cef): embedded webview positioning — CEF pane view as coord reference (breakage #3)"
```

- [ ] **Step 5: Human R0 gate** (controller runs WITH the user)
- **Sits on its box:** the embedded webview (the blue "embedded webview" page) renders INSIDE the red-bordered frame in window 1's host pane — aligned to the border, NOT offset into the sidebar or elsewhere.
- **Tracks on resize:** resizing window 1 keeps the embedded webview aligned to its frame (the panel re-tracks via `set_bounds`).
- **Renders + loads:** the embedded page shows its content (unchanged behavior).
- **Regression:** popover, contextmenu, sidebar/inspector, toolbar, DevTools still work; window 2 unaffected.

---

### Task 2: docs (FINDINGS + SMOKE)

**Files:** Modify `spikes/cef-macos/FINDINGS.md`, `examples/cef-hello/SMOKE.md`

- [ ] **Step 1:** `FINDINGS.md` — an "embedded webview (`<zapp-webview>`) on CEF (breakage #3)" section (match the popover #1 / contextmenu #2 structure): root cause (`darwin_panel_create` host ref via `darwin_window_get_webview` nil on CEF → `set_bounds` `else` fallback assumes `contentView` == host viewport → paned window offsets), the fix (gated `zapp_cef_view_for_slot` host reference — reuses popover #1; `set_bounds`'s `convertRect`/`isFlipped` unchanged), byte-identical WK. Note this is the LAST of the three kitchen-sink-on-CEF breakages — with popover #1 + contextmenu #2, all three catalog breakages are now fixed; the remaining CEF work is E (Helper signing) + the backlog gaps.
- [ ] **Step 2:** `SMOKE.md` — an embedded-webview-on-CEF gate section matching the existing gate-table style; mark ONLY the R0 items the human confirmed (sits-on-box, tracks-on-resize, renders+loads, no-regressions), dated 2026-07-08. Don't claim gates that weren't run.
- [ ] **Step 3:** verify + commit
```bash
bun run check && bun run test     # green (docs); 292 pass
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): embedded webview on CEF (breakage #3) — findings + gate"
```

---

## Self-Review

**1. Spec coverage:**
- The one gated host-reference insert in `darwin_panel_create` → Task 1 Step 1. ✅
- `set_bounds` unchanged → Global Constraints + Task 1 Step 1 (explicit "do NOT touch"). ✅
- Fixture (`<zapp-webview>` tracking a bordered frame in the paned host pane) → Task 1 Step 2. ✅
- Gates (sits-on-box / tracks-on-resize / renders / byte-identical) → Task 1 Steps 4-5. ✅
- Byte-identical WK → Global Constraints + Step 1 (pure `#ifdef` insert) + Step 4 (mechanical check). ✅
- Non-goals (WK unchanged, content stays WKWebView, non-host-pane embeds) — untouched by design. ✅
- Docs → Task 2. ✅

**2. Placeholder scan:** No TBD/TODO. The one "confirm" note (the `Webview.create({ src })` shape + data-URL loadability in Step 2) is a live-source verification, not a placeholder.

**3. Type consistency:** `zapp_cef_view_for_slot(int32_t)->void*` matches its merged definition and popover/contextmenu usage; `Webview.create({ src })` matches `runtime/webview.ts:216`; `window_id` (numeric slot) is the arg both `darwin_window_get_webview` and `zapp_cef_view_for_slot` take; `panel.hostWebview` is the existing `ZappPanel` property being set.
