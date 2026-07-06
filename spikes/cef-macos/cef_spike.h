// CEF spike (Task 0) — shared declarations for the Zapp-specific helper surface.
//
// This is the seam between Nim (`main.nim`, which importc's the functions below
// plus the top-level CEF entry points) and the C/ObjC that builds the CEF
// callback structs + macOS scaffolding. Keeping the fiddly cef_*_t / cef_string_t
// construction in C (which #includes the real CEF headers, so struct layout is
// always correct for the fetched SDK version) lets Nim stay struct-layout-free:
// it just calls cef_initialize / cef_browser_host_create_browser / run / shutdown
// with pointers these helpers return.

#ifndef ZAPP_SPIKE_CEF_SPIKE_H_
#define ZAPP_SPIKE_CEF_SPIKE_H_

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "include/internal/cef_string.h"

// Invariant check — replaces cefsimple_capi/simple_utils.h's CHECK.
#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) {                                                           \
      fprintf(stderr, "[cef-spike] CHECK failed: %s (%s:%d)\n", #cond,       \
              __FILE__, __LINE__);                                           \
      abort();                                                               \
    }                                                                        \
  } while (0)

#ifdef __cplusplus
extern "C" {
#endif

// --- cef_app.c ---
// A minimal (no-op) cef_app_t for the browser process. Returns with ref count 1;
// the reference is transferred to CEF by cef_initialize.
cef_app_t* cefspike_app_create(void);

// --- cef_client.c ---
// A cef_client_t exposing only a life-span handler (tracks browser create/close
// and calls cef_quit_message_loop when the last browser closes). Ref count 1;
// the reference is transferred to CEF by cef_browser_host_create_browser.
cef_client_t* cefspike_client_create(void);

// Build a cef_string_t (UTF-16) from a UTF-8 C string. Returned pointer is to
// static storage — valid until the next call. Fine for the single URL the spike
// hands to cef_browser_host_create_browser.
cef_string_t* cefspike_make_cef_string(const char* utf8);

// Zeroed cef_browser_settings_t with size set. Static storage.
cef_browser_settings_t* cefspike_make_browser_settings(void);

// --- mac_entry.m ---
// Configure the CEF API version (guarded) and install the CefAppProtocol-
// conforming NSApplication subclass. Must run before cef_initialize.
void cefspike_ns_application_init(void);

// Wrap argc/argv (Nim's cmdCount/cmdLine) in a cef_main_args_t. Static storage.
cef_main_args_t* cefspike_make_main_args(int argc, char** argv);

// Build cef_settings_t: no_sandbox, EXTERNAL message pump (Task 1:
// external_message_pump=1, multi_threaded_message_loop=0 — NSApplication owns
// the loop, CEF is pumped via cefspike_pump_schedule), and the explicit
// framework / helper-subprocess / main-bundle paths resolved from NSBundle.
// Static storage.
cef_settings_t* cefspike_make_settings(void);

// Build a cef_window_info_t for an Alloy-style browser hosted in parent_view.
// Static storage.
cef_window_info_t* cefspike_make_window_info(void* parent_view, int width,
                                             int height);

// --- host.m (Task 2) ---
// Create a standard Zapp-style NSWindow (titled/closable/miniaturizable/
// resizable, standard traffic lights, auto-centered — mirrors the basic shape
// of native/platform/darwin/window.m's darwin_window_create). Shows + activates
// the window. Returns the NSWindow* (as void*). Replaces T0/T1's
// cefspike_create_window placeholder (formerly in mac_entry.m).
void* cefspike_make_host_window(int width, int height, const char* title);

// Return the given NSWindow's contentView (as void*), to use as
// cef_window_info_t.parent_view. The window/contentView must already exist —
// call this AFTER cefspike_make_host_window and BEFORE
// cef_browser_host_create_browser (parent_view is read at browser-create
// time).
void* cefspike_host_view_for_window(void* window);

// --- mac_entry.m — Task 1 external message pump + NSApp loop ownership -------

// CEF's external-message-pump hook. Called (from cef_app.c's browser-process
// handler on_schedule_message_pump_work, which may run on ANY thread) whenever
// CEF has queued work for the browser UI thread. Hops to the main thread and
// schedules a cef_do_message_loop_work() on the NSRunLoop after |delay_ms|
// (<= 0 = "soon"; > 0 = "after the delay, cancelling any pending pump"). Safe
// to call before the run loop starts — the hop is queued until [NSApp run].
void cefspike_pump_schedule(int64_t delay_ms);

// Run NSApplication's main loop ([NSApp run]). NSApplication owns the loop; CEF
// is pumped cooperatively via cefspike_pump_schedule. Returns when the loop is
// stopped (cefspike_quit_main_loop). Replaces T0's cef_run_message_loop.
void cefspike_run_main_loop(void);

// Stop the NSApp main loop (external-pump mode: cef_quit_message_loop does not
// apply). Called from the life-span handler when the last browser closes.
void cefspike_quit_main_loop(void);

// Task 1 coexistence probe (SECOND concurrent loop). Spawns a detached pthread
// running its own CFRunLoop with a repeating timer that logs "[worker] tick N".
// This is the loop SHAPE a real ZJS worker uses on Apple (dedicated pthread +
// CFRunLoop). A faithful stand-in for the risk gate; T5 wires the real ZJS
// worker. Call after the browser is created and before cefspike_run_main_loop.
void cefspike_start_worker_stub(void);

// --- scheme_handler.c (Task 3) — custom "zapp" scheme + brotli probe -------

// Register the "zapp" custom scheme (standard + secure + CORS/fetch-enabled).
// Wire this into cef_app_t::on_register_custom_schemes. CEF calls that
// callback in EVERY process — browser AND the Helper subprocess (mac_helper.c
// wires its own minimal cef_app_t to this same function) — and requires
// identical registration across all of them. Deliberately self-contained (no
// dependency on the browser-process handler or the ObjC pump) so it links
// cleanly into the Helper build too.
void cefspike_register_zapp_scheme(cef_scheme_registrar_t* registrar);

// Provide the embedded asset bytes the "zapp" scheme serves. Called once from
// main.nim — which staticRead()s the committed assets/index.html and
// assets/data.json.br at NIM COMPILE TIME — before cef_initialize (the
// browser-process handler's on_context_initialized, which installs the
// scheme handler factory below, can fire synchronously inside
// cef_initialize, so the assets must already be set by then). Browser-process
// only; the Helper has no assets to serve.
//   index_html    -> zapp://app/index.html, Content-Type: text/html
//   data_json_br  -> zapp://app/data.json, Content-Type: application/json,
//                    Content-Encoding: br. PRE-COMPRESSED bytes (see
//                    compress-assets.ts) — this handler does NOT decompress;
//                    the probe is whether Chromium's network stack decodes br
//                    natively for a custom-scheme response.
void cefspike_scheme_set_assets(const char* index_html, int index_html_len,
                                const void* data_json_br,
                                int data_json_br_len);

// Create the "zapp" scheme handler factory and register it with the global
// request context (cef_register_scheme_handler_factory). Call AFTER
// cef_initialize (from the browser-process handler's on_context_initialized)
// and after cefspike_scheme_set_assets. Browser-process only.
void cefspike_install_scheme_handler_factory(void);

#ifdef __cplusplus
}
#endif

#endif  // ZAPP_SPIKE_CEF_SPIKE_H_
