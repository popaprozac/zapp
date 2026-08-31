#import <Foundation/Foundation.h>
#import <compression.h>

#import "zapp_desktop.h"

#include <stdint.h>
#include <stdlib.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
  const char *path;
  const uint8_t *data;
  size_t length;
  size_t original_length;
  int is_brotli;
} ZAppDesktopAsset;

extern const ZAppDesktopAsset zapp_desktop_assets[];
extern const size_t zapp_desktop_assets_count;

@implementation ZAppDesktopBridge (Assets)

+ (NSUInteger)embeddedAssetCount {
  return zapp_desktop_assets_count;
}

+ (nullable NSString *)embeddedAssetPathAtIndex:(NSUInteger)index {
  if (index >= zapp_desktop_assets_count) return nil;
  return [NSString stringWithUTF8String:zapp_desktop_assets[index].path];
}

+ (nullable NSData *)embeddedAssetDataAtIndex:(NSUInteger)index {
  if (index >= zapp_desktop_assets_count) return nil;
  const ZAppDesktopAsset *asset = &zapp_desktop_assets[index];
  if (!asset->is_brotli) {
    return [NSData dataWithBytesNoCopy:(void *)asset->data
                               length:asset->length
                         freeWhenDone:NO];
  }
  if (asset->original_length == 0) return [NSData data];
  uint8_t *decoded = malloc(asset->original_length);
  if (decoded == NULL) return nil;
  size_t length = compression_decode_buffer(
    decoded,
    asset->original_length,
    asset->data,
    asset->length,
    NULL,
    COMPRESSION_BROTLI
  );
  if (length != asset->original_length) {
    free(decoded);
    return nil;
  }
  return [NSData dataWithBytesNoCopy:decoded length:length freeWhenDone:YES];
}

@end

NS_ASSUME_NONNULL_END
