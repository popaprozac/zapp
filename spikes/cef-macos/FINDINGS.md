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
