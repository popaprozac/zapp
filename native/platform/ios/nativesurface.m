// iOS stubs so the shared Nim layer (window.nim) links on iOS. SwiftUI on iOS
// is a future cycle; the native surface is a no-op here for now.
#import <Foundation/Foundation.h>
#import <stdint.h>

void* darwin_native_surface_create(int32_t window_id) { (void)window_id; return NULL; }
const char* darwin_native_surface_backing(int32_t window_id) { (void)window_id; return ""; }
