# iOS A1 — Low-Risk Correctness Batch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the five low-risk iOS correctness fixes (spec `docs/superpowers/specs/2026-06-26-ios-a1-correctness-design.md`): #713 pane-event fan-out, `inspectable` honors config, `viewport-fit` in init templates, inject `--zapp-safe-area-*` on iOS, and parity-lint #637.

**Architecture:** Native ObjC changes in `native/platform/ios/` (window.m, sidebar.m, inspector.m, webview.m), one CLI change (`cli/src/init.ts`), one CLI test (`cli/src/ios-platform-parity.test.ts`), and a kitchen-sink CSS migration. No UI-paradigm decisions (those are A2/A3/SP-4). #713 mirrors the macOS fix (commit 2c1c979) using iOS window.m slot tables (the sidebar table already exists; we add the inspector one).

**Tech Stack:** Objective-C (UIKit/WebKit), TypeScript (CLI + kitchen-sink), Bun.

## Global Constraints

- Branch `feat/nim-native`, kept **UNMERGED**.
- Commit trailer on every commit, EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Staging:** explicit per-file `git add <path>` only. NEVER `git add -A`/`.`. No `git commit --amend`.
- **Always Bun, never Node.**
- iOS native changes are verified by **compile** (`cd kitchen-sink && bun run build --platform ios` → success line `[zapp] build complete:`); there is **no iOS simulator interaction in-session** — runtime behavior is the human smoke (final task).
- Gates: `bun run check` clean; `bun test cli/src` green; iOS-sim build green; default macOS build (`cd kitchen-sink && bun run build`) stays green.
- `bun run check 2>&1 | tail` swallows tsc's exit code — verify via real exit (`if bun run check; then …`).

---

### Task 1: iOS pane-event fan-out (#713) — atomic native

The fix touches window.m (new inspector slot table + dispatch fan-out), sidebar.m (emit reaches inspector), inspector.m (emit reaches sidebar). Atomic — they compile together. Mirrors macOS but iOS-shaped via window.m host→slot tables.

**Files:**
- Modify: `native/platform/ios/window.m` (add inspector slot table + setter + lookup; register at inspector materialize; add inspector to `zapp_dispatch_event_to_js`)
- Modify: `native/platform/ios/sidebar.m` (`zapp_ios_sidebar_emit` also evals the inspector slot)
- Modify: `native/platform/ios/inspector.m` (`zapp_ios_inspector_emit_data` also evals the sidebar slot)

**Interfaces produced (window.m, non-static so other .m can extern them):**
- `void zapp_ios_set_inspector_slot(int32_t host_slot, int32_t inspector_slot)`
- `int32_t zapp_ios_inspector_slot_for(int32_t host_slot)` (returns `-1` if none)
- (existing, reused) `int32_t zapp_ios_sidebar_slot_for(int32_t host_slot)`

- [ ] **Step 1: Add the inspector slot table in window.m**

