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
