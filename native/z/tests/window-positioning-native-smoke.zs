import WebKit from "WebKit/WebKit.h";
import console from "std/console";
import objc from "std/objc";
import { thread } from "std/thread";
import { WindowPosition } from "../framework/window-positioning.zs";
import { WindowError } from "../framework/application-error.zs";
import { MacOSWindow, requestWindowSize, requestWindowPosition, requestWindowCenter,
  applyPendingWindowGeometry } from "../framework/platform/macos/window-resize.zs";
import { macOSWindowPosition, macOSWindowSize, macOSPrimaryScreen, positionFromMacOSFrame,
  positionedMacOSFrame, centeredMacOSFrame } from "../framework/platform/macos/window-geometry.zs";

struct Lifetime on thread.main {
  window: MacOSWindow;
  deinit { this.window.close(); }
}

class MoveRequest on thread.main implements WebKit.NSWindowDelegate {
  window: MacOSWindow;
  requested: boolean;
  function didMove(inout this, in notification: WebKit.NSNotification): void as "windowDidMove:" {
    if (this.requested) return;
    this.requested = true;
    match (attempt requestWindowPosition(this.window, WindowPosition({ x: 240, y: 160 }))) {
      success => {} failure(_) => {}
    }
  }
}

function near(left: f64, right: f64): boolean { return left - right < 1 && right - left < 1; }

function verify(): i32 throws WindowError on thread.main {
  // Synthetic desktops cover negative coordinates and an offset primary origin.
  const primaryFrame = WebKit.NSMakeRect(100, 200, 1600, 1000);
  const original = WebKit.NSMakeRect(-300.5, 1350.25, 400, 300);
  const logical = positionFromMacOSFrame(original, primaryFrame);
  if (logical.x != -400.5 || logical.y != -450.25) return 1;
  const roundTrip = positionedMacOSFrame(original, logical, primaryFrame);
  if (roundTrip.origin.x != original.origin.x || roundTrip.origin.y != original.origin.y) return 2;
  const centered = centeredMacOSFrame(original, WebKit.NSMakeRect(-1200, -300, 1000, 800));
  if (centered.origin.x != -900 || centered.origin.y != -50) return 3;
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyAccessory);
  app.finishLaunching();
  const primary = macOSPrimaryScreen();
  if (primary == null) return 4;
  const style = WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable;
  const window = new MacOSWindow(WebKit.NSMakeRect(100, 100, 320, 240), style);
  const lifetime = Lifetime({ window });
  // Neither move nor center reveals a hidden, non-resizable window.
  try requestWindowPosition(window, WindowPosition({ x: 180.5, y: 130.25 }));
  const measured = try macOSWindowPosition(in window);
  if (!near(measured.x, 180.5) || !near(measured.y, 130.25) || window.visible) return 5;
  try requestWindowCenter(window);
  const screen = window.screen;
  const workArea = screen == null ? primary.visibleFrame : screen.visibleFrame;
  const expected = centeredMacOSFrame(window.frame, workArea);
  if (!near(window.frame.origin.x, expected.origin.x) || !near(window.frame.origin.y, expected.origin.y) || window.visible) return 6;
  window.setSystemResize(true);
  requestWindowSize(window, 450, 310);
  try requestWindowPosition(window, WindowPosition({ x: 200, y: 140 }));
  try requestWindowCenter(window);
  try requestWindowPosition(window, WindowPosition({ x: 220, y: 150 }));
  if (!near(window.frame.origin.x, expected.origin.x)) return 7;
  window.setSystemResize(false);
  applyPendingWindowGeometry(window);
  const restored = try macOSWindowPosition(in window);
  const restoredSize = try macOSWindowSize(in window);
  if (!near(restored.x, 220) || !near(restored.y, 150) || restoredSize.width != 450 || restoredSize.height != 310) return 8;
  // Center is an intent: calculate it with the restored/requested size.
  window.setSystemResize(true);
  try requestWindowCenter(window);
  requestWindowSize(window, 500, 320);
  window.setSystemResize(false);
  applyPendingWindowGeometry(window);
  const centeredNewSize = centeredMacOSFrame(window.frame, workArea);
  if (!near(window.frame.origin.x, centeredNewSize.origin.x) || !near(window.frame.origin.y, centeredNewSize.origin.y)) return 9;
  const zoomable = new MacOSWindow(WebKit.NSMakeRect(150, 150, 350, 250), style | WebKit.NSWindowStyleMaskResizable);
  const zoomLifetime = Lifetime({ window: zoomable });
  zoomable.zoom(null);
  if (!zoomable.zoomed) return 10;
  const maximized = zoomable.frame;
  try requestWindowPosition(zoomable, WindowPosition({ x: 200, y: 130 }));
  requestWindowSize(zoomable, 420, 300);
  if (zoomable.frame.origin.x != maximized.origin.x || zoomable.frame.size.width != maximized.size.width) return 11;
  zoomable.zoom(null);
  applyPendingWindowGeometry(zoomable);
  const ordinary = try macOSWindowPosition(in zoomable);
  const ordinarySize = try macOSWindowSize(in zoomable);
  if (!near(ordinary.x, 200) || !near(ordinary.y, 130) || ordinarySize.width != 420 || ordinarySize.height != 300) return 12;
  const observer = new MoveRequest({ window, requested: false });
  const delegate = objc.adapt<WebKit.NSWindowDelegate>(observer);
  window.delegate = delegate;
  try requestWindowPosition(window, WindowPosition({ x: 210, y: 140 }));
  window.delegate = null;
  const during = try macOSWindowPosition(in window);
  if (!observer.requested || !near(during.x, 210)) return 13;
  applyPendingWindowGeometry(window);
  const after = try macOSWindowPosition(in window);
  if (!near(after.x, 240) || !near(after.y, 160)) return 14;
  window.setSystemResize(true);
  try requestWindowCenter(window);
  window.close();
  window.setSystemResize(false);
  applyPendingWindowGeometry(window);
  match (window.takePendingGeometry()) { some(_) => return 15; none => {} }
  if (window.visible) return 16;
  console.log("global coordinates, geometric centering, fixed-window moves, combined deferred geometry, native zoom, reentrancy and close cleanup passed");
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt verify()) { success(code) => code; failure(_) => 90; };
}
