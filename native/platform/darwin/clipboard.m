// macOS clipboard implementation — NSPasteboard wrappers.
// All operations target the system general pasteboard.
//
// Threading: NSPasteboard is documented as main-thread-only for some
// operations (notably writeObjects:). We main-thread-bounce every
// helper since callers can be webview, worker, or service contexts —
// same pattern as the alpha.31 webview eval fix.

#import <AppKit/AppKit.h>
#import "clipboard.h"

// --- Helpers ---

static char* zapp_strdup_cstr(NSString* s) {
    if (!s) return NULL;
    const char* utf8 = [s UTF8String];
    if (!utf8) return NULL;
    size_t len = strlen(utf8);
    char* buf = (char*)malloc(len + 1);
    if (!buf) return NULL;
    memcpy(buf, utf8, len + 1);
    return buf;
}

// Run `block` synchronously on the main thread and return whatever the
// block computed. If already on main, runs inline. dispatch_sync is
// safe here because every native caller is either on main already
// (router) or on a worker thread (workers, services) — never on a
// queue that the main thread is waiting on.
typedef void (^ZappPasteboardBlock)(NSPasteboard*);
static void zapp_clipboard_main(ZappPasteboardBlock block) {
    if ([NSThread isMainThread]) {
        block([NSPasteboard generalPasteboard]);
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        block([NSPasteboard generalPasteboard]);
    });
}

// --- Text ---

char* darwin_clipboard_read_text(void) {
    @autoreleasepool {
        __block char* result = NULL;
        zapp_clipboard_main(^(NSPasteboard* pb) {
            NSString* s = [pb stringForType:NSPasteboardTypeString];
            result = zapp_strdup_cstr(s);
        });
        return result;
    }
}

bool darwin_clipboard_write_text(const char* text) {
    @autoreleasepool {
        if (!text) return false;
        NSString* s = [NSString stringWithUTF8String:text];
        if (!s) return false;
        __block BOOL ok = NO;
        zapp_clipboard_main(^(NSPasteboard* pb) {
            [pb clearContents];
            ok = [pb setString:s forType:NSPasteboardTypeString];
        });
        return ok == YES;
    }
}

// --- HTML ---

char* darwin_clipboard_read_html(void) {
    @autoreleasepool {
        __block char* result = NULL;
        zapp_clipboard_main(^(NSPasteboard* pb) {
            NSString* s = [pb stringForType:NSPasteboardTypeHTML];
            result = zapp_strdup_cstr(s);
        });
        return result;
    }
}

bool darwin_clipboard_write_html(const char* html) {
    @autoreleasepool {
        if (!html) return false;
        NSString* s = [NSString stringWithUTF8String:html];
        if (!s) return false;
        __block BOOL ok = NO;
        zapp_clipboard_main(^(NSPasteboard* pb) {
            [pb clearContents];
            ok = [pb setString:s forType:NSPasteboardTypeHTML];
        });
        return ok == YES;
    }
}

// --- Image (PNG) ---

bool darwin_clipboard_read_image_png(uint8_t** out_data, int32_t* out_len) {
    if (!out_data || !out_len) return false;
    @autoreleasepool {
        __block NSData* png = nil;
        zapp_clipboard_main(^(NSPasteboard* pb) {
            // Try PNG type first (common for screenshots).
            NSData* d = [pb dataForType:NSPasteboardTypePNG];
            if (d) { png = d; return; }
            // Fall back to TIFF → re-encode as PNG. Older copy paths
            // (Preview "Copy") and many screen-capture tools deposit
            // TIFF rather than PNG.
            NSData* tiff = [pb dataForType:NSPasteboardTypeTIFF];
            if (!tiff) return;
            NSBitmapImageRep* rep = [NSBitmapImageRep imageRepWithData:tiff];
            if (!rep) return;
            png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        });
        if (!png) return false;
        size_t len = png.length;
        uint8_t* buf = (uint8_t*)malloc(len > 0 ? len : 1);
        if (!buf) return false;
        memcpy(buf, png.bytes, len);
        *out_data = buf;
        *out_len = (int32_t)len;
        return true;
    }
}

