# CEF DevTools (sub-cycle D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open Chromium DevTools for a CEF webview (inspect html/css/console/network) via a runtime API + a Cmd-Opt-I shortcut, dev-gated — parity with the WKWebView system inspector.

**Architecture:** A gated native primitive (`zapp_cef_show_dev_tools`/`close`) calling CEF's `cef_browser_host_t::show_dev_tools`/`close_dev_tools` (DevTools in its own window), reached two ways: (1) a runtime API `Window.current().openDevTools()`/`closeDevTools()` → router → an engine-aware `darwin_devtools_open`/`close`; (2) a `CefKeyboardHandler` catching Cmd-Opt-I on the focused browser. All CEF-native code `#ifdef ZAPP_HAS_CEF`-gated (system byte-identical); on WK the API no-ops (system Develop-menu inspector already covers it).

**Tech Stack:** Objective-C / C (`native/platform/darwin/cef/*`, a new `devtools.m`), Nim router (`native/nim/router.nim`), TypeScript runtime (`runtime/window.ts`), the `cef-hello` fixture.

## Global Constraints

- **Byte-identical `system` build:** all CEF-native calls inside `#ifdef ZAPP_HAS_CEF` (or in whole-file-excluded CEF units). `darwin_devtools_open`/`close` compile for both engines but their CEF calls are gated; the WK path is a pure no-op.
- **Dev-gated:** DevTools opens ONLY when `app_get_bootstrap_web_content_inspectable()` is true (dev; `Inspectable.Auto` = on-in-dev, off-in-prod) — parity with WK's inspector gate. The gate lives in `zapp_cef_show_dev_tools` so BOTH the API and the shortcut are covered.
- **DevTools in its own window** (standalone `window_info`, `parent_view = 0`, `CEF_RUNTIME_STYLE_ALLOY`). Not docked this cycle.
- **Refcount idiom:** `zapp_cef_browser_for_slot` returns a BORROWED browser (never release); `get_host` returns an OWNED host (release exactly once).
- **Verification = native build + human R0 gate** (GUI/native, no unit-test harness). No assertion-free tests.
- **Engine flip:** before a chromium build, `rm -rf ~/.cache/nim/app_r`. Canonical typecheck: root `bun run check`.
- **Branch:** `feat/cef-devtools` off `feat/nim-native`. NO merge without asking. Inclusive language.

---

### Task 1: Native CEF show/close + router entry + runtime API

**Files:**
- Modify: `native/platform/darwin/cef/zapp_cef_host.m` (the show/close helpers)
- Modify: `native/platform/darwin/cef/zapp_cef.h` (decls)
- Create: `native/platform/darwin/devtools.m` (engine-aware `darwin_devtools_open`/`close`)
- Modify: `native/nim/router.nim` (importc decls + `devtools:` action dispatch)
- Modify: `runtime/window.ts` (the `openDevTools`/`closeDevTools` API)

**Interfaces:**
- Consumes: `zapp_cef_browser_for_slot(int32_t)`, `get_host`/`show_dev_tools`/`close_dev_tools` (CEF C-API), `app_get_bootstrap_web_content_inspectable()`, `windowAction()` (window.ts).
- Produces: `void zapp_cef_show_dev_tools(int32_t slot)` / `void zapp_cef_close_dev_tools(int32_t slot)`; `void darwin_devtools_open(int32_t window_id)` / `void darwin_devtools_close(int32_t window_id)`; runtime `WindowHandle.openDevTools()` / `closeDevTools()`; router actions `devtools:open` / `devtools:close`.

- [ ] **Step 1: CEF show/close helpers (`zapp_cef_host.m`)**

