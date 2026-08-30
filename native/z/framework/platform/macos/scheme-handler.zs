import native from "zapp_desktop.h";
import Foundation from "Foundation/Foundation.h";
import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import { thread } from "std/thread";

function failAssetRequest(
  in task: WebKit.WKURLSchemeTask,
  status: isize,
  message: String
): void on thread.main {
  native.ZAppDesktopBridge.failURLSchemeTask(
    task,
    status: status,
    message: move message
  );
}

function embeddedAssetIndex(in path: Foundation.NSString): usize on thread.main {
  const count: usize = native.ZAppDesktopBridge.embeddedAssetCount();
  let index: usize = 0;
  while (index < count) {
    const candidate: Foundation.NSString | null =
      native.ZAppDesktopBridge.embeddedAssetPathAtIndex(index);
    if (candidate != null && candidate.isEqualToString(path)) return index;
    index = index + 1;
  }
  return count;
}

function assetMimeType(in path: Foundation.NSString): Foundation.NSString {
  const extension: Foundation.NSString = path.pathExtension.lowercaseString;
  if (extension.isEqualToString("html")) return "text/html";
  if (extension.isEqualToString("css")) return "text/css";
  if (extension.isEqualToString("js")) return "text/javascript";
  if (extension.isEqualToString("mjs")) return "text/javascript";
  if (extension.isEqualToString("json")) return "application/json";
  if (extension.isEqualToString("svg")) return "image/svg+xml";
  if (extension.isEqualToString("png")) return "image/png";
  if (extension.isEqualToString("jpg")) return "image/jpeg";
  if (extension.isEqualToString("jpeg")) return "image/jpeg";
  if (extension.isEqualToString("gif")) return "image/gif";
  if (extension.isEqualToString("webp")) return "image/webp";
  if (extension.isEqualToString("ico")) return "image/x-icon";
  if (extension.isEqualToString("woff")) return "font/woff";
  if (extension.isEqualToString("woff2")) return "font/woff2";
  if (extension.isEqualToString("ttf")) return "font/ttf";
  if (extension.isEqualToString("wasm")) return "application/wasm";
  return "application/octet-stream";
}

function assetIsText(in mimeType: Foundation.NSString): boolean {
  return mimeType.hasPrefix("text/")
    || mimeType.isEqualToString("application/json");
}

function assetPathEscapes(in path: Foundation.NSString): boolean {
  return path.isEqualToString(".")
    || path.isEqualToString("..")
    || path.hasPrefix("./")
    || path.hasPrefix("../")
    || path.hasSuffix("/.")
    || path.hasSuffix("/..")
    || path.containsString("/./")
    || path.containsString("/../");
}

function assetResponse(
  in url: Foundation.NSURL,
  in data: Foundation.NSData,
  in mimeType: Foundation.NSString
): Foundation.NSURLResponse {
  if (assetIsText(mimeType)) {
    return Foundation.NSURLResponse.alloc().initWithURL(
      url,
      MIMEType: mimeType,
      expectedContentLength: isize(data.length),
      textEncodingName: "utf-8"
    );
  }
  return Foundation.NSURLResponse.alloc().initWithURL(
    url,
    MIMEType: mimeType,
    expectedContentLength: isize(data.length),
    textEncodingName: null
  );
}

class DesktopAssetSchemeHandler on thread.main
  implements WebKit.WKURLSchemeHandler {
  function start(
    in webView: WebKit.WKWebView,
    in task: WebKit.WKURLSchemeTask
  ): void as "webView:startURLSchemeTask:" {
    const url: Foundation.NSURL | null = task.request.URL;
    if (url == null) {
      failAssetRequest(task, 403, "Forbidden application origin");
      return;
    }
    const scheme: Foundation.NSString | null = url.scheme;
    const host: Foundation.NSString | null = url.host;
    if (
      scheme == null
      || host == null
      || !scheme.isEqualToString("zapp")
      || !host.isEqualToString("app")
    ) {
      failAssetRequest(task, 403, "Forbidden application origin");
      return;
    }

    const requestedPath: Foundation.NSString | null = url.path;
    let path: Foundation.NSString = "/";
    if (requestedPath != null) {
      if (requestedPath.length > 0) path = requestedPath;
    }
    if (assetPathEscapes(path)) {
      failAssetRequest(task, 403, "Forbidden asset path");
      return;
    }
    if (path.length == 0 || path.isEqualToString("/")) {
      path = "/index.html";
    }

    const count: usize = native.ZAppDesktopBridge.embeddedAssetCount();
    let index: usize = embeddedAssetIndex(path);
    if (index == count && path.pathExtension.length == 0) {
      // Application routes resolve through the frontend entry while concrete
      // asset paths remain honest 404s.
      path = "/index.html";
      index = embeddedAssetIndex(path);
    }
    if (index == count) {
      failAssetRequest(task, 404, "Asset not found");
      return;
    }

    const data: Foundation.NSData | null =
      native.ZAppDesktopBridge.embeddedAssetDataAtIndex(index);
    if (data == null) {
      failAssetRequest(task, 500, "Could not decode embedded asset");
      return;
    }

    const mimeType: Foundation.NSString = assetMimeType(path);
    const response: Foundation.NSURLResponse = assetResponse(url, data, mimeType);
    task.didReceiveResponse(response);
    task.didReceiveData(data);
    task.didFinish();
  }

  function stop(
    in webView: WebKit.WKWebView,
    in task: WebKit.WKURLSchemeTask
  ): void as "webView:stopURLSchemeTask:" {
    // WebKit may stop a task after navigation or cancellation. Embedded asset
    // delivery is synchronous today, so there is no in-flight native work to
    // cancel after the callback returns.
  }
}

internal function createDesktopAssetSchemeHandler(
): objc.Adapter<WebKit.WKURLSchemeHandler> on thread.main {
  const controller = new DesktopAssetSchemeHandler({});
  return objc.adapt<WebKit.WKURLSchemeHandler>(controller);
}
