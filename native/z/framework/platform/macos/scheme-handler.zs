import native from "zapp_desktop.h";
import objc from "std/objc";
import { thread } from "std/thread";

class DesktopAssetSchemeHandler on thread.main
  implements native.WKURLSchemeHandler {
  function start(
    in webView: native.WKWebView,
    in task: native.WKURLSchemeTask
  ): void as "webView:startURLSchemeTask:" {
    native.ZAppDesktopBridge.startURLSchemeTask(
      task,
      inWebView: webView
    );
  }

  function stop(
    in webView: native.WKWebView,
    in task: native.WKURLSchemeTask
  ): void as "webView:stopURLSchemeTask:" {
    // WebKit may stop a task after navigation or cancellation. Embedded asset
    // delivery is synchronous today, so there is no in-flight native work to
    // cancel after the callback returns.
  }
}

internal function createDesktopAssetSchemeHandler(
): objc.Adapter<native.WKURLSchemeHandler> on thread.main {
  const controller = new DesktopAssetSchemeHandler({});
  return objc.adapt<native.WKURLSchemeHandler>(controller);
}
