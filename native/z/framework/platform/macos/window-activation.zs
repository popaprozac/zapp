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
