# CEF macOS spike — FINDINGS

Running log of load-bearing findings from the `webEngine:"chromium"` (CEF) macOS
de-risking spike. Newest task last. **Consolidated verdict + cost/benefit +
production seeds are in the capstone directly below; per-task detail follows.**

---

## ★ VERDICT: GO — CEF is a viable opt-in macOS render backend for Zapp

Every load-bearing seam is proven on macOS (arm64), human-smoked on screen. The
one negative finding (native brotli decode for the custom scheme) has a
demonstrated workaround. Zapp's edge — ZJS workers — runs native, entirely
outside CEF's multi-process tree, and is shown coexisting with CEF. Recommendation:
**GO to a production `webEngine:"chromium"` cycle (macOS-first, Linux-forward).**

### Go/No-Go table (design criteria 0–6)

| # | Criterion | Result | Evidence |
|---|---|---|---|
| 0 | Links + launches from the Nim/ObjC build | **PASS** | `nm` binds `cef_initialize`/`create_browser`/`do_message_loop_work`/`shutdown` to the framework; window launches (GATE 0 on-screen) |
| 1 | Message-loop coexistence (CEF + NSApp + native worker) | **PASS** | external pump (`external_message_pump=1` + `[NSApp run]`); GATE 1 on-screen: window interactive **and** worker ticks, neither starves |
| 2 | Hosts in a standard Zapp `NSWindow` | **PASS** | renders + resizes in a titled/traffic-light NSWindow (GATE 2, confirmed once the T4 crash was fixed) |
| 3 | Custom `zapp://` scheme + brotli | **PASS w/ caveat** | scheme serves assets byte-accurately; **native `br` decode does NOT apply to custom-scheme responses** (Chromium's decode lives in the network service, bypassed by in-process handlers) → **handler-side decode demonstrated** (`78fb514`): size win kept, one-time CPU cost |
| 4 | `zapp` bridge JS↔native round-trip | **PASS** | `window.zapp.invoke("greet")` → process-message round-trip → `Hello from Zapp! (to World)` on screen (GATE 4) |
| 5 | Real ZJS worker coexists | **PASS** | real `libzjs` worker, 1 Hz ticks pushed to the page, coexisting with CEF (GATE 5) |
| 6 | Cost/benefit data | **captured** | see below |

### Cost / benefit (criterion 6)

| Dimension | Value |
|---|---|
| `.app` size | **291 MB** (the `Chromium Embedded Framework.framework` = **289 MB** of it). A WKWebView Zapp app is a few MB (OS provides WebKit) → **~+289 MB is the opt-in price** |
| Dev toolchain | CEF "minimal" distribution ≈ 311 MB extracted (≈110 MB compressed), gitignored, fetched by `fetch-cef.sh` |
| Build | `nim c` + clang(.c/.m) + framework/Helper-bundle assembly; seconds-scale; not wired into `zapp build` |
| Cold launch | multi-process (browser + 5 Helpers) spin-up; qualitatively fine in smoke; **not** benchmarked vs WKWebView (a production measurement item) |
| Licensing | CEF = BSD-3-Clause; bundled Chromium = BSD-style + third-party (LGPL/MPL) components, standard for Chromium redistribution + attribution — no blocker for opt-in bundling |

### Where the size buys perf/features (the explicit "is it worth it" question)

- **Consistent cross-platform rendering** — the headline; identical Chromium everywhere (esp. future **Linux**, where WebKitGTK is weakest).
- **Brotli** — on-disk *size* win: **YES** (handler-side decode, demonstrated). Free-CPU decode: **NO** for `zapp://` (HTTP only). Net: still a win, not free.
- **Available, not exercised**: DevTools protocol, Chromium GPU/compositor pipeline.

### Production seeds (must-do before a shippable `webEngine:"chromium"`)

1. **CEF C-API ref-ownership rule** — *received* values (callback params; create/get returns) = own → release once; values *passed into* a setter/sender (`set_value_bykey`, `send_process_message`) = **consumed → do NOT release**. A double-free here caused the blank-screen (and slipped past a confident review). The **`scheme_handler.c` resource-handler params (`request`/`callback`/`response`, all `refptr_diff`) currently LEAK** (own-but-not-released) — fix in production.
2. **No `CefMessageRouter` in the C API** → the id↔promise protocol is hand-rolled; use a **shared header** for the message-name constants (spike `#define`s them in two TUs).
3. **Brotli** — statically link Zapp's own decoder (spike used Homebrew `libbrotlidec`); handler-side decode is the custom-scheme path.
4. **OSCrypt "Safe Storage"** — real encrypted-storage policy (spike uses `--use-mock-keychain`).
5. **CEF runtime library loader** for the macOS **sandbox** (spike links the framework directly via `@rpath` — fine unsandboxed/dev).
6. **Bootstrap injection** — codegen from `bootstrap/*.ts` (the Helper runs no Nim; spike embeds the bootstrap in a C string).
7. **Helper-process signing + notarization** for distribution.
8. **External pump is sound** on macOS 26 / CEF 144 — the blank scare was a bridge double-free, **not** the pump; `external_message_pump=1` + `[NSApp run]` fits Zapp's Nim/ObjC-owns-the-loop model.

### Human-verified gates
GATE 0/1/2/4/5 = PASS on screen. GATE 3 = negative finding (native custom-scheme `br` decode) + demonstrated handler-side-decode fix. Whole-branch review = **READY-TO-BANK** (bridge refcount fix verified against SDK `cpptoc` source; T5 thread-sound).

### ★ Production slice update (`feat/cef-webengine-prod`, 2026-07-06) — which seeds THIS SLICE closed

The production slice (design:
`docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-design.md`;
promotes this spike's sources into `native/platform/darwin/cef/zapp_cef_*`,
gated behind `-DZAPP_HAS_CEF`) revisits the eight production seeds above.
Five are **CLOSED**; four items remain **OPEN** (one seed above turned out
to fold into two still-open items below).

**CLOSED this slice:**

1. **Real embedded-asset pipeline (seed 3, partially seed 6's asset half).**
   `zapp_cef_scheme_handler.c` now serves the app's *real*
   `zapp_embedded_assets[]` table on `zapp://` — the same weak-linked table
   `webview.m`'s asset path reads, decoded with the same
   `is_brotli && uncompressed_len>0` rule. Brotli decode uses **Apple's own
   `libcompression`** (`compression_decode_buffer`, `COMPRESSION_BROTLI`) —
   **Homebrew `libbrotlidec` is gone**, closing the brotli half of seed 3
   for real (statically-linked, ships in the OS, no dev-machine dependency).
2. **Real bridge → real Nim router.** The spike's bespoke `greet`-stub
   protocol (`zapp:invoke[id,name,argsJSON]` → hand-run stub →
   `zapp:result[id,resultJSON]` → `__zappResolve`) is **deleted**. The CEF
   browser process now calls the exact same
   `zapp_handle_message_from_window(app, envelope, window_id)` entry point
   `webview.m`'s WKWebView handler calls, with the real
   `{t,id,m,a}` envelope `bootstrap/webview.ts` produces — not a
   parser/stub. Results flow back via the real `darwin_window_eval_js`
   (a `#ifdef ZAPP_HAS_CEF` branch calls `execute_java_script` instead of
   `evaluateJavaScript:`); `Events.emit` broadcasts reach the CEF page too.
   The doc-start bootstrap the render process evals is now the **real
   compiled bootstrap** (`zapp_webview_bootstrap_script()` + the real
   `Symbol.for('zapp.*')` carriers), not a hand-written C-string stand-in —
   this also closes the asset/codegen half of **seed 6** (bootstrap
   injection): the browser process links Nim and calls the real codegen'd
   function; only the Helper (which runs no Nim) still can't build it
   itself, so the browser ships it across via CEF's `extra_info` at
   browser-create time.
3. **Loop integration into Zapp's REAL `NSApplication` loop, not a
   spike-owned one.** The spike's `cefspike_run_main_loop` (its own
   `[NSApp run]`) is gone from the production path. `darwin_platform_init()`
   installs the `ZappCefApplication` pump subclass *before* Zapp's own
   `[NSApplication sharedApplication]` call, and CEF's external pump
   (`on_schedule_message_pump_work` → `cef_do_message_loop_work()`) rides
   whichever run loop is already spinning — Zapp's existing
   `darwin_platform_run()` → `[NSApp run]`. Proven both statically (exactly
   one `[NSApp run]` call site; `zapp_cef_run_main_loop` defined but never
   called — see the Minors below) and dynamically (a real built `.app`
   renders + serves assets + fires the bridge, all of which requires the
   pump to be getting serviced by Zapp's loop).
4. **Scheme-handler `refptr_diff` leak (seed 1) — fixed, and extended.**
   The spike's known leak (`request`/`callback`/`response` never released)
   is fixed. Production **also** extends correct-release discipline to
   every resource-handler entry point touched (`open` /
   `get_response_headers` / `skip` / `read`) **and** the factory's
   `create()` (`browser`/`frame`/`request` released once each); the
   factory-returned handler itself is `refptr_same` (consumed by the
   caller, correctly *not* released a second time).
5. **`system` build stays byte-identical (the gate guarantee itself).**
   Not one of the original 8 seeds, but the load-bearing promise the whole
   slice depends on — re-verified in the T5 (docs/smoke) task independently
   of Tasks 2-4: a clean `webEngine:"system"` build of `examples/cef-hello`
   hashes identically to a pre-CEF-version-pin build
   (`sha256 588494f859df1097160d18f371c1d35f4ac45d39e83a790594a20c0b78f93312` — **SUPERSEDED by sub-cycle A: the worker fixture changed source, so a fresh build's hash differs**),
   and `unifdef -UZAPP_HAS_CEF` over `window.m` / `platform.m` / `webview.m`
   shows the CEF-gated lines are the only delta.

**Still OPEN (unchanged from the spike's list, tracked for a future cycle):**

- **macOS sandbox runtime-library loader (seed 5).** Still links the
  framework directly via `@rpath`; fine unsandboxed/dev, not sandboxed
  App Store-shaped distribution.
- **Real OSCrypt "Safe Storage" / keychain policy (seed 4).** Still no
  production policy decision; `--use-mock-keychain` remains a dev-run
  convenience, now inherited by the promoted `zapp_cef_app.c`.
- **Helper-process signing + notarization (seed 7).** Unchanged — the five
  bundled Helper `.app`s (`bundleCefApp` in `cli/src/cef.ts`) are unsigned.

Also unchanged / not attempted this slice: DevTools, multi-window CEF,
native chrome (sidebar/inspector/toolbar) on the `chromium` path, iOS /
Windows / Linux, per-window engine selection, navigation/back-forward — all
explicit non-goals of the design, not regressions.

Non-blocking Minors accumulated across this slice's tasks (recorded for the
eventual whole-branch review): **CEF elision for `setDragRegion`** (currently
round-trips through the router at ~60 Hz as a no-op on the fullbleed CEF
path) is the one still open here — see the ★ sub-cycle A update below for
what closed (`app_get_active()` NULL-guard parity, the now-dead
`zapp_cef_run_main_loop`, and `zapp_cef_host.m` OOM NULL-hardening all
cleared).

### ★ Sub-cycle A update (CEF worker hardening, `feat/cef-worker-hardening`, 2026-07-06)

Design: `docs/superpowers/specs/2026-07-06-cef-worker-hardening-design.md`.
Two deliverables: close the worker-on-CEF gap this doc's "Still OPEN" list
above tracked, and clear 5 of the Minors accumulated across the prod slice
(above) + this sub-cycle's own spec.

**Worker on CEF — CLOSED (human visual gate PASSED 2026-07-06).**
The spec's original premise (a missing broadcast→CEF branch in
`darwin_webview_eval_all`, `webview.m`) turned out to be **stale** — that
branch was already shipped, same-day, in `6f58489`, one layer down inside
`zapp_registered_webviews_eval` (`native/platform/darwin/window.m:154-164`).
Confirmed by reading the shipped source and tracing the delegation chain;
no code change was needed or made in `webview.m`/`window.m` this cycle (see
the design doc's corrected Context + §1 for the full trace — and why a
second branch there would have *double-delivered* every broadcast). The
actual deliverable is `examples/cef-hello`'s new fixture (`b4d30cc`): a real
headless **ZJS** `ticker` worker (`src/ticker.ts`) broadcasting
`Events.emit("tick", { n })` once a second, with no point-to-point send,
subscribed to by the page (`Events.on("tick", …)` → `#tick`). This is the
render-engine-independent worker edge CEF's whole design point rests on,
now backed by a real fixture instead of the spike's T5 argument-by-analogy.
The human visual R0 gate (does `#tick` actually increment on screen) **PASSED
2026-07-06** — GATE 5 in `examples/cef-hello/SMOKE.md` is now PASS (`#tick`
increments live on the Chromium page; sub-cycle B later confirmed it fans out
to *both* windows — see the sub-cycle B update below).

**5 Minors cleared** (`native/platform/darwin/cef/`, 3 commits):

1. **Dead `zapp_cef_run_main_loop` removed** — `20b0faf`. Deleted from
   `zapp_cef_mac_entry.m` + its `.h` declaration + comment refs; was defined
   but never called since the prod slice integrated CEF's pump into Zapp's
   own `[NSApp run]`.
2. **`app_get_active()` NULL-guard parity in the CEF client** — `eb477bc`.
   `zapp_cef_client.c`'s `zapp:invoke` handler now guards the same way
   `webview.m:403-406` does before calling
   `zapp_handle_message_from_window`.
3. **`zapp_cef_host.m` OOM NULL-hardening** — `eb477bc`. The `extra_info`
   population block (bootstrap-JS UTF-16 conversion + `set_string`) is now
   guarded on `bootstrap_js != NULL && extra_info != NULL`; the
   `cef_browser_host_create_browser` call below is unchanged (still
   receives `extra_info`, possibly NULL on OOM, which CEF accepts).
4. **`ZAPP_MSG_INVOKE` single-defined** — `f7278cb`. Hoisted into
   `zapp_cef.h`; the local `#define`s in `zapp_cef_bridge.c` and
   `zapp_cef_client.c` removed. This is the item the "Still OPEN" list above
   tracked as "the rest of seed 2/6" — now closed.
5. **Brotli decode-fail diagnostic** — `f7278cb`. `zapp_cef_scheme_handler.c`
   now logs a warning when `compression_decode_buffer` fails instead of
   silently serving an empty 200; behavior (the empty-200 response itself)
   is unchanged — diagnostic only.

Verified: each Minor's build produced `[zapp] CEF app bundle:` +
`[zapp] build complete:` with no `Undefined symbols` / `implicit
declaration` / `error:` in the log; a headless bounded run after Minor 5
showed clean asset-serving with no spurious decode-failure warning (see
`.superpowers/sdd/task-2-report.md` for full logs).

**Still open, deferred to their own cycles (unchanged by this sub-cycle) —
the 5 coupled Minors from the design's non-goals:** `on_before_close`'s
`[NSApp stop]` quit-guard (**sub-cycle B — CLEARED, see below**);
per-request brotli decode cache (a perf pass, not correctness);
`setDragRegion` CEF elision (fullbleed non-goal, listed above); `.zc`-legacy
`chromium` config value silently falling back to WKWebView (a
config-validation gap, not a runtime bug); `g_active_browser` cross-thread
read (benign, matches the existing single-window pattern — see Task 5's
life-span-handler retain/release above).

### ★ Sub-cycle B update (CEF multi-window, `feat/cef-multi-window`, 2026-07-06)

Design: `docs/superpowers/specs/2026-07-06-cef-multi-window-design.md`.
Builds the real per-window lifecycle a second `window.create` on
`webEngine:"chromium"` needs: a slot↔browser registry, targeted + broadcast
delivery, popup parity, and a per-window close handshake.

**Multi-window (macOS) — CLOSED.** All human R0 gates PASSED on-screen
2026-07-06 (six GATE rows, `examples/cef-hello/SMOKE.md`). What shipped:

1. **Slot↔browser registry** (T1, `7d204ad`) — `zapp_cef_browsers[]`
   replaces the single-window globals `g_active_browser` /
   `g_zapp_cef_window_slot`; each client/handler is now per-window
   (`zapp_cef_client_create(slot)`, slot baked into the client struct).
   Targeted native→JS eval routes by slot (`zapp_cef_eval_in_window`); a
   worker/notification broadcast fans to **every live CEF window**
   (`zapp_cef_broadcast_eval`, wired into `zapp_registered_webviews_eval`'s
   existing `ZAPP_HAS_CEF` branch — no new branch needed, just table
   iteration instead of a single global). Bridge messages tag
   `window_id` from `client->slot`, so an invoke from window 2 resolves back
   to window 2.
2. **Per-window close handshake** (T2, `9d6778e`..`b74651e`/`0bdaa94`) —
   close-guard parity (a JS-vetoed close leaves the browser fully intact,
   same as WKWebView); last-window quit now runs through Zapp's existing
   `terminateAfterLastWindowClosed` path, **not** `on_before_close` →
   `zapp_cef_quit_main_loop()` — the coupled Minor sub-cycle A deferred here
   is now **CLEARED**. See the root-cause finding below for how this landed
   (it took three attempts).
3. **`on_before_popup` → system browser** (T3, `1e75725`) — WKWebView
   parity (`createWebViewWithConfiguration`, webview.m:668-677):
   `window.open`/`target=_blank` cancels the CEF popup and opens the target
   URL via the existing `darwin_open_external` helper, instead of letting
   CEF spawn a chrome-less in-app popup window.

**Durable note for C/D — the close-lifecycle ordering (Task 2's Step-1
spike):** `darwin_window_destroy` has **no reachable caller anywhere in the
current app/router lifecycle**, for either render engine. Traced every call
site: its only trampoline (`WindowManager.close`, `window.zc`) is itself
never called from `router.zc`/`app.zc`/the Nim layer. Both a red-button
close and the JS `Window.close()` action route through plain
`[NSWindow close]` (`windowShouldClose:` → `windowWillClose:`) — the
*reversible*-close path — never through `darwin_window_destroy`. Any future
CEF-window teardown work (sub-cycles C/D, or a redesign of `Window.close()`)
must hook `windowShouldClose:`/`windowWillClose:`, not
`darwin_window_destroy` — treating the latter as the close path (as this
sub-cycle's own design brief initially assumed) produces a leak, because
that function never runs on an ordinary close.

**KEY ROOT-CAUSE FINDING (record prominently — durable for sub-cycles C/D
and any future CEF-window teardown work):** `on_before_close` does **not**
fire on an interactive close of a `SetAsChild` `CEF_RUNTIME_STYLE_ALLOY`
browser hosted in a Zapp `NSWindow`. Because that window is
`setReleasedWhenClosed:NO`, `[window close]` only **hides** it — the
browser's `NSView` stays alive in the now-hidden view hierarchy, so CEF
never finishes destroying the browser, and `on_before_close` is deferred all
the way to `cef_shutdown` (a per-close browser-ref + `zapp_cef_browsers[]`
slot leak). **Fix:** after `CloseBrowser(false)`, do a **delayed
(main-thread) `removeFromSuperview`** of the browser's `NSView` (captured
via `get_window_handle` before closing) — removing the view from the hidden
hierarchy is what lets CEF finish tearing the browser down, so
`on_before_close` finally fires and deregisters the slot / releases the ref.
This is the pattern **Electrobun** uses (blackboardsh/electrobun
`nativeWrapper.mm`, `CEFWebViewImpl remove`) — credited, not
independently discovered. Two earlier approaches were tried and abandoned
first: a re-entrancy fix to the original close-in-`windowWillClose:`
handshake (`9d6778e`/`fd527c2`), then a `windowShouldClose:`-level DEFER
pattern (a per-slot "closing" flag that deferred the `NSWindow` close until
`on_before_close` ran) which **deadlocked** on a refinement pass
(`9d8df4f`, reverted by `67b7520`). The Electrobun `removeFromSuperview`
approach (`b74651e`, comments clarified in `0bdaa94`) abandons defer
machinery entirely and was the one that actually worked, confirmed by
`browser closed (slot N)` finally appearing in the log for an interactive,
non-last-window close.

**KNOWN LIMITATION (documented, not hidden):** the teardown that makes the
leak fix work also makes a CEF window's close **TERMINAL**. `Window.close()`
(normally reversible) followed by `Window.show()` on the same window id
reshows a **BLANK** window — the browser was destroyed by the teardown and
is not recreated — whereas the same sequence on a WKWebView window reshows
it intact. Reversible reshow of a CEF window is a documented sub-cycle B
**non-goal** (recorded in-code too: `native/platform/darwin/window.m`'s
`windowWillClose:` CEF branch, `0bdaa94`). Follow-up candidate for a later
cycle: make the `show` action CEF-aware — either a clean no-op/diagnostic
when the window's browser is already gone, or actually recreate the
browser — rather than silently reshowing a dead window.

**BACKLOG Minor:** `darwin_window_destroy`'s CEF safety-net branch
(`zapp_cef_teardown_browser_for_slot`, idempotent) is currently
**unreachable** — no live caller routes through `window_destroy` today (see
the durable ordering note above). Kept for forward-compat / parity with the
WKWebView teardown branch beside it; harmless dead code, not a regression.

Also unchanged / not attempted this sub-cycle: DevTools, native chrome
(sidebar/inspector/toolbar) on the `chromium` path, iOS/Windows/Linux,
per-window engine selection, navigation/back-forward, in-app popups (§ the
`on_before_popup` design note above), mixed-engine per-window — all explicit
non-goals, tracked for sub-cycles C/D/E.

### ★ Sub-cycle C1 update (CEF sidebar, `feat/cef-native-chrome`, 2026-07-06)

Design: `docs/superpowers/specs/2026-07-06-cef-sidebar-design.md`. First
native-chrome element on the `chromium` path — the **north star**: sidebar
proves the pattern that gets full `kitchen-sink` running on CEF; **C2 =
inspector** (mirrors sidebar), **C3 = toolbar**.

**Sidebar on CEF (macOS) — CLOSED.** All human gates PASSED on-screen
2026-07-06 (`examples/cef-hello/SMOKE.md`). What shipped:

1. **CEF browsers hosted in the split-pane containers** (T1, `f4756b4`) —
   the `NSSplitViewController` pane-mounting in `window.m` grows a
   `ZAPP_HAS_CEF` branch (the WKWebView path is the unchanged `#else`) that
   calls sub-cycle B's `zapp_cef_create_browser_in_view` once per container
   — `mainContainer` (host, `pane_role=0`) and, when `useSidebar`,
   `sidebarContainer` (`pane_role=1`) — instead of once for the whole
   window. Both panes carry the **host** js identity (`win-%d` string,
   `hostWindowId`); each registers its own slot (`zapp_window_ids[host_slot]`
   / `zapp_window_ids[sidebar_slot]`) so `Workers.create()` and JS identity
   resolve correctly from either pane.
2. **The split builder, the sidebar event registry
   (`zapp_sidebar_register`), and collapse/expand/resize event delivery
   (`darwin_window_eval_js`'s `ZAPP_HAS_CEF` branch, `zapp_cef_eval_in_window`)
   are engine-agnostic — reused UNCHANGED.** This is the big DRY win: the
   native-chrome machinery (split view, registries, event fan-out) never
   needed CEF-specific code; only the pane *content* (webview vs. browser)
   branches by engine.
3. **Per-pane teardown** (T3, `b60c28f`) — `windowWillClose:`'s existing
   `ZAPP_HAS_CEF` safety net (sub-cycle B, host-only) now also tears down the
   sidebar pane's slot (and the inspector slot, forward-compat for C2) via
   B's `zapp_cef_teardown_browser_for_slot`, each call independently
   bounds-checked and a no-op when the slot has no live browser. `on_before_close`
   fires for both host + sidebar, no leak.

**Two fixes surfaced by the imperative-toggle gate** (T2, `0394121` +
`919b113`) — worth recording because they generalize to any future
imperative op on a CEF pane (C2 inspector, panel, screen):

1. **Engine-agnostic window resolver** (`0394121`) —
   `darwin_window_get_by_numeric_id` was WK-table-only
   (`zapp_webviews[id].window`), so it returned `NULL` for any CEF slot —
   every imperative op that routes through it (sidebar toggle/collapse/
   setWidth, inspector, panel, screen) silently no-op'd on `webEngine:
   "chromium"`. Fixed with a gated CEF fallback: a new
   `zapp_cef_window_for_slot(slot)` (`zapp_cef_host.m`) resolves the host
   `NSWindow` from the CEF browser's `NSView` (`get_window_handle` →
   `[view window]`), called only when the WK lookup misses and only inside
   `#ifdef ZAPP_HAS_CEF` (a `system` build is untouched).
2. **Shared bootstrap-carrier builder** (`919b113`, DRY refactor) — the CEF
   bootstrap (`zapp_cef_build_bootstrap_js`) never injected the
   `zapp.hasSidebar`/`zapp.isSidebar` (etc.) Symbol carriers WK's document-start
   script does, so `Window.current().sidebar` was `undefined` inside a CEF
   pane and JS-side sidebar control silently no-op'd. Root fix: extracted
   WK's carrier-building code (verbatim — same `bootstrapConfig` fields/
   order/format, same `zapp_escape_js_string` escaping) into one shared
   `zapp_build_bootstrap_carriers()` (`webview.m`, always compiled), and
   routed **both** WK and CEF through it — `zapp_cef_create_browser_in_view`
   now threads `pane_role`/`host_has_sidebar`/`host_has_inspector` into it.
   This eliminated a two-list duplication (WK's carrier list and CEF's,
   drifting independently — the actual source of the bug) and is a **net
   architectural simplification**, not just a bugfix: WK's carrier output was
   verified byte-identical (reviewed), and CEF gains the carriers for free.

**Known limitations / follow-ups (documented, not hidden):**

- **CEF panes are opaque** — no vibrancy. A non-OSR (Alloy) CEF browser
  paints its own background; vibrancy-on-CEF would require off-screen
  rendering (OSR), an explicit non-goal for this cycle.
- **Window-id format inconsistency** — the fullbleed CEF path formats its
  window-id string as `win-%p` (pointer) while the sidebar host/sidebar
  panes use `win-%d` (slot index, `hostWindowId`). Both round-trip
  correctly today (each path is internally consistent); cosmetic, tracked
  for a later cleanup pass rather than fixed here.
- **WK carrier append lacks the CEF path's OOM NULL-check** — cosmetic
  robustness gap in the extracted shared builder's WK call site, not a
  behavioral bug (WK's append already assumed non-NULL before the
  extraction; the CEF call site added the check because CEF's is a fresh
  call site). Noted for a future hardening pass.
- **Sub-cycle B's terminal-close limitation applies per-pane** — closing a
  sidebar-window's host pane tears down (and does not recreate) both CEF
  browsers, same as the fullbleed single-browser case documented in the
  sub-cycle B update above.

Also unchanged / not attempted this sub-cycle: inspector-on-CEF (C2),
toolbar-on-CEF (C3), DevTools, iOS/Windows/Linux, per-window engine
selection, navigation/back-forward — all explicit non-goals, tracked for
sub-cycles C2/C3+.

### ★ Sub-cycle C2 update (CEF inspector, `feat/cef-inspector`, 2026-07-07)

Design: `docs/superpowers/specs/2026-07-07-cef-inspector-design.md`. Second
native-chrome element on the `chromium` path — a direct mirror of C1's
sidebar arm. **C1 sidebar → C2 inspector → C3 toolbar** is the north star
sequence toward running full `kitchen-sink` on chromium; **C3 = toolbar** is
next.

**Inspector on CEF (macOS) — CLOSED.** All human gates PASSED on-screen
2026-07-07 (`examples/cef-hello/SMOKE.md`). What shipped:

1. **A single inspector arm in `window.m`'s CEF pane-mount branch** (T1,
   `b195abb`) — a direct mirror of C1's sidebar arm, added right after it:
   `zapp_cef_create_browser_in_view(inspectorContainer, insCefUrl,
   inspector_slot, hostWindowId, paneOwnerId, 3 /* pane_role */, useSidebar,
   useInspector)`, plus a bounds-checked `zapp_window_ids[inspector_slot] =
   hostWindowId` mirroring the WK path's `zapp_register_webview` identity
   registration. `pane_role=3` matches the WK `#else` inspector arm and the
   shared carrier builder's `isInspector` case, so `zapp.isInspector` /
   `zapp.hasInspector` resolve inside the pane exactly as they do on
   WKWebView. The WK `#else` inspector path is byte-unchanged.
2. **Everything else inherited from C1, untouched — the reason this cycle
   was ~17 lines of new code.** C1 already generalized every piece an
   inspector pane needs: the engine-agnostic window resolver
   (`zapp_cef_window_for_slot`, so imperative inspector control resolves on
   CEF), the shared bootstrap-carrier builder (`zapp_build_bootstrap_
   carriers`, already emits `zapp.hasInspector`/`zapp.isInspector` by
   `pane_role`/composition flags for both engines), per-pane teardown
   (`windowWillClose:`'s CEF safety net already tore down
   `inspectorNumericId`, forward-compat since C1 Task 3, now exercised for
   real), the split builder (`inspectorContainer`, already constructed when
   `useInspector`), and the inspector registry + `inspector.m` events
   (already engine-agnostic, outside the `#ifdef`). None of these needed a
   single change for C2.
3. **Fixture** (`b195abb`) — `examples/cef-hello` window 1 gains an
   `InspectorOptions` (`zapp/app.nim`) alongside its existing sidebar,
   making it a **3-pane CEF window** (sidebar + host + inspector) — the
   fixture that proves sidebar+inspector **coexistence** on Chromium, not
   just sidebar+host. `src/main.ts` grows an `#inspector-pane` route branch
   (own tint, own `which` label) and a host-pane "toggle inspector" button
   beside the existing "toggle sidebar" button, both driven by the same
   `darwin_window_get_by_numeric_id` CEF-fallback resolver C1 shipped.
   Window 2 stays plain (fullbleed regression, unchanged).

**Known limitations / follow-ups (documented, not hidden):**

- **Host-level window-event fan-out (`zapp_dispatch_event_to_js`) is
  WK-only** — a pre-existing, foundational gap since sub-cycle B, **not
  inspector-specific**: it returns early for the host pane and every
  accessory on ALL CEF windows (sidebar, inspector, plain). Deferred to a
  dedicated foundational follow-up **after C2** (user-agreed 2026-07-07).
  The inspector's OWN collapse/resize events (`inspector.m`) DO reach the
  CEF inspector pane via `darwin_window_eval_js`'s `ZAPP_HAS_CEF` branch —
  only the host→pane window-event fan-out (resize/focus/blur/move/maximize)
  is gapped.
- **CEF inspector panes are opaque** — same as C1's sidebar finding; a
  non-OSR (Alloy) CEF browser paints its own background, so the WK
  inspector's vibrancy/material won't show through. Vibrancy-on-CEF remains
  OSR territory, an explicit non-goal.
- **C3 = toolbar** is next in the native-chrome sequence.
- **Sub-cycle B's terminal-close limitation applies per-pane** — closing
  the 3-pane window tears down (and does not recreate) all three CEF
  browsers, same as the sidebar-only and fullbleed single-browser cases
  documented in the sub-cycle B/C1 updates above.

Also unchanged / not attempted this sub-cycle: toolbar-on-CEF (C3),
DevTools, iOS/Windows/Linux, per-window engine selection, navigation/
back-forward — all explicit non-goals, tracked for sub-cycle C3+.

### ★ Sub-cycle C3 update (CEF toolbar, `feat/cef-toolbar`, 2026-07-07/08)

Third and final native-chrome element on the `chromium` path — completes the
**C1 sidebar → C2 inspector → C3 toolbar** north-star sequence toward running
full `kitchen-sink` on chromium. Fixture: `examples/cef-hello` window 1 gains
a toolbar (spike `1c83c9c`) on top of its existing 3-pane (sidebar + host +
inspector) layout from C1/C2.

**Toolbar on CEF (macOS) — CLOSED.** All human gates PASSED on-screen
2026-07-07/08 (`examples/cef-hello/SMOKE.md`). Commits: spike `1c83c9c`; T1
`f2a7ad3` + `7975b3e`; T2 `c20180e` + `f14137c` + `af2dbc4` + `6353234`.

**Inherited unchanged (works on CEF, spike-confirmed, zero code changes
needed):** the toolbar is native chrome and mostly engine-agnostic —
`darwin_toolbar_attach` (top-level `NSToolbar` construction, engine-agnostic),
toolbar clicks → JS (`zapp_toolbar_emit_click`, which already routes through
the CEF-aware `darwin_webview_eval_all` — **not** the WK-only
`zapp_dispatch_event_to_js` — so C3 did **not** need the host-event fan-out
fix C2 deferred), and `toggleSidebar`/`toggleInspector` (the native split-VC
toggle + `darwin_inspector_toggle` resolver, already CEF-aware since C1/C2).

**Three things C3 actually had to fix, all native, none WK-touching:**

1. **(A) CEF panes render a dark band under the toolbar.** Root cause
   (evidence-backed, Task 1's Phase-1 instrumentation logged the browser
   NSView's frame vs. its superview's bounds before/after): CEF's own
   autoresizing mask (`NSViewWidthSizable|NSViewHeightSizable`) was already
   correct on every pane, and the pane containers were already at their
   correct POST-toolbar-attach size — the mask/container-sizing hypotheses
   were both refuted. The actual defect: `cef_browser_host_create_browser`
   is asynchronous, so CEF bakes the browser NSView's initial frame from
   `parent.bounds` captured at the earlier synchronous *request* time — but
   the toolbar attaches (growing the container) one tick later, before the
   view is inserted into the (now taller) hierarchy, so the view lands at
   the stale pre-toolbar height with no live resize event afterward for the
   already-correct mask to react to → a permanent dark band, identical on
   host/sidebar/inspector. Fix (`f2a7ad3`): new
   `zapp_cef_snap_view_to_superview_for_slot(slot)`
   (`native/platform/darwin/cef/zapp_cef_host.m`) snaps `view.frame =
   view.superview.bounds` once, at the earliest point the view exists —
   called from `on_after_created` (`zapp_cef_client.c`) — robust to ordering
   regardless of whether the race lands before or after that callback.
2. **(B) `NSTrackingSeparatorToolbarItem` doesn't track the sidebar divider —
   NOT a CEF bug.** Task 1's second diagnosis pass (instrumenting
   `toolbar.m`'s separator-resolution code) found the split view, its items,
   and the divider index were all correct and stable across the A fix —
   the defect was window chrome, not geometry. The `examples/cef-hello`
   spike fixture omitted `titleBarStyle`, so it resolved to a standard
   (non-unified) titlebar; `NSTrackingSeparatorToolbarItem` can only anchor
   to the split divider under the **unified/hidden-inset** chrome the
   toolbar overlays — in a standard titlebar there's no such continuity, so
   it can't align. Proven engine-agnostic by code path, not just
   empirically: the split construction, `titleBarStyle` handling, and the
   separator's resolution code (`toolbar.m`) are all 100% AppKit, entirely
   outside any `#ifdef ZAPP_HAS_CEF` block — a `webEngine:"system"` build of
   the identical fixture would mis-track the separator exactly the same
   way. Fix (`7975b3e`, fixture-only, matches kitchen-sink): window 1 opts
   into `titleBarStyle: TitleBarStyle.HiddenInset`. No framework/native code
   touched; WK path byte-identical.
3. **(C) chrome-metrics (`--zapp-toolbar-height` etc.) never reached CEF
   panes — native fix, three layers.** `zapp_toolbar_inject_metrics`
   (`toolbar.m`) only knew how to inject into a `WKWebView`
   (`addUserScript:`/`evaluateJavaScript:`) and silently skipped every CEF
   slot. Three fixes, in order of discovery:
   1. **Route (`c20180e`).** Each CEF slot (`if (wv)` falls through to a new
      `#ifdef ZAPP_HAS_CEF` `else`) now routes through the CEF-aware
      `darwin_window_eval_js(slot, js)` instead of being dropped.
   2. **Initial-load race (`af2dbc4`).** R0 showed only the HOST pane got
      the CSS vars on initial load; sidebar/inspector stayed empty until a
      later toolbar mode-change. Root cause: the initial inject (one runloop
      tick after pane-create *requests*, in `window.m`) races the same async
      `cef_browser_host_create_browser` A dealt with — only the host
      browser happens to be registered by that tick, so the sidebar/
      inspector evals silently no-op against a not-yet-existent browser. Fix:
      new `zapp_toolbar_reinject_for_slot(slot)`, called from
      `on_after_created` right after A's frame-snap, so each pane re-fires
      the moment its own browser is ready — not tied to toolbar-attach
      timing specifically.
   3. **No-op guard swallowed the re-inject (`6353234`).** R0 showed the
      re-inject alone still didn't work: `zapp_toolbar_inject_metrics` has
      an unchanged-metrics no-op guard that short-circuits whenever
      `add_user_script=false` and the computed metrics match the window's
      last-cached values — and the re-inject computed the *same* metrics the
      initial host-only inject already cached, so it always hit the guard
      and returned before reaching the per-slot eval. Fix: the re-inject
      call passes `add_user_script=true` to bypass the guard — safe because
      every `addUserScript:` call site is nested inside `if (wv)`/`if
      (hostWv)`, both nil on every CEF slot, so this never actually adds a
      `WKUserScript`; it only skips the cache check on the CEF path.
   The fixture (`f14137c`) pads its content by `--zapp-titlebar-height` to
   demonstrate the metric is live.

**KNOWN LIMITATION (documented, not hidden):** a **manual page reload** on a
CEF pane does not re-fire the chrome-metrics inject — `zapp_cef_client.c`
wires no `cef_load_handler_t`/load-end hook to re-inject from (grepped
clean: no `on_load_end`/`OnLoadEnd` anywhere in the CEF integration). The
metrics only refresh on the next KVO-driven layout change (toolbar
display-mode switch, a resize crossing a chrome-height boundary). This is
distinct from, and not fixed by, the initial-load race fix above — it is a
missing hook, deferred to a future cycle rather than built speculatively per
the task brief's constraint.

Also unchanged / not attempted this sub-cycle: host-level window-event
fan-out (`zapp_dispatch_event_to_js`, WK-only) — the foundational gap C2
deferred remains open, but C3 didn't need it (toolbar clicks use the
already-CEF-aware `zapp_toolbar_emit_click` path, not this one); CEF panes
remain opaque (no vibrancy — an OSR non-goal, same as C1/C2); DevTools
(sub-cycle D); iOS/Windows/Linux, per-window engine selection,
navigation/back-forward — all explicit non-goals.

