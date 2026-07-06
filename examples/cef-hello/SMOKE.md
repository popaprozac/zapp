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

- **Binary hash, re-run fresh in this task:** a clean (`rm -rf ~/.cache/nim/app_r`)
  `webEngine:"system"` build of `examples/cef-hello` produced
  `bin/cef-hello` with `sha256 = 588494f859df1097160d18f371c1d35f4ac45d39e83a790594a20c0b78f93312` —
  **identical** to the hash recorded in Task 3's report, produced *before*
  any CEF-version-pin change existed. Flipping the config back to
  `"chromium"` and rebuilding restores the `.app` bundle exactly as in (a).
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

Worker on CEF, DevTools, multi-window, native chrome (sidebar / inspector /
toolbar) on the `chromium` path, Helper signing/notarization, iOS / Windows /
Linux, per-window engine selection, and navigation/back-forward are all out
of scope for this fixture and this slice — see
`docs/api-reference.md`'s `webEngine` section and
`spikes/cef-macos/FINDINGS.md` for what remains open.
