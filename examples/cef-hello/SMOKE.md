# cef-hello — smoke matrix

`examples/cef-hello` is the minimal fullbleed-web fixture for the CEF
`webEngine:"chromium"` production slice
(`docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-design.md`,
branch `feat/cef-webengine-prod`). One window, one `greet` service, one
button. Its only job is to be the render+bridge smoke target proving (a) a
real Zapp app renders on CEF and round-trips `Services.invoke`, and (b) the
`webEngine:"system"` (WKWebView) path is completely untouched — the gate
guarantee the whole slice depends on.

Two builds, same source tree, only `zapp.config.ts`'s `webEngine` field
differs.

## (a) `webEngine:"chromium"` — CEF render + bridge

```
cd examples/cef-hello
rm -rf ~/.cache/nim/app_r   # required when switching engines — see DX gotcha below
bun run build
open bin/cef-hello.app
```

Expected build output: `[zapp] CEF app bundle: .../bin/cef-hello.app` +
`[zapp] build complete: .../bin/cef-hello (~1.9 MB)`.

| Gate | What it proves | Result |
|---|---|---|
| **GATE 3** — render | A real Zapp `.app`, produced by real `zapp build`, renders its page on Chromium (not WKWebView) inside a standard Zapp `NSWindow` — CEF's external message pump correctly slots into Zapp's *existing* `NSApplication` run loop (R0, the #1 integration risk; no second `[NSApp run]`) | **PASS — human-confirmed 2026-07-06** |
| **GATE 4** — bridge round-trip | Clicking "Say hello" runs `Services.invoke("greet", {name:"CEF"})` through the *real* transport (`bootstrap/webview.ts`'s `{t,id,m,a}` envelope, not a bespoke protocol) → `zapp_handle_message_from_window` → the real Nim router → `greet` service → `darwin_window_eval_js`'s CEF branch (`execute_java_script`) → the page. `#out` shows **`Hello from CEF`** | **PASS — human-confirmed 2026-07-06** |
| **GATE 5** — worker→page broadcast | A headless **ZJS** worker (`src/ticker.ts`, declared in `zapp.config.ts`'s `headless.ticker` block) calls `Events.emit("tick", { n })` once a second with no point-to-point send — a plain broadcast. That rides `dispatch_event_to_all` → `darwin_webview_eval_all` (`webview.m:1247`) → `zapp_registered_webviews_eval`'s existing `ZAPP_HAS_CEF` branch (`window.m:154-164`, shipped in `6f58489` — see `docs/superpowers/specs/2026-07-06-cef-worker-hardening-design.md`'s corrected §1) → the CEF page's `Events.on("tick", …)` handler, which writes `#tick`'s text to `worker tick #N`. Proves the render-engine-independent worker edge — CEF's whole point — reaches Chromium through the same broadcast path as WKWebView, with **zero code changes** to the delivery path. | **PASS — human-confirmed 2026-07-06** (`#tick` incremented on the Chromium page; 25 ticks captured headless) |

### Sub-cycle B — multi-window (macOS)

`zapp/app.nim` opens a **second** CEF window (`win2`, offset so it doesn't
overlap `win`) sharing the same `ticker` worker + `greet` service — the
fixture for the slot↔browser registry, the close handshake, and popup
parity. Design: `docs/superpowers/specs/2026-07-06-cef-multi-window-design.md`;
root-cause finding for the close-teardown fix: `spikes/cef-macos/FINDINGS.md`'s
★ Sub-cycle B update.

| Gate | What it proves | Result |
|---|---|---|
| **GATE 6** — two-window render + broadcast fan-out | A second `window.create` renders on Chromium independently from the first; the `ticker` worker's `Events.emit("tick", …)` broadcast fans out to **both** windows via the slot-indexed `zapp_cef_browsers[]` table (`zapp_cef_broadcast_eval`, T1 `7d204ad`) instead of the old single-global path — both windows' `#tick` counters increment, not just one. | **PASS — human-confirmed 2026-07-06** |
| **GATE 7** — per-window targeted greet | Clicking "Say hello" in **either** window round-trips `Services.invoke("greet")` through that window's own slot-tagged bridge message (`window_id` from `client->slot`) and the result evals back into **only** the clicking window (`zapp_cef_eval_in_window`, targeted by slot, not broadcast) — confirmed independently for `win=0` **and** `win=1`; neither window's result leaks into the other. | **PASS — human-confirmed 2026-07-06** |
| **GATE 8** — close guard | Checking the 🔒 "Close guard" checkbox on a CEF window, then clicking its close button, is **vetoed** (`windowShouldClose VETOED` in the console; browser + window stay fully intact — close-guard parity with WKWebView); unchecking the box and closing again actually closes it. | **PASS — human-confirmed 2026-07-06** |
| **GATE 9** — non-last close (leak-free teardown) | Closing **Window 2** (non-last) leaves **Window 1** alive and still ticking — the app does not quit. `browser closed (slot 1)` appears in the console, i.e. `on_before_close` actually fires (the Electrobun-pattern `removeFromSuperview` teardown, T2 `b74651e` — see FINDINGS' root-cause finding), so the slot deregisters and the owned ref releases with no leak. | **PASS — human-confirmed 2026-07-06** |
| **GATE 10** — last close | Closing the **last** remaining CEF window quits the app cleanly via the existing `terminateAfterLastWindowClosed` path, not `on_before_close` → `[NSApp stop]` — the coupled quit-guard Minor sub-cycle A deferred is now cleared. | **PASS — human-confirmed 2026-07-06** |
| **GATE 11** — popup → system browser | Clicking the `target=_blank` link in the page cancels the CEF popup (`on_before_popup`, T3 `1e75725`) and opens the URL in the **system browser** (Safari) instead — no chrome-less in-app popup window appears, matching WKWebView's `createWebViewWithConfiguration` parity. | **PASS — human-confirmed 2026-07-06** |

**Known limitation (not a regression, documented non-goal):** the teardown
that makes GATE 9 leak-free also makes a CEF window's close **terminal** —
`Window.close()` then `Window.show()` on the same window reshows a **blank**
window (the browser is destroyed and not recreated), unlike a WKWebView
window which reshows intact. Reversible reshow of a CEF window was an
explicit sub-cycle B non-goal; see FINDINGS for the follow-up candidate
(a CEF-aware `show` action).

Non-visual evidence gathered alongside the human gates (bounded ~6s headless
runs of `bin/cef-hello.app/Contents/MacOS/cef-hello`, re-confirmed during
this task after the CEF-version-pin change, which touches only the fetch
script — the already-cached `vendor/cef` build was untouched):

```
[zapp-cef] zapp:// scheme handler factory registered (embedded assets: on)
[zapp-cef] browser created
[zapp-cef] zapp:// serving 861 bytes, status=200, mime=text/html
[zapp-cef][render] bridge bootstrap injected (zapp.bridge ready)
[zapp-cef] zapp:// serving 7867 bytes, status=200, mime=application/javascript
[zapp-cef][browser] -> router (win=0): {"t":4,"m":"ready"}
```

— the real embedded-asset table (brotli-decoded in-handler, matching the
`is_brotli && uncompressed_len>0` rule the WKWebView path uses) is served
byte-accurately over `zapp://`, the real bridge bootstrap injects, and the
page announces `ready` to the real router. (One bounded run also
incidentally captured a `greet` invoke reaching the router with the
button's exact args — consistent with, but not a substitute for, the human
click-through above.)

**Cost measured on this exact build** (`du -sh`):

| | Size |
|---|---|
| `cef-hello.app` (chromium) | **291 MB** |
| `Chromium Embedded Framework.framework` alone | **289 MB** |
| `cef-hello` bare binary (chromium) | 1.9 MB |
| `cef-hello` bare binary (system / WKWebView) | 1.8 MB |

The ~289 MB is the framework — almost the entire opt-in cost. A
`webEngine:"system"` build of the same app is a couple MB.

### Sub-cycle C1 — sidebar (macOS)

Window 1 now sets a `sidebar` (`SidebarOptions`, `zapp/app.nim`) — the
`NSSplitViewController` pane-mounting CEF branch (`window.m`), rendering
HOST vs. SIDEBAR content by route hash, both panes subscribing to the same
`ticker` broadcast. Window 2 stays plain/fullbleed (unchanged), regression
fixture for the non-sidebar CEF path. Design:
`docs/superpowers/specs/2026-07-06-cef-sidebar-design.md`; findings + the
two generalizing fixes: `spikes/cef-macos/FINDINGS.md`'s ★ Sub-cycle C1
update.

| Gate | What it proves | Result |
|---|---|---|
| **GATE 12** — sidebar render | Window 1 renders **two** independent Chromium panes — host + sidebar — inside the same `NSSplitViewController`, each its own CEF browser registered in `zapp_cef_browsers[]` (`zapp_cef_create_browser_in_view`, once per pane container) | **PASS — human-confirmed 2026-07-06** |
| **GATE 13** — broadcast fan-out to both panes | The `ticker` worker's `Events.emit("tick", …)` reaches **both** the host and sidebar CEF browsers of window 1 (the engine-agnostic broadcast path, reused unchanged from sub-cycle B) — both panes' tick counters increment | **PASS — human-confirmed 2026-07-06** |
| **GATE 14** — collapse/expand via divider drag | Dragging the sidebar's divider collapses/expands it; the engine-agnostic sidebar event registry + `darwin_window_eval_js`'s `ZAPP_HAS_CEF` branch deliver `window:sidebar-*` events into both CEF panes exactly as they do for WKWebView | **PASS — human-confirmed 2026-07-06** |
| **GATE 15** — imperative JS toggle | `Window.current().sidebar.toggle()` from the page **collapses the sidebar** — proves the resolver fix (`darwin_window_get_by_numeric_id`'s CEF fallback, `zapp_cef_window_for_slot`) and the bootstrap-carrier fix (`zapp_build_bootstrap_carriers`, shared WK/CEF) together: without both, this no-ops silently on CEF | **PASS — human-confirmed 2026-07-06** |
| **GATE 16** — per-pane teardown on close | Closing window 1 logs `browser closed` for **both** the host and sidebar slots (no leak) — the teardown extension in `windowWillClose:` (T3, `b60c28f`) | **PASS — human-confirmed 2026-07-06** |
| **GATE 17** — window 2 (plain) regression | Window 2, unchanged (no sidebar/inspector/toolbar), still renders + ticks + closes cleanly via the original fullbleed CEF branch — proves the sidebar branch didn't regress the plain path | **PASS — human-confirmed 2026-07-06** |
| **GATE 18** — last-close clean quit | Closing the last remaining window (after both are closed) quits the app cleanly via `terminateAfterLastWindowClosed`, same as the plain multi-window case | **PASS — human-confirmed 2026-07-06** |

**Known limitations (documented, not hidden — see FINDINGS for detail):**
CEF panes are opaque (no vibrancy — an OSR non-goal); the `win-%d` (sidebar
host/sidebar panes) vs. `win-%p` (fullbleed window) window-id format is
inconsistent (cosmetic, tracked); the WK carrier append lacks the CEF path's
OOM NULL-check (cosmetic); sub-cycle B's terminal-close limitation applies
per-pane (closing does not recreate either browser on a later `show()`).

### Sub-cycle C2 — inspector (macOS)

Window 1 (already has a sidebar) now also sets an `inspector`
(`InspectorOptions`, `zapp/app.nim`) — a direct mirror of C1's sidebar arm
in the CEF pane-mount branch (`window.m`), making window 1 a **3-pane** CEF
window (sidebar + host + inspector). A host-pane "toggle inspector" button
sits beside the existing "toggle sidebar" button. Window 2 stays plain/
fullbleed (unchanged), regression fixture for the non-inspector CEF path.
Design: `docs/superpowers/specs/2026-07-07-cef-inspector-design.md`;
findings: `spikes/cef-macos/FINDINGS.md`'s ★ Sub-cycle C2 update.

| Gate | What it proves | Result |
|---|---|---|
| **GATE 19** — inspector render + coexistence | Window 1 renders **three** independent Chromium panes — sidebar + host + inspector — inside the same `NSSplitViewController`, each its own CEF browser registered in `zapp_cef_browsers[]` via the new inspector arm (`pane_role=3`, a direct mirror of C1's sidebar arm) — proves sidebar+inspector **coexistence** on Chromium, not just sidebar+host | **PASS — human-confirmed 2026-07-07** |
| **GATE 20** — broadcast fan-out to all three panes | The `ticker` worker's `Events.emit("tick", …)` reaches **all three** CEF browsers of window 1 (sidebar, host, inspector) — the engine-agnostic broadcast path, reused unchanged from sub-cycles B/C1 — all three panes' tick counters increment | **PASS — human-confirmed 2026-07-07** |
| **GATE 21** — collapse/expand via divider drag | Dragging the inspector's divider collapses/expands it **independently** of the sidebar — both accessories are independently collapsible, proving coexistence extends to interaction, not just rendering — via the engine-agnostic split-pane event delivery reused unchanged from C1 | **PASS — human-confirmed 2026-07-07** |
| **GATE 22** — imperative JS toggle | `Window.current().inspector.toggle()` from a host-pane button collapses the inspector; the sidebar's own toggle button still works side-by-side — proves C1's resolver (`darwin_window_get_by_numeric_id`'s CEF fallback) and shared bootstrap-carrier fixes generalize to the inspector **for free** — no new fix was needed this cycle | **PASS — human-confirmed 2026-07-07** |
| **GATE 23** — per-pane teardown on close | Closing window 1 logs `teardown_browser (slot N)` then `browser closed (slot N)` for **all three** slots — host, sidebar, and inspector — no leak; C1's teardown extension already covered the inspector slot forward-compat (Task 3), exercised for real here for the first time | **PASS — human-confirmed 2026-07-07** |
| **GATE 24** — window 2 (plain) regression | Window 2, unchanged (no sidebar/inspector/toolbar), still renders + ticks + closes cleanly via the original fullbleed CEF branch — proves the inspector arm didn't regress the plain path | **PASS — human-confirmed 2026-07-07** |
| **GATE 25** — last-close clean quit | Closing the last remaining window quits the app cleanly via `terminateAfterLastWindowClosed`, same as the sidebar-only and plain multi-window cases | **PASS — human-confirmed 2026-07-07** |

**Known limitations (documented, not hidden — see FINDINGS for detail):**
host-level window-event fan-out (`zapp_dispatch_event_to_js`) is WK-only — a
foundational gap since sub-cycle B affecting ALL CEF windows, not
inspector-specific (the inspector's own collapse/resize events DO reach the
CEF pane; deferred to a post-C2 follow-up, user-agreed 2026-07-07); CEF
inspector panes are opaque (no vibrancy, same as C1's sidebar finding);
sub-cycle B's terminal-close limitation applies per-pane; C3 (toolbar) is
next.

### Sub-cycle C3 — toolbar (macOS)

Window 1 (already sidebar + inspector from C1/C2) now also gets a toolbar
(spike `1c83c9c`) — the native-chrome element that completes the C1→C2→C3
north-star sequence. Window 2 stays plain/fullbleed (unchanged), regression
fixture for the non-toolbar CEF path. Design:
`docs/superpowers/specs/2026-07-07-cef-toolbar-design.md`; findings + root
causes: `spikes/cef-macos/FINDINGS.md`'s ★ Sub-cycle C3 update.

| Gate | What it proves | Result |
|---|---|---|
| **GATE 26** — panes fill under the toolbar | All three panes (sidebar, host, inspector) render fully under the toolbar with no dark band, and holding the correct size across a window resize — the `cef_browser_host_create_browser` async-frame race fix (`zapp_cef_snap_view_to_superview_for_slot`, T1 `f2a7ad3`) | **PASS — human-confirmed 2026-07-07/08** |
| **GATE 27** — trackingSeparator tracks the sidebar divider | `NSTrackingSeparatorToolbarItem` correctly anchors to the sidebar↔content divider under the unified (HiddenInset) chrome the fixture now opts into (T1 `7975b3e`) — verified interactively: `toggleSidebar` + a `ping` in the sidebar toolbar region, `toggleInspector` in the content region, both landing in the correct toolbar segment | **PASS — human-confirmed 2026-07-07/08** |
| **GATE 28** — chrome-metrics reach all 3 CEF panes | `--zapp-toolbar-height` (and friends) populate on **initial load** for all three panes — not just the host — via the CEF-aware eval route + on-ready per-pane re-inject (T2 `c20180e`/`af2dbc4`/`6353234`); content clears the toolbar (fixture pads by `--zapp-titlebar-height`, `f14137c`); switching the toolbar's display mode (Icon/Text) updates the value live | **PASS — human-confirmed 2026-07-07/08** |
| **GATE 29** — regression | Toolbar click → JS lands in the host pane (`zapp_toolbar_emit_click`, already CEF-aware, unchanged); `toggleSidebar`/`toggleInspector` toggles still work; window 2 (plain, no toolbar) still renders + ticks + closes cleanly; per-pane teardown on close still logs `browser closed` for all three slots, no leak | **PASS — human-confirmed 2026-07-07/08** |

**Known limitation (documented, not hidden — see FINDINGS for detail):** a
**manual page reload** on a CEF pane does not re-fire the chrome-metrics
inject (no `cef_load_handler_t`/load-end hook exists yet in
`zapp_cef_client.c`) — the metrics only refresh on the next KVO-driven
layout change (toolbar mode switch, a chrome-height-crossing resize).
Distinct from, and not fixed by, the GATE 28 initial-load race fix; deferred
to a future cycle. Also unchanged: host-level window-event fan-out
(`zapp_dispatch_event_to_js`, WK-only, foundational gap since sub-cycle B —
C3 didn't need it, since toolbar clicks use the separate, already-CEF-aware
`zapp_toolbar_emit_click` path); CEF panes remain opaque (no vibrancy);
DevTools remains sub-cycle D.

**North star reached:** sidebar (C1) + inspector (C2) + toolbar (C3) are all
CLOSED on the `chromium` path — every native-chrome primitive `kitchen-sink`
exercises now has a working CEF arm, clearing the toolbar blocker toward
running the full `kitchen-sink` app on Chromium.

### Host-event fan-out fix (macOS)

The last CEF window-event gap, flagged and deferred during C2/C3:
`zapp_dispatch_event_to_js` (`window.m`, the shared host-window-event
dispatcher for resize/move/focus/blur/maximize/restore/modal-dismissed)
early-returned for every CEF window because it resolved
`zapp_webviews[window_id]` — nil for CEF, whose browsers live in
`zapp_cef_browsers[]` instead. Window 1's existing 3-pane fixture
(sidebar + host + inspector) now subscribes to `WindowEvent.RESIZE` /
`FOCUS` / `BLUR` and renders the latest into `#winevt` (`index.html`,
`src/main.ts`) to prove the fan-out; window 2 (plain) proves the host-only
path is unaffected. Design:
`docs/superpowers/specs/2026-07-08-cef-host-events-design.md`; findings:
`spikes/cef-macos/FINDINGS.md`'s ★ Host-event fan-out fix update. Commit:
T1 `dd31439`.

| Gate | What it proves | Result |
|---|---|---|
| **GATE 30** — resize fans to all 3 panes | Resizing window 1 updates `#winevt` with the new `resize {width,height}` in **all three** CEF panes (sidebar, host, inspector); window 2 (plain) updates it in its own host pane — the new gated `ZAPP_HAS_CEF` branch in `zapp_dispatch_event_to_js` mirrors the WK JS-build and fans out via `darwin_window_eval_js` to the host + sidebar + inspector slots | **PASS — human-confirmed 2026-07-08** |
| **GATE 31** — focus/blur reach the CEF panes | Clicking away from window 1 then back updates `#winevt` to `blur` then `focus` in the CEF panes — proves the fix isn't resize-specific; the same gated branch dispatches every host window event | **PASS — human-confirmed 2026-07-08** |
| **GATE 32** — C1-C3 surfaces regress cleanly + WK byte-identical | Sidebar/inspector toggles, the `ticker` broadcast, and the `greet` bridge all still work on window 1 and window 2 after the fix; the new CEF branch sits entirely before the WK early-return and `return`s ahead of it, so the WK dispatch path (`window.m`, from the early-return down) is untouched — a `webEngine:"system"` build compiles the exact pre-fix bytes | **PASS — human-confirmed 2026-07-08** |

**Known (cosmetic) difference, deferred — not a bug:** CEF (Chromium)
reserves a bottom-right scrollbar gutter so a vertical and a horizontal
scrollbar can coexist; WKWebView runs its vertical scrollbar full-height
with no gutter. Webview-internal rendering, not a fan-out defect;
normalizable later from the web side (`::-webkit-scrollbar` /
`scrollbar-gutter` CSS), alongside the vibrancy-opacity and manual-reload
chrome-metrics gaps already deferred above.

## (b) `webEngine:"system"` — WKWebView, byte-identical to pre-change

```
cd examples/cef-hello
# zapp.config.ts: webEngine: "system"
rm -rf ~/.cache/nim/app_r
bun run build
```

Expected build output: `[zapp] build complete: .../bin/cef-hello (~1.8 MB)`
— **no** `[zapp] CEF app bundle:` line, **no** `.app` produced at all (a
`system` build emits the bare `bin/<exe>`, same as every other Zapp app).
Zero CEF fetch, zero CEF compile, zero CEF link, zero CEF bundle step runs.

This is the load-bearing guarantee (spec §"Strictly opt-in + gated"),
re-verified independently in this task:

- **Binary hash — SUPERSEDED by the worker-hardening cycle, not re-verified.**
  The `sha256 = 588494f859df1097160d18f371c1d35f4ac45d39e83a790594a20c0b78f93312`
  recorded above predates this cycle's fixture (`b4d30cc`, the `ticker`
  headless worker + `#tick` page wiring). That fixture changed
  `examples/cef-hello`'s source (`zapp.config.ts`'s `headless` block,
  `index.html`, `main.ts`) — changes that apply identically to *both*
  `webEngine` values, since a headless-worker declaration and its compiled-in
  engine are independent of `webEngine`. So a fresh `system` build's hash
  would legitimately differ from `588494f…` now — that's expected, not a
  regression, and this task deliberately does **not** run a `system` build to
  compute a new hash (out of scope for a docs-only task). The load-bearing
  guarantee this section exists to prove doesn't depend on a specific hash
  anyway — it's this: **a `system` build does zero CEF work and produces no
  `.app`** (see the compile-time gate and the "This task's own change" bullet
  below, both of which remain true regardless of what the fixture's source
  looks like). Flipping the config back to `"chromium"` and rebuilding
  restores the `.app` bundle exactly as in (a).
- **Compile-time gate (Task 2/Task 3 proof, re-affirmed):** `renderPlatformNim`'s
  macOS output is byte-identical with/without the CEF block appended only
  when `resolveWebEngine(config) === "chromium"`; `clang -E -P` /
  `unifdef -UZAPP_HAS_CEF` on `window.m` / `platform.m` / `webview.m` shows
  every CEF-specific line is inside `#ifdef ZAPP_HAS_CEF` — a `system` build
  compiles the ORIGINAL, unchanged bytes.
- **This task's own change** (the `CEF_VERSION` pin in `cli/scripts/fetch-cef.sh`)
  cannot affect a `system` build at all: `ensureCefFetched()` /
  `fetch-cef.sh` are only invoked when `resolveWebEngine(config) === "chromium"`
  (`cli/src/native.ts`'s `useCef` gate). A `system` build never imports
  `cli/src/cef.ts`.

## DX gotcha — clean the Nim cache when switching `webEngine`

Flipping `webEngine` between `"chromium"` and `"system"` **in place, without
clearing the Nim build cache, breaks the link.** Nim's `{.compile.}` cache
keys on the source file path, not on the `-D` flags (like `-DZAPP_HAS_CEF`)
it was last compiled with — so a stale `window.m.o` / `platform.m.o` built
for one engine gets silently reused when you rebuild for the other, and the
link fails LOUD with `Undefined symbols: _zapp_cef_*` (switching to
chromium) or an equivalent mismatch (switching to system). It never
produces a wrong-engine binary — the failure is at link time, not runtime —
but it does mean **every engine switch needs a clean build**:

```
rm -rf ~/.cache/nim/<app>_r
bun run build
```

(`<app>_r` is generally `app_r` for the default template; check
`.zapp/zapp_build_config.zc`/the build log if a project renamed its Nim
main module.) This was hit and worked around at every engine flip in Tasks
2/3/5 of this slice — recorded here as the standing gotcha, not something
this task changes.

## Non-goals this slice does NOT smoke

DevTools, native chrome (sidebar, inspector, and toolbar are all CLOSED, see
below) on the `chromium` path, Helper signing/notarization, iOS / Windows /
Linux, per-window engine selection, in-app popups, and navigation/
back-forward are all out of scope for this fixture and this slice — see
`docs/api-reference.md`'s `webEngine` section and
`spikes/cef-macos/FINDINGS.md` for what remains open. (Worker on CEF is GATE
5 above, not a non-goal — **PASS**, human-confirmed 2026-07-06.
**Multi-window is GATEs 6-11 above, not a non-goal either** — sub-cycle B
closed it; all six gates PASSED human-confirmed 2026-07-06. **Sidebar-on-CEF
is GATEs 12-18 above, not a non-goal either** — sub-cycle C1 closed it; all
seven gates PASSED human-confirmed 2026-07-06. **Inspector-on-CEF is GATEs
19-25 above, not a non-goal either** — sub-cycle C2 closed it; all seven
gates PASSED human-confirmed 2026-07-07. **Toolbar-on-CEF is GATEs 26-29
above, not a non-goal either** — sub-cycle C3 closed it; all four gates
PASSED human-confirmed 2026-07-07/08, completing the C1→C2→C3 native-chrome
sequence. Reversible reshow of a closed CEF window remains an explicit
non-goal — see the "Known limitation" note above.)
