// Generic "native surface" — resolves a SwiftUI (enhanced) or AppKit (baseline)
// backing and reports which one. Window attach lives in window.m's split builder.
#import <Cocoa/Cocoa.h>

// Nim-defined (exportc). Round-trips the demonstrative control's value into Nim,
// which emits a Zapp event observable from web content. Defined in window.nim.
extern void zapp_native_surface_emit(int32_t window_id, const char* value);

#ifdef ZAPP_HAS_SWIFTUI
// Swift @_cdecl entry (native_surface.swift). Returns a retained NSView* (+1).
typedef void (*ZappSurfaceCallback)(int32_t window_id, const char* value);
extern void* zapp_swift_native_surface_create(int32_t window_id, ZappSurfaceCallback cb);

// Trampoline so the Swift callback reaches Nim.
static void zapp_native_surface_cb(int32_t window_id, const char* value) {
    zapp_native_surface_emit(window_id, value);
}
#endif

// "swiftui" or "appkit" — last resolved backing for the given window.
static NSMutableDictionary<NSNumber*, NSString*>* zapp_surface_backing(void) {
    static NSMutableDictionary* d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// AppKit baseline: a label + button wired to the same Nim emit.
@interface ZappAppKitSurface : NSView
@property (nonatomic, assign) int32_t windowId;
@property (nonatomic, assign) int32_t taps;
@property (nonatomic, strong) NSTextField* tapsLabel;
@end

@implementation ZappAppKitSurface
- (instancetype)initWithWindowId:(int32_t)wid {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    _windowId = wid;
    NSTextField* title = [NSTextField labelWithString:@"AppKit native surface"];
    title.font = [NSFont boldSystemFontOfSize:13];
    _tapsLabel = [NSTextField labelWithString:@"taps: 0"];
    _tapsLabel.textColor = [NSColor secondaryLabelColor];
    NSButton* btn = [NSButton buttonWithTitle:@"Ping Nim" target:self action:@selector(ping:)];
    NSStackView* stack = [NSStackView stackViewWithViews:@[title, _tapsLabel, btn]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 12;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}
- (void)ping:(id)sender {
    (void)sender;
    self.taps += 1;
    self.tapsLabel.stringValue = [NSString stringWithFormat:@"taps: %d", self.taps];
    NSString* v = [NSString stringWithFormat:@"appkit:%d", self.taps];
    zapp_native_surface_emit(self.windowId, v.UTF8String);
}
@end

// Build the surface view for `window_id`, choosing the backing. Returns an
// autoreleased NSView*; window.m wraps it in a split item.
NSView* darwin_native_surface_create(int32_t window_id) {
    NSView* view = nil;
    NSString* backing = @"appkit";
#ifdef ZAPP_HAS_SWIFTUI
    if (@available(macOS 10.15, *)) {
        void* p = zapp_swift_native_surface_create(window_id, zapp_native_surface_cb);
        if (p) {
            view = (__bridge_transfer NSView*)p; // take the +1 from Swift
            backing = @"swiftui";
        }
    }
#endif
    if (!view) {
        view = [[ZappAppKitSurface alloc] initWithWindowId:window_id];
    }
    zapp_surface_backing()[@(window_id)] = backing;
    if (getenv("ZAPP_LOG")) {
        NSLog(@"[zapp] native surface backing: %@", backing);
    }
    return view;
}

// "swiftui" | "appkit" | "" (none yet). Caller copies immediately.
const char* darwin_native_surface_backing(int32_t window_id) {
    NSString* b = zapp_surface_backing()[@(window_id)];
    return b ? b.UTF8String : "";
}
