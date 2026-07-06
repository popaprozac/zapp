// Zapp CEF host (macOS) — shared declarations for the CEF C-API glue that
// backs `webEngine:"chromium"`.
//
// Promoted from the proven GO spike (`spikes/cef-macos/cef_spike.h` — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md for the full risk-gate writeup).
// This is the seam between the future Nim/build-system caller (T2) and the
// C/ObjC that builds the CEF callback structs + macOS scaffolding. Keeping
// the fiddly cef_*_t / cef_string_t construction in C (which #includes the
// real CEF headers, so struct layout is always correct for the linked SDK
// version) lets the caller stay struct-layout-free: it just calls
// cef_initialize / zapp_cef_create_browser_in_view / cef_shutdown with
// pointers these helpers return.
//
// This task (T1 of the production slice) promotes the spike's proven CEF
// machinery as-is (renamed cefspike_ -> zapp_cef_, "spike" dropped) and
// rewrites ONLY the scheme handler to serve Zapp's REAL embedded-asset table
// (zapp_embedded_assets[] — see zapp_cef_scheme_handler.c and
// native/platform/darwin/webview.m's ZappAssetSchemeHandler, which this
// mirrors) instead of the spike's two hardcoded assets. Build/link
// integration (the include path, the CEF framework link, the window-creation
// branch, and wiring the bridge to Zapp's real router) is explicitly OUT of
// scope here — that's T2/T3/T4. The bridge (zapp_cef_bridge.c) stays the
// spike's `greet` stub this task.

#ifndef ZAPP_CEF_H_
#define ZAPP_CEF_H_

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_render_process_handler_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "include/internal/cef_string.h"

// Invariant check — replaces cefsimple_capi/simple_utils.h's CHECK.
#define CHECK(cond)                                                        \
  do {                                                                     \
    if (!(cond)) {                                                         \
      fprintf(stderr, "[zapp-cef] CHECK failed: %s (%s:%d)\n", #cond,      \
              __FILE__, __LINE__);                                         \
      abort();                                                             \
    }                                                                      \
  } while (0)

