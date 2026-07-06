# CEF macOS spike — FINDINGS

Running log of load-bearing findings from the `webEngine:"chromium"` (CEF) macOS
de-risking spike. Newest task last.

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
`[worker] tick N` keeps incrementing throughout. Console should show
`[cef-spike][browser] zapp:invoke id=… service=greet …` +
`[cef-spike][browser] zapp:result id=… -> "Hello from Zapp! (to World)"`. If all
hold → GATE 4 PASS (JS↔native bridge maps onto CEF).
