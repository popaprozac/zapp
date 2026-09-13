import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import fs from "std/fs";
import process from "std/process";
import console from "std/console";
import json from "std/json";
import { Set } from "std/collections";
import { thread } from "std/thread";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { BridgeDocument } from "../framework/bridge-document.zs";
import { RelatedDocuments, RelatedDocumentIdentity, RelatedDocumentRequest, createRelatedDocuments } from "../framework/related-documents.zs";
import { DesktopRouteMessageOperation, routeDocumentMessage, requestBridgeDocumentBinding } from "../framework/platform/macos/document-transport.zs";

readonly struct ProbeMessage { t: i32 = 0; id: u64 = 0; m: String = ""; }

class Observations on thread.main {
  readonly documents: RelatedDocuments;
  previous: Option<RelatedDocumentRequest>;
  commits: i32;
  staleIgnored: boolean;
  finished: boolean;
  failed: boolean;

  function fail(inout this): void { this.failed = true; this.finished = true; }
  function committed(inout this): void { this.commits = this.commits + 1; }

  function route(inout this, in webView: WebKit.WKWebView, message: String, document: RelatedDocumentIdentity): void {
    const decoded = attempt json.decode<ProbeMessage>(message);
    const request = match (decoded) { success(value) => value; failure(_) => { this.fail(); return; } };
    if (request.t == 4 && request.m == "ready") return;
    if (request.m == "hold") {
      this.previous = this.documents.beginRequest(in document, request.id);
      webView.evaluateJavaScript("location.href='/new.html'", completionHandler: move (value, error): void => {});
      return;
    }
    if (request.m == "ping") {
      const previous = match (copy this.previous) { some(ticket) => ticket; none => { this.fail(); return; } };
      if (previous.document.token == document.token || this.documents.finishRequest(in previous)) { this.fail(); return; }
      // Deliberately enqueue the OLD reply in the replacement WebView before
      // its legitimate reply. Both documents use request ID 1.
      const script = `(()=>{const b=globalThis[Symbol.for('zapp.bridge')];const accepted=b._onDocumentInvokeResult('${previous.document.token}',1,true,'99');b.post(JSON.stringify({t:3,m:accepted?'fail':'stale'}));b._onDocumentInvokeResult('${document.token}',1,true,'42')})()`;
      webView.evaluateJavaScript(move script, completionHandler: move (value, error): void => {});
      return;
    }
    if (request.m == "stale") { this.staleIgnored = true; return; }
    if (request.m == "pass" && this.staleIgnored && this.commits == 2) { this.finished = true; return; }
    this.fail();
  }
}

class ProbeMessages on thread.main implements WebKit.WKScriptMessageHandler {
  readonly state: Observations;
  readonly document: BridgeDocument;
  readonly view: WebKit.WKWebView;
  readonly controller: WebKit.WKUserContentController;
  readonly oldURL: String;
  readonly newURL: String;
  readonly route: DesktopRouteMessageOperation;

  function receive(inout this, in controller: WebKit.WKUserContentController, in message: WebKit.WKScriptMessage): void as "userContentController:didReceiveScriptMessage:" {
    if (controller != this.controller || message.webView != this.view || !message.frameInfo.mainFrame) { this.state.fail(); return; }
    const url = message.frameInfo.request.URL;
    if (url == null) { this.state.fail(); return; }
    const absolute = url.absoluteString;
    if (absolute == null) { this.state.fail(); return; }
    const address: String = absolute;
    if (address != this.oldURL && address != this.newURL) { this.state.fail(); return; }
    const body = message.body;
    if (!(body instanceof WebKit.NSString)) { this.state.fail(); return; }
    const text: String = body;
    routeDocumentMessage(this.document, in this.view, move text, this.route);
  }
}

class ProbeNavigation on thread.main implements WebKit.WKNavigationDelegate {
  readonly state: Observations;
  readonly document: BridgeDocument;
  function commit(inout this, in webView: WebKit.WKWebView, in navigation: WebKit.WKNavigation | null): void as "webView:didCommitNavigation:" {
    this.state.committed();
    this.document.didCommit();
    requestBridgeDocumentBinding(in webView);
  }
}

function selection(): CapabilitySelection {
  let names = Array<String>();
  let permissions = Set<String>();
  let services = Set<String>();
  let workers = Set<String>();
  return new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(), serviceMethods: services.freeze(), workerIds: workers.freeze() });
}

function main(): i32 on thread.main {
  const args = process.args();
  if (args.length != 2) return 2;
  const bootstrap = match (attempt fs.readText(args[1])) { success(value) => value; failure(_) => return 3; };
  const oldURL = `${args[0]}/old.html`;
  const newURL = `${args[0]}/new.html`;
  const url = WebKit.NSURL.URLWithString(copy oldURL);
  if (url == null) return 4;
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  app.finishLaunching();
  const controller = WebKit.WKUserContentController.alloc().init();
  controller.addUserScript(WebKit.WKUserScript.alloc().initWithSource(
    `globalThis[Symbol.for('zapp.documentTransport')]=1;${bootstrap}`,
    injectionTime: WebKit.WKUserScriptInjectionTimeAtDocumentStart, forMainFrameOnly: true));
  const config = WebKit.WKWebViewConfiguration.alloc().init();
  config.userContentController = controller;
  config.websiteDataStore = WebKit.WKWebsiteDataStore.nonPersistentDataStore();
  const view = WebKit.WKWebView.alloc().initWithFrame(WebKit.NSMakeRect(0, 0, 300, 180), configuration: config);
  const documents = createRelatedDocuments();
  const document = new BridgeDocument(1, documents, selection());
  const state = new Observations({ documents, previous: Option<RelatedDocumentRequest>.none, commits: 0, staleIgnored: false, finished: false, failed: false });
  const route: DesktopRouteMessageOperation = move (message: String, identity: RelatedDocumentIdentity): void => state.route(in view, move message, identity);
  const messages = new ProbeMessages({ state, document, view, controller, oldURL, newURL, route });
  const registration = objc.register({ add: controller.addScriptMessageHandler(messages, "zapp"), remove: controller.removeScriptMessageHandlerForName("zapp") });
  const navigationController = new ProbeNavigation({ state, document });
  const navigation = objc.adapt<WebKit.WKNavigationDelegate>(navigationController);
  view.navigationDelegate = navigation;
  const window = WebKit.NSWindow.alloc().initWithContentRect(WebKit.NSMakeRect(200, 200, 300, 180), styleMask: WebKit.NSWindowStyleMaskTitled, backing: WebKit.NSBackingStoreBuffered, defer: false);
  window.releasedWhenClosed = false;
  window.title = "Zapp document routing probe";
  window.contentView = view;
  window.makeKeyAndOrderFront(null);
  view.loadRequest(WebKit.NSURLRequest.requestWithURL(url));
  let attempts: i32 = 0;
  while (!state.finished && attempts < 200) {
    WebKit.NSRunLoop.currentRunLoop.runUntilDate(WebKit.NSDate.dateWithTimeIntervalSinceNow(0.05));
    attempts = attempts + 1;
  }
  document.close();
  window.close();
  const pass = state.finished && !state.failed && documents.count() == 0;
  console.log(`document routing WebKit: pass=${pass} commits=${state.commits} staleIgnored=${state.staleIgnored}`);
  return pass ? 0 : 1;
}