**North star reached:** with sidebar (C1), inspector (C2), and toolbar (C3)
all closed on the `chromium` path, every native-chrome primitive
`kitchen-sink` exercises now has a working CEF arm — clearing the toolbar
blocker toward running the full `kitchen-sink` app on Chromium.

### ★ Host-event fan-out fix (`feat/cef-host-events`, 2026-07-08)

Design: `docs/superpowers/specs/2026-07-08-cef-host-events-design.md`. Not a
new native-chrome element — a foundational fix closing the last CEF
window-event gap, flagged and deferred during C2/C3.

**Host-event fan-out — CLOSED.** All human gates PASSED on-screen
2026-07-08 (`examples/cef-hello/SMOKE.md`, GATEs 30-32). Commit: T1
`dd31439`.

**The gap:** `zapp_dispatch_event_to_js` (`window.m:239`) is the shared
host-window-event dispatcher (resize/move/focus/blur/maximize/restore/
modal-dismissed) — every NSWindow-delegate window event routes through it.
It resolved `webview = zapp_webviews[window_id]` and early-returned when nil
(`!webview || !windowId`), which is correct for WKWebView but wrong for CEF:
a CEF window's browsers live in `zapp_cef_browsers[]`, not `zapp_webviews[]`,
so `webview` is always nil for a CEF window even though
`zapp_window_ids[window_id]` IS set (registered since C1-C3). The
early-return silently dropped EVERY host window event for every CEF window —
sidebar, host, and inspector panes alike. This was distinct from, and did
not affect, the accessory-level events (sidebar/inspector collapse/resize,
`sidebar.m`/`inspector.m`) and toolbar clicks (`zapp_toolbar_emit_click`),
which already routed through the CEF-aware `darwin_webview_eval_all`/
`darwin_window_eval_js` paths and reached CEF fine — only this specific
host→pane fan-out was WK-only.

