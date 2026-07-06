# CEF Multi-Window (Sub-Cycle B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make N app-created CEF windows work correctly — a slot↔browser registry replaces the single-window globals, targeted eval routes by slot, broadcasts fan to all windows, `window.open`/`target=_blank` route to the system browser, and per-window close honors the close guard with a last-window quit that matches WKWebView.

**Architecture:** The CEF client is already created per-browser (`zapp_cef_host.m:272`) and the window slot is already threaded to create (`host.m:256`) — it's just stored in two file-globals (`g_active_browser`, `g_zapp_cef_window_slot`) instead of per-window. This cycle bakes the slot onto the per-window client + its life-span handler, registers each browser in a slot-indexed table `zapp_cef_browsers[]` (the exact mirror of the WKWebView side's `zapp_webviews[]`), and builds the per-window close path (which does not exist today — `close_browser` is called nowhere).

**Tech Stack:** Objective-C / C, CEF C-API (`native/platform/darwin/cef/`), the Zapp Nim router + AppKit window layer (`native/platform/darwin/window.m`), TypeScript fixture (`examples/cef-hello/`), `zapp` CLI build.

## Global Constraints

- **Branch:** `feat/cef-multi-window` (off `feat/nim-native @ 1eb563f`). **Do NOT merge to `nim-native` without asking** (Windows handoff target).
- **Platform:** macOS-only. All CEF work is opt-in behind `webEngine:"chromium"` → `ZAPP_HAS_CEF`.
- **Byte-identical `system` builds:** all `native/platform/darwin/cef/*` TUs compile only under `ZAPP_HAS_CEF`; every `window.m` CEF line stays inside `#ifdef ZAPP_HAS_CEF`. A `webEngine:"system"` build must be unaffected (bare `bin/<exe>`, no `.app`).
- **Table size:** `ZAPP_MAX_WINDOW_CALLBACKS` = 64 (`window.m:102`). The CEF browser table mirrors `zapp_webviews[]` exactly.
- **Parity, not new features:** `on_before_popup` matches WKWebView's `createWebViewWithConfiguration` (system browser). Close guard + last-window quit match the WKWebView `windowShouldClose:` + `terminateAfterLastWindowClosed` behavior. In-app popups and reversible-reshow of a CEF window are **non-goals** (CEF-window close is terminal this cycle; gate/document it).
- **Engine-switch clean build:** `rm -rf ~/.cache/nim/app_r` before every `bun run build` after an engine flip.
- **Canonical gate:** root `bun run check` + `bun run test`. NOT per-example `bunx tsc` (pre-existingly fails on runtime enums — see `reference_example_app_tsc_gate`).
- **Worker fixture wiring:** a headless worker needs BOTH `zapp.config.ts` AND `vite.config.ts`'s `zappWorkers({ headless })` (see `reference_headless_worker_two_place_wiring`). cef-hello already has both from sub-cycle A.
- **Inclusive language:** allowlist/blocklist.
- **Refcount discipline:** CEF C-API callback params are owned refs (release once); the extra `on_after_created` ref is released once on deregister. This is the main correctness hazard — follow the existing comments in `zapp_cef_client.c`.

## File Structure

- `native/platform/darwin/cef/zapp_cef_client.c` — the `zapp_cef_browsers[]` table + slot-bounds helpers; `slot` field on both `zapp_cef_client_t` and `zapp_cef_life_span_handler_t`; `on_after_created`/`on_before_close` register/deregister by slot; `zapp_cef_eval_in_window` indexes the table; `on_process_message_received` tags `window_id` from the client's slot; new `on_before_popup`. Removes `g_active_browser` + `g_zapp_cef_window_slot`.
- `native/platform/darwin/cef/zapp_cef_host.m` — `zapp_cef_create_browser_in_view` passes `window_slot` to `zapp_cef_client_create(slot)`; drops `zapp_cef_set_window_slot`.
- `native/platform/darwin/cef/zapp_cef.h` — decl updates (`zapp_cef_client_create(int32_t)`, a broadcast helper, `zapp_cef_close_browser_for_slot`; remove `get/set_window_slot`).
- `native/platform/darwin/window.m` — broadcast branch iterates the table; `darwin_window_destroy` gains a CEF `close_browser` branch; `windowWillClose:` clears the CEF table slot (broadcast parity).
- `examples/cef-hello/` — second window + a `target=_blank` link + close-guard demo wiring.
- `spikes/cef-macos/FINDINGS.md` — mark multi-window closed + the coupled `on_before_close`→`[NSApp stop]` Minor cleared.

