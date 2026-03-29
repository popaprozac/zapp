// macOS native dialogs — NSOpenPanel, NSSavePanel, NSAlert.
// Returns JSON result strings via static buffers.

#import <Cocoa/Cocoa.h>
#import "dialog.h"

static char dialog_result[8192];
static char dialog_args_buf[4096];

// --- Helpers ---

static NSDictionary* parse_json(const char* json) {
    if (!json || json[0] == '\0') return @{};
    NSData* data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

// Extract "a" (args) from full bridge message JSON
const char* darwin_dialog_extract_args(const char* full_json) {
    if (!full_json || full_json[0] == '\0') return "{}";
    NSDictionary* parsed = parse_json(full_json);
    id args = parsed[@"a"];
    if (!args || ![args isKindOfClass:[NSDictionary class]]) return "{}";
    NSData* data = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
    if (!data) return "{}";
    NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    strncpy(dialog_args_buf, [str UTF8String], sizeof(dialog_args_buf) - 1);
    return dialog_args_buf;
}

static void apply_filters(NSSavePanel* panel, NSArray* filters) {
    if (!filters || ![filters isKindOfClass:[NSArray class]] || filters.count == 0) return;
    NSMutableArray* extensions = [NSMutableArray new];
    for (NSDictionary* filter in filters) {
        NSArray* exts = filter[@"extensions"];
        if ([exts isKindOfClass:[NSArray class]]) {
            [extensions addObjectsFromArray:exts];
        }
    }
    if (extensions.count > 0) {
        [panel setAllowedFileTypes:extensions];
    }
}

// --- Open File ---

const char* darwin_dialog_open_file(const char* options_json) {
    @autoreleasepool {
        NSDictionary* opts = parse_json(options_json);
        NSOpenPanel* panel = [NSOpenPanel openPanel];

        NSString* title = opts[@"title"];
        if (title) [panel setTitle:title];

        NSString* defaultPath = opts[@"defaultPath"];
        if (defaultPath) [panel setDirectoryURL:[NSURL fileURLWithPath:defaultPath]];

        NSNumber* multiple = opts[@"multiple"];
        [panel setAllowsMultipleSelection:[multiple boolValue]];

        NSNumber* directory = opts[@"directory"];
        [panel setCanChooseDirectories:[directory boolValue]];
        [panel setCanChooseFiles:![directory boolValue]];

        apply_filters(panel, opts[@"filters"]);

        NSModalResponse response = [panel runModal];
        if (response != NSModalResponseOK) {
            snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
            return dialog_result;
        }

        // Build paths array
        int pos = 0;
        pos += snprintf(dialog_result + pos, sizeof(dialog_result) - pos, "{\"cancelled\":false,\"paths\":[");
        NSArray<NSURL*>* urls = [panel URLs];
        for (NSUInteger i = 0; i < urls.count; i++) {
            if (i > 0) pos += snprintf(dialog_result + pos, sizeof(dialog_result) - pos, ",");
            NSString* path = [urls[i] path];
            // Escape path for JSON
            NSString* escaped = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
            escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            pos += snprintf(dialog_result + pos, sizeof(dialog_result) - pos, "\"%s\"", [escaped UTF8String]);
        }
        pos += snprintf(dialog_result + pos, sizeof(dialog_result) - pos, "]}");
        return dialog_result;
    }
}

// --- Save File ---

const char* darwin_dialog_save_file(const char* options_json) {
    @autoreleasepool {
        NSDictionary* opts = parse_json(options_json);
        NSSavePanel* panel = [NSSavePanel savePanel];

        NSString* title = opts[@"title"];
        if (title) [panel setTitle:title];

        NSString* defaultPath = opts[@"defaultPath"];
        if (defaultPath) [panel setDirectoryURL:[NSURL fileURLWithPath:defaultPath]];

        NSString* defaultName = opts[@"defaultName"];
        if (defaultName) [panel setNameFieldStringValue:defaultName];

        apply_filters(panel, opts[@"filters"]);

        NSModalResponse response = [panel runModal];
        if (response != NSModalResponseOK) {
            snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
            return dialog_result;
        }

        NSString* path = [[panel URL] path];
        NSString* escaped = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":false,\"path\":\"%s\"}", [escaped UTF8String]);
        return dialog_result;
    }
}

// --- Message Dialog ---

