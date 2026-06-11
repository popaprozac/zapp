// iOS sidebar stubs. The sidebar window option is macOS-only in v1; these
// no-ops satisfy the shared router.zc references on iOS (#ifdef __APPLE__
// is true on iOS too). UISplitViewController is the planned v2.
#import <Foundation/Foundation.h>
#import <stdint.h>

void darwin_sidebar_toggle(int32_t window_id) { (void)window_id; }
void darwin_sidebar_collapse(int32_t window_id) { (void)window_id; }
void darwin_sidebar_expand(int32_t window_id) { (void)window_id; }
void darwin_sidebar_set_width(int32_t window_id, int32_t width) { (void)window_id; (void)width; }
