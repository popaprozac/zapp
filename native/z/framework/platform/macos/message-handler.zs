import WebKit from "WebKit/WebKit.h";
import {
  BridgeResponse,
  bridgeFailure,
} from "../../bridge.zs";
import { thread } from "std/thread";

internal type DesktopRouteMessageOperation = (
  message: String,
  windowId: i32
) => void on thread.main;

internal type DesktopDeliverResponseOperation = (
  in response: BridgeResponse,
  windowId: i32
) => void on thread.main;

internal readonly class DesktopMessageHandler on thread.main
  implements WebKit.WKScriptMessageHandler {
  readonly windowId: i32;
  readonly routeMessage: DesktopRouteMessageOperation;
  readonly deliverResponse: DesktopDeliverResponseOperation;

  function receive(
    in controller: WebKit.WKUserContentController,
    in message: WebKit.WKScriptMessage
  ): void as "userContentController:didReceiveScriptMessage:" {
    const body = message.body;
    if (body instanceof WebKit.NSString) {
      const text: String = body;
      this.routeMessage(move text, this.windowId);
      return;
    }
    const failure = bridgeFailure(
      0,
      "INVALID_MESSAGE",
      "WebView message body must be a string"
    );
    this.deliverResponse(in failure, this.windowId);
  }
}
