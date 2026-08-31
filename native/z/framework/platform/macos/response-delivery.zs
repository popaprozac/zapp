import native from "zapp_desktop.h";
import json from "std/json";
import { TextBuffer } from "std/text";
import { thread } from "std/thread";
import { BridgeResponse } from "../../bridge.zs";
import { configuredFrontendIsDevelopment } from "./configured-webview.zs";
import { setMacOSApplicationResult } from "./application-host.zs";

readonly struct WebViewResponseEnvelope {
  id: String;
  ok: boolean;
  payload: String;
}

function javascriptJSON(in source: String): String {
  let output = TextBuffer();
  let segmentStart: usize = 0;
  let offset: usize = 0;
  const length = source.byteLength;
  while (offset + 2 < length) {
    const separator = source.byteAt(offset) == 226
      && source.byteAt(offset + 1) == 128
      && (
        source.byteAt(offset + 2) == 168
        || source.byteAt(offset + 2) == 169
      );
    if (!separator) {
      offset = offset + 1;
      continue;
    }
    output.appendBytes(source, segmentStart, offset);
    if (source.byteAt(offset + 2) == 168) output.append("\\u2028");
    else output.append("\\u2029");
    offset = offset + 3;
    segmentStart = offset;
  }
  output.appendBytes(source, segmentStart, length);
  return output.finish();
}

function responseScript(in response: BridgeResponse): String {
  const envelope = WebViewResponseEnvelope({
    id: `${response.id}`,
    ok: response.ok,
    payload: copy response.payload,
  });
  const encoded = json.encode(in envelope);
  const source = javascriptJSON(in encoded);
  return `(()=>{const r=${source};const b=globalThis[Symbol.for('zapp.bridge')];if(!b||typeof b._onInvokeResult!=='function'){throw new Error('Zapp bridge is unavailable')}b._onInvokeResult(Number(r.id),r.ok,r.payload)})()`;
}

internal function deliverWebViewResponse(
  in webView: native.WKWebView,
  in window: native.NSWindow,
  in response: BridgeResponse,
  windowId: i32,
  activeWindowCount: usize
): void on thread.main {
  const script = responseScript(in response);
  const payload = copy response.payload;
  const requestId = response.id;
  const development = configuredFrontendIsDevelopment();
  const ok = response.ok;
  webView.evaluateJavaScript(
    move script,
    completionHandler: move (value, error): void => {
      if (error != null) {
        setMacOSApplicationResult(45);
        window.close();
        return;
      }
      native.ZAppDesktopBridge.observeResponseInWebView(
        webView,
        nativeId: windowId,
        payload: payload,
        requestId: requestId,
        activeWindowCount: activeWindowCount,
        development: development,
        ok: ok
      );
    }
  );
}