---

### Task 1: Slot↔browser registry + two-window fixture

Replace the single-window globals with a slot-indexed browser table, bake the slot onto the per-window client, route targeted eval by slot and broadcast to all, and prove it with a second CEF window in the fixture. Interim: `on_before_close` keeps its `quit_main_loop` call (Task 2 removes it) — this task's gate does not close windows.

**Files:**
- Modify: `native/platform/darwin/cef/zapp_cef_client.c`
- Modify: `native/platform/darwin/cef/zapp_cef_host.m:243-272`
- Modify: `native/platform/darwin/cef/zapp_cef.h`
- Modify: `native/platform/darwin/window.m:154-168`
- Modify: `examples/cef-hello/zapp/app.nim`
- Modify: `examples/cef-hello/src/main.ts`, `examples/cef-hello/index.html`

**Interfaces:**
- Produces: `void zapp_cef_client_create` becomes `cef_client_t* zapp_cef_client_create(int32_t slot)`; `zapp_cef_browsers[ZAPP_MAX_WINDOW_CALLBACKS]` slot table (file-static in client.c); `void zapp_cef_broadcast_eval(const char* js)` (iterates the table, main-thread eval) exposed for window.m; `zapp_cef_eval_in_window(int32_t slot, const char* js)` unchanged signature, now table-backed.
- Consumes (Task 2): `on_before_close` still calls `zapp_cef_quit_main_loop()` here; Task 2 removes it. `zapp_cef_browsers[]` + a `zapp_cef_close_browser_for_slot(int32_t)` helper (added Task 2).

- [ ] **Step 1: Add the slot to both structs**

In `zapp_cef_client.c`, add `int32_t slot;` to both structs:

```c
typedef struct _zapp_cef_client_t {
  cef_client_t client;        // MUST be first member.
  atomic_int ref_count;
  int32_t slot;               // Zapp window slot this browser hosts (multi-window).
  zapp_cef_life_span_handler_t* life_span_handler;
} zapp_cef_client_t;

struct _zapp_cef_life_span_handler_t {
  cef_life_span_handler_t handler;   // MUST be first member.
  atomic_int ref_count;
  int32_t slot;                      // same slot as the owning client.
};
```

- [ ] **Step 2: Replace the two globals with the slot table + helpers**

In `zapp_cef_client.c`, replace `g_active_browser` (line 86-90) and `g_zapp_cef_window_slot` + accessors (lines 101-104) with:

```c
// One browser per Zapp window slot — the exact mirror of window.m's
// zapp_webviews[]. Registered in on_after_created, cleared in on_before_close /
// the window-destroy path. Read by the targeted eval (by slot) and the
// broadcast fan-out (all live entries). Main-thread only (CEF UI thread ==
// the external-pump main thread), so no lock — same as zapp_webviews[].
static cef_browser_t* zapp_cef_browsers[ZAPP_MAX_WINDOW_CALLBACKS] = {0};

static int zapp_cef_slot_ok(int32_t slot) {
  return slot >= 0 && slot < ZAPP_MAX_WINDOW_CALLBACKS;
}

cef_browser_t* zapp_cef_browser_for_slot(int32_t slot) {
  return zapp_cef_slot_ok(slot) ? zapp_cef_browsers[slot] : NULL;
}
```

