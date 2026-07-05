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
