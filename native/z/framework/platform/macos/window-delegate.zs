import native from "zapp_desktop.h";
import Foundation from "Foundation/Foundation.h";
import objc from "std/objc";
import { thread } from "std/thread";
import { WindowManager } from "../../window.zs";

class DesktopWindowDelegate on thread.main
  implements native.NSWindowDelegate {
  readonly id: String;
  readonly nativeId: i32;
  readonly window: native.NSWindow;
  readonly windows: Weak<WindowManager>;

  function willClose(
    in notification: Foundation.NSNotification
  ): void as "windowWillClose:" {
    // Keep the Z-owned AppKit graph alive until NSApplication.run has fully
    // unwound its autorelease pools. Native routing stops immediately, while
    // the application runtime retains its graph until the run loop returns.
    const id = copy this.id;
    const nativeId = this.nativeId;
    const window = this.window;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => windows.closedNative(in id);
      failure(_) => {}
    }
    native.ZAppDesktopBridge.detachWindow(
      window,
      nativeId: nativeId
    );
  }

  function didBecomeKey(
    in notification: Foundation.NSNotification
  ): void as "windowDidBecomeKey:" {
    const id = copy this.id;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => windows.focusedNative(in id);
      failure(_) => {}
    }
  }

  function didResignKey(
    in notification: Foundation.NSNotification
  ): void as "windowDidResignKey:" {
    const id = copy this.id;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => windows.blurredNative(in id);
      failure(_) => {}
    }
  }

  function didResize(
    in notification: Foundation.NSNotification
  ): void as "windowDidResize:" {
    const id = copy this.id;
    const window = this.window;
    const contentView = window.contentView;
    if (contentView == null) return;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => windows.resizedNative(
        in id,
        native.ZAppDesktopBridge.contentWidth(window),
        native.ZAppDesktopBridge.contentHeight(window)
      );
      failure(_) => {}
    }
  }
}

internal function createDesktopWindowDelegate(
  id: String,
  nativeId: i32,
  in window: native.NSWindow,
  windows: Weak<WindowManager>
): objc.Adapter<native.NSWindowDelegate> on thread.main {
  const delegate = new DesktopWindowDelegate({
    id: move id,
    nativeId,
    window,
    windows,
  });
  return objc.adapt<native.NSWindowDelegate>(delegate);
}
