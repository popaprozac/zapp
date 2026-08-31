import native from "zapp_desktop.h";
import math from "std/math";

internal function macOSWindowFrame(
  width: u32,
  height: u32
): native.CGRect {
  return native.NSMakeRect(
    0.0,
    0.0,
    f64(width),
    f64(height)
  );
}

internal function macOSContentDimension(value: f64): u32 {
  if (value <= 0.0) return 0;
  if (value >= 4294967295.0) return 4294967295;
  return u32(math.trunc(value));
}
