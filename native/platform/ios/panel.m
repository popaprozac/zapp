// iOS embedded-webview stubs. Panels are macOS-only in v1; these no-ops
// satisfy the shared router.zc references on iOS (#ifdef __APPLE__ is true
// on iOS too). Real iOS panels deferred.
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

void darwin_panel_create(int32_t window_id, const char* panel_id, const char* url,
                         bool bridge, const char* partition) {
    (void)window_id; (void)panel_id; (void)url; (void)bridge; (void)partition;
}
void darwin_panel_set_bounds(const char* panel_id, int32_t x, int32_t y, int32_t w, int32_t h) {
    (void)panel_id; (void)x; (void)y; (void)w; (void)h;
}
void darwin_panel_load_url(const char* panel_id, const char* url) { (void)panel_id; (void)url; }
void darwin_panel_eval_js(const char* panel_id, const char* js) { (void)panel_id; (void)js; }
void darwin_panel_post_message(const char* panel_id, const char* data_json) { (void)panel_id; (void)data_json; }
void darwin_panel_show(const char* panel_id) { (void)panel_id; }
void darwin_panel_hide(const char* panel_id) { (void)panel_id; }
void darwin_panel_reload(const char* panel_id) { (void)panel_id; }
void darwin_panel_go_back(const char* panel_id) { (void)panel_id; }
void darwin_panel_go_forward(const char* panel_id) { (void)panel_id; }
void darwin_panel_destroy(const char* panel_id) { (void)panel_id; }
