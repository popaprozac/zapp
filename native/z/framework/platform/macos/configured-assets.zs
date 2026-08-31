import embed from "std/embed";
import Foundation from "Foundation/Foundation.h";

internal struct ConfiguredEmbeddedAsset {
  bytes: embed.StaticBytes;
  originalLength: usize;
  compressed: boolean;
}

internal function configuredEmbeddedAssetCount(): usize {
  return 0;
}

internal function configuredEmbeddedAssetPathAtIndex(
  index: usize
): Foundation.NSString | null {
  return null;
}

internal function configuredEmbeddedAssetAtIndex(
  index: usize
): Option<ConfiguredEmbeddedAsset> {
  return Option.none;
}
