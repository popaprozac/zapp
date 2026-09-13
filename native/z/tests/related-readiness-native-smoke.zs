// Real WebKit child creation with the production inherited document endpoint.
// This is a bounded integration fixture, not the public RelatedWindow factory.
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
import { RelatedDocuments, RelatedDocumentIdentity, createRelatedDocuments } from "../framework/related-documents.zs";
import { DesktopRouteMessageOperation, routeDocumentMessage, requestBridgeDocumentBinding } from "../framework/platform/macos/document-transport.zs";
import { createDesktopAssetSchemeHandler } from "../framework/platform/macos/scheme-handler.zs";

readonly struct ProbeMessage { t: i32 = 0; id: u64 = 0; m: String = ""; }

function reply(view: WebKit.WKWebView, in document: RelatedDocumentIdentity, id: u64, payload: String): void on thread.main {
  const script = `globalThis[Symbol.for('zapp.bridge')]._onDocumentInvokeResult('${document.token}',${id},true,'${payload}')`;
  view.evaluateJavaScript(move script, completionHandler: move (value, error): void => {});
}

class ChildEndpoint on thread.main {
  readonly view: WebKit.WKWebView;
  readonly window: WebKit.NSWindow;
  readonly document: BridgeDocument;
  readonly registration: objc.Registration;
  readonly navigation: objc.Adapter<WebKit.WKNavigationDelegate>;
  readonly ui: objc.Adapter<WebKit.WKUIDelegate>;
}

class Observations on thread.main {
  readonly documents: RelatedDocuments;
  readonly owner: BridgeDocument;
  preparing: Option<BridgeDocument>;
  ownerIdentity: Option<RelatedDocumentIdentity>;
  children: Array<ChildEndpoint>;
  created: i32;
  rejected: i32;
  replies: i32;
  closed: i32;
  childPassed: boolean;
  failed: boolean;

  function fail(inout this): void { this.failed = true; }
  function reject(inout this): void { this.rejected = this.rejected + 1; }
  function finished(): boolean { return this.failed || (this.childPassed && this.closed == 1); }

  function claim(inout this): Option<BridgeDocument> {
    const identity = match (copy this.ownerIdentity) { some(value) => value; none => return Option.none; };
    if (!this.owner.isCurrent(in identity)) return Option.none;
    return this.takePreparing();
  }

  private function takePreparing(inout this): Option<BridgeDocument> {
    // Retain the direct ARC endpoint before clearing its optional reservation.
    // Whole-Option replace still requires nested ARC alias-transfer support.
    const document = match (in this.preparing) { some(value) => value; none => return Option.none; };
    this.preparing = Option.none;
    return Option.some(document);
  }

  function add(inout this, child: ChildEndpoint): void {
    this.children.push(child);
    this.created = this.created + 1;
  }

  function closeChild(inout this, in view: WebKit.WKWebView): void {
    if (this.closed != 0) return;
    let index: usize = 0;
    while (index < this.children.length) {
      const child = this.children[index];
      if (child.view == view) {
        child.document.close();
        child.window.close();
        this.closed = this.closed + 1;
        if (this.documents.count() != 1) this.fail();
        return;
      }
      index = index + 1;
    }
    this.fail();
  }

  function route(inout this, view: WebKit.WKWebView, message: String, identity: RelatedDocumentIdentity): void {
    const request = match (attempt json.decode<ProbeMessage>(message)) {
      success(value) => value;
      failure(_) => { this.fail(); return; }
    };
    if (request.t == 4 && request.m == "ready") return;
    if (request.m == "prepare" && identity.windowId == 1 && this.created == 0) {
      if (!this.owner.isCurrent(in identity)) { this.fail(); return; }
      this.ownerIdentity = Option.some(copy identity);
      this.preparing = BridgeDocument.beginRelated(2, this.documents, in identity);
      reply(view, in identity, request.id, "true");
      return;
    }
    if (request.m == "echo" && identity.windowId == 2) {
      const authority = match (this.documents.capabilitiesFor(in identity)) {
        some(value) => value;
        none => { this.fail(); return; }
      };
      if (!authority.allowsService("notes.list") || authority.allowsService("admin.erase")) { this.fail(); return; }
      this.replies = this.replies + 1;
      reply(view, in identity, request.id, "42");
      return;
    }
    if (request.m == "pass" && identity.windowId == 2) { this.childPassed = true; return; }
    this.fail();
  }

  function cleanup(inout this): void {
    match (this.takePreparing()) { some(document) => document.close(); none => {} }
    let index: usize = 0;
    while (index < this.children.length) {
      const child = this.children[index];
      child.document.close();
      child.view.stopLoading();
      child.window.close();
      index = index + 1;
    }
    // Drop registrations explicitly while the state owner is still live. The
    // native controller -> callback -> state path must not retain this array.
    this.children = Array<ChildEndpoint>();
  }
}

