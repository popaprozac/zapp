## CEF spike (Task 0) — Nim orchestration.
##
## This module IS the browser-process entry point (Nim's generated `main` runs
## the top-level `cefSpikeMain()` below). It proves the load-bearing thing for
## GATE 0: the CEF C API links into a Nim build. Nim itself calls the four CEF
## lifecycle entry points directly — `cef_initialize`, `cef_browser_host_create_browser`,
## `cef_run_message_loop`, `cef_shutdown` — resolving those symbols from the
## framework at link time. The fiddly cef_*_t / cef_string_t / cef_settings_t
## construction is delegated to the C/ObjC helpers in cef_app.c / cef_client.c /
## mac_entry.m (declared in cef_spike.h) so Nim stays free of CEF struct layout.
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
proc cef_run_message_loop() {.importc, cdecl, header: "cef_spike.h".}
proc cef_shutdown() {.importc, cdecl, header: "cef_spike.h".}

# --- Zapp-specific C/ObjC helpers (cef_spike.h) ----------------------------
proc cefspike_ns_application_init() {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_main_args(argc: cint, argv: ptr cstring): pointer
  {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_settings(): pointer {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_app_create(): pointer {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_client_create(): pointer {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_create_window(width, height: cint, title: cstring): pointer
  {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_window_info(parentView: pointer, width, height: cint): pointer
  {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_cef_string(utf8: cstring): pointer
  {.importc, cdecl, header: "cef_spike.h".}
proc cefspike_make_browser_settings(): pointer
  {.importc, cdecl, header: "cef_spike.h".}

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

  # 4. Open a host NSWindow and create a browser in it, pointed at a data: page.
  let winW = cint(960)
  let winH = cint(680)
  let parentView = cefspike_create_window(winW, winH, "CEF Spike — Task 0")
  let client = cefspike_client_create()
  let windowInfo = cefspike_make_window_info(parentView, winW, winH)
  let url = cefspike_make_cef_string("data:text/html,<h1>CEF</h1>")
  let browserSettings = cefspike_make_browser_settings()
  discard cef_browser_host_create_browser(
    windowInfo, client, url, browserSettings, nil, nil)

  # 5. Run CEF's message loop (T0 placeholder; T1 swaps in external-pump
  #    coexistence). Returns when the last browser closes (cef_quit_message_loop).
  cef_run_message_loop()

  # 6. Tear down.
  cef_shutdown()

cefSpikeMain()
