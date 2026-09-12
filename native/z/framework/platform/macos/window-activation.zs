import AppKit from "AppKit/AppKit.h";
import { thread } from "std/thread";

internal function showMacOSNativeWindow(in window: AppKit.NSWindow): void on thread.main {
  // Visibility alone does not request app activation or keyboard focus.
  window.orderFront(null);
}

internal function focusMacOSNativeWindow(in window: AppKit.NSWindow): void on thread.main {
  const application = AppKit.NSApplication.sharedApplication;
  if (application.hidden) application.unhideWithoutActivation();
  if (window.miniaturized) window.deminiaturize(null);
  // Activation is cooperative on current macOS; don't use the deprecated
  // ignoring-other-apps path or promise an immediate successful activation.
  application.activate();
  window.makeKeyAndOrderFront(null);
}

internal function minimizeMacOSNativeWindow(in window: AppKit.NSWindow): void on thread.main {
  if (!window.miniaturized) window.miniaturize(null);
}

internal function unminimizeMacOSNativeWindow(in window: AppKit.NSWindow): void on thread.main {
  // Undo minimization only. No explicit app activation or key-window request.
  if (window.miniaturized) window.deminiaturize(null);
}

internal function setMacOSNativeWindowMaximized(in window: AppKit.NSWindow, value: boolean): void on thread.main {
  if (usize(window.styleMask & AppKit.NSWindowStyleMaskFullScreen) != 0) return;
  if (usize(window.styleMask & AppKit.NSWindowStyleMaskResizable) == 0) return;
  if (window.zoomed != value) window.zoom(null);
}

internal function setMacOSNativeWindowFullscreen(in window: AppKit.NSWindow, value: boolean): void on thread.main {
  const current = usize(window.styleMask & AppKit.NSWindowStyleMaskFullScreen) != 0;
  if (current != value) window.toggleFullScreen(null);
}
