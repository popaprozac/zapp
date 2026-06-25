# Native Window Tabs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **PRE-STAGED while the user was away.** Design APPROVED (docs/superpowers/specs/2026-06-25-native-window-tabs-design.md, commit d0471a2). T1 is a RISK GATE whose human-visual smoke needs the machine — execution should begin when the user is back.

**Goal:** Group Zapp windows into a native macOS tab bar (Finder/Terminal-style) via `NSWindow` tabbing — windows sharing a `tabbingIdentifier` collapse into one window with a native tab bar; the tab bar "+" emits `NEW_TAB_REQUESTED` so the app adds tabs.

**Architecture:** Create-time `WindowOptions.tabbingIdentifier`/`tabbingMode`/`tabTitle` flow TS → wire JSON → Nim (`window.nim` fields + `wopts_*` getters + `windowOptsApplyJson`) → `native/platform/darwin/window.m` `darwin_window_create`, which sets `window.tabbingIdentifier`/`tabbingMode`/`window.tab.title`. A minimal `ZappWindow : NSWindow` subclass implements `newWindowForTab:` to emit `window:new-tab-requested` (toolbar-style string event); the runtime maps it to `win.on(WindowEvent.NEW_TAB_REQUESTED)` automatically via `eventName()`. macOS-only; iOS path unaffected.

**Tech Stack:** TypeScript (runtime types/events), Nim (`native/nim/window.nim`), Objective-C/AppKit (`native/platform/darwin/window.m`), `bun:test`, `nim c -r`.

## Global Constraints

- Branch `feat/nim-native`, **UNMERGED**. Commit trailer (every commit): `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Staging discipline:** explicit per-file `git add` only. **NEVER** `git add -A` / `git add .` — unrelated WIP under `assets/`, `benchmarks/`, `vendor/`, `spikes/`.
- Always use **Bun**, never Node.
- **macOS-only behavior**, create-time only. The Nim field additions must still cross-compile for the iOS simulator (iOS `darwin_window_create` won't read the new `wopts_*` symbols — no iOS stub needed; just keep it linking).
- Decisions (locked, from the spec): OQ1 = emit `NEW_TAB_REQUESTED` (app creates the tab); OQ2 = default `tabbingMode` "preferred" when `tabbingIdentifier` set, else AppKit `automatic`; OQ3 = minimal v1 (no programmatic tab-group control); OQ4 = include `tabTitle`.
- `NEW_TAB_REQUESTED` = the next free `WindowEvent` value = **21**; string event name `window:new-tab-requested`; payload `{ windowId }`.
- Known no-op combos to honor + document: `borderless: true` (no titlebar) and `asSheetOf` sheets ignore tabbing.
- A `Vite ✓ built` line is NOT a native build success — require the literal `[zapp] build complete:` line + a fresh binary.

---

### Task 1 (RISK GATE): native NSWindow tabbing + the `newWindowForTab:` "+" hook, proven end-to-end

**Why a risk gate:** Zapp windows are plain `NSWindow` (no subclass); the tab bar "+" button only appears + fires if something in the responder chain implements `newWindowForTab:`. Introducing a `ZappWindow : NSWindow` subclass at the allocation site is the one change whose interaction with the existing window identity/teardown can't be fully predicted from the plan. This task proves the whole mechanism (tab grouping + "+" event + the `hiddenInset`+toolbar combo) before the rest of the surface is built.

**Files:**
- Modify: `runtime/window.ts` (WindowOptions ~75–239; normalized-opts passthrough; new-tab event wiring near the toolbar wiring ~510)
- Modify: `runtime/events.ts` (WindowEvent enum ~22–67; WINDOW_EVENT_NAMES map ~94–116)
- Modify: `native/nim/window.nim` (WindowOptions fields ~146–194; `wopts_*` getters ~250–290; `windowOptsApplyJson` ~560–660)
- Modify: `native/platform/darwin/window.m` (extern block ~41–60; `ZappWindow` subclass — new, near `ZappWindowDelegate` ~361; alloc site ~692; tabbing set ~754; a `zapp_tabs_emit_new_tab` helper modeled on `toolbar.m:95`)
- Modify: `kitchen-sink/src/sections/multiwindow.ts` (a temporary "Open 2 tabs" button — replaced by the real demo in T3)

**Interfaces produced (consumed by T2/T3):**
- TS: `WindowOptions.tabbingIdentifier?: string`, `WindowOptions.tabbingMode?: "automatic"|"preferred"|"disallowed"`; `WindowEvent.NEW_TAB_REQUESTED = 21`.
- Native: `extern void zapp_tabs_emit_new_tab(int32_t host_id);` (defined in window.m); `@interface ZappWindow : NSWindow`.
- Nim: `wopts_tabbing_identifier`, `wopts_tabbing_mode` cstring getters.

- [ ] **Step 1: Add the event (events.ts)**

In `runtime/events.ts`, add to the `WindowEvent` enum after `TOOLBAR_GROUP_SELECTED = 20`:
```ts
  NEW_TAB_REQUESTED = 21,
