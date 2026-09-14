// The child allocator, delegates, sender validation, handshake, deadline, and
// rollback are production Z code. Only the root page's prepare route is a probe.
import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import process from "std/process";
import console from "std/console";
import json from "std/json";
import { Set } from "std/collections";
import { thread } from "std/thread";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { BridgeDocument } from "../framework/bridge-document.zs";
import { RelatedDocuments, RelatedDocumentIdentity, createRelatedDocuments } from "../framework/related-documents.zs";
import { RelatedWindowCreations, RelatedWindowReservation, RelatedCreationReply, RelatedCreationResult } from "../framework/related-window-creations.zs";
import { MacOSRelatedWindows, createRelatedWindowUIDelegate } from "../framework/platform/macos/related-window-creations.zs";
import { DesktopMessageHandler } from "../framework/platform/macos/message-handler.zs";
import { DesktopRouteMessageOperation, requestBridgeDocumentBinding } from "../framework/platform/macos/document-transport.zs";
import { installWebViewScripts } from "../framework/platform/macos/webview-injections.zs";
import { createDesktopAssetSchemeHandler } from "../framework/platform/macos/scheme-handler.zs";

readonly struct Request { t: i32 = 0; id: u64 = 0; m: String = ""; }
function reply(view: WebKit.WKWebView, in identity: RelatedDocumentIdentity, id: u64, payload: String): void on thread.main {
  const value = json.JsonValue.string(move payload);
  const encoded = json.stringify(in value);
  view.evaluateJavaScript(`globalThis[Symbol.for('zapp.bridge')]._onDocumentInvokeResult('${identity.token}',${id},true,${encoded})`,
    completionHandler: move (value, error): void => {});
}

class State on thread.main {
  readonly owner: BridgeDocument;
  readonly view: WebKit.WKWebView;
  coordinator: Option<MacOSRelatedWindows>;
  reservation: Option<RelatedWindowReservation>;
  identity: Option<RelatedDocumentIdentity>;
  completionId: u64;
  completions: i32;
  failures: i32;
  echoes: i32;
  passed: boolean;
  failed: boolean;

  function current(): Option<MacOSRelatedWindows> {
    return match (in this.coordinator) {
      some(value) => { const retained: MacOSRelatedWindows = value; select Option.some(retained); }
      none => Option.none;
    };
  }

  function completed(inout this, result: RelatedCreationResult): void {
    match (result) {
      ready(child) => {
        this.completions = this.completions + 1;
        const identity = match (copy this.identity) { some(value) => value; none => { this.failed = true; return; } };
        if (this.completionId == 0 || !this.owner.isCurrent(in identity)) { this.failed = true; return; }
        reply(this.view, in identity, this.completionId, "true");
      }
      failed(_) => {
        this.failures = this.failures + 1;
        const coordinator = match (this.current()) { some(value) => value; none => { this.failed = true; return; } };
        if (coordinator.count() != 0) this.failed = true;
      }
    }
  }

  function route(inout this, message: String, identity: RelatedDocumentIdentity): void {
    const request = match (attempt json.decode<Request>(message)) { success(value) => value; failure(_) => { this.failed = true; return; } };
    if (request.t == 4 && request.m == "ready") return;
    const coordinator = match (this.current()) { some(value) => value; none => { this.failed = true; return; } };
    if (identity.windowId == 1) {
      if (request.m == "prepare" || request.m == "prepareFailure") {
        if (request.m == "prepare" && this.failures != 1) { this.failed = true; return; }
        this.identity = Option.some(copy identity);
        const weakOwner = weak this;
        const completion: RelatedCreationReply = move (result: RelatedCreationResult): void => {
          match (attempt weakOwner.upgrade()) { success(owner) => owner.completed(move result); failure(_) => {} }
        };
        const reservation = match (coordinator.prepare(this.owner, this.view, in identity, 2,
          "Zapp production related child", 320, 200, completion)) {
          some(value) => value; none => { this.failed = true; return; }
        };
        this.reservation = Option.some(copy reservation);
        const address = match (coordinator.address(in reservation)) { some(value) => value; none => { this.failed = true; return; } };
        const value = json.JsonValue.string(move address);
        const encoded = json.stringify(in value);
        reply(this.view, in identity, request.id, move encoded);
        return;
      }
      if (request.m == "rollback") {
        const reservation = match (copy this.reservation) { some(value) => value; none => { this.failed = true; return; } };
        coordinator.fail(in reservation);
        reply(this.view, in identity, request.id, "true");
        return;
      }
      if (request.m == "completion") { this.completionId = request.id; return; }
      if (request.m == "pass") { this.passed = true; return; }
    }
    if (request.m == "echo" && identity.windowId == 2 && this.completions == 1) {
      const runtime = match (coordinator.runtime(in identity)) { some(value) => value; none => { this.failed = true; return; } };
      if (!runtime.document.isActivated(in identity) || !runtime.document.capabilities.allowsService("notes.list")
        || runtime.document.capabilities.allowsService("admin.erase")) { this.failed = true; return; }
      this.echoes = this.echoes + 1;
      reply(runtime.webView, in identity, request.id, "42");
      return;
    }
    this.failed = true;
  }
}