`ZAPP_MAX_WINDOW_CALLBACKS` is defined in `window.m`; add `#define ZAPP_MAX_WINDOW_CALLBACKS 64` guarded near the top of `zapp_cef_client.c` if not already visible (mirror the existing value exactly), or include the shared definition. Verify with the build.

`zapp_cef_get_active_browser()` (client.c:88-89) had a single caller contract — grep its uses; if only internal, remove it; if referenced elsewhere, repoint to `zapp_cef_browser_for_slot`. (Run `git grep zapp_cef_get_active_browser` first.)

- [ ] **Step 3: eval_now + eval_in_window index the table**

`zapp_cef_eval_now` (client.c:112) currently reads `g_active_browser`. Make it take an explicit browser, and have `zapp_cef_eval_in_window` look up by slot:

```c
static void zapp_cef_eval_now(cef_browser_t* b, const char* js) {
  if (b == NULL || js == NULL) return;
  cef_frame_t* frame = b->get_main_frame(b);
  if (frame == NULL) return;
  cef_string_t code, empty;
  memset(&code, 0, sizeof(code));
  memset(&empty, 0, sizeof(empty));
  cef_string_utf8_to_utf16(js, strlen(js), &code);
  frame->execute_java_script(frame, &code, &empty, 0);
  cef_string_clear(&code);
  frame->base.release(&frame->base);
}

int zapp_cef_eval_in_window(int32_t slot, const char* js) {
  cef_browser_t* b = zapp_cef_browser_for_slot(slot);
  if (js == NULL || b == NULL) return 0;   // not handled → caller may fall through
  if (pthread_main_np() != 0) {
    zapp_cef_eval_now(b, js);
  } else {
    char* copy = strdup(js);
    if (copy == NULL) return 1;  // handled (OOM — drop).
    int32_t s = slot;
    dispatch_async(dispatch_get_main_queue(), ^{
      zapp_cef_eval_now(zapp_cef_browser_for_slot(s), copy);  // re-lookup: window may have closed
      free(copy);
    });
  }
  return 1;  // handled by CEF.
}
```
Note: the async path re-looks-up the browser by slot at eval time (a window can close between the worker-thread call and the main-thread hop), instead of capturing a possibly-stale pointer.

- [ ] **Step 4: on_after_created / on_before_close register + deregister by slot**

```c
void CEF_CALLBACK
zapp_cef_life_span_on_after_created(cef_life_span_handler_t* self,
                                    cef_browser_t* browser) {
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)self;
  if (zapp_cef_slot_ok(h->slot)) {
    zapp_cef_browsers[h->slot] = browser;   // keep the owned ref (released on close)
    fprintf(stderr, "[zapp-cef] browser created (slot %d)\n", h->slot);
  } else {
    fprintf(stderr, "[zapp-cef] browser created with bad slot %d — dropping\n", h->slot);
    browser->base.release(&browser->base);
  }
}

void CEF_CALLBACK
zapp_cef_life_span_on_before_close(cef_life_span_handler_t* self,
                                   cef_browser_t* browser) {
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)self;
  if (zapp_cef_slot_ok(h->slot) && zapp_cef_browsers[h->slot] == browser) {
    zapp_cef_browsers[h->slot] = NULL;
    browser->base.release(&browser->base);   // the extra on_after_created ref
  }
  browser->base.release(&browser->base);     // this callback's own owned ref
  // TASK 2 removes the line below — the last-window quit becomes Zapp's
  // terminateAfterLastWindowClosed path. Kept here so single-window quit still
  // works until Task 2 reworks it.
  fprintf(stderr, "[zapp-cef] browser closing (slot %d)\n", h->slot);
  zapp_cef_quit_main_loop();
}
```
`do_close` (client.c:169) is unchanged in Task 1.

- [ ] **Step 5: handler + client create take the slot**