```
And to `WINDOW_EVENT_NAMES`:
```ts
  [WindowEvent.NEW_TAB_REQUESTED]: "window:new-tab-requested",
```

- [ ] **Step 2: Add the two TS WindowOptions fields (window.ts)**

In the `WindowOptions` interface, after `backgroundExtension` (~238):
```ts
  /** macOS native window tabs. Windows sharing a `tabbingIdentifier` collapse
   *  into one window with a native tab bar. macOS; create-time. Ignored when
   *  `borderless` or when this is an `asSheetOf` sheet. */
  tabbingIdentifier?: string;
  /** "preferred" = always tab with same-identifier windows (default when an
   *  identifier is set); "automatic" = respect the system "Prefer tabs"
   *  setting; "disallowed" = never tab. */
  tabbingMode?: "automatic" | "preferred" | "disallowed";
```
These are plain string fields — `Window.create` already passes unknown WindowOptions keys through in the `normalized` object (same as `titleBarStyle`); no normalize change needed. Verify they appear in `normalized` (grep the `normalized` construction — if it's an allowlist, add the two keys; if it spreads, nothing to do).

- [ ] **Step 3: Wire the runtime event subscription (window.ts)**

Near the toolbar event wiring (~510, the `getBridge().on(eventName(WindowEvent.TOOLBAR_CLICKED), …)` block), confirm the generic `win.on(WindowEvent.NEW_TAB_REQUESTED, handler)` path already works (the per-window `win.on` maps any `WindowEvent` via `eventName()` — see `window.ts:1071`). If toolbar-style events need an explicit `getBridge().on(eventName(WindowEvent.NEW_TAB_REQUESTED), p => dispatch to the window)` bridge→window forwarder, add it mirroring the TOOLBAR_CLICKED block exactly (payload `{ windowId }` → route to that window's listeners). Deliverable: `win.on(WindowEvent.NEW_TAB_REQUESTED, p => …)` receives `{ windowId }`.

- [ ] **Step 4: Nim fields + getters + parse (window.nim)**

Add to the Nim `WindowOptions` ref object (near the other window fields ~146–194):
```nim
    tabbingIdentifier*: string
    tabbingMode*: string
```
Add getters (after `wopts_background_extension` ~263):
```nim
proc wopts_tabbing_identifier(p: pointer): cstring {.exportc, cdecl.} = opt(p).tabbingIdentifier.cstring
proc wopts_tabbing_mode(p: pointer): cstring {.exportc, cdecl.} = opt(p).tabbingMode.cstring
```
Add to `windowOptsApplyJson` (with the other `jHasStr` string fields):
```nim
  if jHasStr(a, "tabbingIdentifier"): o.tabbingIdentifier = jStr(a, "tabbingIdentifier")
  if jHasStr(a, "tabbingMode"): o.tabbingMode = jStr(a, "tabbingMode")
