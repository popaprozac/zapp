import Foundation from "Foundation/Foundation.h";
import WebKit from "WebKit/WebKit.h";
import { MacOSRelatedWindows } from "./related-window-creations.zs";
import console from "std/console";
import objc from "std/objc";
import { thread } from "std/thread";
import { BridgeDocument } from "../../bridge-document.zs";
import { requestBridgeDocumentBinding } from "./document-transport.zs";
import { profileAllowsURL } from "./navigation-policy.zs";
import { WindowManager } from "../../window.zs";
import { ContextMenuSessions } from "../../context-menu.zs";
import { ApplicationMenu } from "../../application-menu.zs";
import { MacOSFileDrops } from "./file-drops.zs";
import {
  deliverWebViewWindowNavigationRequested,
} from "./response-delivery.zs";
import {
  macOSApplicationSmokeMode,
  setMacOSApplicationResult,
} from "./application-host.zs";

internal class DesktopNavigationDelegate on thread.main
  implements WebKit.WKNavigationDelegate {
  readonly id: String;
  readonly profile: String;
  readonly window: WebKit.NSWindow;
  readonly webView: WebKit.WKWebView;
  readonly windows: Weak<WindowManager>;
  readonly contextMenus: ContextMenuSessions;
  readonly menu: ApplicationMenu;
  readonly document: BridgeDocument;
  readonly related: Weak<MacOSRelatedWindows>;
  readonly fileDrops: Option<Weak<MacOSFileDrops>>;

  private function endFileDrag(): void {
    match (in this.fileDrops) {
      some(owner) => match (attempt owner.upgrade()) { success(drops) => drops.exit(); failure(_) => {} }
      none => {}
    }
  }

  function didCommitNavigation(
    in webView: WebKit.WKWebView,
    in navigation: WebKit.WKNavigation | null
  ): void as "webView:didCommitNavigation:" {
    if (webView != this.webView) return;
    this.endFileDrag();
    const document = this.document;
    document.didCommit();
    match (attempt this.related.upgrade()) { success(related) => related.pruneInvalidated(); failure(_) => {} }
    requestBridgeDocumentBinding(in webView);
  }

  function processTerminated(
    in webView: WebKit.WKWebView
  ): void as "webViewWebContentProcessDidTerminate:" {
    if (webView != this.webView) return;
    this.endFileDrag();
    const document = this.document;
    document.retire();
    match (attempt this.related.upgrade()) { success(related) => related.pruneInvalidated(); failure(_) => {} }
  }

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
    if (target == null) {
      const allowed = match (attempt this.related.upgrade()) {
        success(related) => related.allows(in webView, in navigationAction);
        failure(_) => false;
      };
      decisionHandler(allowed ? WebKit.WKNavigationActionPolicyAllow : WebKit.WKNavigationActionPolicyCancel);
      return;
    }
    const url = navigationAction.request.URL;
    const mainFrame: boolean = target.mainFrame;
    let address = "<invalid>";
    if (url != null) {
      const absolute = url.absoluteString;
      if (absolute != null) {
        const text: String = absolute;
        address = move text;
      }
    }

    const allowedByProfile: boolean = url != null
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
      if (mainFrame) {
        let sessions = this.contextMenus;
        sessions.invalidateWindow(in this.id);
        let menu = this.menu;
        menu.invalidateFrontendOwner(in this.id);
      }
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
  windows: Weak<WindowManager>,
  contextMenus: ContextMenuSessions,
  menu: ApplicationMenu,
  document: BridgeDocument,
  related: MacOSRelatedWindows,
  fileDrops: Option<Weak<MacOSFileDrops>>
): objc.Adapter<WebKit.WKNavigationDelegate> on thread.main {
  const delegate = new DesktopNavigationDelegate({
    id,
    profile,
    window,
    webView,
    windows,
    contextMenus,
    menu,
    document,
    related: weak related,
    fileDrops,
  });
  return objc.adapt<WebKit.WKNavigationDelegate>(delegate);
}
