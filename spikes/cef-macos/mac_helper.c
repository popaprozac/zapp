// CEF spike (Task 0) — the macOS Helper subprocess entry point.
//
// Adapted from cefsimple_capi/process_helper_mac.c. CEF's multi-process model
// launches render/GPU/utility subprocesses from a separate Helper executable
// bundled at Contents/Frameworks/<name> Helper*.app (build.sh assembles five
// variants). This is that executable: it just runs cef_execute_process and
// returns its exit code.
//
// Divergences from the reference (spike, non-sandbox, direct-linked framework):
//   - No cef_scoped_sandbox_initialize (no_sandbox dev build).
//   - No cef_scoped_library_loader_* — the framework is linked directly with an
//     rpath (@executable_path/../../../ resolves to the main app's Frameworks/).
//   - A NULL cef_app_t is fine: the spike implements no render-process callbacks.

#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_version.h"

int main(int argc, char* argv[]) {
  // Configure the CEF API version before any other CEF call (guarded for older
  // SDKs that predate API versioning).
#ifdef CEF_API_VERSION
  cef_api_hash(CEF_API_VERSION, 0);
#endif

  cef_main_args_t main_args;
  main_args.argc = argc;
  main_args.argv = argv;

  // NULL app: no renderer-side callbacks implemented in this spike.
  return cef_execute_process(&main_args, NULL, NULL);
}
