import WebKit from "WebKit/WebKit.h";
import json from "std/json";
import { thread } from "std/thread";
import { BridgeDocument } from "../../bridge-document.zs";
import { RelatedDocumentIdentity } from "../../related-documents.zs";
import { javascriptJSON, reportEncodingFailure } from "./response-delivery.zs";

readonly struct RelatedInvalidationEnvelope {
  ownerToken: String;
  windowId: String;
  documentToken: String;
  reason: String;
}

internal function deliverRelatedDocumentCreated(
  in webView: WebKit.WKWebView, owner: BridgeDocument,
  in ownerIdentity: RelatedDocumentIdentity, in child: RelatedDocumentIdentity
): void on thread.main {
  if (!owner.isCurrent(in ownerIdentity)) return;
  const event = RelatedInvalidationEnvelope({ ownerToken: `${ownerIdentity.token}`,
    windowId: `related-${child.windowId}`, documentToken: `${child.token}`, reason: "" });
  const encoded = match (attempt json.encode(in event)) {
    success(value) => value;
    failure(error) => { reportEncodingFailure(in error); return; }
  };
  const source = javascriptJSON(in encoded);
  const script = `(()=>{const e=${source};const b=globalThis[Symbol.for('zapp.bridge')];return !!b&&typeof b._onRelatedDocumentCreated==='function'&&b._onRelatedDocumentCreated(e.ownerToken,e.windowId,e.documentToken)})()`;
  webView.evaluateJavaScript(move script, completionHandler: move (value, error): void => {});
}

// Committed native retirement precedes this best-effort notification. Neither
// teardown nor cancellation waits for evaluation/JS listeners. Both checks
// matter: evaluation can land in a replacement realm after native submission.
internal function deliverRelatedDocumentInvalidated(
  in webView: WebKit.WKWebView,
  owner: BridgeDocument,
  in ownerIdentity: RelatedDocumentIdentity,
  in child: RelatedDocumentIdentity
): void on thread.main {
  if (!owner.isCurrent(in ownerIdentity)) return;
  const event = RelatedInvalidationEnvelope({ ownerToken: `${ownerIdentity.token}`,
    windowId: `related-${child.windowId}`, documentToken: `${child.token}`,
    reason: "The related document was closed or retired." });
  const encoded = match (attempt json.encode(in event)) {
    success(value) => value;
    failure(error) => { reportEncodingFailure(in error); return; }
  };
  const source = javascriptJSON(in encoded);
  const script = `(()=>{const e=${source};const b=globalThis[Symbol.for('zapp.bridge')];return !!b&&typeof b._onRelatedDocumentInvalidated==='function'&&b._onRelatedDocumentInvalidated(e.ownerToken,e.windowId,e.documentToken,e.reason)})()`;
  webView.evaluateJavaScript(move script, completionHandler: move (value, error): void => {});
}
