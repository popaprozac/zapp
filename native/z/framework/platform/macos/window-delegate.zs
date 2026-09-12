import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import { thread } from "std/thread";
import { WindowManager } from "../../window.zs";
import { macOSContentDimension } from "./window-geometry.zs";
import { MacOSWindow, queueWindowPresentation, queueWindowFullscreen } from "./window-resize.zs";
import {
  deliverWebViewWindowEvent,
  deliverWebViewWindowResize,
} from "./response-delivery.zs";

internal type NativeWindowClosedOperation = (
  nativeId: i32
) => void on thread.main;

class DesktopWindowDelegate on thread.main
  implements WebKit.NSWindowDelegate {
  readonly id: String;
  readonly nativeId: i32;
  readonly window: MacOSWindow;
  readonly webView: WebKit.WKWebView;
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
    const webView = this.webView;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => {
        windows.focusedNative(in id);
        deliverWebViewWindowEvent(in webView, in id, "focus");
      }
      failure(_) => {}
    }
  }

  function didResignKey(
    in notification: WebKit.NSNotification
  ): void as "windowDidResignKey:" {
    const id = copy this.id;
    const webView = this.webView;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => {
        windows.blurredNative(in id);
        deliverWebViewWindowEvent(in webView, in id, "blur");
      }
      failure(_) => {}
    }
  }

  function didMiniaturize(
    in notification: WebKit.NSNotification
  ): void as "windowDidMiniaturize:" {
    const id = copy this.id;
    const webView = this.webView;
    match (attempt this.windows.upgrade()) {
      success(windows) => {
        windows.minimizedNative(in id);
        deliverWebViewWindowEvent(in webView, in id, "minimized");
      }
      failure(_) => {}
    }
  }

  function didDeminiaturize(
    in notification: WebKit.NSNotification
  ): void as "windowDidDeminiaturize:" {
    const id = copy this.id;
    const webView = this.webView;
    match (attempt this.windows.upgrade()) {
      success(windows) => {
        windows.unminimizedNative(in id);
        deliverWebViewWindowEvent(in webView, in id, "unminimized");
      }
      failure(_) => {}
    }
  }

  function didResize(
    in notification: WebKit.NSNotification
  ): void as "windowDidResize:" {
    const id = copy this.id;
    const window = this.window;
    const webView = this.webView;
    const contentView = window.contentView;
    if (contentView == null) return;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => {
        const width = macOSContentDimension(contentView.bounds.size.width);
        const height = macOSContentDimension(contentView.bounds.size.height);
        windows.resizedNative(in id, width, height);
        // Coalesced observation outside the native geometry entry, including
        // user resizing a previously zoomed window back to an ordinary frame.
        queueWindowPresentation(window);
        deliverWebViewWindowResize(
          in webView,
          in id,
          width,
          height
        );
      }
      failure(_) => {}
    }
  }

  // User tracking and system-owned fullscreen geometry must not race the
  // display-driven controller. These callbacks do not change event delivery.
  function willMove(inout this, in notification: WebKit.NSNotification): void as "windowWillMove:" {
    this.window.cancelResize();
  }

  function willStartLiveResize(inout this, in notification: WebKit.NSNotification): void as "windowWillStartLiveResize:" {
    this.window.cancelResize();
  }

  function willEnterFullScreen(inout this, in notification: WebKit.NSNotification): void as "windowWillEnterFullScreen:" {
    this.window.setSystemResize(true);
    match (attempt this.windows.upgrade()) {
      success(windows) => windows.fullscreenWillChangeNative(in this.id);
      failure(_) => {}
    }
  }

  function willExitFullScreen(inout this, in notification: WebKit.NSNotification): void as "windowWillExitFullScreen:" {
    this.window.setSystemResize(true);
    match (attempt this.windows.upgrade()) {
      success(windows) => windows.fullscreenWillChangeNative(in this.id);
      failure(_) => {}
    }
  }

  function didEnterFullScreen(inout this, in notification: WebKit.NSNotification): void as "windowDidEnterFullScreen:" {
    this.window.setSystemResize(true);
    queueWindowFullscreen(this.window);
  }

  function didExitFullScreen(inout this, in notification: WebKit.NSNotification): void as "windowDidExitFullScreen:" {
    this.window.setSystemResize(false);
    queueWindowFullscreen(this.window);
    queueWindowPresentation(this.window);
  }

  function didFailToEnterFullScreen(inout this, in window: WebKit.NSWindow): void as "windowDidFailToEnterFullScreen:" {
    this.window.setSystemResize(false);
    queueWindowFullscreen(this.window);
    queueWindowPresentation(this.window);
  }

  function didFailToExitFullScreen(inout this, in window: WebKit.NSWindow): void as "windowDidFailToExitFullScreen:" {
    this.window.setSystemResize(true);
    queueWindowFullscreen(this.window);
  }
}

internal function createDesktopWindowDelegate(
  id: String,
  nativeId: i32,
  in window: MacOSWindow,
  in webView: WebKit.WKWebView,
  windows: Weak<WindowManager>,
  didCloseNativeWindow: NativeWindowClosedOperation
): objc.Adapter<WebKit.NSWindowDelegate> on thread.main {
  const delegate = new DesktopWindowDelegate({
    id: move id,
    nativeId,
    window,
    webView,
    windows,
    didCloseNativeWindow,
  });
  return objc.adapt<WebKit.NSWindowDelegate>(delegate);
}
