import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import { thread } from "std/thread";
import { WindowManager } from "../../window.zs";
import { MacOSWindow, windowPresentationNotification, windowFullscreenNotification } from "./window-resize.zs";
import { deliverWebViewWindowEvent } from "./response-delivery.zs";

internal struct WindowPresentationObserver on thread.main {
  zoomToken: objc.Object;
  fullscreenToken: objc.Object;
  window: WebKit.NSWindow;
  deinit {
    const center = WebKit.NSNotificationCenter.defaultCenter;
    center.removeObserver(this.zoomToken);
    center.removeObserver(this.fullscreenToken);
    const zoom = WebKit.NSNotification.notificationWithName(windowPresentationNotification, object: this.window);
    const fullscreen = WebKit.NSNotification.notificationWithName(windowFullscreenNotification, object: this.window);
    const mask = usize(WebKit.NSNotificationCoalescingOnName | WebKit.NSNotificationCoalescingOnSender);
    const queue = WebKit.NSNotificationQueue.defaultQueue;
    queue.dequeueNotificationsMatching(zoom, coalesceMask: mask);
    queue.dequeueNotificationsMatching(fullscreen, coalesceMask: mask);
  }
}

// Deferred native delivery runs after guarded subclass/delegate entries unwind.
// Tokens are scoped; neither callback captures its containing runtime.
internal function observeWindowPresentation(
  id: String,
  in window: MacOSWindow,
  in webView: WebKit.WKWebView,
  owner: Weak<WindowManager>
): WindowPresentationObserver on thread.main {
  const observedWindow = window;
  const observedWebView = webView;
  const fullscreenId = copy id;
  const center = WebKit.NSNotificationCenter.defaultCenter;
  const zoomToken = center.addObserverForName(
    windowPresentationNotification,
    object: window,
    queue: null,
    usingBlock: move (notification): void => {
      if (!observedWindow.presentationStable()) return;
      match (attempt owner.upgrade()) {
        success(windows) => {
          const maximized = observedWindow.zoomed;
          if (windows.maximizedChangedNative(in id, maximized)) {
            const eventName = maximized ? "maximized" : "unmaximized";
            match (windows.get(in id)) {
              some(_) => deliverWebViewWindowEvent(in observedWebView, in id, in eventName);
              none => {}
            }
          }
        }
        failure(_) => {}
      }
    }
  );
  const fullscreenToken = center.addObserverForName(
    windowFullscreenNotification,
    object: window,
    queue: null,
    usingBlock: move (notification): void => {
      match (attempt owner.upgrade()) {
        success(windows) => {
          const fullscreen = usize(observedWindow.styleMask & WebKit.NSWindowStyleMaskFullScreen) != 0;
          if (windows.fullscreenChangedNative(in fullscreenId, fullscreen)) {
            const eventName = fullscreen ? "fullscreen-entered" : "fullscreen-exited";
            match (windows.get(in fullscreenId)) {
              some(_) => deliverWebViewWindowEvent(in observedWebView, in fullscreenId, in eventName);
              none => {}
            }
          }
        }
        failure(_) => {}
      }
    }
  );
  return WindowPresentationObserver({ zoomToken, fullscreenToken, window });
}