class Messages on thread.main implements WebKit.WKScriptMessageHandler {
  readonly state: Observations;
  readonly document: BridgeDocument;
  readonly view: WebKit.WKWebView;
  readonly controller: WebKit.WKUserContentController;
  readonly address: String;
  readonly route: DesktopRouteMessageOperation;

  function receive(inout this, in controller: WebKit.WKUserContentController, in message: WebKit.WKScriptMessage): void as "userContentController:didReceiveScriptMessage:" {
    if (controller != this.controller || message.webView != this.view || !message.frameInfo.mainFrame) { this.state.fail(); return; }
    const url = message.frameInfo.request.URL;
    if (url == null) { this.state.fail(); return; }
    const absolute = url.absoluteString;
    if (absolute == null) { this.state.fail(); return; }
    const address: String = absolute;
    if (address != this.address) { this.state.fail(); return; }
    const body = message.body;
    if (!(body instanceof WebKit.NSString)) { this.state.fail(); return; }
    const text: String = body;
    routeDocumentMessage(this.document, in this.view, move text, this.route);
  }
}

class Navigation on thread.main implements WebKit.WKNavigationDelegate {
  readonly document: BridgeDocument;
  function commit(inout this, in view: WebKit.WKWebView, in navigation: WebKit.WKNavigation | null): void as "webView:didCommitNavigation:" {
    this.document.didCommit();
    requestBridgeDocumentBinding(in view);
  }
}

class ChildUI on thread.main implements WebKit.WKUIDelegate {
  readonly state: Observations;
  function closed(inout this, in view: WebKit.WKWebView): void as "webViewDidClose:" {
    this.state.closeChild(in view);
  }
}

function install(controller: WebKit.WKUserContentController, in bootstrap: String): void on thread.main {
  controller.addUserScript(WebKit.WKUserScript.alloc().initWithSource(
    `globalThis[Symbol.for('zapp.documentTransport')]=1;${bootstrap}`,
    injectionTime: WebKit.WKUserScriptInjectionTimeAtDocumentStart, forMainFrameOnly: true));
}

class OwnerUI on thread.main implements WebKit.WKUIDelegate {
  readonly state: Observations;
  readonly owner: WebKit.WKWebView;
  readonly address: String;
  readonly bootstrap: String;
  readonly shellTest: boolean;

  function create(
    inout this,
    in owner: WebKit.WKWebView,
    in configuration: WebKit.WKWebViewConfiguration,
    in action: WebKit.WKNavigationAction,
    in features: WebKit.WKWindowFeatures
  ): WebKit.WKWebView | null as "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:" {
    if (owner != this.owner || action.targetFrame != null || !action.sourceFrame.mainFrame) return null;
    const url = action.request.URL;
    if (url == null) return null;
    const absolute = url.absoluteString;
    if (absolute == null) return null;
    const address: String = absolute;
    if (address != this.address) return null;
    const document = match (this.state.claim()) {
      some(value) => value;
      none => { this.state.reject(); return null; }
    };
    const controller = WebKit.WKUserContentController.alloc().init();
    configuration.userContentController = controller;
    install(controller, in this.bootstrap);
    if (this.shellTest) {
      // Test instrumentation is injected, not part of the framework's shell.
      // The early native call must wait for body parsing and native activation.
      controller.addUserScript(WebKit.WKUserScript.alloc().initWithSource(
        "(()=>{const b=globalThis[Symbol.for('zapp.bridge')];b.invoke('echo',{}, {timeout:0}).then(value=>{const pass=value===42&&!!document.head&&!!document.body&&document.scripts.length===0&&document.body.children.length===0&&opener.shared.value===41&&opener.document!==document;b.post(JSON.stringify({t:3,m:pass?'pass':'fail'}));window.close()})})()",
        injectionTime: WebKit.WKUserScriptInjectionTimeAtDocumentStart, forMainFrameOnly: true));
    }
    const view = WebKit.WKWebView.alloc().initWithFrame(WebKit.NSMakeRect(0, 0, 300, 180), configuration: configuration);
    const state = this.state;
    const route: DesktopRouteMessageOperation = move (message: String, identity: RelatedDocumentIdentity): void => state.route(view, move message, identity);
    const messages = new Messages({ state, document, view, controller, address, route });
    const registration = objc.register({ add: controller.addScriptMessageHandler(messages, "zapp"), remove: controller.removeScriptMessageHandlerForName("zapp") });
    const nav = new Navigation({ document });
    const navigation = objc.adapt<WebKit.WKNavigationDelegate>(nav);
    const close = new ChildUI({ state });
    const ui = objc.adapt<WebKit.WKUIDelegate>(close);
    view.navigationDelegate = navigation;
    view.UIDelegate = ui;
    const window = WebKit.NSWindow.alloc().initWithContentRect(WebKit.NSMakeRect(520, 200, 300, 180), styleMask: WebKit.NSWindowStyleMaskTitled, backing: WebKit.NSBackingStoreBuffered, defer: false);
    window.releasedWhenClosed = false;
    window.title = "Zapp related readiness child";
    window.contentView = view;
    this.state.add(new ChildEndpoint({ view, window, document, registration, navigation, ui }));
    window.makeKeyAndOrderFront(null);
    return view;
  }
}

