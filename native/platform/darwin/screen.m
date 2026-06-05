// macOS display enumeration. Emits Display JSON in TOP-LEFT GLOBAL coords
// (origin = primary display's top-left, y down). NSScreen is bottom-left
// global, so every y flips around the primary screen height. JSON is built
// with NSJSONSerialization (no fixed buffers). Returned strings are strdup'd;
// the Zen-C route frees them.
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

// Primary display height — the reference for bottom-left <-> top-left flips.
// Shared with window.m (extern) so window position uses the same origin.
double zapp_primary_screen_height(void) {
    NSArray<NSScreen*>* screens = [NSScreen screens];
    if (screens.count == 0) return 0.0;
    return screens[0].frame.size.height;
}

static NSDictionary* zapp_rect_topleft(NSRect r, double Hp) {
    // r is bottom-left global; top-edge in top-left global = Hp - (y + height).
    return @{
        @"x": @((int)r.origin.x),
        @"y": @((int)(Hp - (r.origin.y + r.size.height))),
        @"width": @((int)r.size.width),
        @"height": @((int)r.size.height),
    };
}

static NSDictionary* zapp_display_dict(NSScreen* s, double Hp) {
    CGDirectDisplayID did =
        (CGDirectDisplayID)[[s.deviceDescription objectForKey:@"NSScreenNumber"] unsignedIntValue];
    NSString* name = @"Display";
    if (@available(macOS 10.15, *)) { if (s.localizedName) name = s.localizedName; }
    return @{
        @"id": [NSString stringWithFormat:@"%u", (unsigned)did],
        @"name": name,
        @"bounds": zapp_rect_topleft(s.frame, Hp),
        @"workArea": zapp_rect_topleft(s.visibleFrame, Hp),
        @"scaleFactor": @(s.backingScaleFactor),
        @"isPrimary": @(CGDisplayIsMain(did) != 0),
        @"rotation": @((int)CGDisplayRotation(did)),
    };
}

static const char* zapp_json_strdup(id obj) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return NULL;
    NSString* s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ? strdup([s UTF8String]) : NULL;
}

const char* darwin_screen_list_json(void) {
    @autoreleasepool {
        double Hp = zapp_primary_screen_height();
        NSMutableArray* arr = [NSMutableArray array];
        for (NSScreen* s in [NSScreen screens]) [arr addObject:zapp_display_dict(s, Hp)];
        return zapp_json_strdup(arr);
    }
}

const char* darwin_screen_cursor_json(void) {
    @autoreleasepool {
        double Hp = zapp_primary_screen_height();
        NSPoint pt = [NSEvent mouseLocation]; // bottom-left global
        NSScreen* hit = nil;
        for (NSScreen* s in [NSScreen screens]) {
            if (NSPointInRect(pt, s.frame)) { hit = s; break; }
        }
        if (!hit) hit = [NSScreen mainScreen];
        NSDictionary* out = @{
            @"x": @((int)pt.x),
            @"y": @((int)(Hp - pt.y)),
            @"display": zapp_display_dict(hit, Hp),
        };
        return zapp_json_strdup(out);
    }
}

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);

const char* darwin_screen_for_window_json(int32_t window_id) {
    @autoreleasepool {
        double Hp = zapp_primary_screen_height();
        void* wp = darwin_window_get_by_numeric_id(window_id);
        NSScreen* s = nil;
        if (wp) s = ((__bridge NSWindow*)wp).screen;
        if (!s) s = [NSScreen mainScreen];
        return zapp_json_strdup(zapp_display_dict(s, Hp));
    }
}
