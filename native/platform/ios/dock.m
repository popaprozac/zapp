// iOS dock shim — iOS has no dock concept, but the app icon DOES
// support a numeric badge via UIApplication.applicationIconBadgeNumber.
// We map setBadge → numeric parse → UIApplication; bounce / showIcon /
// hideIcon / setIcon / resetIcon are no-ops since iOS doesn't expose
// equivalents from the app process.

#import <UIKit/UIKit.h>

void darwin_dock_show_icon(void) { /* no-op on iOS */ }
void darwin_dock_hide_icon(void) { /* no-op on iOS */ }

// Static cache so get_badge can return the last-set value (matching
// the macOS API contract); UIApplication doesn't expose a direct
// "current badge string" getter that handles non-numeric labels.
static char zapp_ios_badge[64] = {0};

void darwin_dock_set_badge(const char* label) {
    @autoreleasepool {
        if (!label) {
            zapp_ios_badge[0] = '\0';
            return;
        }
        strncpy(zapp_ios_badge, label, sizeof(zapp_ios_badge) - 1);
        zapp_ios_badge[sizeof(zapp_ios_badge) - 1] = '\0';
        // iOS only supports a numeric badge. If the label is a number,
        // set it; otherwise treat as "1" (something is there).
        NSInteger n = 0;
        NSString* s = [NSString stringWithUTF8String:label];
        if (s) {
            NSScanner* scanner = [NSScanner scannerWithString:s];
            if (![scanner scanInteger:&n] || ![scanner isAtEnd]) n = 1;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].applicationIconBadgeNumber = n;
        });
    }
}

void darwin_dock_remove_badge(void) {
    zapp_ios_badge[0] = '\0';
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
    });
}

const char* darwin_dock_get_badge(void) {
    return zapp_ios_badge;
}

void darwin_dock_bounce(int type) { (void)type; /* no iOS equivalent */ }
void darwin_dock_set_progress(int permille, int mode) { (void)permille; (void)mode; /* no iOS dock */ }
void darwin_dock_set_icon(const char* image_path) { (void)image_path; /* alternate icons exist but require Info.plist setup; defer */ }
void darwin_dock_reset_icon(void) { /* no-op */ }