```c
static zapp_cef_life_span_handler_t* zapp_cef_life_span_handler_create(int32_t slot) {
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)calloc(
      1, sizeof(zapp_cef_life_span_handler_t));
  CHECK(h);
  INIT_CEF_BASE_REFCOUNTED(&h->handler.base, cef_life_span_handler_t,
                           zapp_cef_life_span_handler);
  h->handler.on_after_created = zapp_cef_life_span_on_after_created;
  h->handler.do_close = zapp_cef_life_span_do_close;
  h->handler.on_before_close = zapp_cef_life_span_on_before_close;
  h->slot = slot;
  atomic_store(&h->ref_count, 1);
  return h;
}

cef_client_t* zapp_cef_client_create(int32_t slot) {
  zapp_cef_client_t* client =
      (zapp_cef_client_t*)calloc(1, sizeof(zapp_cef_client_t));
  CHECK(client);
  INIT_CEF_BASE_REFCOUNTED(&client->client.base, cef_client_t, zapp_cef_client);
  client->client.get_life_span_handler = zapp_cef_client_get_life_span_handler;
  client->client.on_process_message_received =
      zapp_cef_client_on_process_message_received;
  client->slot = slot;
  client->life_span_handler = zapp_cef_life_span_handler_create(slot);
  CHECK(client->life_span_handler);
  atomic_store(&client->ref_count, 1);
  return &client->client;
}
```

- [ ] **Step 6: message handler tags window_id from the client's slot**

In `zapp_cef_client_on_process_message_received` (client.c:233): change `(void)self;` to read the slot, and replace both `zapp_cef_get_window_slot()` calls (client.c:268 diagnostic + 275-276 router call) with `client->slot`:

```c
  zapp_cef_client_t* client = (zapp_cef_client_t*)self;
  (void)frame;
  (void)source_process;
  // ... later, in the ZAPP_MSG_INVOKE branch:
      fprintf(stderr, "[zapp-cef][browser] -> router (win=%d): %s\n",
              client->slot, env_utf8.str);
  // ...
      void* app_ptr = app_get_active();
      if (app_ptr != NULL) {
        zapp_handle_message_from_window(app_ptr, env_utf8.str, client->slot);
      }
```

- [ ] **Step 7: host passes the slot to client_create**

In `zapp_cef_host.m` (create fn, lines 256 + 272): remove `zapp_cef_set_window_slot(window_slot);` (line 256, and its 253-255 comment) and change:
```c
  cef_client_t* client = zapp_cef_client_create(window_slot);
```

- [ ] **Step 8: header decls**

In `zapp_cef.h`: change `cef_client_t* zapp_cef_client_create(void);` → `cef_client_t* zapp_cef_client_create(int32_t slot);`. Remove `void zapp_cef_set_window_slot(int32_t);` and `int32_t zapp_cef_get_window_slot(void);`. Add:
```c
// Fan a broadcast into every live CEF browser (all slots). Main-thread safe.
void zapp_cef_broadcast_eval(const char* js);
```
And add its implementation to `zapp_cef_client.c`:
```c
void zapp_cef_broadcast_eval(const char* js) {
  if (js == NULL) return;
  void (^run)(void) = ^{
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
      cef_browser_t* b = zapp_cef_browsers[i];
      if (b) zapp_cef_eval_now(b, js);
    }
  };
  if (pthread_main_np() != 0) run();
  else {
    char* copy = strdup(js);
    if (copy == NULL) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        cef_browser_t* b = zapp_cef_browsers[i];
        if (b) zapp_cef_eval_now(b, copy);
      }
      free(copy);
    });
  }
}
```

- [ ] **Step 9: window.m broadcast branch fans to all CEF browsers**

