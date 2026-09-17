import WebKit from "WebKit/WebKit.h";
import math from "std/math";
import { thread } from "std/thread";
import { WindowSize } from "../../events.zs";
import { WindowError } from "../../application-error.zs";
import { WindowSizeLimits } from "../../window-sizing.zs";
import { WindowPosition } from "../../window-positioning.zs";
import { Bounds, Display } from "../../window-display.zs";

internal readonly struct WindowGeometryRequest {
  resize: boolean;
  width: f64;
  height: f64;
  reposition: boolean;
  center: boolean;
  x: f64;
  y: f64;
}

// mainScreen follows the key window, not the coordinate system's primary screen.
internal function macOSPrimaryScreen(): WebKit.NSScreen | null on thread.main {
  const first = WebKit.NSScreen.screens.firstObject;
  if (first instanceof WebKit.NSScreen) return first;
  return null;
}

internal function positionFromMacOSFrame(frame: WebKit.CGRect, primary: WebKit.CGRect): WindowPosition {
  return WindowPosition({ x: frame.origin.x - primary.origin.x,
    y: primary.origin.y + primary.size.height - frame.origin.y - frame.size.height });
}

internal function boundsFromMacOSFrame(frame: WebKit.CGRect, primary: WebKit.CGRect): Bounds {
  const position = positionFromMacOSFrame(frame, primary);
  return Bounds({ x: position.x, y: position.y, width: frame.size.width, height: frame.size.height });
}

internal function macOSWindowBounds(in window: WebKit.NSWindow): Bounds throws WindowError on thread.main {
  const primary = macOSPrimaryScreen();
  if (primary == null) throw WindowError({ id: "", message: "no primary display is available" });
  return boundsFromMacOSFrame(window.frame, primary.frame);
}

internal function macOSWindowDisplay(in window: WebKit.NSWindow): Option<Display> throws WindowError on thread.main {
  // AppKit selects the screen containing most of the frame, or nil offscreen.
  // Unlike center(), this measurement must not invent a primary-screen fallback.
  const screen = window.screen;
  if (screen == null) return Option<Display>.none;
  const primary = macOSPrimaryScreen();
  if (primary == null) throw WindowError({ id: "", message: "no primary display is available" });
  const key = WebKit.NSString.stringWithUTF8String("NSScreenNumber");
  if (key == null) throw WindowError({ id: "", message: "native display identity key is unavailable" });
  const number = screen.deviceDescription.objectForKey(key);
  if (!(number instanceof WebKit.NSNumber)) {
    throw WindowError({ id: "", message: "native display identity is unavailable" });
  }
  const nativeId = number.unsignedIntValue;
  return Option.some(Display({ id: `${nativeId}`,
    bounds: boundsFromMacOSFrame(screen.frame, primary.frame),
    workArea: boundsFromMacOSFrame(screen.visibleFrame, primary.frame),
    scaleFactor: screen.backingScaleFactor, isPrimary: screen == primary }));
}

internal function positionedMacOSFrame(frame: WebKit.CGRect, position: WindowPosition, primary: WebKit.CGRect): WebKit.CGRect {
  return WebKit.NSMakeRect(primary.origin.x + position.x,
    primary.origin.y + primary.size.height - position.y - frame.size.height,
    frame.size.width, frame.size.height);
}

internal function centeredMacOSFrame(frame: WebKit.CGRect, workArea: WebKit.CGRect): WebKit.CGRect {
  return WebKit.NSMakeRect(workArea.origin.x + (workArea.size.width - frame.size.width) / 2,
    workArea.origin.y + (workArea.size.height - frame.size.height) / 2,
    frame.size.width, frame.size.height);
}

internal function macOSWindowPosition(in window: WebKit.NSWindow): WindowPosition throws WindowError on thread.main {
  const primary = macOSPrimaryScreen();
  if (primary == null) throw WindowError({ id: "", message: "no primary display is available" });
  return positionFromMacOSFrame(window.frame, primary.frame);
}

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