const char* darwin_dialog_message(const char* options_json) {
    @autoreleasepool {
        NSDictionary* opts = parse_json(options_json);
        NSAlert* alert = [[NSAlert alloc] init];

        NSString* message = opts[@"message"];
        if (message) [alert setMessageText:message];

        NSString* title = opts[@"title"];
        if (title) [alert setInformativeText:title];

        NSString* kind = opts[@"kind"];
        if ([kind isEqualToString:@"warning"]) {
            [alert setAlertStyle:NSAlertStyleWarning];
        } else if ([kind isEqualToString:@"critical"]) {
            [alert setAlertStyle:NSAlertStyleCritical];
        } else {
            [alert setAlertStyle:NSAlertStyleInformational];
        }

        NSArray* buttons = opts[@"buttons"];
        if ([buttons isKindOfClass:[NSArray class]] && buttons.count > 0) {
            for (NSString* btn in buttons) {
                [alert addButtonWithTitle:btn];
            }
        } else {
            [alert addButtonWithTitle:@"OK"];
        }

        NSModalResponse response = [alert runModal];
        int buttonIndex = (int)(response - NSAlertFirstButtonReturn);
        snprintf(dialog_result, sizeof(dialog_result), "{\"button\":%d}", buttonIndex);
        return dialog_result;
    }
}

// --- Native API (typed params, zero JSON) ---

static char dialog_path_buf[4096];

const char* darwin_dialog_open_file_typed(const char* title, bool multiple, bool directory) {
    @autoreleasepool {
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        if (title && title[0]) [panel setTitle:[NSString stringWithUTF8String:title]];
        [panel setAllowsMultipleSelection:multiple];
        [panel setCanChooseDirectories:directory];
        [panel setCanChooseFiles:!directory];

        if ([panel runModal] != NSModalResponseOK || panel.URLs.count == 0) {
            dialog_path_buf[0] = '\0';
            return dialog_path_buf;
        }

        // Return first path (for multiple, caller can use the JSON API)
        NSString* path = [[panel URLs][0] path];
        strncpy(dialog_path_buf, [path UTF8String], sizeof(dialog_path_buf) - 1);
        return dialog_path_buf;
    }
}

const char* darwin_dialog_save_file_typed(const char* title, const char* default_name) {
    @autoreleasepool {
        NSSavePanel* panel = [NSSavePanel savePanel];
        if (title && title[0]) [panel setTitle:[NSString stringWithUTF8String:title]];
        if (default_name && default_name[0]) [panel setNameFieldStringValue:[NSString stringWithUTF8String:default_name]];

        if ([panel runModal] != NSModalResponseOK) {
            dialog_path_buf[0] = '\0';
            return dialog_path_buf;
        }

        NSString* path = [[panel URL] path];
        strncpy(dialog_path_buf, [path UTF8String], sizeof(dialog_path_buf) - 1);
        return dialog_path_buf;
    }
}

static NSAlert* build_alert(const char* message, const char* title, int style) {
    NSAlert* alert = [[NSAlert alloc] init];
    if (message && message[0]) [alert setMessageText:[NSString stringWithUTF8String:message]];
    if (title && title[0]) [alert setInformativeText:[NSString stringWithUTF8String:title]];
    if (style == 1) [alert setAlertStyle:NSAlertStyleWarning];
    else if (style == 2) [alert setAlertStyle:NSAlertStyleCritical];
    else [alert setAlertStyle:NSAlertStyleInformational];
    return alert;
}

int darwin_dialog_message_typed(const char* message, const char* title, int style) {
    @autoreleasepool {
        NSAlert* alert = build_alert(message, title, style);
        [alert addButtonWithTitle:@"OK"];
        return (int)([alert runModal] - NSAlertFirstButtonReturn);
    }
}

int darwin_dialog_message_buttons_typed(const char* message, const char* title, int style,
                                        const char* btn1, const char* btn2, const char* btn3) {
    @autoreleasepool {
        NSAlert* alert = build_alert(message, title, style);
        if (btn1 && btn1[0]) [alert addButtonWithTitle:[NSString stringWithUTF8String:btn1]];
        if (btn2 && btn2[0]) [alert addButtonWithTitle:[NSString stringWithUTF8String:btn2]];
        if (btn3 && btn3[0]) [alert addButtonWithTitle:[NSString stringWithUTF8String:btn3]];
        if (!btn1 || !btn1[0]) [alert addButtonWithTitle:@"OK"];
        return (int)([alert runModal] - NSAlertFirstButtonReturn);
    }
}
