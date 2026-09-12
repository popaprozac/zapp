import AppKit from "AppKit/AppKit.h";
import console from "std/console";
import { thread } from "std/thread";
import { showMacOSNativeWindow, focusMacOSNativeWindow } from "../framework/platform/macos/window-activation.zs";

struct WindowLifetime on thread.main {
  window: AppKit.NSWindow;
  deinit { this.window.close(); }
}

function pump(): void on thread.main {
  AppKit.NSRunLoop.currentRunLoop.runUntilDate(AppKit.NSDate.dateWithTimeIntervalSinceNow(0.05));
}

function main(): i32 on thread.main {
  const app = AppKit.NSApplication.sharedApplication;
  app.setActivationPolicy(AppKit.NSApplicationActivationPolicyRegular);
  app.finishLaunching();
  const style = AppKit.NSWindowStyleMaskTitled | AppKit.NSWindowStyleMaskClosable | AppKit.NSWindowStyleMaskMiniaturizable;
  const window = AppKit.NSWindow.alloc().initWithContentRect(AppKit.NSMakeRect(0, 0, 280, 160),
    styleMask: style, backing: AppKit.NSBackingStoreBuffered, defer: false);
  window.releasedWhenClosed = false;
  const lifetime = WindowLifetime({ window });
  window.title = "Zapp bounded focus probe";
  window.center();
  showMacOSNativeWindow(in window);
  pump();
  if (!window.visible || window.keyWindow) return 1;
  focusMacOSNativeWindow(in window);
  pump();
  if (!window.visible || window.miniaturized) return 2;
  window.orderOut(null);
  if (window.visible) return 3;
  focusMacOSNativeWindow(in window);
  pump();
  if (!window.visible) return 4;
  window.miniaturize(null);
  pump();
  if (!window.miniaturized) return 5;
  focusMacOSNativeWindow(in window);
  pump();
  if (window.miniaturized || !window.visible) return 6;
  // OS activation may be denied to unattended processes. Verify restoration
  // here, and report actual activation rather than asserting a guarantee.
  console.log(`focus probe: active=${app.active} key=${window.keyWindow}`);
  return 0;
}