In `native/platform/ios/window.m`, immediately AFTER the existing sidebar slot-table block (the `zapp_ios_sidebar_slot_of[]` / `zapp_ios_set_sidebar_slot` / `zapp_ios_sidebar_slot_for` group around lines 112–131), add the parallel inspector table:
```objc
// Host slot -> inspector slot (mirror of zapp_ios_sidebar_slot_of). -1 = none.
static int32_t zapp_ios_inspector_slot_of[ZAPP_MAX_WINDOW_CALLBACKS];
static bool zapp_ios_inspector_slot_of_init = false;

void zapp_ios_set_inspector_slot(int32_t host_slot, int32_t inspector_slot) {
    if (!zapp_ios_inspector_slot_of_init) {
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) zapp_ios_inspector_slot_of[i] = -1;
        zapp_ios_inspector_slot_of_init = true;
    }
    if (host_slot >= 0 && host_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_ios_inspector_slot_of[host_slot] = inspector_slot;
    }
}

int32_t zapp_ios_inspector_slot_for(int32_t host_slot) {
    if (!zapp_ios_inspector_slot_of_init) return -1;
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOW_CALLBACKS) return -1;
    return zapp_ios_inspector_slot_of[host_slot];
}
```
(Match the exact signature style of the sidebar trio you're mirroring; if the sidebar setter/lookup are `static`, make these NON-static — sidebar.m/inspector.m must extern `zapp_ios_*_slot_for`. If `zapp_ios_sidebar_slot_for` is currently `static`, also drop its `static` so sidebar/inspector emit can extern it — see Steps 4–5.)

- [ ] **Step 2: Register the inspector slot at materialize**

Find the inspector materialize path in window.m — the site that calls `zapp_ios_inspector_register(...)` (extern declared at window.m:162) and where `d->inspectorNumericId` is the inspector webview's slot. Mirror the sidebar registration (window.m:349 `zapp_ios_set_sidebar_slot(d->numeric_id, d->sidebarNumericId);`) by adding, right after the inspector is registered/created:
```objc
// Record host→inspector for pane-event fan-out (#713).
zapp_ios_set_inspector_slot(d->numeric_id, d->inspectorNumericId);
```
There is exactly one inspector materialize path (gated by `d->hasInspector`); add the call once there.

- [ ] **Step 3: Add the inspector pane to `zapp_dispatch_event_to_js`**

In window.m's `zapp_dispatch_event_to_js` (around lines 636–650), the current fan-out resolves `sidebar_slot` + `sidebarWebview` then evals host + sidebar in the `run` block. Add the inspector slot alongside, mirroring the sidebar lines:
```objc
    int32_t sidebar_slot = zapp_ios_sidebar_slot_for(window_id);
    WKWebView* sidebarWebview = (sidebar_slot >= 0 && sidebar_slot != window_id &&
                                 sidebar_slot < ZAPP_MAX_WINDOW_CALLBACKS)
        ? zapp_ios_webviews[sidebar_slot] : nil;
    int32_t inspector_slot = zapp_ios_inspector_slot_for(window_id);
    WKWebView* inspectorWebview = (inspector_slot >= 0 && inspector_slot != window_id &&
                                   inspector_slot < ZAPP_MAX_WINDOW_CALLBACKS)
        ? zapp_ios_webviews[inspector_slot] : nil;

    void (^run)(void) = ^{
        [webview evaluateJavaScript:js completionHandler:nil];
        if (sidebarWebview) [sidebarWebview evaluateJavaScript:js completionHandler:nil];
        if (inspectorWebview) [inspectorWebview evaluateJavaScript:js completionHandler:nil];
    };
```
(Use the actual webview-array name from the surrounding code — `zapp_ios_webviews` per the sidebar line.)

- [ ] **Step 4: Sidebar emit reaches the inspector pane (sidebar.m)**

In `native/platform/ios/sidebar.m`, at the top extern block (near `extern void darwin_window_eval_js(...)`), add:
```objc
extern int32_t zapp_ios_inspector_slot_for(int32_t host_slot);
```
Then in `zapp_ios_sidebar_emit` (lines ~153–165), after the existing host + sidebar evals, add the inspector eval:
```objc
    darwin_window_eval_js(c.hostWindowId, js);
    if (c.sidebarSlotId >= 0 && c.sidebarSlotId != c.hostWindowId) {
        darwin_window_eval_js(c.sidebarSlotId, js);
    }
    int32_t inspectorSlot = zapp_ios_inspector_slot_for(c.hostWindowId);
    if (inspectorSlot >= 0 && inspectorSlot != c.hostWindowId && inspectorSlot != c.sidebarSlotId) {
        darwin_window_eval_js(inspectorSlot, js);
    }
```

- [ ] **Step 5: Inspector emit reaches the sidebar pane (inspector.m)**

In `native/platform/ios/inspector.m`, at the top extern block (near `extern void darwin_window_eval_js(...)` at line 25), add:
```objc
extern int32_t zapp_ios_sidebar_slot_for(int32_t host_slot);
```
Then in `zapp_ios_inspector_emit_data` (lines ~94–114), after the existing host + inspector evals, add the sidebar eval:
```objc
    darwin_window_eval_js(c.hostWindowId, js);
    if (c.inspectorSlotId >= 0 && c.inspectorSlotId != c.hostWindowId) {
        darwin_window_eval_js(c.inspectorSlotId, js);
    }
    int32_t sidebarSlot = zapp_ios_sidebar_slot_for(c.hostWindowId);
    if (sidebarSlot >= 0 && sidebarSlot != c.hostWindowId && sidebarSlot != c.inspectorSlotId) {
        darwin_window_eval_js(sidebarSlot, js);
    }
```

- [ ] **Step 6: Build-verify (iOS-sim compile)**

```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
```
Expected: ends with `[zapp] build complete: …`. If a symbol is unresolved (`zapp_ios_inspector_slot_for` / `zapp_ios_sidebar_slot_for`), it means the window.m definition is still `static` — drop `static` so the extern resolves. Also run the default macOS build to confirm no regression: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/window.m native/platform/ios/sidebar.m native/platform/ios/inspector.m
git commit -m "fix(ios): pane-event fan-out reaches all panes (#713 iOS parity)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `inspectable` honors config (iOS)

**Files:**
- Modify: `native/platform/ios/window.m` (`darwin_window_create` opts block, ~line 663)

- [ ] **Step 1: Read the inspectable option into the deferred struct**

In `native/platform/ios/window.m`, `darwin_window_create` initializes `d->inspectable = true;` (line ~661) then enters `if (opts) { … }` (line ~663). Inside that `if (opts)` block (next to the other `extern int wopts_*` accessor declarations, e.g. after the `wopts_sheet_*` lines), add:
```objc
        extern int wopts_inspectable(void* opts);
        d->inspectable = wopts_inspectable(opts) > 0;
```
This matches darwin/window.m's `bool inspectable = wopts_inspectable(opts) > 0;` (darwin/window.m:779). `d->inspectable` already flows into every `darwin_webview_create_ext(... d->inspectable ...)` call in the materialize paths (window.m:311/326/368/421), and the iOS-16.4 `webview.inspectable` gate in webview.m consumes it — so no other change is needed.

- [ ] **Step 2: Build-verify**

```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
```
Expected: `[zapp] build complete:`. (Runtime behavior — devtools off when `inspectable:false` — is the human smoke in Task 5.)

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/window.m
git commit -m "fix(ios): window inspectable honors config instead of hardcoded true

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `viewport-fit=cover` in `zapp init` templates (#577)

**Files:**
- Modify: `cli/src/init.ts` (post-process generated `index.html` after create-vite)
- Test: `cli/src/init.test.ts` (create if absent) — focused unit test on a pure helper

**Interfaces produced:** `export function ensureViewportFitCover(html: string): string` — idempotently ensures the viewport `<meta>` includes `viewport-fit=cover`.

- [ ] **Step 1: Write the failing test**

Create/extend `cli/src/init.test.ts`:
```ts
import { test, expect } from "bun:test";
import { ensureViewportFitCover } from "./init";

test("adds viewport-fit=cover to a standard vite viewport meta", () => {
  const inp = `<meta name="viewport" content="width=device-width, initial-scale=1.0" />`;
  expect(ensureViewportFitCover(inp)).toContain("viewport-fit=cover");
});

test("is idempotent when viewport-fit already present", () => {
  const inp = `<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />`;
  expect(ensureViewportFitCover(inp)).toBe(inp);
});

test("leaves html without a viewport meta unchanged", () => {
  const inp = `<head><title>x</title></head>`;
  expect(ensureViewportFitCover(inp)).toBe(inp);
});
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bun test cli/src/init.test.ts`
Expected: FAIL — `ensureViewportFitCover` is not exported.

- [ ] **Step 3: Implement the helper + wire it in**

In `cli/src/init.ts`, add the exported helper:
```ts
/** Ensure the index.html viewport meta opts into the safe-area inset model on
 *  iOS (env(safe-area-inset-*) is 0 without viewport-fit=cover). Idempotent;
 *  no-op when there is no viewport meta. */
export function ensureViewportFitCover(html: string): string {
  return html.replace(
    /(<meta\s+name=["']viewport["']\s+content=["'])([^"']*)(["'])/i,
    (full, pre: string, content: string, post: string) =>
      /viewport-fit\s*=\s*cover/i.test(content)
        ? full
        : `${pre}${content.replace(/\s*$/, "")}, viewport-fit=cover${post}`,
  );
}
```
Then, after the `bunx create-vite@latest …` spawn completes (around init.ts:152) and before install/finish, read + rewrite the scaffolded `index.html` (use the same dir the CLI scaffolds into; guard on existence):
```ts
{
  const idx = `${name}/index.html`;
  const f = Bun.file(idx);
  if (await f.exists()) {
    const html = await f.text();
    const next = ensureViewportFitCover(html);
    if (next !== html) await Bun.write(idx, next);
  }
}
```
(Use the existing path/name variable the function already has for the scaffold dir; the snippet uses `name` as seen at init.ts:152.)

- [ ] **Step 4: Run the test — verify it passes**

Run: `bun test cli/src/init.test.ts`
Expected: PASS (3/3).

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/init.ts cli/src/init.test.ts
git commit -m "feat(cli): zapp init adds viewport-fit=cover to index.html (#577)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Inject `--zapp-safe-area-*` on iOS + kitchen-sink dogfood

**Files:**
- Modify: `native/platform/ios/webview.m` (inject `--zapp-safe-area-*` after load + re-inject on safe-area change)
- Modify: `native/platform/ios/window.m` only if the safe-area hook lives there (implementer's call based on which object owns `viewSafeAreaInsetsDidChange`)
- Modify: `kitchen-sink/src/style.css` (migrate raw `env()` to the vars with env fallback)

**Reference (macOS):** darwin/toolbar.m reads `hostWv.safeAreaInsets` (line 828) and evals `r.style.setProperty('--zapp-safe-area-{top,left,right,bottom}','%.0fpx')` on `document.documentElement` (lines ~870–880). iOS mirrors the same JS.

- [ ] **Step 1: Add the iOS safe-area injection helper**

In `native/platform/ios/webview.m`, add a helper that reads a webview's `safeAreaInsets` and evals the same `--zapp-safe-area-*` setProperty JS as macOS:
```objc
// Inject --zapp-safe-area-{top,right,bottom,left} from the webview's
// safeAreaInsets (macOS parity; mirrors darwin/toolbar.m). Idempotent; safe to
// call repeatedly (after load + on safe-area changes).
void zapp_ios_inject_safe_area(WKWebView* wv) {
    if (!wv) return;
    UIEdgeInsets sa = wv.safeAreaInsets;
    char js[320];
    snprintf(js, sizeof(js),
        "(function(){var r=document.documentElement.style;"
        "r.setProperty('--zapp-safe-area-top','%.0fpx');"
        "r.setProperty('--zapp-safe-area-right','%.0fpx');"
        "r.setProperty('--zapp-safe-area-bottom','%.0fpx');"
        "r.setProperty('--zapp-safe-area-left','%.0fpx');})();",
        sa.top, sa.right, sa.bottom, sa.left);
    [wv evaluateJavaScript:[NSString stringWithUTF8String:js] completionHandler:nil];
}
```
Call it once after the webview's initial load completes (in the existing navigation-finished delegate / the same place the bootstrap is known-ready in webview.m). If `webview.m` has no `static` exposure issue, keep the helper file-local + also call it from the safe-area hook (Step 2); if the hook lives in another file, make the helper non-`static` and `extern` it there.

- [ ] **Step 2: Re-inject on safe-area change**

Hook the WKWebView's (or its container view's) `safeAreaInsetsDidChange` so rotation / multitasking re-injects. The minimal approach: subclass or category-override is heavy — instead, in the content view controller that owns the webview, override `viewSafeAreaInsetsDidChange` and call `zapp_ios_inject_safe_area(theWebview)` for the host (and sidebar/inspector panes if present). Use the existing per-window webview lookups (`zapp_ios_webviews[slot]`, `zapp_ios_sidebar_slot_for`, `zapp_ios_inspector_slot_for` from Task 1) to re-inject all panes. (If a dedicated VC subclass already exists for the content webview, add the override there; otherwise add it to the root VC created in materialize.)

- [ ] **Step 3: Build-verify**

```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
```
Expected: `[zapp] build complete:`.

- [ ] **Step 4: Migrate the kitchen-sink to the vars (dogfood)**

In `kitchen-sink/src/style.css`, change the two raw-`env()` usages to the canonical vars with an `env()` fallback (so it works pre-injection + on the web):
- Line ~60: `padding-top: env(safe-area-inset-top);` → `padding-top: var(--zapp-safe-area-top, env(safe-area-inset-top));`
- Line ~103: `.main-pane--ios-offset { padding-top: calc(env(safe-area-inset-top) + 44px + 8px); }` → `.main-pane--ios-offset { padding-top: calc(var(--zapp-safe-area-top, env(safe-area-inset-top)) + 44px + 8px); }`
Update the adjacent comment (style.css:56) to note the vars are injected on iOS (macOS parity), env() is the fallback. (Leave `bg-demo-pane.ts`, already on `var(--zapp-safe-area-left, …)`, as-is. Do NOT touch the sidebar-pane spacing — that's A2.)

- [ ] **Step 5: Gates + commit**

`bun run check` clean; `cd kitchen-sink && bun run build` (macOS, no regression) + `bun run build --platform ios`.
```bash
cd /Users/zach/code/zapp
git add native/platform/ios/webview.m native/platform/ios/window.m kitchen-sink/src/style.css
git commit -m "feat(ios): inject --zapp-safe-area-* (macOS parity) + kitchen-sink dogfood

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
(Only `git add` window.m if Step 2 actually modified it.)

---

### Task 5: Parity-lint #637 + full gates + HUMAN SMOKE

**Files:**
- Modify: `cli/src/ios-platform-parity.test.ts` (new test arm for `native/nim/**` importc)

- [ ] **Step 1: Add the importc-coverage test arm**

`ios-platform-parity.test.ts` already has `nimExportcProvidedSymbols()` (globs `native/nim/**/*.nim` for `{.exportc.}` — init.ts pattern at lines ~131–164). Add a parallel scanner for `{.importc.}`'d `darwin_*` symbols and assert each has an iOS definition (or is darwin-defined-with-iOS-too, same as the `.zc` test). Add near the other scanners:
```ts
// Every darwin_* the Nim layer {.importc.}s must have an iOS definition,
// else the iOS link is missing a symbol the Nim build references (#637).
function nimImportcDarwinSymbols(): Set<string> {
  const out = new Set<string>();
  const glob = new Bun.Glob("native/nim/**/*.nim");
  for (const f of glob.scanSync(".")) {
    const src = Bun.file(f).text ? "" : ""; // (use readFileSync like the sibling scanners)
    void src;
  }
  return out;
}
```
Match the EXISTING file's read idiom (it uses synchronous reads in `nimExportcProvidedSymbols` — copy that exact approach; the placeholder above is only to show intent, replace with the real `importc`/`darwin_` regex used for `darwin_*` capture, mirroring `darwinSymbolsReferencedInZc`'s symbol regex). Then the test:
```ts
test("every darwin_* {.importc.}'d in native/nim has an iOS definition (#637)", () => {
  const imported = nimImportcDarwinSymbols();
  const definedIos = definedSymbolsIn("native/platform/ios", imported);
  const definedDarwin = definedSymbolsIn("native/platform/darwin", imported);
  const violations = [...imported]
    .filter((s) => definedDarwin.has(s) && !definedIos.has(s))
    .sort();
  expect(violations).toEqual([]);
});
```
(Same "defined-on-darwin-but-missing-on-iOS = violation" rule as the existing `.zc` test, so it can't false-positive on Nim-only or runtime symbols. Read the exact regexes/helpers in the file and reuse them — do not invent new parsing.)

- [ ] **Step 2: Run the parity suite**

Run: `bun test cli/src/ios-platform-parity.test.ts`
Expected: PASS (existing tests + the new arm). If the new arm reports violations, that's a REAL finding — surface it (a `darwin_*` the Nim layer imports with no iOS def); do not weaken the assertion to hide it — report it for triage.

- [ ] **Step 3: Full gates**

```bash
cd /Users/zach/code/zapp
bun run check
bun test cli/src
cd kitchen-sink && bun run build            # macOS, no regression
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
```
Expected: check exit 0; `bun test cli/src` all pass; both builds print `[zapp] build complete:`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/ios-platform-parity.test.ts
git commit -m "test(ios): parity lint covers native/nim importc darwin_* symbols (#637)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: HUMAN SMOKE (device/sim — pause)**

STOP. Ask the human to run the kitchen-sink on an iPhone sim AND iPad sim and confirm:
1. **#713:** nav to the **Sidebar** section; the **inspector pane** updates live ("collapsed"/"expanded"/"width N") when the sidebar collapses/expands/drags (iPad, where both are visible). Reverse (Inspector section) still updates.
2. **inspectable:** with a build configured `inspectable:false`, Safari ▸ Develop ▸ (sim) can NOT attach to the app webview; with default config, it can.
3. **viewport-fit:** `zapp init` a throwaway app → its `index.html` viewport meta contains `viewport-fit=cover`.
4. **safe-area:** `--zapp-safe-area-*` resolve non-zero on iOS AND the kitchen-sink faux top bar (now using the vars) still sits correctly under the notch / Dynamic Island on iPhone + iPad.

Do not consider A1 complete until confirmed. After the gate: update the program matrix (`docs/superpowers/specs/2026-06-26-ios-ipados-program-matrix.md`) marking the A1 rows fixed; close #713; note A2 is next.

---

## Self-Review

**Spec coverage:** A1.1 #713 → Task 1; A1.2 inspectable → Task 2; A1.3 viewport-fit (#577) → Task 3; A1.4 inject `--zapp-safe-area-*` + kitchen-sink dogfood → Task 4; A1.5 parity-lint #637 → Task 5. Verification (check/parity/iOS-sim build/macOS build + human smoke) → Tasks 1–5 build steps + Task 5 Step 3/5. Non-goals (sidebar presentation, inspector transition, dialogs/file-drop, app-events) untouched. ✓

**Placeholder scan:** Task 1–4 carry exact before/after code. Task 5's `nimImportcDarwinSymbols` body is intentionally shown as intent-with-instruction ("reuse the file's existing read idiom + symbol regex") rather than invented parsing — flagged explicitly so the implementer copies the proven helpers; the test assertion itself is concrete. Two implementer-located sites are pinned with their mirror pattern: the inspector-register call (Task 1 Step 2, mirror window.m:349) and the safe-area VC hook (Task 4 Step 2) — both have one obvious home and a named reference.

**Type/signature consistency:** `zapp_ios_inspector_slot_for(int32_t)` / `zapp_ios_set_inspector_slot(int32_t,int32_t)` defined in Task 1 Step 1, registered Step 2, consumed Step 3 (window.m) + Step 5 (inspector.m extern); `zapp_ios_sidebar_slot_for` reused (Task 1 Step 4 extern in sidebar.m) — note Step 1 says to drop `static` from the sidebar lookup if needed so the extern resolves. `ensureViewportFitCover(html: string): string` consistent between Task 3 test and impl. `--zapp-safe-area-{top,right,bottom,left}` names match macOS (darwin/toolbar.m) and the kitchen-sink var usage in Task 4 Step 4.
