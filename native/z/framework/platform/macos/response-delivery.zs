import WebKit from "WebKit/WebKit.h";
import json from "std/json";
import { TextBuffer } from "std/text";
import { thread } from "std/thread";
import { BridgeResponse } from "../../bridge.zs";
import { configuredFrontendIsDevelopment } from "./configured-webview.zs";
import { setMacOSApplicationResult } from "./application-host.zs";
import {
  observeConfiguredWebViewResponse,
} from "./configured-smoke.zs";

readonly struct WebViewResponseEnvelope {
  id: String;
  ok: boolean;
  payload: String;
}

readonly struct WebViewWindowEventEnvelope {
  windowId: String;
  eventName: String;
  dataJson: String;
}

readonly struct WebViewApplicationWorkerMessageEnvelope {
  workerId: String;
  channel: String;
  payload: String;
}

readonly struct WebViewMenuCommandEnvelope {
  ownerToken: String;
  commandId: String;
}

readonly struct WebViewWindowSizePayload {
  width: u32;
  height: u32;
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

function windowEventScript(
  in windowId: String,
  in eventName: String,
  in dataJson: String
): String {
  const envelope = WebViewWindowEventEnvelope({
    windowId: copy windowId,
    eventName: copy eventName,
    dataJson: copy dataJson,
  });
  const encoded = json.encode(in envelope);
  const source = javascriptJSON(in encoded);
  return `(()=>{const e=${source};const b=globalThis[Symbol.for('zapp.bridge')];if(!b||typeof b.dispatchWindowEvent!=='function')return;b.dispatchWindowEvent(e.windowId,e.eventName,e.dataJson||undefined)})()`;
}

function applicationWorkerMessageScript(
  in workerId: String,
  in channel: String,
  in payload: String
): String {
  const envelope = WebViewApplicationWorkerMessageEnvelope({
    workerId: copy workerId,
    channel: copy channel,
    payload: copy payload,
  });
  const encoded = json.encode(in envelope);
  const source = javascriptJSON(in encoded);
  return `(()=>{const e=${source};const b=globalThis[Symbol.for('zapp.bridge')];if(!b||typeof b.dispatchApplicationWorkerMessage!=='function')return;b.dispatchApplicationWorkerMessage(e.workerId,e.channel,e.payload)})()`;
}

function menuCommandScript(
  in ownerToken: String,
  in commandId: String
): String {
  const envelope = WebViewMenuCommandEnvelope({
    ownerToken: copy ownerToken,
    commandId: copy commandId,
  });
  const encoded = json.encode(in envelope);
  const source = javascriptJSON(in encoded);
  return `(()=>{const e=${source};const b=globalThis[Symbol.for('zapp.bridge')];if(!b||typeof b.dispatchMenuCommand!=='function')return;b.dispatchMenuCommand(e.ownerToken,e.commandId)})()`;
}

internal function deliverWebViewMenuCommand(
  in webView: WebKit.WKWebView,
  in ownerToken: String,
  in commandId: String
): void on thread.main {
  const script = menuCommandScript(in ownerToken, in commandId);
  webView.evaluateJavaScript(
    move script,
    completionHandler: move (value, error): void => {}
  );
}

internal function deliverWebViewWindowEvent(
  in webView: WebKit.WKWebView,
  in windowId: String,
  in eventName: String
): void on thread.main {
  const script = windowEventScript(in windowId, in eventName, "");
  webView.evaluateJavaScript(
    move script,
    completionHandler: move (value, error): void => {}
  );
}

internal function deliverWebViewWindowResize(
  in webView: WebKit.WKWebView,
  in windowId: String,
  width: u32,
  height: u32
): void on thread.main {
  const payload = WebViewWindowSizePayload({ width, height });
  const dataJson = json.encode(in payload);
  const script = windowEventScript(in windowId, "resize", in dataJson);
  webView.evaluateJavaScript(
    move script,
    completionHandler: move (value, error): void => {}
  );
}

internal function deliverWebViewApplicationWorkerMessage(
  in webView: WebKit.WKWebView,
  in workerId: String,
  in channel: String,
  in payload: String
): void on thread.main {
  const script = applicationWorkerMessageScript(
    in workerId,
    in channel,
    in payload
  );
  webView.evaluateJavaScript(
    move script,
    completionHandler: move (value, error): void => {}
  );
}

internal function deliverWebViewResponse(
  in webView: WebKit.WKWebView,
  in window: WebKit.NSWindow,
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
      observeConfiguredWebViewResponse(
        in webView,
        windowId,
        activeWindowCount,
        in payload,
        requestId,
        development,
        ok
      );
    }
  );
}
