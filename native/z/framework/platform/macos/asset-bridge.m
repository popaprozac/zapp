#import <Foundation/Foundation.h>
#import <compression.h>

#import "zapp_desktop.h"

#include <stdint.h>
#include <stdlib.h>

NS_ASSUME_NONNULL_BEGIN

@implementation ZAppDesktopBridge (Assets)

+ (nullable NSData *)decodeBrotliData:(NSData *)data
                       originalLength:(NSUInteger)originalLength {
  if (originalLength == 0) return [NSData data];
  uint8_t *decoded = malloc(originalLength);
  if (decoded == NULL) return nil;
  size_t length = compression_decode_buffer(
    decoded,
    originalLength,
    data.bytes,
    data.length,
    NULL,
    COMPRESSION_BROTLI
  );
  if (length != originalLength) {
    free(decoded);
    return nil;
  }
  return [NSData dataWithBytesNoCopy:decoded length:length freeWhenDone:YES];
}

@end

NS_ASSUME_NONNULL_END
