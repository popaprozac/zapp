import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import { thread } from "std/thread";
import { WindowManager } from "../../window.zs";
import { macOSContentDimension } from "./window-geometry.zs";

internal type NativeWindowClosedOperation = (
  nativeId: i32
) => void on thread.main;

class DesktopWindowDelegate on thread.main
  implements WebKit.NSWindowDelegate {
  readonly id: String;
  readonly nativeId: i32;
  readonly window: WebKit.NSWindow;
  readonly windows: Weak<WindowManager>;
  readonly didCloseNativeWindow: NativeWindowClosedOperation;

  function shouldClose(
    in window: WebKit.NSWindow
  ): boolean as "windowShouldClose:" {
    const id = copy this.id;
    const current = attempt this.windows.upgrade();
    return match (current) {
      success(windows) => windows.closeRequestedNative(in id);
      failure(_) => true;
    };
  }

  function willClose(
    in notification: WebKit.NSNotification
  ): void as "windowWillClose:" {
    // Keep the Z-owned AppKit graph alive until NSApplication.run has fully
    // unwound its autorelease pools. Native routing stops immediately, while
    // the application runtime retains its graph until the run loop returns.
    const id = copy this.id;
    const nativeId = this.nativeId;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => windows.closedNative(in id);
      failure(_) => {}
    }
    this.didCloseNativeWindow(nativeId);
  }

  function didBecomeKey(
    in notification: WebKit.NSNotification
  ): void as "windowDidBecomeKey:" {
    const id = copy this.id;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => windows.focusedNative(in id);
      failure(_) => {}
    }
  }

  function didResignKey(
    in notification: WebKit.NSNotification
  ): void as "windowDidResignKey:" {
    const id = copy this.id;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => windows.blurredNative(in id);
      failure(_) => {}
    }
  }

  function didResize(
    in notification: WebKit.NSNotification
  ): void as "windowDidResize:" {
    const id = copy this.id;
    const window = this.window;
    const contentView = window.contentView;
    if (contentView == null) return;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => windows.resizedNative(
        in id,
        macOSContentDimension(contentView.bounds.size.width),
        macOSContentDimension(contentView.bounds.size.height)
      );
      failure(_) => {}
    }
  }
}

internal function createDesktopWindowDelegate(
  id: String,
  nativeId: i32,
  in window: WebKit.NSWindow,
  windows: Weak<WindowManager>,
  didCloseNativeWindow: NativeWindowClosedOperation
): objc.Adapter<WebKit.NSWindowDelegate> on thread.main {
  const delegate = new DesktopWindowDelegate({
    id: move id,
    nativeId,
    window,
    windows,
    didCloseNativeWindow,
  });
  return objc.adapt<WebKit.NSWindowDelegate>(delegate);
}
