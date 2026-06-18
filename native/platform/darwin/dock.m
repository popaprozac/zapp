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

// --- Dock progress -------------------------------------------------------
// macOS has no first-class dock-progress API (unlike Windows ITaskbarList3).
// We render it the way Safari / Chrome / the App Store do: a custom NSDockTile
// contentView that draws the app icon + a progress-bar overlay, repainted via
// [dockTile display]. Inspired by sindresorhus/DockProgress. The NSDockTile
// keeps drawing the badge label over our contentView, so badge + progress coexist.

@interface ZappDockProgressView : NSView
@property (nonatomic) double fraction;  // 0..1 (determinate)
@property (nonatomic) int progressMode; // 0 normal, 1 indeterminate, 2 error, 3 paused
@property (nonatomic) double phase;     // 0..1 animation phase (indeterminate)
@end

@implementation ZappDockProgressView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect b = self.bounds;

    // The app icon fills the tile (we own the whole contentView now).
    NSImage* icon = [NSApp applicationIconImage];
    if (icon) {
        [icon drawInRect:b fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver fraction:1.0];
    }

    // Progress capsule: inset, near the bottom of the tile.
    CGFloat inset = b.size.width * 0.10;
    CGFloat barH  = b.size.height * 0.13;
    CGFloat barY  = b.size.height * 0.12;
    NSRect track  = NSMakeRect(b.origin.x + inset, b.origin.y + barY,
                               b.size.width - inset * 2.0, barH);
    CGFloat radius = barH / 2.0;

    // Track: dark backdrop + faint light border so it reads on any icon.
    NSBezierPath* trackPath = [NSBezierPath bezierPathWithRoundedRect:track xRadius:radius yRadius:radius];
    [[NSColor colorWithWhite:0.0 alpha:0.55] setFill];
    [trackPath fill];
    trackPath.lineWidth = 1.0;
    [[NSColor colorWithWhite:1.0 alpha:0.25] setStroke];
    [trackPath stroke];

    NSColor* fillColor;
    switch (self.progressMode) {
        case 2:  fillColor = [NSColor systemRedColor];    break;  // error
        case 3:  fillColor = [NSColor systemOrangeColor]; break;  // paused
        default: fillColor = [NSColor controlAccentColor]; break; // normal / indeterminate
    }

    [NSGraphicsContext saveGraphicsState];
    [trackPath addClip];   // keep the fill inside the capsule
    if (self.progressMode == 1) {
        // Indeterminate: a ~35%-wide segment sweeping left→right and back out.
        CGFloat segW   = track.size.width * 0.35;
        CGFloat travel = track.size.width + segW;
        CGFloat x      = track.origin.x - segW + travel * self.phase;
        NSRect seg = NSMakeRect(x, track.origin.y, segW, track.size.height);
        [fillColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:seg xRadius:radius yRadius:radius] fill];
    } else {
        double f = self.fraction; if (f < 0) f = 0; if (f > 1) f = 1;
        NSRect fill = NSMakeRect(track.origin.x, track.origin.y, track.size.width * f, track.size.height);
        [fillColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:radius yRadius:radius] fill];
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

static ZappDockProgressView* zapp_dock_progress_view = nil;
static NSTimer* zapp_dock_progress_timer = nil;

static void zapp_dock_progress_stop_timer(void) {
    if (zapp_dock_progress_timer) {
        [zapp_dock_progress_timer invalidate];
        zapp_dock_progress_timer = nil;
    }
}

void darwin_dock_set_progress(int permille, int mode) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDockTile* tile = [NSApp dockTile];
        // Clear: negative permille or mode 4 (none) → restore the default icon.
        if (permille < 0 || mode == 4) {
            zapp_dock_progress_stop_timer();
            tile.contentView = nil;
            [tile display];
            return;
        }
        if (!zapp_dock_progress_view) {
            zapp_dock_progress_view = [[ZappDockProgressView alloc] initWithFrame:NSMakeRect(0, 0, 128, 128)];
        }
        zapp_dock_progress_view.fraction = (double)permille / 1000.0;
        zapp_dock_progress_view.progressMode = mode;
        tile.contentView = zapp_dock_progress_view;

        if (mode == 1) {
            // Indeterminate: drive the sweep at ~30fps (start once, idempotent).
            if (!zapp_dock_progress_timer) {
                zapp_dock_progress_timer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                    repeats:YES block:^(NSTimer* t) {
                        (void)t;
                        if (!zapp_dock_progress_view) return;
                        double p = zapp_dock_progress_view.phase + 0.02;
                        zapp_dock_progress_view.phase = (p > 1.0) ? (p - 1.0) : p;
                        [zapp_dock_progress_view setNeedsDisplay:YES];
                        [[NSApp dockTile] display];
                    }];
            }
        } else {
            zapp_dock_progress_stop_timer();
        }
        // The dock tile caches a custom contentView's rendering — it won't re-run
        // drawRect: on [display] unless the view is explicitly invalidated, so a
        // mode/fraction change would otherwise keep showing the first render.
        [zapp_dock_progress_view setNeedsDisplay:YES];
        [tile display];
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