In `zapp_registered_webviews_eval` (window.m:154-164), replace the single-slot CEF block with the fan-out helper:
```c
#ifdef ZAPP_HAS_CEF
        // A CEF window has no zapp_webviews[] entry, so the loop above misses
        // it. Fan the broadcast into EVERY live CEF browser (multi-window).
        // script.UTF8String is retained by this block. Compiled out on `system`.
        extern void zapp_cef_broadcast_eval(const char* js);
        zapp_cef_broadcast_eval([script UTF8String]);
#endif
```
(The `zapp_cef_broadcast_eval` helper already hops to main / iterates; this call is inside the existing `run` block which is already on main, so it takes the inline path.)

- [ ] **Step 10: fixture — open a second CEF window**

In `examples/cef-hello/zapp/app.nim`, create a second window in `runApp` (after the first), each revealed by `onReady`:
```nim
  let win2 = app.window.create(WindowOptions(
    title: "CEF Hello — Window 2",
    visible: false,
    width: 480, height: 320,
    inspectable: Inspectable.Auto,
  ))
  win2.onReady(onReady)
```
Both windows load the same page (same `ticker` broadcast + `greet` service). In `index.html`/`main.ts`, add a small `#which` label so each window is visually distinguishable (e.g., render `location.href` or a window counter) — the page is shared, so use the tick display already present; the two windows are distinguished by title + position.

- [ ] **Step 11: Build + R0 gate (both windows work while open)**

Run:
```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expect `[zapp] CEF app bundle:` + `[zapp] build complete:`. Then:
```bash
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
**R0 gate:** two CEF windows open; **both** show the ticking counter incrementing (broadcast fan-out); clicking **Say hello** in **each** window shows `Hello from CEF` in that window (targeted eval routes per-window). Do not close windows yet (Task 2). Ctrl-C to end.

Headless evidence: `… 2>&1 | grep -E "browser created \(slot|-> router \(win="` — expect two `browser created (slot N)` lines with distinct slots, and `-> router (win=N)` tagged with the clicking window's slot.

- [ ] **Step 12: Commit**

```bash
git add native/platform/darwin/cef/zapp_cef_client.c native/platform/darwin/cef/zapp_cef_host.m \
        native/platform/darwin/cef/zapp_cef.h native/platform/darwin/window.m \
        examples/cef-hello/zapp/app.nim examples/cef-hello/src/main.ts examples/cef-hello/index.html
git commit -m "feat(cef): slot↔browser registry + two-window fixture (multi-window render/broadcast/targeted)"
```

---

### Task 2: Close handshake — close-guard parity + last-window quit

Build the per-window close path so CEF teardown routes through the window handlers: the close guard (at `windowShouldClose:`) vetoes as it does for WKWebView, a closed window's browser is torn down via `close_browser`, and the app quits only on last-window-close via `terminateAfterLastWindowClosed` (not `on_before_close`). **This is the highest-risk task — start with the spike step.**

**Files:**
- Modify: `native/platform/darwin/cef/zapp_cef_client.c` (drop `quit_main_loop`; add `zapp_cef_close_browser_for_slot`)
- Modify: `native/platform/darwin/cef/zapp_cef.h` (decl)
- Modify: `native/platform/darwin/window.m:454-479` (`windowWillClose:` clear the CEF slot) and `native/platform/darwin/window.m:1300+` (`darwin_window_destroy` CEF `close_browser` branch)

**Interfaces:**
- Consumes: `zapp_cef_browsers[]` + `zapp_cef_browser_for_slot` (Task 1).
- Produces: `void zapp_cef_close_browser_for_slot(int32_t slot)` — calls `browser->get_host()->close_browser(host, /*force=*/1)` for the slot's browser (guarded).

- [ ] **Step 1: SPIKE — determine the close ordering empirically**

