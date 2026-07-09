# CEF context-menu fix (breakage #2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ContextMenu.show(items, { event })` pops a native `NSMenu` at the cursor on a `webEngine:"chromium"` window (it no-op'd before).

**Architecture:** `darwin_menu_show_context` resolves the view to position the menu relative to via `darwin_window_get_webview(window_id)` → nil on CEF → `if (!wv_ptr) return` → the menu never shows. Fix, `#ifdef ZAPP_HAS_CEF`-gated: fall back to `zapp_cef_view_for_slot(window_id)` (the helper built for popover breakage #1, already merged) when the WKWebView is nil. Everything else (`build_menu_from_json`, the `isFlipped` point flip, `popUpMenuPositioningItem:atLocation:inView:`) is engine-agnostic and unchanged.

**Tech Stack:** Objective-C (`native/platform/darwin/menu.m`), the `cef-hello` fixture (TypeScript).

## Global Constraints

- **Byte-identical `system` build:** the CEF change is a pure `#ifdef ZAPP_HAS_CEF` insert; `unifdef -UZAPP_HAS_CEF menu.m` must reproduce the original bytes. The WK view-lookup path is unchanged. (menu.m has no existing `#ifdef ZAPP_HAS_CEF` — this adds the first.)
- **Reuse, don't rebuild:** `zapp_cef_view_for_slot(int32_t slot) -> void*` (the CEF pane's NSView) already exists in `zapp_cef_host.m`/`zapp_cef.h` (merged from popover #1). Declare it `extern` in menu.m; do not add a new helper.
- **Verification = native build + human R0 gate** (GUI). Engine flip → `rm -rf ~/.cache/nim/app_r` before a chromium build. Canonical typecheck: root `bun run check`.
- **Branch:** `feat/cef-contextmenu` off `feat/nim-native @ e8fae88`. NO merge without ask. Inclusive language.
- **CefContextMenuHandler is a documented contingency, NOT a task:** only if the R0 gate shows Chromium's own context menu ALSO appearing does a follow-up handler get built. Do not build it preemptively.

---

### Task 1: context menu on CEF — anchor-view fallback + fixture

**Files:**
- Modify: `native/platform/darwin/menu.m` (the gated fallback in `darwin_menu_show_context`)
- Modify: `examples/cef-hello/src/main.ts` (right-click fixture)

**Interfaces:**
- Consumes: `zapp_cef_view_for_slot(int32_t slot) -> void*` (CEF pane NSView; declared in `zapp_cef.h`, defined in `zapp_cef_host.m`); `darwin_window_get_webview(int32_t)`; `ContextMenu.show(items: MenuItemDef[], options?: { event?: MouseEvent })` (`runtime/context-menu.ts:107`).
- Produces: nothing new — a behavior fix.

- [ ] **Step 1: gated anchor-view fallback (`darwin_menu_show_context`)**

The current view-resolution block (menu.m:367-370):
```objc
        // Find the window's WebView to position the menu
        extern void* darwin_window_get_webview(int32_t numeric_id);
        void* wv_ptr = darwin_window_get_webview(window_id);
        if (!wv_ptr) return;
```
becomes (a pure `#ifdef` INSERT before the existing `if (!wv_ptr) return;` — nothing else in the function changes):
```objc
        // Find the window's WebView to position the menu
        extern void* darwin_window_get_webview(int32_t numeric_id);
        void* wv_ptr = darwin_window_get_webview(window_id);
#ifdef ZAPP_HAS_CEF
        // CEF windows have no WKWebView in the registry — anchor the menu to the
        // CEF pane's NSView instead (the helper from popover breakage #1).
        // window_id is the numeric slot zapp_cef_view_for_slot takes; the
        // isFlipped-guarded point flip below handles its coordinate system.
        if (!wv_ptr) {
            extern void* zapp_cef_view_for_slot(int32_t slot);
            wv_ptr = zapp_cef_view_for_slot(window_id);
        }
#endif
        if (!wv_ptr) return;
```
Leave menu.m:372-382 (the `NSView* view = ...`, the `isFlipped` flip, `popUpMenuPositioningItem:...`) untouched. Reason through `unifdef -UZAPP_HAS_CEF menu.m`: the inserted block vanishes → the file is byte-for-byte the original.

- [ ] **Step 2: cef-hello fixture — right-click context menu**

`examples/cef-hello/src/main.ts`, in the HOST-pane-only block (`if (!isSidebar && !isInspector) { … }`), add a `contextmenu` listener mirroring kitchen-sink (`src/sections/contextmenu.ts:53-54`). Import `ContextMenu` + `MenuItemDef` from `@zappdev/runtime` (add to the existing import line). Use a small status line to prove item clicks route back:
```ts
  // Breakage #2 gate: native context menu on CEF. Right-click anywhere in the
  // host pane -> ContextMenu.show -> router (showContextMenu) ->
  // darwin_menu_show_context, which (with the CEF anchor-view fallback) pops a
  // native NSMenu at the cursor. Clicking an item routes its action back to JS.
  const ctxStatus = document.querySelector<HTMLPreElement>("#ctxstatus")!;
  const ctxMenu: MenuItemDef[] = [
    { label: "Context: log a line", action: () => { ctxStatus.textContent = "context menu: item A clicked"; } },
    { type: "separator" },
    { label: "Context: item B", action: () => { ctxStatus.textContent = "context menu: item B clicked"; } },
  ];
  document.addEventListener("contextmenu", (e) => {
    if (isSidebar || isInspector) return;   // host pane only
    e.preventDefault();
    ContextMenu.show(ctxMenu, { event: e });
  });
```
Add `<pre id="ctxstatus"></pre>` to `examples/cef-hello/index.html` near the other status lines. (Confirm the `MenuItemDef` shape — `label`/`action`/`type:"separator"` — against `runtime`'s exported `MenuItemDef`; adjust if the field names differ.)

- [ ] **Step 3: typecheck + build**

```bash
bun run check
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expected: tsc clean; both markers (`[zapp] CEF app bundle:` + `[zapp] build complete:`); no `Undefined symbols`/`error:`.

- [ ] **Step 4: byte-identity + headless + commit**

```bash
unifdef -UZAPP_HAS_CEF native/platform/darwin/menu.m > /tmp/menu_u.m; git show HEAD:native/platform/darwin/menu.m > /tmp/menu_orig.m
diff -q /tmp/menu_u.m /tmp/menu_orig.m && echo BYTE-IDENTICAL || echo DIFFERS
```
Expected: `BYTE-IDENTICAL`. Then launch ~6s, kill, no crash. Commit:
```bash
git add native/platform/darwin/menu.m examples/cef-hello/src/main.ts examples/cef-hello/index.html
git commit -m "fix(cef): context menu on CEF — anchor NSMenu to the CEF pane view (breakage #2)"
```

- [ ] **Step 5: Human R0 gate** (controller runs WITH the user)
- **Appears at cursor:** right-click the CEF host pane → the native `NSMenu` pops at the pointer (not 0,0/offscreen).
- **Items route back:** clicking "item A"/"item B" updates `#ctxstatus` (the action round-tripped JS→router→native→JS).
- **No stray Chromium menu:** Chromium's own context menu does NOT also appear. **If it does** → STOP and report: this triggers the gate-contingent `CefContextMenuHandler` follow-up (a new task: a `cef_context_menu_handler_t` on the client whose `on_before_context_menu` clears the model), not part of this task.
- **Regression:** popover, sidebar/inspector, toolbar, DevTools still work; window 2 unaffected.

---

### Task 2: docs (FINDINGS + SMOKE)

**Files:** Modify `spikes/cef-macos/FINDINGS.md`, `examples/cef-hello/SMOKE.md`

- [ ] **Step 1:** `FINDINGS.md` — a "context menu on CEF (breakage #2)" section (match the popover #1 / C-series structure): root cause (`darwin_menu_show_context` view via `darwin_window_get_webview` nil on CEF → early return), the fix (gated `zapp_cef_view_for_slot` fallback — reuses popover #1's helper; `isFlipped` flip unchanged), byte-identical WK. Record the R0 result including whether the `CefContextMenuHandler` contingency was needed. Note this is #2 of 3; cross-reference the remaining one (embedded-webview #3).
- [ ] **Step 2:** `SMOKE.md` — a context-menu-on-CEF gate section matching the existing gate-table style; mark ONLY the R0 items the human actually confirmed (appears-at-cursor, items-route, no-stray-Chromium-menu), dated 2026-07-08. Don't claim gates that weren't run.
- [ ] **Step 3:** verify + commit
```bash
bun run check && bun run test     # green (docs); 292 pass
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): context menu on CEF (breakage #2) — findings + gate"
```

---

## Self-Review

**1. Spec coverage:**
- Primary fix — gated `zapp_cef_view_for_slot` anchor fallback in `darwin_menu_show_context` → Task 1 Step 1. ✅
- Gate-contingent `CefContextMenuHandler` — documented as a STOP-and-report contingency, not a preemptive task → Task 1 Step 5 + Global Constraints. ✅
- Fixture (right-click → `ContextMenu.show`, item routes back) → Task 1 Step 2. ✅
- Gates (appears/items/no-stray-menu/byte-identical) → Task 1 Steps 4-5. ✅
- Byte-identical WK → Global Constraints + Step 1 (pure `#ifdef` insert) + Step 4 (mechanical check). ✅
- Non-goals (WK unchanged, Chromium menu content) — untouched by design. ✅
- Docs → Task 2. ✅

**2. Placeholder scan:** No TBD/TODO. The one "confirm" note (the `MenuItemDef` field shape in Step 2) is a live-source verification, not a placeholder.

**3. Type consistency:** `zapp_cef_view_for_slot(int32_t)->void*` matches its merged definition; `ContextMenu.show(items, {event})` matches `runtime/context-menu.ts:107`; `window_id` (numeric slot) is the argument `zapp_cef_view_for_slot` and `darwin_window_get_webview` both take.