```

- [ ] **Step 5: Native — `ZappWindow` subclass + emit helper (window.m)**

Add the extern + emit helper near the top extern block (~41–60):
```objc
// Emits window:new-tab-requested (toolbar-style string event) for the tab bar "+".
void zapp_tabs_emit_new_tab(int32_t host_id) {
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&b._onEvent)b._onEvent('window:new-tab-requested',"
        "'{\"windowId\":\"win-%d\"}');})();", host_id];
    darwin_webview_eval_all([js UTF8String]);
    worker_broadcast_eval_js((char*)[js UTF8String]);
}
```
(`darwin_webview_eval_all` + `worker_broadcast_eval_js` are already declared/used in this file; confirm — if not, add the `extern` lines as in `toolbar.m:14–15`.)

Add a minimal `NSWindow` subclass after `ZappWindowDelegate` (~388). It reads its delegate's `numericId` to identify the host:
```objc
@interface ZappWindow : NSWindow
@end
@implementation ZappWindow
- (void)newWindowForTab:(id)sender {
    (void)sender;
    id d = self.delegate;
    if ([d isKindOfClass:[ZappWindowDelegate class]]) {
        int32_t hid = ((ZappWindowDelegate*)d).numericId;
        if (hid >= 0) zapp_tabs_emit_new_tab(hid);
    }
}
@end
```

- [ ] **Step 6: Native — allocate `ZappWindow`, set tabbing (window.m ~692, ~754)**

Change the alloc at ~692 from `[[NSWindow alloc] initWithContentRect:…]` to `[[ZappWindow alloc] initWithContentRect:…]` (same args). **RISK CHECK:** grep for any `isKindOfClass:[NSWindow class]` / exact-class checks on the window elsewhere in window.m that a subclass could change — a subclass passes `isKindOfClass:[NSWindow class]` so this should be safe, but verify no `[obj class] == [NSWindow class]` identity checks.

After the traffic-light block (~754), declare the externs near the top and set tabbing:
```objc
const char* tabId = wopts_tabbing_identifier(opts);
const char* tabMode = wopts_tabbing_mode(opts);
if (tabId && tabId[0]) {
    window.tabbingIdentifier = [NSString stringWithUTF8String:tabId];
    // default "preferred" when an identifier is set (OQ2)
    if (tabMode && strcmp(tabMode, "automatic") == 0)       window.tabbingMode = NSWindowTabbingModeAutomatic;
    else if (tabMode && strcmp(tabMode, "disallowed") == 0) window.tabbingMode = NSWindowTabbingModeDisallowed;
    else                                                    window.tabbingMode = NSWindowTabbingModePreferred;
} else if (tabMode && strcmp(tabMode, "disallowed") == 0) {
    window.tabbingMode = NSWindowTabbingModeDisallowed;
}
```
Add the two `extern const char* wopts_tabbing_identifier(void*);` / `wopts_tabbing_mode` lines to the extern block.

- [ ] **Step 7: Kitchen-sink — temporary "Open 2 tabs" button (multiwindow.ts)**

In `kitchen-sink/src/sections/multiwindow.ts`, add a temporary button + handler (replaced in T3) that opens two windows sharing a `tabbingIdentifier` and logs `NEW_TAB_REQUESTED`:
```ts
    onAct(host, "tabs-probe", () => {
      const id = "ks-tabs";
      void open(host, "tab A", () => Window.create({ title: "Tab A", url: "#sidebar-pane", width: 700, height: 480, tabbingIdentifier: id }));
      void open(host, "tab B", () => Window.create({ title: "Tab B", url: "#sidebar-pane", width: 700, height: 480, tabbingIdentifier: id }));
    });
    Window.current().on(WindowEvent.NEW_TAB_REQUESTED, (p: any) => setResult(host, `new-tab-requested: ${p.windowId}`));
