import WebKit from "WebKit/WebKit.h";
import math from "std/math";
import { thread } from "std/thread";
import { WindowSize } from "../../events.zs";
import { WindowError } from "../../application-error.zs";
import { WindowSizeLimits } from "../../window-sizing.zs";

internal function applyMacOSSizeLimits(in window: WebKit.NSWindow, limits: WindowSizeLimits): void on thread.main {
  const minimum = window.contentMinSize;
  const maximum = window.contentMaxSize;
  const minWidth = match (limits.minWidth) { some(value) => f64(value); none => minimum.width; };
  const minHeight = match (limits.minHeight) { some(value) => f64(value); none => minimum.height; };
  const maxWidth = match (limits.maxWidth) { some(value) => f64(value); none => maximum.width; };
  const maxHeight = match (limits.maxHeight) { some(value) => f64(value); none => maximum.height; };
  window.contentMinSize = WebKit.NSMakeSize(minWidth, minHeight);
  window.contentMaxSize = WebKit.NSMakeSize(maxWidth, maxHeight);
}

internal function macOSWindowSize(in window: WebKit.NSWindow): WindowSize throws WindowError on thread.main {
  const content = window.contentView;
  if (content == null || content.bounds.size.width <= 0 || content.bounds.size.height <= 0) {
    throw WindowError({ id: "", message: "native window content is unavailable" });
  }
  return WindowSize({ width: macOSContentDimension(content.bounds.size.width),
    height: macOSContentDimension(content.bounds.size.height) });
}

internal function macOSWindowFrame(
  width: u32,
  height: u32
): WebKit.CGRect {
  return WebKit.NSMakeRect(
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
