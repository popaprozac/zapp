import { WindowSize } from "./events.zs";
import { WindowError } from "./application-error.zs";

// Shared validation for native, ordinary frontend, and related windows.
internal readonly struct WindowSizeLimits {
  minWidth: Option<u32> = Option<u32>.none;
  minHeight: Option<u32> = Option<u32>.none;
  maxWidth: Option<u32> = Option<u32>.none;
  maxHeight: Option<u32> = Option<u32>.none;
}

function checkedDimension(value: u32, minimum: Option<u32>, maximum: Option<u32>): u32 throws WindowError {
  if (value == 0) throw WindowError({ id: "", message: "window dimensions must be positive" });
  const lower: u32 = match (minimum) { some(limit) => limit; none => 1; };
  const upper: u32 = match (maximum) { some(limit) => limit; none => 4294967295; };
  if (lower == 0 || upper == 0 || lower > upper) {
    throw WindowError({ id: "", message: "window size limits must be positive and minimum must not exceed maximum" });
  }
  if (value < lower) return lower;
  if (value > upper) return upper;
  return value;
}

internal function checkedWindowSize(size: WindowSize, limits: WindowSizeLimits): WindowSize throws WindowError {
  return WindowSize({
    width: try checkedDimension(size.width, limits.minWidth, limits.maxWidth),
    height: try checkedDimension(size.height, limits.minHeight, limits.maxHeight),
  });
}
