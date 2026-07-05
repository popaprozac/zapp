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

#include <stdio.h>
#include <stdlib.h>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
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

// Build cef_settings_t: no_sandbox, single-threaded loop (T0), and the explicit
// framework / helper-subprocess / main-bundle paths resolved from NSBundle.
// Static storage.
cef_settings_t* cefspike_make_settings(void);

// Create a plain NSWindow and return its content NSView* (as void*) to use as
// cef_window_info_t.parent_view. Shows + activates the window. (T2 formalizes
// this into Zapp's NSWindow shape in host.m.)
void* cefspike_create_window(int width, int height, const char* title);

// Build a cef_window_info_t for an Alloy-style browser hosted in parent_view.
// Static storage.
cef_window_info_t* cefspike_make_window_info(void* parent_view, int width,
                                             int height);

#ifdef __cplusplus
}
#endif

#endif  // ZAPP_SPIKE_CEF_SPIKE_H_
