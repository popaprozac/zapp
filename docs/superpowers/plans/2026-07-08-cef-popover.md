# CEF popover fix (breakage #1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Window.current().createPopover(opts)` + `PopoverHandle.show(anchor)` (an `NSPopover` hosting web content) works on a `webEngine:"chromium"` window — opens, renders on Chromium, anchors to the pane, tears down cleanly.

**Architecture:** Mirror the C-series. The popover no-ops on CEF because (a) its content webview is a WKWebView (`darwin_popover_create` → `darwin_webview_create_ext`) and (b) its anchor view is `zapp_webview_for_slot` (nil on CEF → `if (!anchorView) return`). Fix, all `#ifdef ZAPP_HAS_CEF`-gated: mount a CEF browser in the popover container (`pane_role=2` → `zapp.isPopover`); resolve the anchor via a new `zapp_cef_view_for_slot`; tear down the CEF browser in the popover's central teardown.

**Tech Stack:** Objective-C (`native/platform/darwin/popover.m`, `window.m`), C (`native/platform/darwin/cef/zapp_cef_host.m` + `zapp_cef.h`), the `cef-hello` fixture.

## Global Constraints

- **Byte-identical `system` build:** every CEF change is inside `#ifdef ZAPP_HAS_CEF` (including new helper functions and popover.m branches); `unifdef -UZAPP_HAS_CEF` of each modified file must reproduce the original bytes. The WK path (`darwin_webview_create_ext` content, `zapp_webview_for_slot` anchor, teardown) is unchanged.
- **Refcount discipline:** `zapp_cef_browser_for_slot` = borrowed (never release); `get_host` = owned (release exactly once). Mirror `zapp_cef_window_for_slot`.
- **Reusable popover:** create once → show/hide many → destroy once. The CEF browser is torn down at DESTROY (`zapp_popover_destroy_controller`, where the WK `zapp_teardown_pane_webview` lives), NOT on `popoverDidClose`/hide — else reopen breaks.
- **Verification = native build + human R0 gate** (GUI; no unit-test harness). Engine flip → `rm -rf ~/.cache/nim/app_r` before a chromium build. Canonical typecheck: root `bun run check`.
- **Branch:** `feat/cef-popover` off `feat/nim-native @ 6a00907`. NO merge without ask. Inclusive language.

---

### Task 1: popover on CEF — content + anchor + teardown + fixture

**Files:**
- Modify: `native/platform/darwin/cef/zapp_cef_host.m` + `native/platform/darwin/cef/zapp_cef.h` (`zapp_cef_view_for_slot`)
- Modify: `native/platform/darwin/popover.m` (content branch, anchor fallback, teardown)
- Modify: `examples/cef-hello/src/main.ts`, `examples/cef-hello/index.html` (fixture)

