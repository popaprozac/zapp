import native from "zapp_desktop.h";
import Foundation from "Foundation/Foundation.h";
import WebKit from "WebKit/WebKit.h";
import console from "std/console";
import objc from "std/objc";
import { thread } from "std/thread";
import { configuredFrontendOrigin } from "./configured-webview.zs";
import {
  macOSApplicationSmokeMode,
  setMacOSApplicationResult,
} from "./application-host.zs";

function frontendOrigin(): Foundation.NSURL | null on thread.main {
  return Foundation.NSURL.URLWithString(configuredFrontendOrigin());
}

internal function resolveLogicalURL(
  in logicalURL: String
): Foundation.NSURL | null on thread.main {
  let logical = copy logicalURL;
  if (logical.byteLength == 0) logical = "/";
  const components: Foundation.NSURLComponents | null =
    Foundation.NSURLComponents.componentsWithString(copy logical);
  if (
    components == null
    || components.scheme != null
    || components.host != null
  ) return null;
  const base = frontendOrigin();
  if (base == null) return null;
  const resolved: Foundation.NSURL | null =
    Foundation.NSURL.URLWithString(move logical, relativeToURL: base);
  if (resolved == null) return null;
  return resolved.absoluteURL;
}

function hasFrontendOrigin(
  in url: Foundation.NSURL
): boolean on thread.main {
  const origin = frontendOrigin();
  if (origin == null) return false;
  const scheme = url.scheme;
  const originScheme = origin.scheme;
  const host = url.host;
  const originHost = origin.host;
  if (
    scheme == null
    || originScheme == null
    || host == null
    || originHost == null
  ) return false;
  if (
    scheme.caseInsensitiveCompare(originScheme) != Foundation.NSOrderedSame
    || host.caseInsensitiveCompare(originHost) != Foundation.NSOrderedSame
  ) return false;
  const port = url.port;
  const originPort = origin.port;
  if (port == null || originPort == null) {
    return port == null && originPort == null;
  }
  return port.isEqualToNumber(originPort);
}

internal class DesktopNavigationDelegate on thread.main
  implements WebKit.WKNavigationDelegate {
  readonly window: native.NSWindow;

  function didFailProvisionalNavigation(
    in webView: WebKit.WKWebView,
    in navigation: WebKit.WKNavigation | null,
    in error: Foundation.NSError
  ): void as "webView:didFailProvisionalNavigation:withError:" {
    console.error("frontend navigation failed before commit");
    if (macOSApplicationSmokeMode()) {
      setMacOSApplicationResult(54);
      this.window.close();
    }
  }

  function didFailNavigation(
    in webView: WebKit.WKWebView,
    in navigation: WebKit.WKNavigation | null,
    in error: Foundation.NSError
  ): void as "webView:didFailNavigation:withError:" {
    console.error("frontend navigation failed after commit");
    if (macOSApplicationSmokeMode()) {
      setMacOSApplicationResult(55);
      this.window.close();
    }
  }

  function decidePolicyForNavigationAction(
    in webView: WebKit.WKWebView,
    in navigationAction: WebKit.WKNavigationAction,
    in decisionHandler: (policy: WebKit.WKNavigationActionPolicy) => void
  ): void as "webView:decidePolicyForNavigationAction:decisionHandler:" {
    const target = navigationAction.targetFrame;
    if (target != null && !target.mainFrame) {
      decisionHandler(WebKit.WKNavigationActionPolicyAllow);
      return;
    }
    const url = navigationAction.request.URL;
    if (target != null && url != null && hasFrontendOrigin(url)) {
      decisionHandler(WebKit.WKNavigationActionPolicyAllow);
      return;
    }
    let address = "<invalid>";
    if (url != null) {
      const absolute = url.absoluteString;
      if (absolute != null) {
        const text: String = absolute;
        address = move text;
      }
    }
    console.error(`blocked navigation outside the application origin: ${address}`);
    decisionHandler(WebKit.WKNavigationActionPolicyCancel);
  }
}

internal function createDesktopNavigationDelegate(
  in window: native.NSWindow
): objc.Adapter<WebKit.WKNavigationDelegate> on thread.main {
  const delegate = new DesktopNavigationDelegate({ window });
  return objc.adapt<WebKit.WKNavigationDelegate>(delegate);
}