**The fix (approach B, decided with the human over approach A):** a
byte-identical, gated `#ifdef ZAPP_HAS_CEF` branch inserted **before** the WK
early-return. For a CEF window (`!webview && windowId`) it builds the SAME
event JS the WK path builds a few lines below (~15 lines — the event-name
lookup + the modal / resize-move-maximize-restore / plain `snprintf`
switch, mirrored verbatim with a "keep in sync" comment) and fans it out to
the host pane + sidebar pane (`zapp_sidebar_slot_for`) + inspector pane
(`zapp_inspector_slot_for`) via the CEF-aware `darwin_window_eval_js`, then
`return`s before reaching the WK early-return. The WK path from the
early-return down is **completely unchanged** — the project's mechanical
`unifdef -UZAPP_HAS_CEF → original-bytes` gate guarantee holds. Approach A
(refactor the shared dispatcher to route both engines through
`darwin_window_eval_js`, eliminating the JS-build duplication) was
considered and rejected: it's more DRY, but it touches the *shared*
dispatcher's bytes, trading the byte-identical guarantee for a regression
risk on every future WK change. Approach B's cost — one bounded, ~15-line
JS-build mirror, sitting adjacent to its WK twin with an explicit
"keep in sync" comment — was judged the acceptable price; DRY was the
softer principle here.

