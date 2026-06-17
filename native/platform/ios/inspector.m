// iOS stubs — NSSplitViewController is AppKit-only. The router references the
// four control symbols under #ifdef __APPLE__ (true on iOS), so they must
// exist; window.m/toolbar.m registry symbols are macOS-only (darwin/ twins
// not compiled on iOS) and are not stubbed here.
#include <stdbool.h>
#include <stdint.h>

void darwin_inspector_toggle(int32_t window_id) { (void)window_id; }
void darwin_inspector_collapse(int32_t window_id) { (void)window_id; }
void darwin_inspector_expand(int32_t window_id) { (void)window_id; }
void darwin_inspector_set_width(int32_t window_id, int32_t width) { (void)window_id; (void)width; }
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) { (void)window_id; (void)can_collapse; }
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) { (void)window_id; (void)resizable; }
