// macOS filesystem primitives — POSIX + Foundation.
// Called by Zen-C's FsManager after allowlist enforcement and path
// expansion. No allowlist checks happen here.

#import <Foundation/Foundation.h>
#import "fs.h"

// --- Path variables ---

static char fs_path_var_buf[2048];

const char* darwin_fs_path_var(const char* name) {
    @autoreleasepool {
        if (!name || !name[0]) { fs_path_var_buf[0] = '\0'; return fs_path_var_buf; }
        NSString* key = [NSString stringWithUTF8String:name];
        NSSearchPathDirectory which;
        BOOL useBundleSuffix = NO;

        if ([key isEqualToString:@"userData"] || [key isEqualToString:@"appData"]) {
            which = NSApplicationSupportDirectory;
            useBundleSuffix = YES;
        } else if ([key isEqualToString:@"cache"]) {
            which = NSCachesDirectory;
            useBundleSuffix = YES;
        } else if ([key isEqualToString:@"documents"]) {
            which = NSDocumentDirectory;
        } else if ([key isEqualToString:@"downloads"]) {
            which = NSDownloadsDirectory;
        } else if ([key isEqualToString:@"home"]) {
            NSString* home = NSHomeDirectory();
            strncpy(fs_path_var_buf, [home UTF8String], sizeof(fs_path_var_buf) - 1);
            fs_path_var_buf[sizeof(fs_path_var_buf) - 1] = '\0';
            return fs_path_var_buf;
        } else if ([key isEqualToString:@"temp"]) {
            NSString* tmp = NSTemporaryDirectory();
            if (tmp.length > 0 && [tmp hasSuffix:@"/"]) tmp = [tmp substringToIndex:tmp.length - 1];
            strncpy(fs_path_var_buf, [tmp UTF8String], sizeof(fs_path_var_buf) - 1);
            fs_path_var_buf[sizeof(fs_path_var_buf) - 1] = '\0';
            return fs_path_var_buf;
        } else {
            fs_path_var_buf[0] = '\0';
            return fs_path_var_buf;
        }

        NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(which, NSUserDomainMask, YES);
        if (paths.count == 0) { fs_path_var_buf[0] = '\0'; return fs_path_var_buf; }
        NSString* base = paths[0];

        if (useBundleSuffix) {
            // Namespace per-app so two apps don't collide in ~/Library/Application Support/
            NSString* bundleId = [[NSBundle mainBundle] bundleIdentifier];
            if (!bundleId.length) bundleId = [[NSProcessInfo processInfo] processName];
            if (bundleId.length) base = [base stringByAppendingPathComponent:bundleId];
            // Create on demand so apps don't have to mkdir it themselves
            [[NSFileManager defaultManager] createDirectoryAtPath:base
                                      withIntermediateDirectories:YES
                                                       attributes:nil error:nil];
        }

        strncpy(fs_path_var_buf, [base UTF8String], sizeof(fs_path_var_buf) - 1);
        fs_path_var_buf[sizeof(fs_path_var_buf) - 1] = '\0';
        return fs_path_var_buf;
    }
}

// --- Read ---

char* darwin_fs_read_file(const char* path) {
    @autoreleasepool {
        if (!path) return NULL;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSError* err = nil;
        NSString* contents = [NSString stringWithContentsOfFile:nsPath
                                                       encoding:NSUTF8StringEncoding error:&err];
        if (!contents) return NULL;
        const char* utf8 = [contents UTF8String];
        if (!utf8) return NULL;
        size_t len = strlen(utf8);
        char* buf = (char*)malloc(len + 1);
        if (!buf) return NULL;
        memcpy(buf, utf8, len + 1);
        return buf;
    }
}

bool darwin_fs_read_bytes(const char* path, uint8_t** out_data, int32_t* out_len) {
    @autoreleasepool {
        if (!path || !out_data || !out_len) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSData* data = [NSData dataWithContentsOfFile:nsPath];
        if (!data) return false;
        size_t len = data.length;
        uint8_t* buf = (uint8_t*)malloc(len > 0 ? len : 1);
        if (!buf) return false;
        memcpy(buf, data.bytes, len);
        *out_data = buf;
        *out_len = (int32_t)len;
        return true;
    }
}

// --- Write ---

bool darwin_fs_write_file(const char* path, const char* data) {
    @autoreleasepool {
        if (!path || !data) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSString* nsData = [NSString stringWithUTF8String:data];
        NSError* err = nil;
        return [nsData writeToFile:nsPath atomically:YES encoding:NSUTF8StringEncoding error:&err] == YES;
    }
}

bool darwin_fs_write_bytes(const char* path, const uint8_t* data, int32_t len) {
    @autoreleasepool {
        if (!path || (len > 0 && !data)) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSData* ns = [NSData dataWithBytes:data length:(NSUInteger)len];
        return [ns writeToFile:nsPath atomically:YES] == YES;
    }
}

