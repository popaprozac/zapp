// iPhone owned-nav chrome (R1). On iPhone with native routing, the window root is
// an app-owned UINavigationController (sidebar = root VC) instead of a
// UISplitViewController — eliminating the collapse-combine collision. Per-window
// registry mirrors ios/sidebar.m's zapp_ios_sidebars.
#import <UIKit/UIKit.h>
#include <string.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern const char* zapp_form_factor(void);            // "phone" | "tablet" (platform.m)
extern bool zapp_window_native_routing(int32_t window_id);  // window.nim (exportc)

@interface ZappOwnedNavController : NSObject
@property (nonatomic, strong) UINavigationController* nav;
@property (nonatomic, strong) UIViewController* sidebarVC;   // owned nav root
@property (nonatomic, strong) UIViewController* contentVC;   // held; pushed on section-select (Task 3)
@end
@implementation ZappOwnedNavController @end

static NSMutableDictionary<NSValue*, ZappOwnedNavController*>* g_owned_navs = nil;

// Gate: this window uses the owned-nav chrome iff phone idiom AND native routing.
bool zapp_ios_owned_nav_enabled(int32_t window_id) {
    const char* ff = zapp_form_factor();
    bool phone = (ff && strcmp(ff, "phone") == 0);
    return phone && zapp_window_native_routing(window_id);
}

void zapp_ios_register_owned_nav(void* window_ptr, UINavigationController* nav,
                                 UIViewController* sidebarVC, UIViewController* contentVC) {
    if (!window_ptr || !nav) return;
    if (!g_owned_navs) g_owned_navs = [NSMutableDictionary dictionary];
    ZappOwnedNavController* c = [ZappOwnedNavController new];
    c.nav = nav; c.sidebarVC = sidebarVC; c.contentVC = contentVC;
    g_owned_navs[[NSValue valueWithPointer:window_ptr]] = c;
}

UINavigationController* zapp_ios_owned_nav_for_window(void* window_ptr) {
    if (!window_ptr || !g_owned_navs) return nil;
    return g_owned_navs[[NSValue valueWithPointer:window_ptr]].nav;
}

UIViewController* zapp_ios_owned_content_vc_for_window(void* window_ptr) {
    if (!window_ptr || !g_owned_navs) return nil;
    return g_owned_navs[[NSValue valueWithPointer:window_ptr]].contentVC;
}
