// iOS clipboard — UIPasteboard. Mirrors darwin/clipboard.m's API
// surface using iOS-native types (UIImage / UIPasteboard / UTType).

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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

// UIPasteboard methods are documented main-thread-safe but we mirror
// macOS's main-thread-bounce for consistency — every native caller is
// either on main already (router) or on a worker/service thread.
typedef void (^ZappPasteboardBlock)(UIPasteboard*);
static void zapp_clipboard_main(ZappPasteboardBlock block) {
    if ([NSThread isMainThread]) {
        block([UIPasteboard generalPasteboard]);
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        block([UIPasteboard generalPasteboard]);
    });
}

// --- Text ---

char* darwin_clipboard_read_text(void) {
    @autoreleasepool {
        __block char* result = NULL;
        zapp_clipboard_main(^(UIPasteboard* pb) {
            result = zapp_strdup_cstr(pb.string);
        });
        return result;
    }
}

bool darwin_clipboard_write_text(const char* text) {
    @autoreleasepool {
        if (!text) return false;
        NSString* s = [NSString stringWithUTF8String:text];
        if (!s) return false;
        zapp_clipboard_main(^(UIPasteboard* pb) {
            pb.string = s;
        });
        return true;
    }
}

// --- HTML ---

char* darwin_clipboard_read_html(void) {
    @autoreleasepool {
        __block char* result = NULL;
        zapp_clipboard_main(^(UIPasteboard* pb) {
            // Try public.html first; fall back to public.rtf-html. The
            // dataForPasteboardType: form returns NSData; HTML clipboard
            // payloads are always UTF-8 strings.
            NSData* d = [pb dataForPasteboardType:@"public.html"];
            if (!d) d = [pb dataForPasteboardType:@"public.rtf-html"];
            if (!d) return;
            NSString* s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
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
        NSData* d = [s dataUsingEncoding:NSUTF8StringEncoding];
        if (!d) return false;
        zapp_clipboard_main(^(UIPasteboard* pb) {
            [pb setData:d forPasteboardType:@"public.html"];
        });
        return true;
    }
}

// --- Image (PNG) ---

bool darwin_clipboard_read_image_png(uint8_t** out_data, int32_t* out_len) {
    if (!out_data || !out_len) return false;
    @autoreleasepool {
        __block NSData* png = nil;
        zapp_clipboard_main(^(UIPasteboard* pb) {
            // Prefer raw PNG bytes if present (screenshots, web image
            // copies). Fall back to UIImage → PNG re-encode.
            NSData* d = [pb dataForPasteboardType:@"public.png"];
            if (d) { png = d; return; }
            UIImage* img = pb.image;
            if (!img) return;
            png = UIImagePNGRepresentation(img);
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
        UIImage* img = [UIImage imageWithData:nsData];
        if (!img) return false;
        zapp_clipboard_main(^(UIPasteboard* pb) {
            pb.image = img;
        });
        return true;
    }
}

// --- Files ---
//
// iOS pasteboard files: technically possible via UIPasteboard.URLs but
// only meaningful when items have file:// URLs. Most iOS-native
// "share" flows hand off file URLs through extension contexts, not
// pasteboard. Best-effort: read whatever URLs are there and filter to
// file scheme.

char* darwin_clipboard_read_files(void) {
    @autoreleasepool {
        __block NSArray<NSURL*>* urls = nil;
        zapp_clipboard_main(^(UIPasteboard* pb) {
            urls = pb.URLs ?: @[];
        });
        NSMutableArray<NSString*>* paths = [NSMutableArray new];
        for (NSURL* u in urls) {
            if ([u isFileURL]) {
                NSString* p = [u path];
                if (p) [paths addObject:p];
            }
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
        zapp_clipboard_main(^(UIPasteboard* pb) {
            if (strcmp(fmt, "text") == 0) {
                has = pb.hasStrings;
            } else if (strcmp(fmt, "html") == 0) {
                has = [pb containsPasteboardTypes:@[@"public.html", @"public.rtf-html"]];
            } else if (strcmp(fmt, "image") == 0) {
                has = pb.hasImages;
            } else if (strcmp(fmt, "files") == 0) {
                if (!pb.hasURLs) { has = NO; return; }
                for (NSURL* u in pb.URLs) {
                    if ([u isFileURL]) { has = YES; return; }
                }
            }
        });
        return has == YES;
    }
}

void darwin_clipboard_clear(void) {
    @autoreleasepool {
        zapp_clipboard_main(^(UIPasteboard* pb) {
            pb.items = @[];
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