Before writing the handshake, confirm how Zapp's window close/destroy lifecycle fires for a CEF window. Add temporary `fprintf(stderr, ...)` traces to `windowShouldClose:`, `windowWillClose:`, `darwin_window_destroy`, and the CEF `do_close`/`on_before_close`, rebuild the two-window fixture, and record (in the report): for a **user close of a non-last window** — the exact order of these callbacks, whether `darwin_window_destroy` is even called on a plain close (vs only on app quit), and whether `terminateAfterLastWindowClosed` triggers `darwin_window_destroy`. This determines whether `close_browser` goes in `windowWillClose:` or `darwin_window_destroy` and whether `do_close` must return 1 (defer) or 0 (allow). Remove the temporary traces before Step 5. Document the observed ordering in the commit + FINDINGS.

- [ ] **Step 2: Add the close-browser helper**

In `zapp_cef_client.c`:
```c
void zapp_cef_close_browser_for_slot(int32_t slot) {
  cef_browser_t* b = zapp_cef_browser_for_slot(slot);
  if (b == NULL) return;
  cef_browser_host_t* host = b->get_host(b);   // owned ref
  if (host) {
    host->close_browser(host, /*force_close=*/1);
    host->base.release(&host->base);
  }
}
```
Declare in `zapp_cef.h`: `void zapp_cef_close_browser_for_slot(int32_t slot);`.

- [ ] **Step 3: on_before_close no longer quits**

In `zapp_cef_life_span_on_before_close` (client.c), delete the `zapp_cef_quit_main_loop();` line and its comment (the interim from Task 1). The handler now only deregisters + releases:
```c
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)self;
  if (zapp_cef_slot_ok(h->slot) && zapp_cef_browsers[h->slot] == browser) {
    zapp_cef_browsers[h->slot] = NULL;
    browser->base.release(&browser->base);
  }
  browser->base.release(&browser->base);
  fprintf(stderr, "[zapp-cef] browser closed (slot %d)\n", h->slot);
```

- [ ] **Step 4: windowWillClose clears the CEF slot (broadcast parity)**

In `windowWillClose:` (window.m:454-478), add a CEF branch mirroring the `zapp_webviews[self.numericId] = nil;` clears, so a closed window stops receiving broadcasts:
```objc
#ifdef ZAPP_HAS_CEF
    // CEF windows have no zapp_webviews[] entry; clear the CEF browser slot so
    // broadcasts skip a closed window (parity with the zapp_webviews clears
    // above). The browser itself is torn down in darwin_window_destroy.
    extern void zapp_cef_browsers_clear_slot(int32_t slot);
    if (self.numericId >= 0 && self.numericId < ZAPP_MAX_WINDOW_CALLBACKS)
        zapp_cef_browsers_clear_slot(self.numericId);
#endif
```
Add `zapp_cef_browsers_clear_slot` to client.c (sets `zapp_cef_browsers[slot] = NULL` if in bounds, without releasing — the browser ref is released in on_before_close) and its `zapp_cef.h` decl. **NOTE:** the exact site (here vs `darwin_window_destroy`) and whether `close_browser` is called here depends on the Step-1 spike; adjust per the observed ordering.

- [ ] **Step 5: darwin_window_destroy tears the browser down**

In `darwin_window_destroy` (window.m:1300+), alongside the WKWebView teardown (1321-1324), add:
```objc
#ifdef ZAPP_HAS_CEF
    // Terminal CEF teardown — mirror zapp_teardown_webview. CEF-window close is
    // terminal this cycle (reversible reshow is a non-goal); close_browser here
    // releases the browser + fires on_before_close (deregisters the slot).
    extern void zapp_cef_close_browser_for_slot(int32_t slot);
    // resolve the window's slot the same way the rest of this fn does:
    ZappWindowDelegate* d = (ZappWindowDelegate*)[window delegate];
    if ([d isKindOfClass:[ZappWindowDelegate class]] && d.numericId >= 0)
        zapp_cef_close_browser_for_slot(d.numericId);
#endif
```
(Confirm the delegate/slot accessor name against the surrounding code in this function.)