bool darwin_clipboard_write_image_png(const uint8_t* data, int32_t len) {
    @autoreleasepool {
        if (!data || len <= 0) return false;
        NSData* nsData = [NSData dataWithBytes:data length:(NSUInteger)len];
        NSImage* img = [[NSImage alloc] initWithData:nsData];
        if (!img) return false;
        __block BOOL ok = NO;
        zapp_clipboard_main(^(NSPasteboard* pb) {
            [pb clearContents];
            ok = [pb writeObjects:@[img]];
        });
        return ok == YES;
    }
}

// --- Files ---

char* darwin_clipboard_read_files(void) {
    @autoreleasepool {
        __block NSArray<NSURL*>* urls = nil;
        zapp_clipboard_main(^(NSPasteboard* pb) {
            urls = [pb readObjectsForClasses:@[[NSURL class]]
                                     options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
        });
        NSMutableArray<NSString*>* paths = [NSMutableArray new];
        for (NSURL* u in urls) {
            NSString* p = [u path];
            if (p) [paths addObject:p];
        }
        NSData* json = [NSJSONSerialization dataWithJSONObject:paths options:0 error:nil];
        if (!json) {
            char* empty = (char*)malloc(3);
            if (empty) { empty[0] = '['; empty[1] = ']'; empty[2] = '\0'; }
            return empty;
        }
        size_t len = json.length;
        char* buf = (char*)malloc(len + 1);
        if (!buf) return NULL;
        memcpy(buf, json.bytes, len);
        buf[len] = '\0';
        return buf;
    }
}

// --- Format presence + clear ---

bool darwin_clipboard_has(const char* fmt) {
    if (!fmt || !fmt[0]) return false;
    @autoreleasepool {
        __block BOOL has = NO;
        zapp_clipboard_main(^(NSPasteboard* pb) {
            NSArray<NSPasteboardType>* types = pb.types ?: @[];
            if (strcmp(fmt, "text") == 0) {
                has = [types containsObject:NSPasteboardTypeString];
            } else if (strcmp(fmt, "html") == 0) {
                has = [types containsObject:NSPasteboardTypeHTML];
            } else if (strcmp(fmt, "image") == 0) {
                has = [types containsObject:NSPasteboardTypePNG] ||
                      [types containsObject:NSPasteboardTypeTIFF];
            } else if (strcmp(fmt, "files") == 0) {
                has = [types containsObject:NSPasteboardTypeFileURL];
            }
        });
        return has == YES;
    }
}

void darwin_clipboard_clear(void) {
    @autoreleasepool {
        zapp_clipboard_main(^(NSPasteboard* pb) {
            [pb clearContents];
        });
    }
}

// --- Bridge wire helpers (PNG ↔ base64) ---

char* darwin_clipboard_read_image_png_b64(void) {
    @autoreleasepool {
        uint8_t* data = NULL;
        int32_t len = 0;
        if (!darwin_clipboard_read_image_png(&data, &len) || !data || len <= 0) {
            if (data) free(data);
            return NULL;
        }
        // Hand the buffer to NSData with freeWhenDone so the encoding
        // step doesn't double-copy. NSData takes ownership.
        NSData* d = [NSData dataWithBytesNoCopy:data length:(NSUInteger)len freeWhenDone:YES];
        NSString* encoded = [d base64EncodedStringWithOptions:0];
        return zapp_strdup_cstr(encoded);
    }
}

bool darwin_clipboard_write_image_png_b64(const char* b64) {
    @autoreleasepool {
        if (!b64 || !b64[0]) return false;
        NSString* s = [NSString stringWithUTF8String:b64];
        if (!s) return false;
        NSData* d = [[NSData alloc] initWithBase64EncodedString:s
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!d || d.length == 0) return false;
        return darwin_clipboard_write_image_png((const uint8_t*)d.bytes, (int32_t)d.length);
    }
}