**Interfaces:**
- Consumes: `zapp_cef_create_browser_in_view(void* parent_view, const char* url, int32_t window_slot, const char* window_id, const char* owner_id, int pane_role, bool host_has_sidebar, bool host_has_inspector)`; `zapp_cef_browser_for_slot`; `zapp_cef_teardown_browser_for_slot(int32_t)`; `zapp_resolve_url(const char*)`; `Window.current().createPopover`/`PopoverHandle.show`.
- Produces: `void* zapp_cef_view_for_slot(int32_t slot)` (the browser's NSView, or NULL).

**Engine is compile-time, not per-window:** `webEngine` is app-wide, so a build is entirely WK or entirely CEF. window.m's pane-mount is a plain `#ifdef ZAPP_HAS_CEF` (CEF) / `#else` (WK) with NO runtime predicate, and it uses `hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot]` directly (window.m:1172) — NOT `zapp_window_ids`. popover.m mirrors this exactly: pure `#ifdef`/`#else`, `win-%d` id, no accessor.

- [ ] **Step 1: `zapp_cef_view_for_slot` (mirror `zapp_cef_window_for_slot`)**

First READ `zapp_cef_window_for_slot` in `zapp_cef_host.m` and mirror its borrowed/owned idiom exactly. Add:
```c
// The CEF browser's NSView for |slot| (borrowed browser -> owned host, released
// once -> the SetAsChild view handle). NULL if no browser. Mirrors
// zapp_cef_window_for_slot, which returns that view's .window. Used by the
// popover to anchor to a CEF pane (popover.m).
void* zapp_cef_view_for_slot(int32_t slot) {
  cef_browser_t* b = zapp_cef_browser_for_slot(slot);   // borrowed — do not release
  if (b == NULL) return NULL;
  cef_browser_host_t* host = b->get_host(b);            // owned
  if (host == NULL) return NULL;
  cef_window_handle_t h = host->get_window_handle(host);
  host->base.release(&host->base);
  return (void*)h;   // NSView*
}
```
Declare in `zapp_cef.h` next to `zapp_cef_window_for_slot`. (If `zapp_cef_window_for_slot`'s real impl differs — e.g. returns the view directly vs `.window` — follow the ACTUAL file and adjust so this returns the NSView, not the window.)

- [ ] **Step 2: content branch — mount a CEF browser (`darwin_popover_create`)**

Replace the WK content-mount (popover.m:78-87) with a pure compile-time gated branch. The `#else` is the EXISTING WK code verbatim (so `unifdef -U` restores it byte-for-byte). Mirror window.m's CEF pane create (window.m:1172-1204) — `win-%d` id, `owner-%p` owner:
```objc
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    c.container = container;
#ifdef ZAPP_HAS_CEF
    // Popover content on CEF (webEngine:"chromium" build): mount a CEF browser
    // (pane_role=2 -> zapp.isPopover in the shared carrier builder), host-twin
    // identity = the host window — exactly as window.m's CEF pane-mount does.
    {
        extern NSURL* zapp_resolve_url(const char* url_cstr);
        extern void zapp_cef_create_browser_in_view(void* parent_view, const char* url,
                                                    int32_t window_slot, const char* window_id,
                                                    const char* owner_id, int pane_role,
                                                    bool host_has_sidebar, bool host_has_inspector);
        NSString* hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot];
        NSString* ownerId = [NSString stringWithFormat:@"owner-%p", window];
        NSURL* nsUrl = zapp_resolve_url(url);
        const char* cefUrl = nsUrl ? [[nsUrl absoluteString] UTF8String] : "zapp://index.html";
        if (!cefUrl || cefUrl[0] == '\0') cefUrl = "zapp://index.html";
        zapp_cef_create_browser_in_view((__bridge void*)container, cefUrl, popover_slot,
                                        [hostWindowId UTF8String], [ownerId UTF8String],
                                        2, false, false);
        // c.webview stays nil (no WKWebView); teardown handled via the CEF slot.
    }
#else
    darwin_webview_create_ext(window_ptr, true, true, url, popover_slot, true,
                              (__bridge void*)container, host_slot, 2, false, false);
    for (NSView* sub in container.subviews) {
        if ([sub isKindOfClass:[WKWebView class]]) { c.webview = (WKWebView*)sub; break; }
    }
    if (c.webview) {
        zapp_register_pane_webview(popover_slot, c.webview, host_slot);
    }
#endif
```
No runtime engine predicate — the build is entirely WK or entirely CEF. Confirm popover.m already `#import`s / has visibility to build under `ZAPP_HAS_CEF` (it's compiled for both engines; the CEF externs are declared inline above, so no CEF header is needed — mirrors window.m).

- [ ] **Step 3: anchor fallback + coordinate flip (`darwin_popover_show`)**

Insert a gated fallback BEFORE `if (!anchorView) return;` (popover.m:145) — minimal, so `unifdef -U` restores the original:
```objc
    WKWebView* anchorView = zapp_webview_for_slot(sender_slot);
    if (!anchorView || anchorView.window != window) {
        anchorView = zapp_webview_for_slot(c.hostSlot);
    }
#ifdef ZAPP_HAS_CEF
    if (!anchorView) {
        // No WKWebView -> a CEF pane. Its browser NSView anchors the popover.
        // Cast to WKWebView* is deliberate: the show tail below uses only NSView
        // API (.window/.bounds/.isFlipped/showRelativeToRect:ofView:) on it.
        NSView* cv = (__bridge NSView*)zapp_cef_view_for_slot(sender_slot);
        if (!cv || cv.window != window) cv = (__bridge NSView*)zapp_cef_view_for_slot(c.hostSlot);
        anchorView = (WKWebView*)cv;
    }
#endif
    if (!anchorView) return;
```
Then insert a gated y-flip immediately BEFORE the final `showRelativeToRect:` (popover.m:174), so the DOM-top-left rect maps into the CEF view:
```objc
    if (w < 1) w = 1;
    if (h < 1) h = 1;
#ifdef ZAPP_HAS_CEF
    // WKWebView is flipped (top-left); CEF's browser NSView may not be. When it
    // isn't, convert the DOM-top-left y so the popover anchors at the element,
    // not mirrored. isFlipped-guarded so a flipped view (incl. all WK) is untouched.
    if (!anchorView.isFlipped) { y = anchorView.bounds.size.height - y - h; }
#endif
    [c.popover showRelativeToRect:NSMakeRect(x, y, w, h) ofView:anchorView preferredEdge:edge];
```
Both blocks vanish under `unifdef -U` → byte-identical. NOTE: the `edge` mapping (edgeName→NSRectEdge) also assumes a flipped view; if the R0 gate shows the popover opening off the wrong edge on a NON-flipped CEF view, gate an edge swap (MaxY↔MinY / MinY↔MaxY) the same way — record it as a gate follow-up if hit.

- [ ] **Step 4: teardown (`zapp_popover_destroy_controller`)**

In `zapp_popover_destroy_controller` (popover.m:181), add the gated CEF teardown alongside the WK one (`c.webview` is nil on CEF, so its `zapp_teardown_pane_webview` no-ops; the CEF browser needs its own):
```objc
static void zapp_popover_destroy_controller(ZappPopoverController* c) {
    if (!c) return;
    if (c.popover.isShown) [c.popover performClose:nil];
    if (c.webview) zapp_teardown_pane_webview(c.webview);
#ifdef ZAPP_HAS_CEF
    zapp_cef_teardown_browser_for_slot(c.popoverSlot);   // no-op if no CEF browser at slot
#endif
    zapp_clear_pane_slot(c.popoverSlot);
    c.popover.delegate = nil;
    [zapp_popovers removeObjectForKey:c.popoverId];
}
```
Confirm `zapp_cef_teardown_browser_for_slot` is safe/no-op when the slot has no CEF browser (WK popover on a CEF-enabled build path); if not, guard with `if (zapp_cef_browser_for_slot(c.popoverSlot))`.

- [ ] **Step 5: cef-hello fixture — Show popover button + `#popover-pane`**

`index.html`: add a `<button id="show-popover">Show popover</button>` near the host-pane buttons. `src/main.ts`:
- Add a `#popover-pane` branch alongside `isSidebar`/`isInspector` (a distinct tinted page, e.g. `const isPopover = location.hash === "#popover-pane";` → set a background + `which.textContent`), so the popover content is identifiable.
- In the host-pane-only block, wire the button (lazy create + show, anchored to the button's rect):
```ts
  let pop: Awaited<ReturnType<ReturnType<typeof Window.current>["createPopover"]>> | undefined;
  document.querySelector<HTMLButtonElement>("#show-popover")!.addEventListener("click", async (e) => {
    if (!pop) pop = await Window.current().createPopover({ url: "#popover-pane", width: 240, height: 160 });
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    await pop.show({ anchor: { x: r.left, y: r.top, width: r.width, height: r.height }, edge: "bottom" });
  });
```
- Add `#show-popover` to the accessory-pane hide list (it's a host-scoped control, like the others).
- (Confirm the exact `createPopover`/`show` option shape against `runtime/window.ts:586` `normalizePopoverOptions` + `PopoverHandle.show` — adjust the anchor object to match.)

- [ ] **Step 6: typecheck + build**

```bash
bun run check
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expected: tsc clean; both markers (`[zapp] CEF app bundle:` + `[zapp] build complete:`); no `Undefined symbols`/`error:`.

- [ ] **Step 7: headless smoke + commit**

Launch ~6s, kill, confirm no crash (the popover itself is the human gate). Commit:
```bash
git add native/platform/darwin/popover.m \
        native/platform/darwin/cef/zapp_cef_host.m native/platform/darwin/cef/zapp_cef.h \
        examples/cef-hello/src/main.ts examples/cef-hello/index.html
git commit -m "fix(cef): popover on CEF — content browser + anchor + teardown (breakage #1)"
```

- [ ] **Step 8: Human R0 gate** (controller runs WITH the user)
- **Opens + renders:** clicking **Show popover** on the CEF window opens an `NSPopover` showing the `#popover-pane` content on Chromium.
- **Anchored:** the popover is anchored at the button (not floating at a corner / vertically mirrored). If mirrored → the flip/edge follow-up (Step 4 note).
- **Teardown:** dismissing (click-away, transient) closes it; reopening works; no leak (`browser closed (slot <popover>)` in the log on window close).
- **Regression:** the C1-C3 + DevTools surfaces still work; window 2 unaffected.

---

### Task 2: docs (FINDINGS + SMOKE)

**Files:** Modify `spikes/cef-macos/FINDINGS.md`, `examples/cef-hello/SMOKE.md`

- [ ] **Step 1:** `FINDINGS.md` — a "popover on CEF (breakage #1)" section: root cause (content WKWebView + anchor `zapp_webview_for_slot` nil), the fix (CEF browser content `pane_role=2`, `zapp_cef_view_for_slot` anchor, `zapp_window_id_for_slot`, teardown in `zapp_popover_destroy_controller`), the coordinate-flip finding (isFlipped-guarded y adjust; edge follow-up if hit), WK unchanged. Cross-reference the two remaining breakages (contextmenu, embedded-webview).
- [ ] **Step 2:** `SMOKE.md` — a popover-on-CEF gate row matching the actual R0 result (opens/renders/anchors/tears-down). Only mark PASS for what the human confirmed; qualify anything not exercised. Match the existing gate-table style.
- [ ] **Step 3:** verify + commit
```bash
bun run check && bun run test    # green (docs); 292 pass
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): popover on CEF (breakage #1) — findings + gate"
```

---

## Self-Review

**1. Spec coverage:**
- Content — CEF browser `pane_role=2`, pure `#ifdef`/`#else`, `win-%d` id (mirrors window.m) → Task 1 Step 2. ✅
- Anchor — `zapp_cef_view_for_slot` fallback + isFlipped y-adjust → Task 1 Steps 1, 3. ✅
- Teardown — CEF teardown in `zapp_popover_destroy_controller` (corrected from the spec's imprecise "popoverDidClose") → Task 1 Step 4. ✅
- Gated / byte-identical → Global Constraints + every gated block has the `#else`/minimal-insert restoring the original. ✅
- Fixture (Show popover + `#popover-pane`) → Task 1 Step 5. ✅
- Gates (opens/renders/anchors/teardown/byte-identical) → Task 1 Step 8. ✅
- Non-goals (WK unchanged, vibrancy, toolbar-item path) — untouched by design. ✅
- Docs → Task 2. ✅

**2. Placeholder scan:** No TBD/TODO. The two "confirm" notes (`zapp_cef_window_for_slot`'s exact return in Step 1; the `createPopover`/`show` option shape in Step 5) are verification instructions against live source, not placeholders — the exact call is genuinely file-specific. No runtime engine predicate remains (engine is compile-time).

**3. Type consistency:** `zapp_cef_view_for_slot(int32_t)->void*` is consistent across Steps 1/3; `zapp_cef_create_browser_in_view`'s 8-arg signature matches `zapp_cef.h`; `pane_role=2` matches the `isPopover` carrier; the fixture's `createPopover`/`show` match the runtime API (pending the Step 5 confirm). No window.m change (accessor removed — window id is `win-%d` directly).
