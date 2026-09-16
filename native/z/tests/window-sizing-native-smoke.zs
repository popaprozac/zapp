import WebKit from "WebKit/WebKit.h";
import console from "std/console";
import objc from "std/objc";
import { thread } from "std/thread";
import { WindowError } from "../framework/application-error.zs";
import { WindowSizeLimits } from "../framework/window-sizing.zs";
import { MacOSWindow, requestWindowSize, applyPendingWindowSize } from "../framework/platform/macos/window-resize.zs";
import { macOSWindowSize, applyMacOSSizeLimits } from "../framework/platform/macos/window-geometry.zs";

struct Lifetime on thread.main {
  window: MacOSWindow;
  deinit { this.window.close(); }
}

class ResizeRequest on thread.main implements WebKit.NSWindowDelegate {
  window: MacOSWindow;
  requested: boolean;
  function didResize(inout this, in notification: WebKit.NSNotification): void as "windowDidResize:" {
    if (this.requested) return;
    this.requested = true;
    requestWindowSize(this.window, 550, 350);
  }
}

function verify(): i32 throws WindowError on thread.main {
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyAccessory);
  app.finishLaunching();
  // Hidden and fixed for user resizing: application sizing must still work.
  const style = WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable;
  const window = new MacOSWindow(WebKit.NSMakeRect(200, 300, 420, 280), style);
  const lifetime = Lifetime({ window });
  applyMacOSSizeLimits(in window, WindowSizeLimits({ minWidth: Option.some(u32(300)),
    minHeight: Option.some(u32(200)), maxWidth: Option.some(u32(900)), maxHeight: Option.some(u32(700)) }));
  if (window.contentMinSize.width != 300 || window.contentMaxSize.height != 700) return 1;
  const original = window.frame;
  requestWindowSize(window, 600, 400);
  const size = try macOSWindowSize(in window);
  if (size.width != 600 || size.height != 400) return 2;
  const updated = window.frame;
  if (updated.origin.x != original.origin.x
    || updated.origin.y + updated.size.height != original.origin.y + original.size.height) return 3;
  // A native fullscreen transition owns geometry. Latest request wins afterward.
  window.setSystemResize(true);
  requestWindowSize(window, 650, 450);
  requestWindowSize(window, 700, 500);
  const deferred = try macOSWindowSize(in window);
  if (deferred.width != 600 || deferred.height != 400) return 4;
  window.setSystemResize(false);
  applyPendingWindowSize(window);
  const restored = try macOSWindowSize(in window);
  if (restored.width != 700 || restored.height != 500) return 5;
  // Overlay content uses the same content-size contract, not outer frame height.
  const inset = new MacOSWindow(WebKit.NSMakeRect(100, 100, 400, 300), style | WebKit.NSWindowStyleMaskFullSizeContentView);
  const insetLifetime = Lifetime({ window: inset });
  requestWindowSize(inset, 480, 360);
  const insetSize = try macOSWindowSize(in inset);
  if (insetSize.width != 480 || insetSize.height != 360) return 6;
  const zoomable = new MacOSWindow(WebKit.NSMakeRect(200, 200, 360, 240), style | WebKit.NSWindowStyleMaskResizable);
  const zoomLifetime = Lifetime({ window: zoomable });
  zoomable.zoom(null);
  if (!zoomable.zoomed) return 7;
  const maximized = zoomable.frame;
  requestWindowSize(zoomable, 450, 320);
  requestWindowSize(zoomable, 460, 330);
  if (zoomable.frame.size.width != maximized.size.width || zoomable.frame.size.height != maximized.size.height) return 8;
  zoomable.zoom(null);
  if (zoomable.zoomed) return 9;
  applyPendingWindowSize(zoomable);
  const ordinary = try macOSWindowSize(in zoomable);
  if (ordinary.width != 460 || ordinary.height != 330) return 10;
  const observer = new ResizeRequest({ window, requested: false });
  const delegate = objc.adapt<WebKit.NSWindowDelegate>(observer);
  window.delegate = delegate;
  requestWindowSize(window, 600, 400);
  window.delegate = null;
  const applying = try macOSWindowSize(in window);
  if (!observer.requested || applying.width != 600 || applying.height != 400) return 11;
  // Production's deferred presentation notification performs this after the
  // native geometry entry unwinds, never recursively inside that entry.
  applyPendingWindowSize(window);
  const reentrant = try macOSWindowSize(in window);
  if (reentrant.width != 550 || reentrant.height != 350) return 12;
  console.log("fixed and inset content size, constraints, native zoom deferral, reentrant requests, latest request, top-left preservation passed");
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt verify()) { success(code) => code; failure(_) => 90; };
}