class RootNavigation on thread.main implements WebKit.WKNavigationDelegate {
  readonly document: BridgeDocument;
  readonly related: MacOSRelatedWindows;
  function commit(inout this, in view: WebKit.WKWebView, in navigation: WebKit.WKNavigation | null): void as "webView:didCommitNavigation:" {
    this.document.didCommit();
    this.related.pruneInvalidated();
    requestBridgeDocumentBinding(in view);
  }
}

function main(): i32 on thread.main {
  const args = process.args();
  if (args.length != 2 && args.length != 3) return 2;
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  app.finishLaunching();
  let permissions = Set<String>();
  permissions.add("window:create");
  let services = Set<String>();
  services.add("notes.list");
  let workers = Set<String>();
  let names = Array<String>("notes");
  const selection = new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(),
    serviceMethods: services.freeze(), workerIds: workers.freeze() });
  const documents = createRelatedDocuments();
  const creations = new RelatedWindowCreations(documents);
  const owner = new BridgeDocument(1, documents, selection);
  const controller = WebKit.WKUserContentController.alloc().init();
  const inject = Array<String>();
  const id = "owner";
  match (attempt installWebViewScripts(controller, in id, in inject)) { success => {} failure(_) => return 3; }
  const configuration = WebKit.WKWebViewConfiguration.alloc().init();
  configuration.userContentController = controller;
  configuration.preferences.javaScriptCanOpenWindowsAutomatically = true;
  configuration.websiteDataStore = WebKit.WKWebsiteDataStore.nonPersistentDataStore();
  const scheme = createDesktopAssetSchemeHandler();
  configuration.setURLSchemeHandler(scheme, forURLScheme: "zapp");
  const view = WebKit.WKWebView.alloc().initWithFrame(WebKit.NSMakeRect(0, 0, 320, 200), configuration: configuration);
  const state = new State({ owner, view, coordinator: Option<MacOSRelatedWindows>.none,
    reservation: Option<RelatedWindowReservation>.none, identity: Option<RelatedDocumentIdentity>.none,
    completionId: 0, completions: 0, failures: 0, echoes: 0, passed: false, failed: false });
  const weakState = weak state;
  const route: DesktopRouteMessageOperation = move (message: String, identity: RelatedDocumentIdentity): void => {
    match (attempt weakState.upgrade()) { success(state) => state.route(move message, identity); failure(_) => {} }
  };
  const related = new MacOSRelatedWindows(documents, creations, route);
  state.coordinator = Option.some(related);
  const handler = new DesktopMessageHandler({ document: owner, expectedView: view, expectedController: controller, routeMessage: route });
  const registration = objc.register({ add: controller.addScriptMessageHandler(handler, "zapp"), remove: controller.removeScriptMessageHandlerForName("zapp") });
  const navigationController = new RootNavigation({ document: owner, related });
  const navigation = objc.adapt<WebKit.WKNavigationDelegate>(navigationController);
  const ui = createRelatedWindowUIDelegate(related);
  view.navigationDelegate = navigation;
  view.UIDelegate = ui;
  const window = WebKit.NSWindow.alloc().initWithContentRect(WebKit.NSMakeRect(100, 100, 320, 200),
    styleMask: WebKit.NSWindowStyleMaskTitled, backing: WebKit.NSBackingStoreBuffered, defer: false);
  window.releasedWhenClosed = false;
  window.contentView = view;
  window.makeKeyAndOrderFront(null);
  const url = WebKit.NSURL.URLWithString(`${args[0]}/owner.html`);
  if (url == null) return 4;
  view.loadRequest(WebKit.NSURLRequest.requestWithURL(url));
  let ticks: i32 = 0;
  while (!state.failed && !(state.passed && related.count() == 0) && ticks < 200) {
    WebKit.NSRunLoop.currentRunLoop.runUntilDate(WebKit.NSDate.dateWithTimeIntervalSinceNow(0.05));
    ticks = ticks + 1;
  }
  const pass = !state.failed && state.passed && state.completions == 1 && state.failures == 1
    && state.echoes == 1 && related.count() == 0 && creations.count() == 0 && documents.count() == 1;
  related.closeAll();
  owner.close();
  view.stopLoading();
  window.close();
  console.log(`related production WebKit: pass=${pass} completed=${state.completions} failed=${state.failures} echoes=${state.echoes}`);
  return pass ? 0 : 1;
}
