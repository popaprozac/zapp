// iOS stubs — NSSplitViewController is AppKit-only. The router references the
// four control symbols under #ifdef __APPLE__ (true on iOS), so they must
// exist; window.m/toolbar.m registry symbols are macOS-only (darwin/ twins
// not compiled on iOS) and are not stubbed here.
#include <stdint.h>

void darwin_inspector_toggle(int32_t window_id) { (void)window_id; }
void darwin_inspector_collapse(int32_t window_id) { (void)window_id; }
void darwin_inspector_expand(int32_t window_id) { (void)window_id; }
void darwin_inspector_set_width(int32_t window_id, int32_t width) { (void)window_id; (void)width; }
