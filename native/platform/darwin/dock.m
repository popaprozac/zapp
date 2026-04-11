// macOS dock features — NSDockTile, badge, icon visibility, bounce.

#import <Cocoa/Cocoa.h>
#import "dock.h"

// Cached badge label (NSDockTile doesn't expose a getter)
static NSString* zapp_badge_label = nil;

void darwin_dock_show_icon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
        // Restore badge: clear first (required by macOS), then re-set after delay
        if (zapp_badge_label) {
            NSString* saved = [zapp_badge_label copy];
            [[NSApp dockTile] setBadgeLabel:nil];
            [[NSApp dockTile] display];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                dispatch_get_main_queue(), ^{
                    [[NSApp dockTile] setBadgeLabel:saved];
                    [[NSApp dockTile] display];
                });
        }
    });
}

void darwin_dock_hide_icon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Cache badge, clear it, then hide — macOS resets dock tile on policy change
        [[NSApp dockTile] setBadgeLabel:nil];
        [[NSApp dockTile] display];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    });
}

void darwin_dock_set_badge(const char* label) {
    NSString* badge = label ? [NSString stringWithUTF8String:label] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        zapp_badge_label = [badge copy];
        [[NSApp dockTile] setBadgeLabel:badge];
        [[NSApp dockTile] display];
    });
}

void darwin_dock_remove_badge(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        zapp_badge_label = nil;
        [[NSApp dockTile] setBadgeLabel:nil];
        [[NSApp dockTile] display];
    });
}

const char* darwin_dock_get_badge(void) {
    static char badge_buf[256];
    if (zapp_badge_label) {
        strncpy(badge_buf, [zapp_badge_label UTF8String], sizeof(badge_buf) - 1);
        return badge_buf;
    }
    return "";
}

void darwin_dock_bounce(int type) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSRequestUserAttentionType attentionType =
            (type == 1) ? NSCriticalRequest : NSInformationalRequest;
        // requestUserAttention only works when app is NOT active.
        // For critical: bounces until user activates the app.
        // For informational: bounces once.
        [NSApp requestUserAttention:attentionType];
    });
}

void darwin_dock_set_icon(const char* image_path) {
    if (!image_path) return;
    NSString* path = [NSString stringWithUTF8String:image_path];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSImage* image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image) {
            [NSApp setApplicationIconImage:image];
        }
    });
}

void darwin_dock_reset_icon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp setApplicationIconImage:nil];
    });
}