- [ ] **Step 6: Build + R0 close gate**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
**R0 gate:**
- Close **Window 2** (non-last) → Window 1 stays open and **keeps ticking**; the app does NOT quit. (`browser closed (slot N)` logs for window 2 only.)
- Close the **last** window → the app quits (`terminateAfterLastWindowClosed`).
- **Close guard:** with a close guard set on a window (add a temporary `Window.setCloseGuard(true)` in the fixture for the gate), clicking close is **vetoed** and the JS `window:close` handler fires; clearing the guard / force-close then actually closes it.

- [ ] **Step 7: Commit**

```bash
git add native/platform/darwin/cef/zapp_cef_client.c native/platform/darwin/cef/zapp_cef.h \
        native/platform/darwin/window.m
git commit -m "feat(cef): per-window close handshake — close-guard parity + last-window quit"
```

---

### Task 3: Popup parity — on_before_popup → system browser

Wire CEF's popup callback to match WKWebView: `window.open`/`target=_blank` cancel the popup and open in the system browser, instead of CEF spawning a chrome-less popup window.

**Files:**
- Modify: `native/platform/darwin/cef/zapp_cef_client.c` (add `on_before_popup` to the life-span handler)
- Modify: `examples/cef-hello/index.html` (a `target=_blank` link for the gate)

**Interfaces:**
- Consumes: nothing new.
- Produces: `on_before_popup` on the life-span handler (returns 1 = cancel).

- [ ] **Step 1: Implement on_before_popup**

In `zapp_cef_client.c`, add the callback (extract the target URL, open it in the system browser, cancel the popup). CEF's `on_before_popup` runs on the UI thread:
```c
int CEF_CALLBACK zapp_cef_life_span_on_before_popup(
    cef_life_span_handler_t* self, cef_browser_t* browser, cef_frame_t* frame,
    const cef_string_t* target_url, const cef_string_t* target_frame_name,
    cef_window_open_disposition_t target_disposition, int user_gesture,
    const cef_popup_features_t* popup_features, cef_window_info_t* window_info,
    cef_client_t** client, cef_browser_settings_t* settings,
    cef_dictionary_value_t** extra_info, int* no_javascript_access) {
  (void)self; (void)browser; (void)frame; (void)target_frame_name;
  (void)target_disposition; (void)user_gesture; (void)popup_features;
  (void)window_info; (void)client; (void)settings; (void)extra_info;
  (void)no_javascript_access;
  // Match WKWebView (webview.m:668-677): open in the system browser, no in-app
  // window. target_url is a cef_string_t (UTF-16); convert + hand to NSWorkspace.
  if (target_url != NULL && target_url->str != NULL) {
    cef_string_utf8_t u8; memset(&u8, 0, sizeof(u8));
    cef_string_utf16_to_utf8(target_url->str, target_url->length, &u8);
    if (u8.str != NULL) {
      extern void zapp_open_url_in_system_browser(const char* url);  // see Step 2
      zapp_open_url_in_system_browser(u8.str);
    }
    cef_string_utf8_clear(&u8);
  }
  return 1;  // cancel the popup — no in-app browser is created.
}
```
Wire it in `zapp_cef_life_span_handler_create`: `h->handler.on_before_popup = zapp_cef_life_span_on_before_popup;`.

- [ ] **Step 2: system-browser helper (avoid ObjC in the .c file)**

`zapp_cef_client.c` is C, not ObjC, so `NSWorkspace` can't be called directly. Add a small ObjC shim in `zapp_cef_host.m` (which is `.m`):
```objc
void zapp_open_url_in_system_browser(const char* url) {
  if (!url || !url[0]) return;
  NSString* s = [NSString stringWithUTF8String:url];
  NSURL* u = s ? [NSURL URLWithString:s] : nil;
  if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}
```
Declare in `zapp_cef.h`: `void zapp_open_url_in_system_browser(const char* url);`. (If a `zapp_open_url`-style helper already exists in the darwin layer, reuse it instead — grep first.)

- [ ] **Step 3: fixture link**

