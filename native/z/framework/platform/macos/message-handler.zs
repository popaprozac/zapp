import WebKit from "WebKit/WebKit.h";
import console from "std/console";
import { BridgeDocument } from "../../bridge-document.zs";
import { routeDocumentMessage, DesktopRouteMessageOperation } from "./document-transport.zs";
import { thread } from "std/thread";
import { hasConfiguredFrontendOrigin } from "./navigation-policy.zs";

internal readonly class DesktopMessageHandler on thread.main
  implements WebKit.WKScriptMessageHandler {
  readonly document: BridgeDocument;
  readonly expectedView: WebKit.WKWebView;
  readonly expectedController: WebKit.WKUserContentController;
  readonly routeMessage: DesktopRouteMessageOperation;

  function receive(
    in controller: WebKit.WKUserContentController,
    in message: WebKit.WKScriptMessage
  ): void as "userContentController:didReceiveScriptMessage:" {
    if (controller != this.expectedController || message.webView != this.expectedView) {
      console.error("blocked native bridge message from an unrelated WebView endpoint");
      return;
    }
    const frame = message.frameInfo;
    if (!frame.mainFrame) {
      console.error("blocked native bridge message from a WebView subframe");
      return;
    }
    const sourceURL = frame.request.URL;
    if (sourceURL == null || !hasConfiguredFrontendOrigin(in sourceURL)) {
      console.error("blocked native bridge message outside the application origin");
      return;
    }
    const body = message.body;
    if (body instanceof WebKit.NSString) {
      const text: String = body;
      routeDocumentMessage(this.document, in this.expectedView, move text, this.routeMessage);
      return;
    }
    console.error("blocked native bridge message without document-bound string body");
  }
}
