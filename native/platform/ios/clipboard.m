// iOS clipboard — UIPasteboard. Mirrors darwin/clipboard.m's API
// surface with iOS equivalents (UIPasteboard.generalPasteboard).
// Phase 1: text + has + clear are wired; HTML / image / files are
// stubbed (UIPasteboard's representations differ enough that the
// straight port has gotchas — phase 2 fills these in).

#import <UIKit/UIKit.h>
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

char* darwin_clipboard_read_text(void) {
    @autoreleasepool {
        UIPasteboard* pb = [UIPasteboard generalPasteboard];
        return zapp_strdup_cstr(pb.string);
    }
}

bool darwin_clipboard_write_text(const char* text) {
    @autoreleasepool {
        if (!text) return false;
        NSString* s = [NSString stringWithUTF8String:text];
        if (!s) return false;
        [UIPasteboard generalPasteboard].string = s;
        return true;
    }
}

char* darwin_clipboard_read_html(void) { return NULL; }    // Phase 2
bool darwin_clipboard_write_html(const char* html) { (void)html; return false; }
bool darwin_clipboard_read_image_png(uint8_t** out_data, int32_t* out_len) {
    (void)out_data; (void)out_len; return false;
}
bool darwin_clipboard_write_image_png(const uint8_t* data, int32_t len) {
    (void)data; (void)len; return false;
}
char* darwin_clipboard_read_files(void) {
    char* empty = (char*)malloc(3);
    if (empty) { empty[0]='['; empty[1]=']'; empty[2]='\0'; }
    return empty;
}
char* darwin_clipboard_read_image_png_b64(void) { return NULL; }
bool darwin_clipboard_write_image_png_b64(const char* b64) { (void)b64; return false; }

bool darwin_clipboard_has(const char* fmt) {
    if (!fmt || !fmt[0]) return false;
    @autoreleasepool {
        UIPasteboard* pb = [UIPasteboard generalPasteboard];
        if (strcmp(fmt, "text") == 0) return pb.hasStrings;
        if (strcmp(fmt, "image") == 0) return pb.hasImages;
        if (strcmp(fmt, "files") == 0) return pb.hasURLs;
        return false;
    }
}

void darwin_clipboard_clear(void) {
    [UIPasteboard generalPasteboard].items = @[];
}
