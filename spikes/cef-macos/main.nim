## CEF spike (Task 0 + Task 1 + Task 2) — Nim orchestration.
##
## This module IS the browser-process entry point (Nim's generated `main` runs
## the top-level `cefSpikeMain()` below). It proves the load-bearing thing for
## GATE 0: the CEF C API links into a Nim build. Nim itself calls the CEF
## lifecycle entry points directly — `cef_initialize`,
## `cef_browser_host_create_browser`, `cef_shutdown` — resolving those symbols
## from the framework at link time. The fiddly cef_*_t / cef_string_t /
## cef_settings_t construction is delegated to the C/ObjC helpers in cef_app.c /
## cef_client.c / mac_entry.m (declared in cef_spike.h) so Nim stays free of CEF
## struct layout.
##
## Task 1 (message-loop coexistence, the #1 risk gate) swaps T0's placeholder
## `cef_run_message_loop` (CEF owns the loop) for CEF's EXTERNAL MESSAGE PUMP:
## NSApplication owns the loop (`cefspike_run_main_loop` = [NSApp run]) and CEF
## is pumped cooperatively via `cef_do_message_loop_work` scheduled from the
## browser-process handler (see cef_app.c + the ObjC pump in mac_entry.m). A
## second, ZJS-worker-shaped loop (`cefspike_start_worker_stub`) runs alongside
## to prove neither starves.
##
## Task 2 (hosting-fit) hosts the CEF browser inside a standard Zapp-style
## NSWindow (titlebar + traffic lights, mirroring native/platform/darwin/
## window.m's basic shape) instead of T0/T1's ad hoc placeholder window:
## `cefspike_make_host_window` (host.m) builds that window and
## `cefspike_host_view_for_window` returns its contentView to use as
## `cef_window_info_t.parent_view`. The browser was already created WINDOWED
## (parent_view + Alloy runtime_style) since T0 — T2 only formalizes the host
## window itself, not the browser-creation mode.
##
## Build/link surface lives here (per the Task 0 brief): the CEF include dir and
## the framework link are wired via {.passC.}/{.passL.}; the C/ObjC sources via
## {.compile.}. The CEF distribution root is injected by build.sh as
## `-d:cefRoot:<abs path to spikes/cef-macos/cef_binary>`.
##
## NOTE (spike): the framework is LINKED DIRECTLY (rpath), not loaded at runtime
## via CEF's library loader. Simpler for a Nim build; fine for a non-sandbox dev
## run. Production `webEngine:"chromium"` would use the runtime loader (sandbox).

import std/os

const thisDir = currentSourcePath().parentDir()

## CEF binary distribution root. Overridden by build.sh via -d:cefRoot:<abs>.
const cefRoot {.strdefine.}: string = thisDir & "/cef_binary"

const cefFrameworkBin =
  cefRoot & "/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"

# --- build/link surface ---------------------------------------------------
# Include dirs: the CEF dist root (so `include/capi/...` resolves) and this
# spike dir (so `cef_spike.h` / `cef_refcount.h` resolve). These reach the
# {.compile.}'d C/ObjC files and Nim's own generated C alike.
{.passC: "-I" & cefRoot.}
{.passC: "-I" & thisDir.}

# The CEF callback structs (C) and macOS scaffolding (ObjC, ARC).
{.compile(thisDir & "/cef_app.c", "-std=c11").}
{.compile(thisDir & "/cef_client.c", "-std=c11").}
{.compile(thisDir & "/mac_entry.m", "-fobjc-arc").}
{.compile(thisDir & "/host.m", "-fobjc-arc").}

# Link the CEF framework directly by its binary path (single-quoted: the bundle
# name has spaces). The dylib's install name is @rpath-based, so dyld resolves
# it at runtime via the rpath below (-> <app>.app/Contents/Frameworks).
{.passL: "'" & cefFrameworkBin & "'".}
{.passL: "-framework Cocoa".}
{.passL: "-Wl,-rpath,@executable_path/../Frameworks".}

# --- CEF C API entry points (resolved from the framework at link time) -----
proc cef_initialize(args, settings, app, sandboxInfo: pointer): cint
  {.importc, cdecl, header: "cef_spike.h".}
