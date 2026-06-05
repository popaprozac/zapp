// iOS display info — singular (UIScreen.mainScreen). External-display
// hot-plug deferred. Signatures match the macOS darwin_screen_* (the shared
// router.zc references them under #ifdef __APPLE__, true on iOS too).
#import <UIKit/UIKit.h>
#import <stdint.h>

static NSDictionary* zapp_ios_display_dict(void) {
    UIScreen* s = [UIScreen mainScreen];
    CGRect b = s.bounds;
    NSDictionary* rect = @{ @"x": @0, @"y": @0,
                            @"width": @((int)b.size.width), @"height": @((int)b.size.height) };
    return @{
        @"id": @"main", @"name": @"Built-in",
        @"bounds": rect, @"workArea": rect,
        @"scaleFactor": @(s.scale), @"isPrimary": @YES, @"rotation": @0,
    };
}

static const char* zapp_ios_json_strdup(id obj) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return NULL;
    NSString* s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ? strdup([s UTF8String]) : NULL;
}

const char* darwin_screen_list_json(void) {
    @autoreleasepool { return zapp_ios_json_strdup(@[ zapp_ios_display_dict() ]); }
}
const char* darwin_screen_cursor_json(void) {
    @autoreleasepool {
        return zapp_ios_json_strdup(@{ @"x": @0, @"y": @0, @"display": zapp_ios_display_dict() });
    }
}
const char* darwin_screen_for_window_json(int32_t window_id) {
    (void)window_id;
    @autoreleasepool { return zapp_ios_json_strdup(zapp_ios_display_dict()); }
}
