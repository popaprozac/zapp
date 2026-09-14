import WebKit from "WebKit/WebKit.h";
import json from "std/json";
import { thread } from "std/thread";
import { BridgeDocument } from "../../bridge-document.zs";
import { RelatedDocumentIdentity } from "../../related-documents.zs";

internal type DesktopRouteMessageOperation = (
  message: String,
  document: RelatedDocumentIdentity
) => void on thread.main;

readonly struct DocumentBinding {
  realm: String;
  token: String;
  shell: boolean;
}

function confirmDocumentShell(
  document: BridgeDocument,
  webView: WebKit.WKWebView,
  token: String,
  realm: String
): void on thread.main {
  if (!document.requiresShell() || !document.bindingMatches(in token, in realm)) return;
  const binding = DocumentBinding({ realm: copy realm, token: copy token, shell: true });
  const encoded = json.encode(in binding);
  const probe = `(()=>{const r=${encoded};const b=globalThis[Symbol.for('zapp.bridge')];return !!b&&typeof b._documentShellReady==='function'&&b._documentShellReady(r.realm,r.token)})()`;
  webView.evaluateJavaScript(move probe, completionHandler: move (value, error): void => {
    if (error != null || !(value instanceof WebKit.NSNumber)) return;
    if (!value.boolValue || !document.observeShell(in token, in realm)) return;
    // Registry readiness precedes queued JS calls. The eventual script checks
    // its realm/token/disposal again; native acceptance still rejects retirement
    // even if this activation was queued before JS disposal could run.
    const activation = `(()=>{const r=${encoded};const b=globalThis[Symbol.for('zapp.bridge')];return !!b&&typeof b._activateDocument==='function'&&b._activateDocument(r.realm,r.token)})()`;
    // The nested callback owns its snapshots independently of this callback's
    // environment; native completion lifetime must not borrow outer storage.
    const activationToken = copy token;
    const activationRealm = copy realm;
    webView.evaluateJavaScript(move activation, completionHandler: move (result, failure): void => {
      if (failure != null || !(result instanceof WebKit.NSNumber) || !result.boolValue) return;
      document.observeActivation(in activationToken, in activationRealm);
    });
  });
}

function lineEnd(in source: String): usize {
  let index: usize = 0;
  while (index < source.byteLength) {
    if (source.byteAt(index) == 10) return index;
    index = index + 1;
  }
  return index;
}

function validRealm(in realm: String): boolean {
  if (realm.byteLength != 32) return false;
  let index: usize = 0;
  while (index < realm.byteLength) {
    const byte = realm.byteAt(index);
    if (!(byte >= 48 && byte <= 57) && !(byte >= 97 && byte <= 102)) return false;
    index = index + 1;
  }
  return true;
}

internal function requestBridgeDocumentBinding(in webView: WebKit.WKWebView): void on thread.main {
  webView.evaluateJavaScript(
    "(()=>{const b=globalThis[Symbol.for('zapp.bridge')];if(b&&typeof b._requestDocumentBinding==='function')b._requestDocumentBinding()})()",
    completionHandler: move (value, error): void => {}
  );
}

// Only called after the handler validates its exact WebView, controller,
// main frame and configured origin. Native identities never come from JSON.
internal function routeDocumentMessage(
  document: BridgeDocument,
  in webView: WebKit.WKWebView,
  message: String,
  route: DesktopRouteMessageOperation
): void on thread.main {
  const end = lineEnd(in message);
  if (end == message.byteLength || end == 0) return;
  const tag = message.copyBytes(0, end);
  const body = message.copyBytes(end + 1, message.byteLength);
  if (tag == "@hello") {
    if (!validRealm(in body)) return;
    match (document.offer(in body)) {
      some(identity) => {
        const binding = DocumentBinding({ realm: copy body, token: `${identity.token}`, shell: document.requiresShell() });
        const source = json.encode(in binding);
        const script = `(()=>{const r=${source};const b=globalThis[Symbol.for('zapp.bridge')];return !!b&&typeof b._bindDocument==='function'&&b._bindDocument(r.realm,r.token,r.shell)})()`;
        webView.evaluateJavaScript(move script, completionHandler: move (value, error): void => {});
      }
      none => {}
    }
    return;
  }
  if (tag == "@ready") {
    const tokenEnd = lineEnd(in body);
    if (tokenEnd == body.byteLength) return;
    const token = body.copyBytes(0, tokenEnd);
    const realm = body.copyBytes(tokenEnd + 1, body.byteLength);
    if (validRealm(in realm)) {
      document.acknowledge(in token, copy realm);
      confirmDocumentShell(document, webView, move token, move realm);
    }
    return;
  }
  if (tag.byteAt(0) != 64) return;
  const token = tag.copyBytes(1, tag.byteLength);
  match (document.accept(in token)) {
    some(identity) => route(move body, identity);
    none => {}
  }
}