Add (mirroring `zapp_cef_window_for_slot`'s borrowed/owned idiom). Build a LOCAL `window_info` (parent_view=0 → standalone DevTools window):
```c
// Open Chromium DevTools for the CEF browser at `slot`, in its own window.
// Dev-gated (parity with WK's inspector): no-op unless inspectable. Both the
// runtime API and the Cmd-Opt-I shortcut route here, so the gate lives here.
void zapp_cef_show_dev_tools(int32_t slot) {
  extern bool app_get_bootstrap_web_content_inspectable(void);
  if (!app_get_bootstrap_web_content_inspectable()) return;
  cef_browser_t* b = zapp_cef_browser_for_slot(slot);   // borrowed
  if (b == NULL) return;
  cef_browser_host_t* host = b->get_host(b);            // owned
  if (host == NULL) return;
  cef_window_info_t info;
  memset(&info, 0, sizeof(info));
  info.size = sizeof(info);
  info.bounds.x = 0; info.bounds.y = 0; info.bounds.width = 960; info.bounds.height = 720;
  info.parent_view = (cef_window_handle_t)0;   // no parent -> standalone DevTools window
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  host->show_dev_tools(host, &info, NULL, NULL, NULL);  // default client/settings, no inspect-point
  host->base.release(&host->base);
}

void zapp_cef_close_dev_tools(int32_t slot) {
  cef_browser_t* b = zapp_cef_browser_for_slot(slot);
  if (b == NULL) return;
  cef_browser_host_t* host = b->get_host(b);
  if (host == NULL) return;
  host->close_dev_tools(host);
  host->base.release(&host->base);
}
```
Declare both in `zapp_cef.h` (near `zapp_cef_window_for_slot`). If `show_dev_tools` with `parent_view=0` does not open a standalone window on this CEF build, the R0 gate will show it — adjust the `window_info` (e.g. a popup style) then.

- [ ] **Step 2: Engine-aware router entry (`native/platform/darwin/devtools.m`, new)**

```objc
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>

// Reverse of the WK inspector's system-provided path: DevTools on CEF needs an
// explicit trigger. Engine-aware — CEF opens Chromium DevTools; WK no-ops (its
// inspector is the macOS system Develop menu / right-click Inspect).
extern cef_browser_t* zapp_cef_browser_for_slot(int32_t slot) __attribute__((weak));

void darwin_devtools_open(int32_t window_id) {
#ifdef ZAPP_HAS_CEF
  extern void zapp_cef_show_dev_tools(int32_t slot);
  extern cef_browser_t* zapp_cef_browser_for_slot(int32_t slot);
  if (zapp_cef_browser_for_slot(window_id)) { zapp_cef_show_dev_tools(window_id); return; }
#endif
  fprintf(stderr, "[zapp] devtools:open on a WKWebView window (slot %d) — use the "
                  "system Develop menu / right-click Inspect Element.\n", window_id);
}

void darwin_devtools_close(int32_t window_id) {
#ifdef ZAPP_HAS_CEF
  extern void zapp_cef_close_dev_tools(int32_t slot);
  extern cef_browser_t* zapp_cef_browser_for_slot(int32_t slot);
  if (zapp_cef_browser_for_slot(window_id)) { zapp_cef_close_dev_tools(window_id); return; }
#endif
  (void)window_id;
}
```
Confirm before writing: check how CEF `.m`/`.c` files reach the source list (`cli/src/build-config.ts`) — `devtools.m` must compile for BOTH engines (it is NOT CEF-only; it's the engine-aware router surface). If the shared darwin source list is in `cli/src/native.ts`, add `devtools.m` there; if a CEF include is needed for the `cef_browser_t*` type, guard it under `#ifdef ZAPP_HAS_CEF` (the `extern` decls + the type must be visible only in the CEF build — restructure the externs so the non-CEF build needs no `cef_browser_t` type, e.g. declare `zapp_cef_browser_for_slot` and the helpers only inside `#ifdef ZAPP_HAS_CEF`). Report the exact wiring in your report.

- [ ] **Step 3: Router dispatch (`router.nim`)**

Add the importc decls near `darwin_sidebar_toggle` (router.nim:135):
```nim
proc darwin_devtools_open(windowId: int32) {.importc, cdecl.}
proc darwin_devtools_close(windowId: int32) {.importc, cdecl.}
```
In `routeWindowAction`, add a `devtools:` block mirroring the `sidebar:`/`inspector:` dispatch (router.nim:658). Use the same `target` resolution the sidebar block uses:
```nim
  if action.startsWith("devtools:"):
    case action
    of "devtools:open":  darwin_devtools_open(target)
    of "devtools:close": darwin_devtools_close(target)
    else: discard
    return
```
(Place it alongside the `sidebar:`/`inspector:` branch; confirm `target` is the resolved slot there.)

- [ ] **Step 4: Runtime API (`runtime/window.ts`)**

Add `openDevTools(): void` and `closeDevTools(): void` to the `WindowHandle` interface, and implement them in the object `createWindowHandle` returns (alongside the sidebar/inspector handles), using the `windowAction` helper (window.ts:1489):
```ts
    openDevTools()  { windowAction("devtools:open",  { windowId }); },
    closeDevTools() { windowAction("devtools:close", { windowId }); },
```
Document on the interface that on WKWebView these no-op (use the system Develop menu).

- [ ] **Step 5: Typecheck + build**

```bash
bun run check
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expected: `tsc` clean; both build markers; no `Undefined symbols`/`error:`.

- [ ] **Step 6: Headless smoke + commit**

Launch cef-hello ~6s, kill, confirm 3 browsers + no crash (DevTools itself needs the human gate). Commit:
```bash
git add native/platform/darwin/cef/zapp_cef_host.m native/platform/darwin/cef/zapp_cef.h \
        native/platform/darwin/devtools.m native/nim/router.nim runtime/window.ts
# + the build-config/native.ts file that registers devtools.m
git commit -m "feat(cef): DevTools show/close primitive + router + openDevTools API (D)"
```

- [ ] **Step 7: (deferred to Task 3's gate)** the API R0 gate is run with the fixture in Task 3.

---

### Task 2: Cmd-Opt-I keyboard shortcut (CefKeyboardHandler)

**Files:**
- Modify: `native/platform/darwin/cef/zapp_cef_client.c` (add a `cef_keyboard_handler_t` via `get_keyboard_handler`)

**Interfaces:**
- Consumes: `zapp_cef_show_dev_tools(int32_t)` (Task 1); the client's per-slot value (the client is created with a slot — `zapp_cef_client_create(window_slot)`); CEF `cef_keyboard_handler_t` / `cef_key_event_t`.
- Produces: Cmd-Opt-I on a focused CEF browser opens its DevTools (dev-gated via the Task-1 primitive).

- [ ] **Step 1: Add the keyboard handler to the client**

In `zapp_cef_client.c`, define a `cef_keyboard_handler_t` whose `on_key_event` catches Cmd-Opt-I and calls `zapp_cef_show_dev_tools` for the client's slot. The handler must carry the slot (mirror how the life-span handler is wired per-client). `cef_key_event_t` fields (confirmed): `type` (`KEYEVENT_RAWKEYDOWN`=0), `modifiers` (`EVENTFLAG_COMMAND_DOWN`=1<<7, `EVENTFLAG_ALT_DOWN`=1<<3), `windows_key_code` (VKEY_I = 0x49):
```c
static int CEF_CALLBACK zapp_cef_on_key_event(struct _cef_keyboard_handler_t* self,
                                              struct _cef_browser_t* browser,
                                              const cef_key_event_t* event,
                                              cef_event_handle_t os_event) {
  (void)browser; (void)os_event;
  if (event && event->type == KEYEVENT_RAWKEYDOWN &&
      (event->modifiers & EVENTFLAG_COMMAND_DOWN) &&
      (event->modifiers & EVENTFLAG_ALT_DOWN) &&
      event->windows_key_code == 0x49 /* VKEY_I */) {
    extern void zapp_cef_show_dev_tools(int32_t slot);
    zapp_cef_show_dev_tools(/* this client's slot */ ((zapp_cef_keyboard_handler_t*)self)->slot);
    return 1;  // handled
  }
  return 0;
}
```
Wire it: define a `zapp_cef_keyboard_handler_t` struct = `{ cef_keyboard_handler_t base; int32_t slot; }` (like the existing life-span handler struct), zero-init + set `base.on_key_event` + `slot` when the client is created (in `zapp_cef_client_create`), and return it from the client's `get_keyboard_handler`. Confirm the exact life-span-handler wiring in the file and mirror it (allocation/lifetime, `base.size`, ref-counting `add_ref`/`release` if the existing handlers use it). The dev-gate is already inside `zapp_cef_show_dev_tools` — no extra gate here.

- [ ] **Step 2: Build + headless**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Both markers; headless ~6s, 3 browsers, no crash.

- [ ] **Step 3: Commit**

```bash
git add native/platform/darwin/cef/zapp_cef_client.c
git commit -m "feat(cef): Cmd-Opt-I opens DevTools for the focused browser (D)"
```

- [ ] **Step 4: (gate in Task 3)**

---

### Task 3: Fixture + docs + R0 gates

**Files:**
- Modify: `examples/cef-hello/index.html` (an "Open DevTools" button)
- Modify: `examples/cef-hello/src/main.ts` (wire the button)
- Modify: `spikes/cef-macos/FINDINGS.md`, `examples/cef-hello/SMOKE.md`

- [ ] **Step 1: Fixture button**

`index.html` — add after the existing host-pane buttons:
```html
      <button id="open-devtools">Open DevTools</button>
```
`main.ts` — wire it in the HOST-pane block (guarded `!isSidebar && !isInspector`, alongside the toggle buttons):
```ts
  document.querySelector<HTMLButtonElement>("#open-devtools")!
    .addEventListener("click", () => Window.current().openDevTools());
```

- [ ] **Step 2: Build**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Both markers.

- [ ] **Step 3: Commit**

```bash
git add examples/cef-hello/index.html examples/cef-hello/src/main.ts
git commit -m "fixture(cef): Open DevTools button (D gate)"
```

- [ ] **Step 4: Human R0 gates** (controller runs WITH the user)

```bash
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
- **API:** click **Open DevTools** in window 1's host pane → a Chromium **DevTools window opens** showing that pane's live html/css/console. Interacting (Elements/Console) works.
- **Shortcut:** focus the host pane, press **Cmd-Opt-I** → DevTools opens for it. Focus the **sidebar** pane, Cmd-Opt-I → DevTools opens for the SIDEBAR's browser (confirms per-focused-browser targeting).
- **Close:** the DevTools window's own close works; `Window.current().closeDevTools()` (if exercised) closes it.
- **Regression:** the C1-C3 + host-event surfaces still work; window 2 unaffected.

- [ ] **Step 5: Docs**

`FINDINGS.md`: DevTools-on-CEF shipped — `zapp_cef_show_dev_tools`/`close` (own window, dev-gated), reached via `Window.current().openDevTools()`/`closeDevTools()` + Cmd-Opt-I (`CefKeyboardHandler`, focused-browser). WK no-ops (system inspector). This is the debug tool for the popover/contextmenu/embedded-webview cycles. `SMOKE.md`: the API + shortcut + per-focused-pane gates. Then:
```bash
bun run check && bun run test   # green (docs); 292 pass
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): close sub-cycle D DevTools-on-CEF — findings + gates"
```

---

## Self-Review

**1. Spec coverage:**
- Native CEF show/close (own window, dev-gated) → Task 1 Step 1. ✅
- Engine-aware router + `devtools:` actions → Task 1 Steps 2-3. ✅
- Runtime API → Task 1 Step 4. ✅
- Cmd-Opt-I CefKeyboardHandler (focused browser) → Task 2. ✅
- Fixture + gates (API, shortcut, per-focused-pane, dev-gate parity) → Task 3. ✅
- Byte-identical WK (`#ifdef` gating; WK no-op) → Global Constraints + Task 1 Step 2. ✅
- Non-goals (WK programmatic, nav, docked) → out of scope, unaddressed by design. ✅
- Docs → Task 3 Step 5. ✅

**2. Placeholder scan:** No TBD/TODO. Step 1's helpers + Step 2's router + Task 2's handler are complete code; the two "confirm the wiring" notes (devtools.m source-list registration; the life-span-handler mirror for the keyboard handler) are verification instructions, not placeholders — the exact per-file wiring is genuinely file-specific and must be read from the current source.

**3. Type consistency:** `zapp_cef_show_dev_tools`/`close_dev_tools(int32_t)` and `darwin_devtools_open`/`close(int32_t)` are consistent across Task 1/2/3; `windowAction("devtools:open"/"devtools:close")` matches the router `case` strings; `WindowHandle.openDevTools`/`closeDevTools` match the runtime + fixture calls; the `cef_key_event_t` fields + `EVENTFLAG_*` + `KEYEVENT_RAWKEYDOWN` + `0x49` match `cef_types.h`.