```
(Add a `{ act: "tabs-probe", label: "Open 2 tabs (probe)" }` button to a card. `WindowEvent` import may need adding to the file.)

- [ ] **Step 8: Build (macOS)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: `[zapp] build complete: …/kitchen-sink (…KB)` (clean compile of the `ZappWindow` subclass + tabbing).

- [ ] **Step 9: RISK-GATE human visual smoke (pause for the user)**

Stop and ask the user to `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`, Multi-window → "Open 2 tabs (probe)", and confirm:
1. The two windows open as **one window with a native tab bar** (two tabs labelled "Tab A"/"Tab B").
2. Clicking the tab bar **"+"** logs `new-tab-requested: win-…` (the event fires).
3. Repeat with a window opened at `titleBarStyle: "hiddenInset"` + a `toolbar` (temporarily add to one of the probe windows) — confirm the tab bar + toolbar coexist without a broken/squeezed titlebar (the spec's flagged combo). Note any layout issue.

Do not proceed until the user confirms tabs group + "+" fires. If the `newWindowForTab:` hook doesn't fire (subclass not in the responder chain as expected), the fallback is to implement `newWindowForTab:` on the app delegate using `[[NSApp keyWindow] delegate]`'s `numericId` — try that before escalating.

- [ ] **Step 10: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/events.ts runtime/window.ts native/nim/window.nim native/platform/darwin/window.m kitchen-sink/src/sections/multiwindow.ts
git commit -m "$(cat <<'EOF'
feat(macos): native window tabs — tabbingIdentifier + NEW_TAB_REQUESTED (#tabs T1 risk gate)

ZappWindow:NSWindow subclass implements newWindowForTab: → window:new-tab-requested;
tabbingIdentifier/tabbingMode set in darwin_window_create (default preferred).
TS WindowOptions fields + NEW_TAB_REQUESTED=21 + Nim parity. Probe button proves
tabs group + "+" fires (human-gated).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `tabTitle`, harden defaults, round-trip tests, build matrix

**Files:**
- Modify: `runtime/window.ts` (add `tabTitle` field + JSDoc)
- Modify: `native/nim/window.nim` (`tabTitle` field + getter + parse)
- Modify: `native/platform/darwin/window.m` (set `window.tab.title`)
- Modify: `native/nim/tests/windowmanager_test.nim` (round-trip test for the three fields)

**Interfaces:** Consumes T1's fields. Produces `WindowOptions.tabTitle?: string` + `wopts_tab_title`.

- [ ] **Step 1: Failing Nim round-trip test (windowmanager_test.nim)**

Add a `block:` after the existing window-options round-trip tests:
```nim
block:
  # native window tabs: tabbingIdentifier/tabbingMode/tabTitle survive JSON round-trip
  var o = WindowOptions()
  let j = %*{"tabbingIdentifier": "grp", "tabbingMode": "preferred", "tabTitle": "Tab One"}
  windowOptsApplyJson(o, j)
  doAssert o.tabbingIdentifier == "grp"
  doAssert o.tabbingMode == "preferred"
  doAssert o.tabTitle == "Tab One"
```
Run: `nim c -r --hints:off native/nim/tests/windowmanager_test.nim`
Expected: FAIL — `tabTitle` field/parse not defined yet (T1 added the first two; `tabTitle` is new here).

- [ ] **Step 2: Nim `tabTitle` field + getter + parse (window.nim)**

Add `tabTitle*: string` to the WindowOptions object; add
```nim
proc wopts_tab_title(p: pointer): cstring {.exportc, cdecl.} = opt(p).tabTitle.cstring
```
and `if jHasStr(a, "tabTitle"): o.tabTitle = jStr(a, "tabTitle")` to `windowOptsApplyJson`.

Run the test → PASS (`windowmanager ok`).

- [ ] **Step 3: TS `tabTitle` field (window.ts)**

After `tabbingMode` in WindowOptions:
```ts
  /** Tab label override (defaults to the window `title`). Sets NSWindow.tab.title
   *  (macOS 10.13+). macOS; create-time. */
  tabTitle?: string;