#ifdef __cplusplus
extern "C" {
#endif

// --- zapp_cef_app.c ---
// A minimal (no-op besides the browser-process handler below) cef_app_t for
// the browser process. Returns with ref count 1; the reference is
// transferred to CEF by cef_initialize.
cef_app_t* zapp_cef_app_create(void);

// --- zapp_cef_client.c ---
// A cef_client_t exposing a life-span handler (tracks browser create/close
// and calls cef_quit_message_loop when the last browser closes) plus the
// browser-process half of the `zapp` JS<->native bridge (handles
// "zapp:invoke", runs a stub service this task — real-router wiring is a
// later task — and ships "zapp:result" back). Ref count 1; the reference is
// transferred to CEF by cef_browser_host_create_browser.
cef_client_t* zapp_cef_client_create(void);

// Build a cef_string_t (UTF-16) from a UTF-8 C string. Returned pointer is to
// static storage — valid until the next call.
cef_string_t* zapp_cef_make_cef_string(const char* utf8);

// Zeroed cef_browser_settings_t with size set. Static storage.
cef_browser_settings_t* zapp_cef_make_browser_settings(void);

// Read-only accessor for the currently-hosted browser. zapp_cef_client.c's
// life-span handler retains this (since on_after_created, releasing the
// separate on_before_close owned ref alongside it) instead of releasing it
// immediately, so a future native->page push mechanism (a worker event, the
// real bridge's async replies, etc.) can reach the page via
// `browser->get_main_frame(...)->execute_java_script(...)`. Returns NULL
// before the browser exists / after it has closed. Main-thread-only by
// construction: the writer (zapp_cef_client.c's life-span callbacks, which
// run on the CEF UI thread == the main thread under the external pump) and
// any reader both touch this only on the main thread, so no locking is
// needed.
cef_browser_t* zapp_cef_get_active_browser(void);

// --- zapp_cef_mac_entry.m ---
// Configure the CEF API version (guarded) and install the CefAppProtocol-
// conforming NSApplication subclass. Must run before cef_initialize.
void zapp_cef_ns_application_init(void);

// Browser-process bootstrap (T3). Installs the CefAppProtocol NSApplication
// subclass + external-pump owner (via zapp_cef_ns_application_init), builds the
// browser-process main_args/settings/app, and calls cef_initialize with
// external_message_pump=1. Call ONCE at app startup, BEFORE the host app's own
// [NSApplication sharedApplication] (so NSApp is the ZappCefApplication) — see
// native/platform/darwin/platform.m's darwin_platform_init. CEF's pump then
// drives off the SAME [NSApp run] loop the host already owns; this does NOT
// start a second run loop (do NOT also call zapp_cef_run_main_loop). The
// browser process does NOT cef_execute_process: on macOS the child processes
// are the separate Helper .apps (zapp_cef_mac_helper.c owns their main()).
void zapp_cef_app_init(void);

// cef_shutdown at app teardown. Idempotent (a static guard makes a double call
// a no-op), so it is safe to invoke from BOTH the [NSApp stop] browser-close
// path (after [NSApp run] returns) and applicationWillTerminate.
void zapp_cef_app_shutdown(void);

// Wrap argc/argv in a cef_main_args_t. Static storage.
cef_main_args_t* zapp_cef_make_main_args(int argc, char** argv);

// Build cef_settings_t: no_sandbox, EXTERNAL message pump
// (external_message_pump=1, multi_threaded_message_loop=0 — the host
// application owns the loop, CEF is pumped via zapp_cef_pump_schedule), and
// the explicit framework / helper-subprocess / main-bundle paths resolved
// from NSBundle. Static storage.
cef_settings_t* zapp_cef_make_settings(void);

// Build a cef_window_info_t for an Alloy-style browser hosted in parent_view.
// Static storage.
cef_window_info_t* zapp_cef_make_window_info(void* parent_view, int width,
                                             int height);

// --- zapp_cef_host.m ---
// Create a standard Zapp-style NSWindow (titled/closable/miniaturizable/
// resizable, standard traffic lights, auto-centered — mirrors the basic
// shape of native/platform/darwin/window.m's darwin_window_create). Shows +
// activates the window. Returns the NSWindow* (as void*). Standalone-window
// helper — kept for parity with the spike; production hosting normally goes
// through zapp_cef_create_browser_in_view below, which takes an
// ALREADY-EXISTING NSView (Zapp's own window/webview content view) instead
// of creating its own window.
void* zapp_cef_make_host_window(int width, int height, const char* title);

// Return the given NSWindow's contentView (as void*), to use as
// cef_window_info_t.parent_view. The window/contentView must already exist —
// call this AFTER zapp_cef_make_host_window and BEFORE
// cef_browser_host_create_browser (parent_view is read at browser-create
// time).
void* zapp_cef_host_view_for_window(void* window);

// Production entry point (T3 will call this from the window-creation branch
// for `webEngine:"chromium"`). Hosts a CEF browser INSIDE |parent_view| — an
// NSView the CALLER already owns and keeps alive (Zapp's own window content
// view; see native/platform/darwin/window.m), rather than creating a new
// NSWindow the way zapp_cef_make_host_window does. |parent_view| is a plain
// `void*` (not `NSView*`) so this header stays includable from the plain-C
// translation units in this directory (zapp_cef_app.c, zapp_cef_mac_helper.c
// — Nim/C callers use `pointer`/`void*` the same way); the .m implementation
// bridges it to NSView internally. |url| should be the resolved zapp://...
// URL in production mode, or — when zapp_build_use_embedded_assets() == 0
// (dev) — the Vite devUrl instead (T3's job to choose; this function just
// hosts whatever URL string it is given — see zapp_cef_scheme_handler.c's
// factory create() for the matching dev-mode "don't serve embedded" hook).
// Fire-and-forget: does not block for on_after_created; use
// zapp_cef_get_active_browser() once the browser exists.
void zapp_cef_create_browser_in_view(void* parent_view, const char* url);

// --- zapp_cef_mac_entry.m — external message pump + main-loop ownership ----

// CEF's external-message-pump hook. Called (from zapp_cef_app.c's
// browser-process handler on_schedule_message_pump_work, which may run on
// ANY thread) whenever CEF has queued work for the browser UI thread. Hops
// to the main thread and schedules a cef_do_message_loop_work() on the
// NSRunLoop after |delay_ms| (<= 0 = "soon"; > 0 = "after the delay,
// cancelling any pending pump"). Safe to call before the run loop starts —
// the hop is queued until [NSApp run].
void zapp_cef_pump_schedule(int64_t delay_ms);

// Run NSApplication's main loop ([NSApp run]). NSApplication owns the loop;
// CEF is pumped cooperatively via zapp_cef_pump_schedule. Returns when the
// loop is stopped (zapp_cef_quit_main_loop).
void zapp_cef_run_main_loop(void);

// Stop the NSApp main loop (external-pump mode: cef_quit_message_loop does
// not apply). Called from the life-span handler when the last browser
// closes.
void zapp_cef_quit_main_loop(void);

// --- zapp_cef_scheme_handler.c — the "zapp" custom scheme, real assets -----

// Register the "zapp" custom scheme (standard + secure + CORS/fetch-
// enabled). Wire this into cef_app_t::on_register_custom_schemes. CEF calls
// that callback in EVERY process — browser AND the Helper subprocess
// (zapp_cef_mac_helper.c wires its own minimal cef_app_t to this same
// function) — and requires identical registration across all of them.
// Deliberately self-contained (no dependency on the browser-process handler
// or the ObjC pump) so it links cleanly into the Helper build too.
void zapp_cef_register_zapp_scheme(cef_scheme_registrar_t* registrar);

// Create the "zapp" scheme handler factory and register it with the global
// request context (cef_register_scheme_handler_factory). Call AFTER
// cef_initialize (from the browser-process handler's on_context_initialized)
// — browser-process only. Unlike the spike, there is no separate
// "set assets" call: the factory reads the REAL embedded-asset table
// (`extern ZappEmbeddedAsset zapp_embedded_assets[]` /
// `zapp_embedded_assets_count` — the CLI-generated table T2 links in,
// mirroring native/platform/darwin/webview.m's ZappAssetSchemeHandler)
// directly at request time, so there is nothing to hand over up front.
void zapp_cef_install_scheme_handler_factory(void);

// --- zapp_cef_bridge.c — the `zapp` JS<->native bridge, RENDER-process half -

// Create the render-process handler that owns the bridge: it injects the
// document-start bootstrap + native V8 binding (window.zapp.invoke ->
// __zappSendNative) in on_context_created, and resolves the JS promise on
// the "zapp:result" reply in on_process_message_received. Ref count 1; the
// Helper app (zapp_cef_mac_helper.c) owns it and returns it from
// get_render_process_handler. RENDER-process only — the browser-side half
// lives in zapp_cef_client.c's on_process_message_received (message names:
// "zapp:invoke"/"zapp:result"). Stays the spike's `greet` STUB this task —
// wiring it to Zapp's real router/service registry is a later task.
cef_render_process_handler_t* zapp_cef_render_process_handler_create(void);

#ifdef __cplusplus
}
#endif

#endif  // ZAPP_CEF_H_