function selection(): CapabilitySelection {
  let names = Array<String>("notes");
  let permissions = Set<String>();
  let services = Set<String>();
  let workers = Set<String>();
  permissions.add("window.create");
  services.add("notes.list");
  return new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(), serviceMethods: services.freeze(), workerIds: workers.freeze() });
}

function main(): i32 on thread.main {
  const args = process.args();
  if (args.length != 2 && args.length != 3) return 2;
  const shellTest = args.length == 3;
  const bootstrap = match (attempt fs.readText(args[1])) { success(value) => value; failure(_) => return 3; };
  const address = `${args[0]}/owner.html`;
  const childPath = shellTest ? "/.zapp/related.html" : "/child.html";
  const childAddress = `${args[0]}${childPath}`;
  const url = WebKit.NSURL.URLWithString(copy address);
  if (url == null) return 4;
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  app.finishLaunching();
  const controller = WebKit.WKUserContentController.alloc().init();
  install(controller, in bootstrap);
  const config = WebKit.WKWebViewConfiguration.alloc().init();
  config.userContentController = controller;
  const scheme = createDesktopAssetSchemeHandler();
  config.setURLSchemeHandler(scheme, forURLScheme: "zapp");
  config.websiteDataStore = WebKit.WKWebsiteDataStore.nonPersistentDataStore();
  config.preferences.javaScriptCanOpenWindowsAutomatically = true;
  const view = WebKit.WKWebView.alloc().initWithFrame(WebKit.NSMakeRect(0, 0, 300, 180), configuration: config);
  const documents = createRelatedDocuments();
  const document = new BridgeDocument(1, documents, selection());
  const state = new Observations({ documents, owner: document, preparing: Option<BridgeDocument>.none,
    ownerIdentity: Option<RelatedDocumentIdentity>.none, children: Array<ChildEndpoint>(),
    created: 0, rejected: 0, replies: 0, closed: 0, childPassed: false, failed: false });
  const route: DesktopRouteMessageOperation = move (message: String, identity: RelatedDocumentIdentity): void => state.route(view, move message, identity);
  const messages = new Messages({ state, document, view, controller, address, route });
  const registration = objc.register({ add: controller.addScriptMessageHandler(messages, "zapp"), remove: controller.removeScriptMessageHandlerForName("zapp") });
  const nav = new Navigation({ document });
  const navigation = objc.adapt<WebKit.WKNavigationDelegate>(nav);
  const owner = new OwnerUI({ state, owner: view, address: childAddress, bootstrap, shellTest });
  const ui = objc.adapt<WebKit.WKUIDelegate>(owner);
  view.navigationDelegate = navigation;
  view.UIDelegate = ui;
  const window = WebKit.NSWindow.alloc().initWithContentRect(WebKit.NSMakeRect(200, 200, 300, 180), styleMask: WebKit.NSWindowStyleMaskTitled, backing: WebKit.NSBackingStoreBuffered, defer: false);
  window.releasedWhenClosed = false;
  window.title = "Zapp related readiness owner";
  window.contentView = view;
  window.makeKeyAndOrderFront(null);
  view.loadRequest(WebKit.NSURLRequest.requestWithURL(url));
  let attempts: i32 = 0;
  while (!state.finished() && attempts < 200) {
    WebKit.NSRunLoop.currentRunLoop.runUntilDate(WebKit.NSDate.dateWithTimeIntervalSinceNow(0.05));
    attempts = attempts + 1;
  }
  state.cleanup();
  document.close();
  view.stopLoading();
  window.close();
  const pass = state.finished() && !state.failed && state.created == 1 && state.rejected == 1
    && state.replies == 1 && state.closed == 1 && documents.count() == 0;
  console.log(`related readiness WebKit: pass=${pass} created=${state.created} rejected=${state.rejected} replies=${state.replies} closed=${state.closed}`);
  return pass ? 0 : 1;
}
