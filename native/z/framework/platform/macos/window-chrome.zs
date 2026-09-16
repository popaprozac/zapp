import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";

internal struct WindowChromeMetrics {
  top: f64 = 0;
  controlsLeft: f64 = 0;
}

function controlRight(in window: WebKit.NSWindow, in view: WebKit.WKWebView,
  bounds: WebKit.CGRect, kind: WebKit.NSWindowButton): f64 on thread.main {
  const button = window.standardWindowButton(kind);
  if (button != null && !button.hidden) {
    const rect = view.convertRect(button.bounds, fromView: button);
    if (rect.origin.y + rect.size.height > bounds.origin.y && rect.origin.y < bounds.origin.y + bounds.size.height) {
      const right = rect.origin.x + rect.size.width - bounds.origin.x;
      if (right > 0 && right <= bounds.size.width) return right;
    }
  }
  return 0;
}

// Convert AppKit's own layout and buttons into this WebView's coordinates.
// An ordinary content view does not overlap chrome and therefore reports zero.
internal function measureWindowChrome(
  in window: WebKit.NSWindow, in view: WebKit.WKWebView
): WindowChromeMetrics on thread.main {
  const bounds = view.bounds;
  if (bounds.size.width <= 0 || bounds.size.height <= 0) return WindowChromeMetrics();
  const layout = view.convertRect(window.contentLayoutRect, fromView: null);
  let top = view.flipped ? layout.origin.y - bounds.origin.y
    : bounds.origin.y + bounds.size.height - layout.origin.y - layout.size.height;
  if (top < 0) top = 0;
  if (top > bounds.size.height) top = bounds.size.height;
  // No per-resize collection allocation for the fixed three native controls.
  const close = controlRight(in window, in view, bounds, WebKit.NSWindowCloseButton);
  const minimize = controlRight(in window, in view, bounds, WebKit.NSWindowMiniaturizeButton);
  const zoomButton = controlRight(in window, in view, bounds, WebKit.NSWindowZoomButton);
  let controlsLeft = close > minimize ? close : minimize;
  if (zoomButton > controlsLeft) controlsLeft = zoomButton;
  const zoom = view.pageZoom > 0 ? view.pageZoom : 1.0;
  return WindowChromeMetrics({ top: top / zoom, controlsLeft: controlsLeft / zoom });
}

internal function windowChromeScript(in view: WebKit.WKWebView): String on thread.main {
  const window = view.window;
  if (window == null) return "";
  const metrics = measureWindowChrome(in window, in view);
  // Reuse the installed setter rather than retransmit its body on every resize.
  return `globalThis[Symbol.for('zapp.windowChrome')]?.(${metrics.top},${metrics.controlsLeft})`;
}

internal function installWindowChrome(
  in view: WebKit.WKWebView, in controller: WebKit.WKUserContentController
): void on thread.main {
  const initial = windowChromeScript(in view);
  // Keep the latest values until the root exists; suppress identical DOM writes.
  const source = `(()=>{let top=0,left=0;const apply=()=>{const r=document.documentElement;if(!r)return;const t=top+'px',l=left+'px';if(r.style.getPropertyValue('--zapp-titlebar-height')!==t)r.style.setProperty('--zapp-titlebar-height',t);if(r.style.getPropertyValue('--zapp-window-controls-inset-left')!==l)r.style.setProperty('--zapp-window-controls-inset-left',l)};globalThis[Symbol.for('zapp.windowChrome')]=(t,l)=>{top=t;left=l;apply()};document.addEventListener('DOMContentLoaded',apply,{once:true})})();${initial}`;
  const script = WebKit.WKUserScript.alloc().initWithSource(move source,
    injectionTime: WebKit.WKUserScriptInjectionTimeAtDocumentStart, forMainFrameOnly: true);
  controller.addUserScript(script);
}

internal function updateWindowChrome(in view: WebKit.WKWebView): void on thread.main {
  const script = windowChromeScript(in view);
  view.evaluateJavaScript(move script, completionHandler: move (value, error): void => {});
}
