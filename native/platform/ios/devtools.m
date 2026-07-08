// iOS is WKWebView-only (no CEF). DevTools is a no-op here — the WKWebView
// inspector is Safari's Web Inspector (connect a Mac, Develop menu). Defined
// for darwin_* iOS symbol parity (#637); mirrors the macOS devtools.m WK
// no-op path (minus its stderr hint — silent, like the other iOS router
// stubs).
#import <Foundation/Foundation.h>
#include <stdint.h>

void darwin_devtools_open(int32_t window_id)  { (void)window_id; }
void darwin_devtools_close(int32_t window_id) { (void)window_id; }