**Gates (human-confirmed 2026-07-08):** resizing window 1 (the existing
3-pane sidebar+host+inspector fixture) fans `resize {width,height}` to
**all three** CEF panes; window 2 (plain) gets it in its own host pane;
focus/blur reach the CEF panes the same way, proving the fix isn't
resize-specific; the C1-C3 surfaces (sidebar/inspector toggle, `ticker`
broadcast, `greet` bridge) regress cleanly on both windows; the WK dispatch
path is byte-identical (unchanged below the early-return). See
`examples/cef-hello/SMOKE.md` GATEs 30-32.

**Known (cosmetic) difference, deferred — not a bug:** CEF (Chromium)
reserves a bottom-right scrollbar gutter so a vertical and a horizontal
scrollbar can coexist; WKWebView runs its vertical scrollbar full-height
with no gutter. Purely webview-internal rendering, unrelated to the
fan-out fix; normalizable later from the web side
(`::-webkit-scrollbar` / `scrollbar-gutter` CSS), alongside the
vibrancy-opacity (C1) and manual-reload chrome-metrics (C3) gaps already
deferred.

This closes the item the C2/C3 "Known limitations"/"Also unchanged" notes
above flagged as open (`zapp_dispatch_event_to_js` WK-only) — no other CEF
host-window-event gap is currently tracked.

---

## Task 1 (RISK GATE): message-loop coexistence — CEF + NSApplication + a second (ZJS-shaped) loop

**Verdict: GO (pending human GATE-1 on-screen check).** CEF's external message
pump coexists with `[NSApp run]` and a second concurrent CFRunLoop-on-a-pthread
loop. Neither starves — proven at the process/log level; on-screen interactivity
is the human's smoke.

### Loop-integration MODE landed: EXTERNAL MESSAGE PUMP

`cef_settings_t.external_message_pump = 1`, `multi_threaded_message_loop = 0`.
NSApplication owns the loop (`cefspike_run_main_loop` = `[NSApp run]`); CEF is
advanced by `cef_do_message_loop_work()` calls scheduled cooperatively.

