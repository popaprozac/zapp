// iOS filesystem — port of darwin/fs.m. NSFileManager works the same
// on iOS; the path-var resolver maps to iOS-appropriate sandbox dirs:
//   $home / $userData / $appData / $documents → app container Documents
//   $cache → app container Caches
//   $temp → NSTemporaryDirectory
//   $downloads / $desktop → no iOS equivalent (return Documents as a
//     reasonable fallback so apps don't fail on a name that the
//     allowlist might use)
//
// The framework's allowlist enforcement (in native/fs/fs.zc) is
// platform-agnostic — only the resolution differs.

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static char fs_path_var_buf[2048];

const char* darwin_fs_path_var(const char* name) {
    @autoreleasepool {
        if (!name || !name[0]) { fs_path_var_buf[0] = '\0'; return fs_path_var_buf; }
        NSString* key = [NSString stringWithUTF8String:name];
        NSSearchPathDirectory which;

        if ([key isEqualToString:@"home"] ||
            [key isEqualToString:@"userData"] ||
            [key isEqualToString:@"appData"] ||
            [key isEqualToString:@"documents"] ||
            [key isEqualToString:@"downloads"] ||  // no iOS equivalent — fall back
            [key isEqualToString:@"desktop"]) {
            which = NSDocumentDirectory;
        } else if ([key isEqualToString:@"cache"]) {
            which = NSCachesDirectory;
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
        strncpy(fs_path_var_buf, [paths[0] UTF8String], sizeof(fs_path_var_buf) - 1);
        fs_path_var_buf[sizeof(fs_path_var_buf) - 1] = '\0';
        return fs_path_var_buf;
    }
}

char* darwin_fs_read_file(const char* path) {
    @autoreleasepool {
        if (!path) return NULL;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSError* err = nil;
        NSString* contents = [NSString stringWithContentsOfFile:nsPath encoding:NSUTF8StringEncoding error:&err];
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
        NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
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
        NSData* ns = [NSData dataWithBytes:data length:(NSUInteger)len];
        return [ns writeToFile:[NSString stringWithUTF8String:path] atomically:YES] == YES;
    }
}

bool darwin_fs_append_file(const char* path, const char* data) {
    @autoreleasepool {
        if (!path || !data) return false;
        NSString* nsPath = [NSString stringWithUTF8String:path];
        NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:nsPath];
        if (!fh) return darwin_fs_write_file(path, data);
        [fh seekToEndOfFile];
        [fh writeData:[[NSString stringWithUTF8String:data] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
        return true;
    }
}

bool darwin_fs_exists(const char* path) {
    @autoreleasepool {
        return path ? [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:path]] : false;
    }
}

bool darwin_fs_stat(const char* path, int64_t* out_size, int64_t* out_mtime_ms, int32_t* out_kind) {
    @autoreleasepool {
        if (!path || !out_size || !out_mtime_ms || !out_kind) return false;
        NSError* err = nil;
        NSDictionary* attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:[NSString stringWithUTF8String:path] error:&err];
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
        NSArray<NSString*>* entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:nsPath error:nil];
        if (!entries) return NULL;
        NSMutableArray* out = [NSMutableArray new];
        for (NSString* name in entries) {
            NSString* child = [nsPath stringByAppendingPathComponent:name];
            NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:child error:nil];
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

bool darwin_fs_mkdir(const char* path, bool recursive) {
    @autoreleasepool {
        if (!path) return false;
        NSError* err = nil;
        return [[NSFileManager defaultManager]
            createDirectoryAtPath:[NSString stringWithUTF8String:path]
            withIntermediateDirectories:recursive attributes:nil error:&err] == YES;
    }
}

bool darwin_fs_remove(const char* path) {
    @autoreleasepool {
        if (!path) return false;
        NSError* err = nil;
        return [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:path] error:&err] == YES;
    }
}

bool darwin_fs_rmdir(const char* path, bool recursive) {
    @autoreleasepool {
        if (!path) return false;
        NSFileManager* fm = [NSFileManager defaultManager];
        NSString* p = [NSString stringWithUTF8String:path];
        if (!recursive) {
            NSArray* contents = [fm contentsOfDirectoryAtPath:p error:nil];
            if (contents.count > 0) return false;
        }
        return [fm removeItemAtPath:p error:nil] == YES;
    }
}

bool darwin_fs_rename(const char* from, const char* to) {
    @autoreleasepool {
        if (!from || !to) return false;
        return [[NSFileManager defaultManager]
            moveItemAtPath:[NSString stringWithUTF8String:from]
                    toPath:[NSString stringWithUTF8String:to] error:nil] == YES;
    }
}

bool darwin_fs_copy(const char* from, const char* to) {
    @autoreleasepool {
        if (!from || !to) return false;
        return [[NSFileManager defaultManager]
            copyItemAtPath:[NSString stringWithUTF8String:from]
                    toPath:[NSString stringWithUTF8String:to] error:nil] == YES;
    }
}