```

- [ ] **Step 4: Native — set `window.tab.title` (window.m)**

After the tabbing block (~754), add (declare `extern const char* wopts_tab_title(void*);`):
```objc
const char* tabTitle = wopts_tab_title(opts);
if (tabTitle && tabTitle[0]) {
    if (@available(macOS 10.13, *)) window.tab.title = [NSString stringWithUTF8String:tabTitle];
}
```

- [ ] **Step 5: Build matrix**

- `cd /Users/zach/code/zapp && nim c -r --hints:off native/nim/tests/windowmanager_test.nim` → `windowmanager ok`
- `cd /Users/zach/code/zapp && bun test runtime/ && bunx tsc --noEmit -p tsconfig.json` → pass + clean
- `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:`
- `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios` → `[zapp] build complete:` (ios; proves the Nim field additions cross-compile)

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/window.ts native/nim/window.nim native/platform/darwin/window.m native/nim/tests/windowmanager_test.nim
git commit -m "$(cat <<'EOF'
feat(macos): window tab title + tabs round-trip test (#tabs T2)

tabTitle overrides NSWindow.tab.title (macOS 10.13+); Nim round-trip test for
tabbingIdentifier/tabbingMode/tabTitle. macOS + iOS-sim build gates green.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Kitchen-sink "Tabs" demo + docs + final gates + human visual smoke

**Files:**
- Modify: `kitchen-sink/src/sections/multiwindow.ts` (replace the T1 probe with a real "Tabs" card)
- Modify: `docs/api-reference.md` (document the three fields + `NEW_TAB_REQUESTED` + the no-op combos)

- [ ] **Step 1: Real "Tabs (native window tabs)" demo (multiwindow.ts)**

Replace the T1 `tabs-probe` button/handler with a card whose buttons (a) open two tabbed windows sharing `tabbingIdentifier: "ks-tabs"` with distinct `tabTitle`s, and (b) a `NEW_TAB_REQUESTED` handler that opens another tab in the same group:
```ts
    host.appendChild(card({
      title: "Tabs (native window tabs)",
      intro: "Opens windows that group into one native tab bar (macOS). The tab bar \"+\" fires NEW_TAB_REQUESTED; this app responds by adding another tab.",
      buttons: [{ act: "tabs-open", label: "Open tabbed windows" }],
    }));
    let tabN = 0;
    const openTab = () => { tabN += 1; return Window.create({ title: `Tab ${tabN}`, tabTitle: `Tab ${tabN}`, url: "#sidebar-pane", width: 760, height: 500, tabbingIdentifier: "ks-tabs", titleBarStyle: "hiddenInset" }); };
    onAct(host, "tabs-open", () => { void open(host, "tab", openTab); void open(host, "tab", openTab); });
    Window.current().on(WindowEvent.NEW_TAB_REQUESTED, () => { void open(host, "new tab", openTab); });
```
(Ensure `WindowEvent` is imported. Keep the main window clean — this is opt-in via the button, consistent with prior demos.)

- [ ] **Step 2: Build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:`.

- [ ] **Step 3: Docs (api-reference.md)**

Add a "Native window tabs (macOS)" subsection near the window-options docs documenting: `tabbingIdentifier`, `tabbingMode` (default `preferred` when id set), `tabTitle` (defaults to window title), the `NEW_TAB_REQUESTED` event (`win.on(WindowEvent.NEW_TAB_REQUESTED, p => …)`, payload `{ windowId }`, app must respond to make "+" work), and the no-op combos (`borderless`, `asSheetOf`). macOS-only, create-time.

- [ ] **Step 4: Full gate matrix**

- `nim c -r --hints:off native/nim/tests/windowmanager_test.nim` → `windowmanager ok`
- `bun test runtime/` → pass; `bunx tsc --noEmit -p tsconfig.json` → clean
- `cd kitchen-sink && bun run build` → `[zapp] build complete:`
- `cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:` (ios)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/multiwindow.ts docs/api-reference.md
git commit -m "$(cat <<'EOF'
demo+docs(tabs): kitchen-sink native window tabs demo + api-reference (#tabs T3)

"Tabs" demo opens grouped tabbed windows + handles NEW_TAB_REQUESTED to add tabs.
Docs cover tabbingIdentifier/tabbingMode/tabTitle, the event, and no-op combos.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: FINAL human visual smoke (pause for the user)**

Ask the user to `bun run dev`, Multi-window → "Open tabbed windows", and confirm: (1) windows group into one tab bar with `tabTitle` labels; (2) clicking "+" adds a new tab (NEW_TAB_REQUESTED → app opens another tab in the group); (3) tabs select/close normally (FOCUS/CLOSE reused). Then dispatch the final whole-branch review.

---

## Self-Review

**1. Spec coverage:** `tabbingIdentifier`/`tabbingMode` (T1) + `tabTitle` (T2) + `NEW_TAB_REQUESTED` (T1) + default-preferred (T1 Step 6) + no-op combos documented (T3) + macOS-only/iOS cross-compile (T2 Step 5) + kitchen-sink demo (T3) — all covered. ✓
**2. Placeholder scan:** T1 Step 3 and the `newWindowForTab:` hook are honestly risk-gated (the plan specifies the proposed code + the fallback), appropriate for a RISK GATE — not a placeholder. Every other step has concrete code/commands.
**3. Type consistency:** `tabbingIdentifier`/`tabbingMode`/`tabTitle` (string), `NEW_TAB_REQUESTED = 21`, `zapp_tabs_emit_new_tab(int32_t)`, `wopts_tabbing_identifier`/`wopts_tabbing_mode`/`wopts_tab_title` are named identically across TS, Nim, and native. ✓
