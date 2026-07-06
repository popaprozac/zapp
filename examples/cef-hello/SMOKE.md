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

DevTools, multi-window, native chrome (sidebar / inspector /
toolbar) on the `chromium` path, Helper signing/notarization, iOS / Windows /
Linux, per-window engine selection, and navigation/back-forward are all out
of scope for this fixture and this slice — see
`docs/api-reference.md`'s `webEngine` section and
`spikes/cef-macos/FINDINGS.md` for what remains open. (Worker on CEF is now
GATE 5 above, not a non-goal — the broadcast path was proven already-present;
its human visual gate is still pending.)
