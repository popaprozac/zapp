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