In `examples/cef-hello/index.html`, add inside `<main>`:
```html
      <p><a href="https://example.com" target="_blank">open external (should hit system browser)</a></p>
```

- [ ] **Step 4: Build + R0 gate**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
**R0 gate:** clicking the "open external" link opens `example.com` in your **default browser**, and **no** chrome-less CEF popup window appears. (Regression: ticking + greet still work.)

- [ ] **Step 5: Commit**

```bash
git add native/platform/darwin/cef/zapp_cef_client.c native/platform/darwin/cef/zapp_cef_host.m \
        native/platform/darwin/cef/zapp_cef.h examples/cef-hello/index.html
git commit -m "feat(cef): on_before_popup → system browser (WKWebView parity)"
```

---

### Task 4: Docs — close multi-window + record the cleared Minor

**Files:**
- Modify: `spikes/cef-macos/FINDINGS.md`
- Modify: `examples/cef-hello/SMOKE.md` (add the multi-window gates)

**Interfaces:** none (docs).

- [ ] **Step 1: FINDINGS**

In `spikes/cef-macos/FINDINGS.md`: add a sub-cycle B section — multi-window CLOSED (slot↔browser registry; broadcast fan-out; per-window close handshake with close-guard parity + last-window quit; `on_before_popup`→system browser). Record the coupled **`on_before_close`→`[NSApp stop]` quit-guard Minor as cleared**. Record the Step-1 spike's observed close ordering (a durable note for C/D). Note the reversible-reshow-of-a-CEF-window non-goal.

- [ ] **Step 2: SMOKE**

In `examples/cef-hello/SMOKE.md`: add GATE rows for multi-window — two-window render + broadcast fan-out, per-window targeted greet, close-guard veto + force-close, non-last vs last close, popup→system browser. Mark each with its R0 result (human-confirmed, dated) as gates pass.

- [ ] **Step 3: Verify canonical gate unchanged**

Run (repo root): `bun run check && bun run test`
Expected: green/unchanged (docs + fixture config are data; no CLI logic changed).

- [ ] **Step 4: Commit**

```bash
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): close multi-window (sub-cycle B) + record cleared quit-guard Minor"
```

---

## Self-Review

**Spec coverage:**
- §1 registry → Task 1 (Steps 1-9). §2 targeted eval → Task 1 Step 3. §3 broadcast → Task 1 Steps 8-9. §4 message tagging → Task 1 Step 6. §5 popup parity → Task 3. §6 close handshake / guard / quit → Task 2. §7 fixture + gates → Task 1 Step 10 (2nd window) + Tasks 2/3 gates. Non-goals (in-app popups, mixed-engine, native-chrome, reversible reshow) → untouched; documented Task 4.
- Byte-identical `system` build: all changes are in `cef/*` (gated TUs) or inside `#ifdef ZAPP_HAS_CEF` in `window.m` → verified per constraint; single-window regression is part of Task 1/2 gates.

**Placeholder scan:** The Task 2 spike (Step 1) is a genuine investigation the risky handshake requires (spec-authorized), not a placeholder — it produces a recorded finding that shapes Steps 4-5. All code steps carry real before/after code. The two "grep first" notes (`zapp_cef_get_active_browser` uses, existing `zapp_open_url` helper) are correctness checks against the live tree, not deferred work.

**Type/name consistency:** `zapp_cef_client_create(int32_t slot)` used in host.m Step 7 matches client.c Step 5 + header Step 8. `zapp_cef_browser_for_slot` / `zapp_cef_slot_ok` / `zapp_cef_browsers[]` / `zapp_cef_broadcast_eval` / `zapp_cef_close_browser_for_slot` / `zapp_cef_browsers_clear_slot` / `zapp_open_url_in_system_browser` are each defined once and referenced consistently. `slot` field name matches on both structs and all call sites. `ZAPP_MAX_WINDOW_CALLBACKS` = 64 everywhere.