bool darwin_fs_append_file(const char* path, const char* data) {
    @autoreleasepool {
        if (!path || !data) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:nsPath];
        if (!fh) {
            // File doesn't exist yet — create it.
            return darwin_fs_write_file(path, data);
        }
        [fh seekToEndOfFile];
        NSData* bytes = [[NSString stringWithUTF8String:data] dataUsingEncoding:NSUTF8StringEncoding];
        [fh writeData:bytes];
        [fh closeFile];
        return true;
    }
}

// --- Metadata ---

bool darwin_fs_exists(const char* path) {
    @autoreleasepool {
        if (!path) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        return [[NSFileManager defaultManager] fileExistsAtPath:nsPath];
    }
}

bool darwin_fs_stat(const char* path, int64_t* out_size, int64_t* out_mtime_ms, int32_t* out_kind) {
    @autoreleasepool {
        if (!path || !out_size || !out_mtime_ms || !out_kind) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSError* err = nil;
        NSDictionary<NSFileAttributeKey, id>* attrs =
            [[NSFileManager defaultManager] attributesOfItemAtPath:nsPath error:&err];
        if (!attrs) return false;
        *out_size = [[attrs objectForKey:NSFileSize] longLongValue];
        NSDate* mtime = [attrs objectForKey:NSFileModificationDate];
        *out_mtime_ms = mtime ? (int64_t)([mtime timeIntervalSince1970] * 1000.0) : 0;
        NSString* type = [attrs objectForKey:NSFileType];
        if ([type isEqualToString:NSFileTypeRegular]) *out_kind = 0;
        else if ([type isEqualToString:NSFileTypeDirectory]) *out_kind = 1;
        else if ([type isEqualToString:NSFileTypeSymbolicLink]) *out_kind = 2;
        else *out_kind = 3;
        return true;
    }
}

char* darwin_fs_read_dir(const char* path) {
    @autoreleasepool {
        if (!path) return NULL;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSError* err = nil;
        NSArray<NSString*>* entries =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:nsPath error:&err];
        if (!entries) return NULL;

        NSMutableArray* out = [NSMutableArray arrayWithCapacity:entries.count];
        for (NSString* name in entries) {
            NSString* child = [nsPath stringByAppendingPathComponent:name];
            NSDictionary* attrs =
                [[NSFileManager defaultManager] attributesOfItemAtPath:child error:nil];
            NSString* type = attrs ? [attrs objectForKey:NSFileType] : nil;
            int kind = 3;
            if ([type isEqualToString:NSFileTypeRegular]) kind = 0;
            else if ([type isEqualToString:NSFileTypeDirectory]) kind = 1;
            else if ([type isEqualToString:NSFileTypeSymbolicLink]) kind = 2;
            [out addObject:@{ @"name": name, @"kind": @(kind) }];
        }
        NSData* json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        if (!json) return NULL;
        size_t len = json.length;
        char* buf = (char*)malloc(len + 1);
        if (!buf) return NULL;
        memcpy(buf, json.bytes, len);
        buf[len] = '\0';
        return buf;
    }
}

// --- Mutations ---

bool darwin_fs_mkdir(const char* path, bool recursive) {
    @autoreleasepool {
        if (!path) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSError* err = nil;
        return [[NSFileManager defaultManager] createDirectoryAtPath:nsPath
                                         withIntermediateDirectories:recursive
                                                          attributes:nil error:&err] == YES;
    }
}

bool darwin_fs_remove(const char* path) {
    @autoreleasepool {
        if (!path) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSError* err = nil;
        return [[NSFileManager defaultManager] removeItemAtPath:nsPath error:&err] == YES;
    }
}

bool darwin_fs_rmdir(const char* path, bool recursive) {
    @autoreleasepool {
        if (!path) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSFileManager* fm = [NSFileManager defaultManager];
        // Guard: fail fast if non-recursive and dir is not empty.
        if (!recursive) {
            NSArray* contents = [fm contentsOfDirectoryAtPath:nsPath error:nil];
            if (contents.count > 0) return false;
        }
        NSError* err = nil;
        return [fm removeItemAtPath:nsPath error:&err] == YES;
    }
}

bool darwin_fs_rename(const char* from, const char* to) {
    @autoreleasepool {
        if (!from || !to) return false;
        NSString* nsFrom = [NSString stringWithUTF8String:from];
        NSString* nsTo = [NSString stringWithUTF8String:to];
        NSError* err = nil;
        return [[NSFileManager defaultManager] moveItemAtPath:nsFrom toPath:nsTo error:&err] == YES;
    }
}

bool darwin_fs_copy(const char* from, const char* to) {
    @autoreleasepool {
        if (!from || !to) return false;
        NSString* nsFrom = [NSString stringWithUTF8String:from];
        NSString* nsTo = [NSString stringWithUTF8String:to];
        NSError* err = nil;
        return [[NSFileManager defaultManager] copyItemAtPath:nsFrom toPath:nsTo error:&err] == YES;
    }
}