Wiring (C-API port of cefclient's `browser_message_loop_external_pump*`):

- `cef_app.c` — the browser-process handler's `on_schedule_message_pump_work(delay_ms)`
  (called from any thread) forwards to `cefspike_pump_schedule(delay_ms)`.
- `mac_entry.m` — `cefspike_pump_schedule` hops to the main thread
  (`performSelectorOnMainThread:…modes:NSRunLoopCommonModes` — so the pump also
  fires during live-resize / modal tracking loops). `<= 0` pumps immediately;
  `> 0` arms an `NSTimer` (capped at ~33 ms / 30 fps so an idle CEF is still
  serviced). `-doWork` runs `cef_do_message_loop_work()` under a **reentrancy
  guard** (CEF can pump nested run loops that re-enter us) and reschedules
  immediately if CEF asked for more work mid-pump.

The **fallback** (a fixed periodic `cef_do_message_loop_work` timer) was **NOT
needed** — the external pump worked on the first build. It remains the documented
plan-B if the pump ever misbehaves.

### Second concurrent loop: STAND-IN (real ZJS worker deferred to T5)

A detached **pthread running its own `CFRunLoop`** with a repeating 1 s timer
logging `[worker] tick N` (`cefspike_start_worker_stub` in `mac_entry.m`). This
is the **same loop shape** a real ZJS worker uses on Apple —
`native/worker/engines/zjs.c` runs each worker on a dedicated pthread whose main
loop ticks `CFRunLoopRunInMode` (alongside a kqueue) to drain NSURLSession
completions; here a `CFRunLoopTimer` stands in for the JS `setInterval` tick.

**Why stand-in, not the real worker:** pulling `libzjs` into this standalone
`nim c` spike is disproportionate for a risk gate. The real worker path is not
just the `.a` — it is `zjs.c` + the worker registry + capability-module
machinery + build-config.ts headless-worker codegen + script-URL resolution
(Vite/bundled assets) + the symbol-hidden `libzjs_embed.a` repack link. The risk
this gate exists to retire is purely *does a second pthread+CFRunLoop starve, or
starve CEF* — the stand-in reproduces that shape faithfully. **T5 still owes the
real ZJS worker** ("ZJS worker coexists — formalize + demo").

### Keychain prompt (production seed)

`cef_app.c on_before_command_line_processing` appends `--use-mock-keychain` for
the browser process, so Chromium's OSCrypt "Safe Storage" keychain prompt
(hit by the human at GATE 0) does not appear on the dev run. **PRODUCTION SEED:**
real `webEngine:"chromium"` needs an actual encrypted-storage policy — the mock
keychain is a dev-run convenience only.

### Evidence gathered (non-visual)

- Build green: `[build] complete:` + fresh binary mtime.
- `nm -mu` on the main binary: `_cef_do_message_loop_work` is now an undefined
  external resolved from the framework; **`_cef_run_message_loop` is gone**
  (T0's CEF-owns-the-loop call removed). `_cef_initialize` / `_cef_shutdown` /
  `_cef_browser_host_create_browser` still bind.
- Time-bounded run (~9 s, self-terminated via `perl alarm`): captured
  `[worker] stand-in loop started` -> `[cef-spike] browser created` ->
  `[worker] tick 1 … tick 7`, steady 1 Hz, **interleaved with CEF's own network
  log lines** — both loops advanced concurrently, no crash, **no keychain
  prompt**. (`root_cache_path` warning + GCM/`PHONE_REGISTRATION_ERROR` lines are
  benign Chromium network-service noise, unrelated to loop coexistence.)

### GATE 1 — remaining human step

Run `open spikes/cef-macos/build/cef-spike.app` (or run the binary directly for
console logs). Confirm the window is **interactive** (drag it, resize it, the
`<h1>CEF</h1>` page is live) **AND** `[worker] tick N` keeps incrementing in the
console — neither starves. If both hold -> GATE 1 PASS.

---

## Task 2: host the CEF browser inside a standard Zapp NSWindow (hosting-fit)

**Verdict: builds + launches clean (pending human GATE-2 on-screen check).**
Formalizes T0/T1's ad hoc placeholder window into a Zapp-shaped `NSWindow`,
proving CEF hosts cleanly in the kind of window Zapp actually creates.

### What changed

- **New `host.m`**: `cefspike_make_host_window(width, height, title)` builds a
  standard Zapp-style `NSWindow` — titled, closable, miniaturizable, resizable
  (all three traffic lights enabled via styleMask, no per-button overrides
  needed), `setReleasedWhenClosed:NO`, `windowBackgroundColor` pre-paint
  (avoids a white flash before CEF's first paint), auto-centered. Mirrors the
  BASICS of `native/platform/darwin/window.m`'s `darwin_window_create` without
  importing that module or its sidebar/inspector/vibrancy/toolbar machinery
  (out of scope for a hosting-fit spike). `cefspike_host_view_for_window(window)`
  returns the window's `contentView` (as `void*`) for use as
  `cef_window_info_t.parent_view`.
- **`mac_entry.m`**: removed the T0/T1 placeholder (`cefspike_create_window` +
  its `g_window` static) now that host.m formalizes it, per the note left in
  T1's `cef_spike.h` comment ("T2 formalizes this into Zapp's NSWindow shape in
  host.m"). Nothing else in mac_entry.m changed — the external-pump/loop
  machinery from T1 is untouched.
- **`cef_spike.h`**: swapped the `cefspike_create_window` declaration for
  `cefspike_make_host_window` / `cefspike_host_view_for_window`.
- **`main.nim`**: compiles `host.m` (`{.compile.}`), calls
  `cefspike_make_host_window` then `cefspike_host_view_for_window` in place of
  the old single call, feeding the result into the SAME
  `cefspike_make_window_info` / `cef_browser_host_create_browser` sequence as
  before.

### Browser-creation mode: already windowed since T0 (no change needed)

The brief's "switch from windowless to windowed" step was already satisfied —
T0 already set `cef_window_info_t.parent_view` + `CEF_RUNTIME_STYLE_ALLOY`
with no `windowless_rendering_enabled`/OSR handler, i.e. a real windowed
browser hosted in an `NSView`, never CEF's own top-level window. T2's actual
job was narrower: formalize *which* `NSWindow` that `NSView` lives in.

### Ordering (load-bearing)

`cefspike_make_host_window` -> `cefspike_host_view_for_window` -> 
`cefspike_make_window_info` (captures `parent_view`) ->
`cef_browser_host_create_browser`. The window/contentView exist before the
browser is created into them — unchanged shape from T0/T1, just relocated.

### Resize mechanism (no CEF-side call needed)

CEF's own Mac windowed-browser implementation gives its browser `NSView` an
`NSViewWidthSizable|NSViewHeightSizable` autoresizing mask so it tracks
`parent_view`'s frame. `host.m`'s content view carries the same mask relative
to the window, so classic springs-and-struts autoresizing chains
window-resize -> content view -> CEF's browser view automatically.

### Evidence gathered (non-visual)

- Build green: `[build] complete:` + fresh binary mtime; `nim check` clean (no
  output/errors).
- `nm` on the final binary: `_cefspike_make_host_window` and
  `_cefspike_host_view_for_window` are defined (`T`) symbols;
  `cefspike_create_window` no longer appears anywhere (removed cleanly, no
  dangling reference). `build/nimcache/@mhost.m.o` confirms host.m compiled.
- Bounded ~8s run (`perl -e 'alarm 8; exec @ARGV' ...`, SIGALRM exit 142):
  `[worker] stand-in loop started` -> `[cef-spike] browser created` ->
  `[worker] tick 1..6`, no crash, no entries in
  `~/Library/Logs/DiagnosticReports/`. Same healthy profile as T1's gate run —
  moving window construction into host.m didn't regress the browser-create or
  pump/worker coexistence paths.

### GATE 2 — remaining human step

Run `open spikes/cef-macos/build/cef-spike.app`. Confirm: (1) the window looks
like a **standard Zapp window** (titlebar, all three traffic lights, not
borderless/custom-chrome), (2) the CEF `<h1>CEF</h1>` page renders **inside**
that window (not a separate CEF-owned window), (3) dragging/resizing the
window resizes the CEF content live with it, (4) `[worker] tick N` keeps
incrementing in the console throughout. If all hold -> GATE 2 PASS.

---

## Task 3: custom `zapp://` scheme handler + native-brotli-decode probe

**Verdict: builds + launches clean; scheme + factory + both assets served
correctly at the CEF resource-handler level (pending human GATE-3 on-screen
check, deferred to T6).** Proves the mechanics Zapp's real `webEngine:
"chromium"` asset-serving would use, and probes the "size cost buys perf"
bet: ship brotli-compressed assets and let Chromium's own network stack
decode them, instead of decompressing ourselves.

### What changed

- **New `scheme_handler.c`**: owns the whole `zapp` scheme end-to-end —
  `cefspike_register_zapp_scheme()` (scheme registration, called in every
  process), a `cef_scheme_handler_factory_t` (`create()` matches the request
  URL against the two known asset URLs), a `cef_resource_handler_t`
  (`open`/`get_response_headers`/`skip`/`read`/`cancel` — the modern,
  non-deprecated vtable slots; `process_request`/`read_response` left `NULL`),
  and `cefspike_scheme_set_assets()` / `cefspike_install_scheme_handler_factory()`.
  Same manual-refcounting pattern (`cef_refcount.h`'s
  `IMPLEMENT_REFCOUNTING_SIMPLE`) T0 established.
- **New `assets/index.html`**: `<h1>` + `<pre id="out">`, with an inline
  script that `fetch("zapp://app/data.json")` and renders the decoded
  response text (plus the observed `Content-Encoding`/`Content-Type`
  headers) into `#out`.
- **New `assets/data.json`** (20364 bytes, human-readable source) +
  **`assets/data.json.br`** (1176 bytes, committed binary, brotli-compressed
  via `compress-assets.ts`) — the brotli probe payload.
- **New `compress-assets.ts`**: `bun run spikes/cef-macos/compress-assets.ts`
  — Bun's `node:zlib` `brotliCompressSync` (quality 11), NOT Node. Re-run
  whenever `assets/data.json` changes.
- **`cef_spike.h`**: added `#include ".../cef_scheme_capi.h"` (transitively
  already pulled in via `cef_app_capi.h`, included explicitly for clarity)
  and declarations for the three `scheme_handler.c` entry points.
- **`cef_app.c`**: added `on_register_custom_schemes` to the browser-process
  `cef_app_t` (forwards to `cefspike_register_zapp_scheme`) and
  `on_context_initialized` to the browser-process handler (forwards to
  `cefspike_install_scheme_handler_factory`).
- **`mac_helper.c`**: **no longer passes a `NULL` `cef_app_t`.** CEF calls
  `on_register_custom_schemes` in EVERY process, before init, and requires
  identical registration everywhere — so the Helper subprocess (renderer/
  GPU/utility) now builds its own minimal, standalone `cef_app_t` (same
  refcounting macros) whose only job is that one callback, wired to the same
  `cefspike_register_zapp_scheme()` scheme_handler.c exports. It deliberately
  does **not** reuse `cef_app.c`'s `cefspike_app_create()`: that app's
  browser-process handler calls `cefspike_pump_schedule` (mac_entry.m's ObjC
  external-pump owner), which the Helper build does not compile — reusing it
  would mean linking Cocoa/NSApplication pump scaffolding into a renderer/GPU
  child process for no reason. `scheme_handler.c` has no such dependency, so
  it links cleanly into the Helper (confirmed: `nm` shows
  `_cefspike_register_zapp_scheme` defined in the Helper binary, and `otool
  -L` shows **no** Cocoa link there — the ObjC pump machinery stayed fully
  out of the Helper build.)
- **`build.sh`**: helper-compile step now also compiles `scheme_handler.c`
  (no new `-I` needed — its quoted `#include`s resolve relative to its own
  directory, same as `mac_helper.c`'s pre-existing includes).
- **`main.nim`**: compiles `scheme_handler.c`; `staticRead()`s
  `assets/index.html`, `assets/data.json` (raw, for the size-delta log line
  only — never served), and `assets/data.json.br` at **Nim compile time**
  (absolute paths via `thisDir`, same style as `cefRoot`); hands the served
  buffers to C once via `cefspike_scheme_set_assets` **before**
  `cef_initialize` (the browser-process handler's `on_context_initialized`
  — which installs the factory — can fire synchronously inside
  `cef_initialize`, so the assets must already be set by then); the browser
  URL is now `zapp://app/index.html` (was `data:text/html,<h1>CEF</h1>`
  through T0-T2).

### Scheme options chosen

`CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED` — standard
so `zapp://app/index.html` parses as `scheme://host/path`; secure so no
mixed-content warnings; CORS/fetch-enabled so `index.html`'s same-origin
`fetch("zapp://app/data.json")` is permitted (same-origin here, so CORS
headers weren't strictly required, but a real `webEngine:"chromium"` asset
scheme would want these regardless).

### Resource-handler vtable used (CEF 144.0.29 / Chromium 144.0.7559.256)

The **current, non-deprecated** slots:
`open` -> `get_response_headers` -> `skip` (Range support) -> `read`
(repeatedly; `bytes_read == 0` + return `0` signals completion) -> `cancel`.
`process_request` / `read_response` (the pre-`open`/`read` legacy pair) exist
in the struct but are **only invoked as a fallback if `open`/`read` aren't
implemented** per the header's own doc comment — left `NULL` (calloc'd),
never called. No vtable surprises versus the brief's expected mechanics;
matched `cef_binary/include/capi/cef_resource_handler.h` +
`cef_scheme.h` exactly, no blocking issues.

### Brotli-direct probe: sizes + how it was verified

`assets/data.json` raw = **20364 bytes** -> `assets/data.json.br` = **1176
bytes** (`compress-assets.ts` reports "94% smaller"; `main.nim`'s own
integer-division log line reports "95% smaller" — same ratio
(1 - 1176/20364 = 0.9422), different rounding formulas, not a bug).

**How verified (code path + bounded run — on-screen decode is T6's GATE 3):**
a `perl -e 'alarm 8; exec @ARGV' ...` bounded run of the fresh build produced,
in order:

```
[cef-spike] brotli probe: data.json raw=20364B  br=1176B  (95% smaller)
[cef-spike] zapp:// scheme handler factory registered (index.html=1875 bytes, data.json.br=1176 bytes)
[worker] stand-in loop started (dedicated pthread + CFRunLoop)
[cef-spike] browser created
[cef-spike] zapp:// serving 1875 bytes, mime=text/html, encoding=(none)
[cef-spike] zapp:// serving 1176 bytes, mime=application/json, encoding=br
[worker] tick 1
[worker] tick 2
[worker] tick 3 … tick 6
```

This confirms, at the CEF resource-handler level: (1) `zapp://app/index.html`
was requested and served (1875 bytes = the exact committed file size); (2)
the page's inline script's `fetch("zapp://app/data.json")` **reached the zapp
scheme handler** and was served the exact 1176-byte brotli payload with
`Content-Encoding: br` — proving the CORS/fetch-enabled scheme flags allowed
the request through; (3) no `"zapp:// unhandled request"` log line appeared
(the only other branch in `create()`), i.e. no mismatched/unexpected URLs;
(4) no crash, no entries in `~/Library/Diagnostics/DiagnosticReports/`,
`[worker] tick N` kept incrementing throughout — T1/T2's pump/worker
coexistence is unaffected by T3's changes.

**What this does NOT prove:** whether Chromium actually **decoded** the br
bytes before handing them to `fetch().text()` (vs. the page receiving raw
compressed garbage) — that requires eyes on `#out`'s rendered content, which
is explicitly **T6's GATE 3 job**, not this task's. If GATE 3 shows garbled/
binary content instead of readable JSON, the probe's verdict flips to "CEF
custom-scheme responses don't run through Chromium's content-decoding
filters" — worth flagging loudly in that case, since it would kill perf-win
#1 for the custom-scheme-asset path specifically (HTTP responses would still
decode br fine; only custom-scheme resource-handler responses would be in
question).

### GATE 3 — remaining human step (T6)

Run `open spikes/cef-macos/build/cef-spike.app`. Confirm: (1) the window
shows the Task 3 page — an `<h1>CEF</h1>` and, below it, `#out` populated
with **readable JSON text** (not garbled binary) prefixed with
`Content-Encoding: br` / `Content-Type: application/json` lines; (2) the
JSON text is recognizably the `assets/data.json` content (the `"note"` field
mentioning brotli, the `items` array); (3) `[worker] tick N` keeps
incrementing in the console throughout. If all hold -> GATE 3 PASS (native
brotli-decode confirmed for custom-scheme responses).

### GATE 3 RESULT — **FAILED** (confirmed on-screen 2026-07-05)

The `#br-out` box renders `Content-Encoding: br` / `Content-Type:
application/json` followed by **raw binary garbage**, not JSON. Verdict (the
"flag it loudly" branch above): **Chromium does NOT run custom-scheme
resource-handler responses through its content-decoding filters.** The
`fetch().text()` call received the raw 1176-byte brotli payload verbatim, and
the `Content-Encoding: br` header even **survived to JS** (a decoded response
would have had it stripped) — double-confirming no decode happened.

- **This is a decode failure, not a serve failure.** The `zapp://` handler
  served the correct bytes with the correct headers (the same 1176-byte payload
  a real HTTP `br` response carries). Chromium simply doesn't decode it for the
  custom-scheme in-process resource path (content-decoding lives in the network
  service, which cef_resource_handler_t bypasses). Real **HTTP** `br` responses
  would still decode fine — only the custom-scheme asset path is affected.
- **Kills perf-win #1 for the `zapp://` asset path specifically** ("ship brotli,
  let the engine decode"). For a real `webEngine:"chromium"`, asset serving must
  instead either (a) **decode brotli in the resource handler** before handing
  bytes to CEF (we already ship a brotli decoder elsewhere; drops the "free"
  part of the bet but keeps on-disk size savings), or (b) serve assets from a
  **loopback HTTP origin** so Chromium's network stack does the decode (heavier;
  reintroduces a socket). Recommend (a).
- Everything else in T3 stands: the `zapp://` standard+secure+fetch scheme, the
  resource-handler vtable, and byte-accurate serving all work (the page loads,
  CORS/fetch is allowed, headers arrive intact). Only the *native-decode*
  hypothesis is disproven.

(Unrelated benign log noise seen alongside: `google_apis/gcm/... DEPRECATED_ENDPOINT`
is Chromium's push/GCM registration probing a dead Google endpoint — no bearing
on the spike; would be disabled with the GCM feature off in a real build.)

### GATE 3 FIX — option (a) implemented + verified (in-handler brotli decode)

`scheme_handler.c` now **decodes the brotli asset itself** and serves plain
`application/json` (no `Content-Encoding`), so `fetch().text()` gets readable
JSON. This is the production-shaped path: ship compressed, decode natively,
serve decoded.

- **Only the `.br` (1176 B) is embedded in the binary** — `main.nim` `staticRead`s
  `data.json.br` for the bytes but keeps only the `.len` of `data.json` (the
  decoded size the one-shot decoder needs), so the 20 KB never enters the binary.
  The size win is real, not just on the source tree.
- **Decoder:** Homebrew `libbrotlidec` via `BrotliDecoderDecompress`, gated by
  `-DCEFSPIKE_HAVE_BROTLI` so **only the browser build links brotli** — the
  Helper (render/GPU) subprocess compiles `scheme_handler.c` without it and stays
  dependency-free (it only registers the scheme; it never serves). `build.sh`
  resolves the keg via `brew --prefix brotli` and passes it as
  `-d:brotliPrefix:`; `main.nim` defaults to the arm64 keg for a bare `nim check`.
  A real `webEngine:"chromium"` would statically link the brotli decoder Zapp
  already ships instead of Homebrew.
- **Verified** (headless + on-screen): `brotli decoded in handler: 1176 br bytes
  -> 20364 JSON bytes`, then `zapp:// serving 20364 bytes, mime=application/json,
  encoding=(none)`; `#br-out` renders readable JSON; bridge round-trip + libzjs
  worker unaffected; `nim check` clean; zero crashes / dyld errors.
- Trade recorded: this pays CPU (decode per cold asset load) to keep the on-disk
  size win — the "engine decodes it for free" half of the original bet is gone
  for the custom-scheme path, exactly as GATE 3 forced. A loopback-HTTP origin
  (option b) would restore free decode at the cost of a socket; (a) chosen.

---

## Task 4 (MAKE-OR-BREAK): the `zapp` bridge — one JS↔native round-trip

Does the Zapp JS↔native contract map onto CEF? CEF's own promise plumbing
(`CefMessageRouter` / `window.cefQuery`) is **C++-only** (`libcef_dll_wrapper`);
on the raw C API we hand-roll the equivalent with `cef_v8` + `cef_process_message`.
Result: **yes, it maps cleanly** — the same shape as the WKWebview bridge
(document-start user-script + a native message handler + a promise-resolve
hook), just split across CEF's render↔browser process boundary.

### What changed

- **`bridge.c` (NEW, render-process half)** — a `cef_render_process_handler_t`
  (`on_context_created` + `on_process_message_received`) plus a `cef_v8_handler_t`.
  Compiled **into the Helper subprocess only** (see `build.sh`), because the
  render process IS the Helper.
- **`mac_helper.c`** — the Helper's minimal `cef_app_t` now returns the bridge
  handler from `get_render_process_handler` (switched to `IMPLEMENT_REFCOUNTING_
  MANUAL` + a hand-written release that frees the owned `rph`, mirroring
  `cef_app.c`'s browser-process-handler ownership).
- **`cef_client.c` (browser-process half)** — implements the client's
  `on_process_message_received` for `"zapp:invoke"`: runs a STUB `greet` service
  and ships `"zapp:result"` back to `PID_RENDERER`.
- **`assets/index.html`** — adds an "Invoke greet" button that
  `await window.zapp.invoke("greet", {name:"World"})` and renders the result
  into `#out`. The T3 brotli fetch demo is preserved (now under `#br-out`).
- **`cef_spike.h`** — declares `cefspike_render_process_handler_create()` and
  pulls in `cef_render_process_handler_capi.h`.

### Message-name protocol + which handler lives where

| name          | direction         | args                              | sender                              | handler                                            |
|---------------|-------------------|-----------------------------------|-------------------------------------|----------------------------------------------------|
| `zapp:invoke` | RENDER → BROWSER  | `[0]=id:int,[1]=name:str,[2]=argsJSON:str` | `bridge.c` V8 handler → `frame->send_process_message(PID_BROWSER)` | `cef_client.c` `on_process_message_received` (**cef_client_t**) |
| `zapp:result` | BROWSER → RENDER  | `[0]=id:int,[1]=resultJSON:str`   | `cef_client.c` → `frame->send_process_message(PID_RENDERER)` | `bridge.c` `on_process_message_received` (**cef_render_process_handler_t**) |

`on_process_message_received` exists on **both** `cef_client_t` (browser side)
and `cef_render_process_handler_t` (render side) — each side wires its own; both
processes agree on the two literal names (`#define`d identically in both files).

### V8 binding + promise-resolve mechanism

- **JS→native binding.** In `on_context_created` we `context->enter()`, grab
  `get_global()`, create `cef_v8_value_create_function("__zappSendNative", handler)`,
  and `set_value_bykey(global, "__zappSendNative", fn)`. The `cef_v8_handler_t.execute`
  reads `(id, name, argsJSON)`, finds its frame via
  `cef_v8_context_get_current_context()->get_frame()`, and ships the `zapp:invoke`
  process message. `window.zapp.invoke()` (defined in the bootstrap) wraps this:
  it mints an id, stores `{resolve,reject}` in a pending map, and calls
  `__zappSendNative(id, name, JSON.stringify(args))`.
- **native→JS resolve.** Chosen path: **`frame->execute_java_script(
  "window.__zappResolve(<id>, <resultJSON>)")`** from the render
  `on_process_message_received`. This is the "simplest robust path" — it
  sidesteps storing a `cef_v8_context_t` across the async round-trip (the render
  `frame` handed to the callback is enough to re-enter JS). `resultJSON` is a
  JSON *value* (the browser already quoted+escaped the string via
  `cefspike_json_quote`), so it splices verbatim into the JS call and lands as
  the resolved value.

### Doc-start injection point

`on_context_created(browser, frame, context)` **is** the document-start moment
(V8 context just built, before page scripts run) — the exact analog of
WKWebView's `WKUserScriptInjectionTimeAtDocumentStart`. We (a) bind
`__zappSendNative` on the global via the V8 API, then (b) run the bootstrap JS
(defines `window.zapp.invoke`, the `id→{resolve,reject}` pending map, and
`window.__zappResolve`/`__zappReject`) via `execute_java_script`. Binding before
running the bootstrap guarantees `__zappSendNative` exists by the time any page
script calls `invoke()`.

### FINDING — CEF C-API callback params are OWNED refs (must Release)

The load-bearing ABI detail for correctness. Every ref-counted argument to a
client callback is `refptr_diff` in the translator (`libcef_dll/cpptoc/*.cc`,
e.g. `render_process_handler_cpptoc.cc`, `client_cpptoc.cc`, `v8_handler_cpptoc.cc`):
**ownership is transferred to the callee, which must `->base.release()` it.**
This matches the existing T0 life-span handler releasing its `browser` param.
So the bridge releases: `browser`/`frame`/`context` in `on_context_created`;
`browser`/`frame`/`message` in both `on_process_message_received`s; and the V8
handler's `object` **and every `arguments[i]`** (`refptr_vec_diff_byref_const`).
Getters that return new refs (`get_argument_list`, `get_frame`,
`get_current_context`, `get_global`, `cef_v8_value_create_function`,
`cef_process_message_create`) are released too; `cef_string_userfree_t` results
are `cef_string_userfree_free`'d. Getting this wrong is a leak (under-release)
or a use-after-free crash (over-release), so it was verified against the
translator source, not guessed.

### FINDING (blank-screen bug, post-ship fix) — args passed INTO CEF setters/senders are CONSUMED

The mirror of the rule above, and the one that actually bit. Ref-counted
arguments you pass **into** a CEF call are `refptr_same`, routed through the
translator's `Unwrap` (`libcef_dll/ctocpp/ctocpp_ref_counted.h`), whose comment
is explicit: *"Add a reference … that will be released once the structure is
received"* — i.e. **the callee CONSUMES one reference.** So a value you created
with `ref=1` and then pass into such a call has had its reference **transferred**
— you must **NOT** release it afterward. Two calls in this bridge are
`refptr_same`-consuming:

- `cef_v8_value_t.set_value_bykey(global, key, fn, …)` — consumes `fn`.
- `cef_frame_t.send_process_message(frame, pid, msg)` — consumes `msg` (its
  header even says "the message reference will be invalidated").

The original T4 commit released `fn` after `set_value_bykey` (in
`on_context_created`) and `msg`/`reply` after `send_process_message` (both
processes). All three were **double-releases**. The `fn` one fired on **every
page load**: it corrupted/killed the render process *inside*
`on_context_created` → the render frame died → **blank white page, no page-JS
executing, right-click context menu gone, and `blink.mojom.FrameWidgetHost`
"Message rejected"** in the browser log. It was misdiagnosed at first as a T2
hosting / compositor / external-pump issue because the symptom is browser-side;
the actual cause was a render-process crash. Bisected by logging each step of
`on_context_created` and seeing it reach `set_value_bykey` then vanish before
the next line. Fix: drop the three post-consume releases. The `create_function`
handler arg, by contrast, is `refptr_diff` via `CppToC_Wrap` — create RETAINS
it — so releasing our construction ref on the handler stays correct.

Rule of thumb for this C API: **`Wrap` (values you RECEIVE — callback params,
create/get return values) = you OWN → you release; `Unwrap` (values you PASS
into a setter/sender) = CONSUMED → you don't.**

### JSON at the boundary (spike-grade)

The browser stub hand-rolls two tiny helpers in `cef_client.c`:
`cefspike_json_quote` (encode a C string as a JSON value, minimal escaping,
heap-allocated to dodge the stack-buffer-truncation bug family) and
`cefspike_json_str_field` (extract `"name"` from `{"name":"World"}` — no
nested-escape handling; enough for the spike). Production `webEngine:"chromium"`
would route real args/results through the same typed C-ABI Zapp already uses for
WKWebView, not ad-hoc string surgery — flagged for the real implementation.

### Process-boundary friction worth logging

- **No `CefMessageRouter`.** The C++ helper that gives you `window.cefQuery`
  + automatic promise correlation is unavailable on the C API. The id↔promise
  correlation, the pending map, and the two-message protocol are all
  hand-rolled here. It's ~1 file of boilerplate, but it IS boilerplate every
  raw-C-API embedder re-implements. (Production could still link
  `libcef_dll_wrapper` for just the message router if desired — a size/complexity
  trade to weigh later.)
- **The bootstrap JS lives in a C string** (`kZappBootstrapJS` in `bridge.c`),
  contrary to Zapp's usual "worker/bootstrap JS belongs in `bootstrap/*.ts`
  through codegen" convention — because the render handler runs in the Helper
  subprocess, which never runs Nim and never `staticRead()`s an asset. `bridge.c`
  is the only code that reaches the render V8 context, so the bootstrap must
  compile INTO the Helper binary. A production port would generate this string
  from a `.ts` source at build time and `#include` it.
- **Two builds, one contract.** The invoke/result names are `#define`d in two
  separately-compiled translation units (`bridge.c` → Helper, `cef_client.c` →
  main app). Nothing enforces they agree except discipline; a shared header
  constant would be the production fix.

### Evidence gathered (non-visual)

`bash spikes/cef-macos/build.sh` → `[build] complete:` + fresh binary mtime;
`nim check … main.nim` exit 0 (clean). The Helper binary links the bridge:
`nm` shows `_cefspike_render_process_handler_create`,
`_cefspike_rph_on_context_created`, `_cefspike_v8_handler_execute`; `strings`
shows the `__zappSendNative` bootstrap. Two bounded runs (~35s, ~10s): app
launches, browser created, `zapp://app/index.html` served, `[worker] tick N`
keeps incrementing, **clean exit 0, zero crash reports**.

**What the bounded runs did NOT show:** any render-side page-JS execution — the
render process's `fprintf(stderr, …)` never reached the captured log, AND T3's
own `fetch("zapp://app/data.json")` **also never served** in these headless/
detached runs (no `serving … data.json` line). I.e. the render process loads
the top resource but doesn't run page scripts without a real GUI session, so the
round-trip is **not auto-observable here** — it is genuinely T6's on-screen job,
exactly as the brief scopes it. This is an environment limitation, not a bridge
defect (the browser-side handler, which IS in the captured process, would have
logged `[browser] zapp:invoke` had a message arrived; none did because no page
JS ran to send one).

### GATE 4 — remaining human step (T6)

Run `open spikes/cef-macos/build/cef-spike.app`. Confirm: (1) the window shows
the Task 4 page with an **"Invoke greet"** button; (2) clicking it replaces
`#out` with **`Hello from Zapp! (to World)`** (contains `Hello from Zapp!`) —
proving the full JS→render-V8→`zapp:invoke` IPC→browser stub→`zapp:result`
IPC→render→`__zappResolve`→awaited-Promise round-trip across the process
boundary; (3) the T3 `#br-out` brotli demo still shows readable JSON; (4)
the console keeps incrementing worker output throughout (Task 5 replaced
the stand-in's `[worker] tick N` line with `[worker] real zjs tick N ->
posting to page` — see Task 5, below). Console should show
`[cef-spike][browser] zapp:invoke id=… service=greet …` +
`[cef-spike][browser] zapp:result id=… -> "Hello from Zapp! (to World)"`. If all
hold → GATE 4 PASS (JS↔native bridge maps onto CEF).

### GATE 4 RESULT — **PASS** (confirmed on-screen 2026-07-05)

The full round-trip works on the real GUI. Observed console:

```
[cef-spike][render] bridge bootstrap injected (window.zapp.invoke ready)
[cef-spike][browser] zapp:invoke id=1 service=greet args={"name":"World"}
[cef-spike][browser] zapp:result id=1 -> "Hello from Zapp! (to World)"
[cef-spike][render] zapp:result id=1 -> resolving JS
```

`#out` renders `Hello from Zapp! (to World)`. **The Zapp JS↔native contract maps
onto CEF** — JS `window.zapp.invoke` → render V8 binding → `zapp:invoke` IPC →
browser stub service → `zapp:result` IPC → render → `__zappResolve` → resolved
Promise, all across the render↔browser process boundary, coexisting with the
real libzjs worker (Task 5) ticking throughout.

**Prerequisite fix (see the double-release FINDING above):** GATE 4 only passes
after the `refptr_same`-consume double-release bug was fixed. As originally
shipped, T4 crashed the render process on every page load (blank screen); the fix
commit dropped the three post-consume `release()` calls.

---

## Task 5: ZJS worker coexists — formalize + demo (REAL libzjs, PRIMARY path)

**Verdict: PRIMARY path (real libzjs worker) delivered, builds + launches
clean; bounded-run evidence shows the real engine ticking at 1 Hz while CEF
stays alive (pending human GATE-5 on-screen check, deferred to T6).**
Replaces Task 1's stand-in (a pthread+CFRunLoop timer logging `[worker] tick
N`, deferred by design — see Task 1 above) with a genuine embed of
`vendor/zjs`'s C ABI, and wires its output into the CEF-rendered page.

### Path taken: PRIMARY (real libzjs), not the timebox fallback

The orchestrator's brief flagged a timeboxed fallback (keep the stand-in,
argue ZJS's render-engine-independence by construction) in case a minimal
libzjs embed turned into a rabbit hole. It didn't: `vendor/zjs/include/zjs.h`
already documents an embedder-facing "CLI-style loop" (`zjs_has_pending_work`
/ `zjs_next_timer_ms` / `zjs_run_pending_timers`) and a
`zjs_new_minimal_context()` constructor built exactly for tight embeddings —
this is a much smaller surface than `native/worker/engines/zjs.c`'s full
production embedding (worker registry, kqueue+CFRunLoop hybrid for
NSURLSession draining, capability modules). The whole worker fit in one new
file, `zjs_worker.c`, with no build-system fights: `vendor/zjs/build/libzjs.a`
was already built (prerequisite, not produced by this task) and linked on the
first `nim c` attempt with zero duplicate-symbol errors and zero missing
frameworks beyond what `nm -u` predicted. PRIMARY delivered as scoped.

### What changed

- **New `zjs_worker.c`** — the whole real-worker surface:
  - `cefspike_start_zjs_worker()`: spawns a detached pthread (`pthread_create`
    + `pthread_detach`, same shape as T1's stand-in) that:
    1. `zjs_new_minimal_context()` — ES-core-only context. No Ring-1/2 web
       globals, no `node:` modules — this demo needs neither.
    2. `zjs_register_host_function(ctx, "__zapp_native_post", ...)` — one
       host function the JS tick calls once a second.
    3. `zjs_eval(ctx, "setInterval(function () { ... }, 1000)")` — a REAL
       `setInterval` tick on the REAL interpreter, computing
       `{tick, at, source}` and calling `__zapp_native_post(JSON.stringify(...))`.
    4. The documented CLI-style loop (`while (zjs_has_pending_work(ctx)) {
       sleep to zjs_next_timer_ms; zjs_run_pending_timers(ctx); }`) pumps the
       context for the process lifetime. `setInterval` re-arms its own timer
       every fire, so "pending work" never reaches zero — this loop runs
       forever, the same shape as T1's `CFRunLoopRun()`.
  - `host_native_post`: copies the JSON string out immediately (per zjs.h's
    lifetime contract — a `ZjsValue`'s backing bytes are only guaranteed
    live while the cell is reachable, and this function is about to return
    and hop threads), heap-allocates the JS call string (the
    stack-buffer-truncation lesson from `reference_dispatch_buffer_bug` /
    bridge.c's own `zapp:result` path — no fixed-size stack buffers here),
    then `dispatch_async`s to the main queue where it calls
    `cefspike_get_active_browser()` → `browser->get_main_frame(browser)` →
    `frame->execute_java_script(frame, "if (window.__zappWorker) window.
    __zappWorker(<jsonValue>);", ...)` — Task 4's exact bridge.c mechanism
    (`frame->execute_java_script` resolving `window.__zappResolve`), reused
    for a timer push instead of a process-message reply.
  - Logs `[worker] real zjs tick N -> posting to page` once per tick (same
    evidence-gathering style as T1's `[worker] tick N`) so a bounded/headless
    run — which can't see the page — still shows the real engine advancing.
- **`cef_client.c`** — the life-span handler now **retains** the browser
  instead of releasing it on `on_after_created` (`g_active_browser`), exposed
  read-only via `cefspike_get_active_browser()`. This parameter is an OWNED
  ref per the Task 4 ownership finding (CEF hands each callback invocation a
  fresh owned ref) — T0-T4 released it immediately since nothing needed it
  past the log line; T5 keeps it and releases it in `on_before_close`
  alongside that callback's own owned ref (two distinct refs, both released,
  no leak). `get_main_frame`'s own doc comment confirms this is safe: "In the
  browser process this will return a valid object until after
  cef_life_span_handler_t::OnBeforeClose is called."
- **`mac_entry.m`** — removed Task 1's stand-in (`cefspike_start_worker_stub`,
  `cefspike_worker_thread`, `cefspike_worker_timer_cb`) and its now-unused
  `#include <pthread.h>`, replacing the block with a short pointer to
  `zjs_worker.c`. The T1 external-pump machinery (`ZappCefPump`,
  `cefspike_pump_schedule`, `cefspike_run_main_loop`,
  `cefspike_quit_main_loop`) is untouched — only the stand-in "second loop"
  bit was superseded, per the orchestrator's explicit "replace the stand-in"
  resolution.
- **`cef_spike.h`** — swapped `cefspike_start_worker_stub`'s declaration for
  `cefspike_start_zjs_worker` + `cefspike_get_active_browser`.
- **`main.nim`** — added the zjs build/link surface (below), compiles
  `zjs_worker.c`, swapped the `cefspike_start_worker_stub()` call (step 6) for
  `cefspike_start_zjs_worker()`, updated the module doc comment.
- **`assets/index.html`** — new "Task 5" section: a `<pre id="worker-out">`
  and `window.__zappWorker(v)` (an IIFE closing over a capped 20-line ring
  buffer) that formats each tick (`[HH:MM:SS] tick N — real zjs worker
  (libzjs)`) and re-renders the `<pre>`. The T3 brotli demo (`#br-out`) and T4
  bridge button (`#out`) are untouched below it.

### libzjs link surface (the actual answer to "how small")

Linked **`vendor/zjs/build/libzjs.a` DIRECTLY** — NOT the symbol-hidden
`libzjs_embed.a` repack `cli/src/build-config.ts`'s production build
post-processes (`ld -r` + `-exported_symbols_list _zjs_*`, ~40 lines of
build-config.ts machinery to dodge duplicate-symbol clashes against the
OTHER zenc-stdlib runtime — `Arena__`/`Vec__`/etc. — a full Zapp binary also
embeds). This spike links no such runtime anywhere else (its C/ObjC files
hand-roll their own JSON helpers rather than use the zenc `JsonValue` type —
see `cef_client.c`'s `cefspike_json_quote`/`cefspike_json_str_field`), so
there's nothing to dodge. Confirmed empirically, not just by inspection: the
first `nim c` build with `libzjs.a` on the link line succeeded with zero
duplicate-symbol errors.

`main.nim`'s new build/link surface, in full:

```nim
const zjsRoot = thisDir & "/../../vendor/zjs"
{.passC: "-I" & zjsRoot & "/include".}
{.compile(thisDir & "/zjs_worker.c", "-std=c11").}
{.passL: zjsRoot & "/build/libzjs.a".}
{.passL: "-framework Security".}
{.passL: "-lz".}
{.passL: "-lm".}
```

`-framework Security` and `-lz` were determined by running `nm -u` on the
prebuilt archive and cross-checking against `vendor/zjs/Makefile`'s own
`PLATFORM_LDFLAGS` (Darwin: `-framework Foundation -framework Security
-fobjc-arc -lz`) and `smoke_static`'s link recipe (adds `-lm`) — the archive's
undefined externals are exactly `deflate`/`inflate` (node:zlib),
`SecRandomCopyBytes`/`CC_SHA*`/`CCHmac` (crypto.subtle), and
`NSURLSession`/Foundation classes (already covered transitively by the
existing `-framework Cocoa` link). No `-framework Foundation` needed
explicitly; no `-lcompression` needed (that flag belongs to
`native/worker/engines/zjs.c`'s OWN embedded-asset decode path, not to
`libzjs.a` itself — this spike doesn't compile that file, so it doesn't need
that flag). `libzjs.a`'s single `libzjs.o` is the ENTIRE zc-transpiled engine
as one translation unit (not compiled with `ZJS_TIER=minimal`, so
`zjs_new_minimal_context()` saves RUNTIME work — skipped installers — not
LINK-time size; referencing any `zjs_*` symbol pulls in the whole object).
Binary size was not a goal for this spike; a production port would want the
`ZJS_TIER=minimal` build + the `libzjs_embed.a` symbol-hiding repack once it
sits alongside the full worker stack.

### Evidence gathered (non-visual)

`bash spikes/cef-macos/build.sh` → `[build] complete:` + fresh binary mtime
(first-attempt success, no relink needed); `nim check` on `main.nim` — clean,
zero output. `nm` on the final main binary confirms `_zjs_new_minimal_context`
/ `_zjs_eval` / `_cefspike_start_zjs_worker` / `_cefspike_get_active_browser`
/ `_host_native_post` all defined (`T`/`t`); `otool -L` shows
`Security.framework` and `libz.1.dylib` now linked alongside the pre-existing
Cocoa/AppKit/Foundation/CEF-framework set.

A bounded run (~25s, `perl -e 'alarm 25; exec @ARGV' ...`) produced, in order:

```
[cef-spike] brotli probe: data.json raw=20364B  br=1176B  (95% smaller)
[cef-spike] zapp:// scheme handler factory registered (index.html=5139 bytes, data.json.br=1176 bytes)
[worker] real zjs worker starting (libzjs 0.0.1-phase0)
[worker] real zjs loop started (setInterval armed)
[cef-spike] browser created
[cef-spike] zapp:// serving 5139 bytes, mime=text/html, encoding=(none)
[worker] real zjs tick 1 -> posting to page
[worker] real zjs tick 2 -> posting to page
…
[worker] real zjs tick 23 -> posting to page
```

Steady 1 Hz for the full 25s window, interleaved with CEF's own browser
creation and asset serving — the real zjs engine advances concurrently with
CEF, exactly as T1's stand-in did, now with a genuine `libzjs` context instead
of a `CFRunLoopTimer`. No crash of the main `cef-spike` process across five
separate bounded runs (10s/12s/15s/25s) during this task; `nm`/`otool` link
checks above confirm the binary that produced this log is the one just built
(fresh mtime).

**Environment caveat found while gathering this evidence (not a T5
regression):** the `cef-spike Helper (Renderer)` subprocess produces an
`EXC_BREAKPOINT`/`SIGTRAP` diagnostic report at the moment the bounded-run
harness's `SIGALRM` abruptly kills the parent process — but this was ALREADY
happening in `~/Library/Logs/DiagnosticReports/` on THIS machine in reports
timestamped *before* any Task 5 code existed in this session (17:49–18:10,
vs. this task's first build at 18:19), so it predates and is independent of
this task's changes. The symbolication in those reports is unreliable (a
stripped release Chromium binary resolves to nonsense nearest-symbol names
like `rust_png$cxxbridge...`), consistent with a Mojo/IPC teardown assertion
firing when a child process's parent disappears non-gracefully (SIGALRM's
default disposition is immediate termination, not `cef_shutdown`'s orderly
`on_before_close` → `cef_shutdown` path a real window-close/Cmd-Q would
trigger) rather than a genuine Task-5-introduced bug. **Zero crash reports
appeared for the main `cef-spike` process itself** across every run in this
task. Flagging for T6: as part of GATE 5, prefer quitting the app normally
(closing the window / Cmd-Q) over killing it from a terminal, and note
whether a Renderer crash report still appears after a graceful quit — if it
does, that would upgrade this from "test-harness artifact" to a real finding
worth chasing.

### FINDINGS — ZJS is render-engine-independent by construction

The point this task exists to prove, now demonstrated rather than argued: the
zjs worker in `zjs_worker.c` never references CEF, `cef_spike.h`'s
CEF-specific types, or anything Chromium-shaped, **except** at the single
`cefspike_get_active_browser()` / `execute_java_script` call inside
`host_native_post` — the one push-to-page hop. Everything upstream of that
hop (`zjs_new_minimal_context`, `zjs_register_host_function`, `zjs_eval`, the
`zjs_has_pending_work`/`zjs_next_timer_ms`/`zjs_run_pending_timers` pump loop)
is identical to what `native/worker/engines/zjs.c` already does in
production against WKWebView — a worker runs on its own native pthread,
entirely outside whichever render engine's process tree hosts the page (CEF
splits into browser/renderer/GPU/utility processes; WKWebView is
single-process-from-Zapp's-perspective; the zjs worker thread lives inside
Zapp's OWN process either way and touches the render engine only at the
narrow "push a value into the page" boundary). Swapping WKWebView for CEF
required **zero** changes to how a zjs worker is constructed, how JS runs
inside it, or how its event loop is pumped — the only render-engine-specific
code is the one-line difference between WKWebView's
`evaluateJavaScript:completionHandler:` and CEF's
`frame->execute_java_script`, both of which are "hop to the UI thread, tell
the webview to run this JS string" with no deeper coupling. This is exactly
the "worker layer is untouched by the render engine" claim the task brief
asks this cycle to make concrete, now backed by a working real-engine
implementation rather than the Task 1 stand-in's argument-by-analogy.

### GATE 5 — remaining human step (T6)

Run `open spikes/cef-macos/build/cef-spike.app`. Confirm: (1) the window
shows the Task 5 section at the top with **live ticks appearing in
`#worker-out`** roughly once a second, formatted like `[3:45:12 PM] tick 4 —
real zjs worker (libzjs)`, **without clicking anything** — this is the
worker pushing to the page on its own, independent of any user action; (2)
the Task 4 `#out` "Invoke greet" button and the Task 3 `#br-out` brotli demo
both still work exactly as before; (3) the console shows `[worker] real zjs
tick N -> posting to page` incrementing steadily at ~1 Hz throughout; (4) as
noted above, prefer quitting via the window's close button / Cmd-Q rather
than killing the process, and check whether a Renderer crash report still
appears afterward (if it does NOT, that confirms the SIGALRM artifact
flagged above; if it DOES, flag it as a real Task 5 finding). If (1)-(3) hold
→ GATE 5 PASS (a real ZJS worker runs alongside CEF and drives live page
content, independent of the render engine).

---

## Kitchen-sink-on-CEF integration catalog (2026-07-08)

Spike (catalog-only, `feat/cef-kitchen-sink-catalog`): temp-flipped `kitchen-sink`
to `webEngine:"chromium"`, built, walked all 21 native surfaces, cataloged, then
REVERTED the flip (kitchen-sink stays `system` by default). Spec:
`docs/superpowers/specs/2026-07-08-cef-kitchen-sink-catalog-design.md`. This is the
north-star integration checkpoint after C1 sidebar / C2 inspector / C3 toolbar /
host-event fan-out all merged.

**Finding #0 — builds + launches cleanly on CEF.** `bun run build` produced both
markers (1922 KB); headless launch = 3 browsers (host+sidebar+inspector), bridge
ready in all, greeter **zjs worker started**, sidebar/inspector wired, **0 crash
markers**. No build-level breakage — every surface's native code compiles under
`ZAPP_HAS_CEF` and links with CEF.

**Result: 18 / 21 surfaces PASS on CEF. 1 PARTIAL, 2 BROKEN.**

| Surface | Status | Note |
|---|---|---|
| home | PASS | renders |
| sidebar | PASS | collapse/expand + toolbar toggle (C1) |
| inspector | PASS | collapse/expand (C2) |
| toolbar | PASS | buttons fire, tracking separator (C3) |
| workers | PASS | greeter invoke round-trips (A/B) |
| events | PASS | window events show (host-event fan-out) |
| sync | PASS | state syncs |
| window-log | PASS | logs appear |
| multiwindow | PASS | opens 2nd window (B) |
| clipboard | PASS | text/html/image/files |
| filedrop | PASS | dropped PNG loads in the webview |
| dialogs | PASS | open/save/alert all work |
| tray | PASS | status-bar item + window |
| notifications | PASS | posts (fixture has no click-receipt UI — not a CEF gap) |
| dock | PASS | menu/badge/bounce |
| screen | PASS | displays info |
| shortcuts | PASS | global shortcut fires (Carbon) |
| app-events | PASS | active/inactive fire (the active double-fire is a PRE-EXISTING non-CEF bug) |
| **embedded-webview** | **PARTIAL** | the nested `<zapp-webview>` (a real WKWebView-in-CEF) RENDERS + loads a URL, but does NOT position/track its host box — it lands mis-placed. A WKWebView inside a CEF page works; the geometry tracking is the gap. |
| **popover** | **BROKEN** | `Window.current().popover…` NO-OPs — NSPopover doesn't open on a CEF window. |
| **contextmenu** | **BROKEN** | JS→native fires correctly (router receives `showContextMenu` with the full item tree), but the native menu never appears. The native show path is WK-specific and/or CEF's own context menu suppresses it. |

**Cross-cutting cosmetic gaps (not per-surface; deferred polish):**
- **Vibrancy / material** — kitchen-sink uses `vibrancy: Material.Sidebar`; on WK the panels show the material behind a solid content bg, on CEF the panels render translucent/flat. This is the documented "CEF panes are opaque, no vibrancy" non-goal surfacing in a vibrancy-heavy app. Needs a decision (accept the flat look on CEF, or an OSR/background approach).
- **Scrollbar gutter** — Chromium reserves a bottom scrollbar corner vs WKWebView full-height. See the CEF scrollbar note. Cosmetic.

**Roadmap (follow-up cycles, prioritized):**
1. **popover-on-CEF** (BROKEN, no-op) — likely the NSPopover host-view/positioning path assumes a WKWebView; own cycle.
2. **contextmenu-on-CEF** (BROKEN) — the JS side works (router msg received); fix the native `showContextMenu` display for CEF (and/or suppress CEF's built-in context menu); own cycle.
3. **embedded-webview positioning-on-CEF** (PARTIAL) — the `<zapp-webview>` box-tracking geometry on a CEF host page; own cycle.
4. **Cosmetic (deferred):** vibrancy/material opacity + scrollbar gutter — a later polish pass, or accept as CEF-intrinsic.

Everything else (18 surfaces) works on CEF unchanged — the C-series + host-event
fix covered the bulk of the native-surface matrix.
