import Foundation from "Foundation/Foundation.h";
import WebKit from "WebKit/WebKit.h";
import console from "std/console";
import objc from "std/objc";
import { thread } from "std/thread";
import {
  configuredFrontendOrigin,
  configuredNavigationAllowsSelf,
  configuredNavigationExternalSchemeAtIndex,
  configuredNavigationOriginAtIndex,
} from "./configured-webview.zs";
import { WindowManager } from "../../window.zs";
import {
  deliverWebViewWindowNavigationRequested,
} from "./response-delivery.zs";
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

function hasSameOrigin(
  in url: Foundation.NSURL,
  in origin: Foundation.NSURL
): boolean on thread.main {
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

internal function hasConfiguredFrontendOrigin(
  in url: Foundation.NSURL
): boolean on thread.main {
  const origin = frontendOrigin();
  return origin != null && hasSameOrigin(in url, in origin);
}

internal function navigationProfileAllowsExternalURL(
  in profile: String,
  in address: String
): boolean on thread.main {
  const url = Foundation.NSURL.URLWithString(copy address);
  if (url == null) return false;
  const scheme = url.scheme;
  if (scheme == null) return false;
  const normalizedScheme: String = scheme.lowercaseString;
  let index: usize = 0;
  while (true) {
    const configured = configuredNavigationExternalSchemeAtIndex(
      in profile,
      index
    );
    match (configured) {
      some(value) => {
        const expected = value.copyBytes(0, value.byteLength - 1);
        if (normalizedScheme == expected) return true;
      }
      none => return false;
    }
    index = index + 1;
  }
  return false;
}

function profileAllowsURL(
  in profile: String,
  in url: Foundation.NSURL
): boolean on thread.main {
  if (
    configuredNavigationAllowsSelf(in profile)
    && hasConfiguredFrontendOrigin(in url)
  ) return true;

  let index: usize = 0;
  while (true) {
    const configured = configuredNavigationOriginAtIndex(in profile, index);
    match (configured) {
      some(value) => {
        const origin = Foundation.NSURL.URLWithString(value);
        if (origin != null && hasSameOrigin(in url, in origin)) return true;
      }
      none => return false;
    }
    index = index + 1;
  }
  return false;
}

internal class DesktopNavigationDelegate on thread.main
  implements WebKit.WKNavigationDelegate {
  readonly id: String;
  readonly profile: String;
  readonly window: WebKit.NSWindow;
  readonly webView: WebKit.WKWebView;
  readonly windows: Weak<WindowManager>;

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
    const url = navigationAction.request.URL;
    const mainFrame: boolean = target != null && target.mainFrame;
    let address = "<invalid>";
    if (url != null) {
      const absolute = url.absoluteString;
      if (absolute != null) {
        const text: String = absolute;
        address = move text;
      }
    }

    const allowedByProfile: boolean = target != null
      && url != null
      && profileAllowsURL(in this.profile, in url);
    let acceptedByNative = false;
    const current = attempt this.windows.upgrade();
    match (current) {
      success(windows) => acceptedByNative = windows.navigationRequestedNative(
        in this.id,
        in address,
        mainFrame,
        allowedByProfile
      );
      failure(_) => {}
    }
    const allowed: boolean = allowedByProfile && acceptedByNative;
    if (allowed) {
      decisionHandler(WebKit.WKNavigationActionPolicyAllow);
    } else {
      console.error(`blocked navigation by window policy: ${address}`);
      decisionHandler(WebKit.WKNavigationActionPolicyCancel);
    }
    // WebKit requires its decision completion before scheduling work back into
    // the page. This event is observational and cannot affect the result.
    const retainedWebView = this.webView;
    deliverWebViewWindowNavigationRequested(
      in retainedWebView,
      in this.id,
      in address,
      mainFrame,
      allowedByProfile,
      !allowed
    );
  }
}

internal function createDesktopNavigationDelegate(
  id: String,
  profile: String,
  in window: WebKit.NSWindow,
  in webView: WebKit.WKWebView,
  windows: Weak<WindowManager>
): objc.Adapter<WebKit.WKNavigationDelegate> on thread.main {
  const delegate = new DesktopNavigationDelegate({
    id,
    profile,
    window,
    webView,
    windows,
  });
  return objc.adapt<WebKit.WKNavigationDelegate>(delegate);
}
