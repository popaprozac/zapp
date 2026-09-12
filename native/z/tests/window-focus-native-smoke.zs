import AppKit from "AppKit/AppKit.h";
import console from "std/console";
import objc from "std/objc";
import { thread } from "std/thread";
import { showMacOSNativeWindow, focusMacOSNativeWindow,
  minimizeMacOSNativeWindow, unminimizeMacOSNativeWindow } from "../framework/platform/macos/window-activation.zs";

class Observations on thread.main implements AppKit.NSWindowDelegate {
  minimized: i32;
  unminimized: i32;

  function didMinimize(inout this, in notification: AppKit.NSNotification): void as "windowDidMiniaturize:" {
    this.minimized = this.minimized + 1;
  }

  function didUnminimize(inout this, in notification: AppKit.NSNotification): void as "windowDidDeminiaturize:" {
    this.unminimized = this.unminimized + 1;
  }
}

struct WindowLifetime on thread.main {
  window: AppKit.NSWindow;
  deinit { this.window.close(); }
}

function pump(): void on thread.main {
  AppKit.NSRunLoop.currentRunLoop.runUntilDate(AppKit.NSDate.dateWithTimeIntervalSinceNow(0.05));
}

function waitForEvents(in observations: Observations, minimized: i32, unminimized: i32): boolean on thread.main {
  let attempts: i32 = 0;
  while ((observations.minimized < minimized || observations.unminimized < unminimized) && attempts < 20) {
    pump();
    attempts = attempts + 1;
  }
  const matched = observations.minimized == minimized && observations.unminimized == unminimized;
  if (!matched) console.log(`native events: expected ${minimized}/${unminimized}, observed ${observations.minimized}/${observations.unminimized}`);
  return matched;
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
  const observations = new Observations({ minimized: 0, unminimized: 0 });
  const delegate = objc.adapt<AppKit.NSWindowDelegate>(observations);
  window.delegate = delegate;
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
  minimizeMacOSNativeWindow(in window);
  minimizeMacOSNativeWindow(in window);
  pump();
  if (!window.miniaturized) return 5;
  if (!waitForEvents(in observations, 1, 0)) return 11;
  unminimizeMacOSNativeWindow(in window);
  unminimizeMacOSNativeWindow(in window);
  pump();
  if (window.miniaturized || !window.visible) return 7;
  if (!waitForEvents(in observations, 1, 1)) return 8;
  // Allow the Dock's restoration animation to settle before requesting the
  // opposite transition. The notification is not an animation-completion API.
  AppKit.NSRunLoop.currentRunLoop.runUntilDate(AppKit.NSDate.dateWithTimeIntervalSinceNow(0.5));
  minimizeMacOSNativeWindow(in window);
  pump();
  if (!waitForEvents(in observations, 2, 1)) return 12;
  focusMacOSNativeWindow(in window);
  pump();
  if (window.miniaturized || !window.visible) return 6;
  if (!waitForEvents(in observations, 2, 2)) return 9;
  window.orderOut(null);
  unminimizeMacOSNativeWindow(in window);
  if (window.visible) return 10;
  window.delegate = null;
  // OS activation may be denied to unattended processes. Verify restoration
  // here, and report actual activation rather than asserting a guarantee.
  console.log(`focus probe: active=${app.active} key=${window.keyWindow}`);
  return 0;
}