proc cef_browser_host_create_browser(windowInfo, client, url, browserSettings,
                                     extraInfo, requestContext: pointer): cint
  {.importc, cdecl, header: "cef_spike.h".}
proc cef_shutdown() {.importc, cdecl, header: "cef_spike.h".}

# --- Zapp-specific C/ObjC helpers (cef_spike.h) ----------------------------
proc cefspike_ns_application_init() {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_main_args(argc: cint, argv: ptr cstring): pointer
  {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_settings(): pointer {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_app_create(): pointer {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_client_create(): pointer {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_window_info(parentView: pointer, width, height: cint): pointer
  {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_cef_string(utf8: cstring): pointer
  {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_browser_settings(): pointer
  {.importc, cdecl, header: "cef_spike.h".}

# --- Task 2 host window (host.m) --------------------------------------------
proc cefspike_make_host_window(width, height: cint, title: cstring): pointer
  {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_host_view_for_window(window: pointer): pointer
  {.importc, cdecl, header: "cef_spike.h".}

# Task 1 — external-pump loop ownership + the second-loop coexistence probe.
proc cefspike_start_worker_stub() {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_run_main_loop() {.importc, cdecl, header: "cef_spike.h".}

# argv backing store — must outlive cef_initialize (CEF snapshots it into a
# command line). Module globals stay alive for the process lifetime.
var gArgStrings: seq[string]
var gArgv: seq[cstring]

proc cefSpikeMain() =
  # 1. Install the CefAppProtocol NSApplication + configure the API version.
  cefspike_ns_application_init()

  # 2. Reconstruct argc/argv for cef_main_args_t (argv[0] = exe path).
  gArgStrings = @[getAppFilename()]
  for p in commandLineParams():
    gArgStrings.add(p)
  gArgv = newSeq[cstring](gArgStrings.len + 1)  # +1 for the NULL terminator
  for i in 0 ..< gArgStrings.len:
    gArgv[i] = gArgStrings[i].cstring
  gArgv[gArgStrings.len] = nil
  let mainArgs = cefspike_make_main_args(gArgStrings.len.cint, addr gArgv[0])

  # 3. Initialize CEF (Nim calls cef_initialize directly).
  let settings = cefspike_make_settings()
  let app = cefspike_app_create()
  if cef_initialize(mainArgs, settings, app, nil) == 0:
    stderr.writeLine "[cef-spike] cef_initialize failed"
    quit(1)

  # 4. Open a standard Zapp-style host NSWindow (host.m — T2) and create a
  #    browser in it, pointed at a data: page. Ordering is load-bearing: the
  #    window/contentView must exist before the browser is created, since
  #    parent_view is captured into cef_window_info_t below and read by CEF at
  #    cef_browser_host_create_browser time.
  let winW = cint(960)
  let winH = cint(680)
  let hostWindow = cefspike_make_host_window(winW, winH, "CEF Spike — Task 2")
  let parentView = cefspike_host_view_for_window(hostWindow)
  let client = cefspike_client_create()
  let windowInfo = cefspike_make_window_info(parentView, winW, winH)
  let url = cefspike_make_cef_string("data:text/html,<h1>CEF</h1>")
  let browserSettings = cefspike_make_browser_settings()
  discard cef_browser_host_create_browser(
    windowInfo, client, url, browserSettings, nil, nil)

  # 5. Coexistence probe (Task 1, the #1 risk): spawn the SECOND concurrent loop
  #    — a ZJS-worker-shaped pthread+CFRunLoop that logs `[worker] tick N`. It
  #    must keep ticking while CEF + NSApplication run, and vice versa.
  cefspike_start_worker_stub()

  # 6. Run the loop under NSApplication (Task 1 external message pump): [NSApp run]
  #    owns the loop; CEF is pumped cooperatively via cef_do_message_loop_work
  #    scheduled from the browser-process handler. Returns when the last browser
  #    closes (life-span handler stops NSApp).
  cefspike_run_main_loop()

  # 7. Tear down.
  cef_shutdown()

cefSpikeMain()
