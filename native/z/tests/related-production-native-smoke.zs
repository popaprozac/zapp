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
import { WindowManager, WindowOptions, WindowBackend, WindowCreateOperation, WindowOperation, WindowTitleOperation, createWindowManager } from "../framework/window.zs";
import { WindowError } from "../framework/application-error.zs";
import { WindowCloseRequestedEvent, WindowClosedEvent } from "../framework/events.zs";
import { WindowEventSubscription } from "../framework/window-events.zs";
import { MacOSWindow } from "../framework/platform/macos/window-resize.zs";
import { createDesktopWindowDelegate, NativeWindowClosedOperation } from "../framework/platform/macos/window-delegate.zs";

function backend(owner: Weak<MacOSRelatedWindows>, root: MacOSWindow): WindowBackend on thread.main {
  const create: WindowCreateOperation = (in id: String, in options): void => {};
  const show: WindowOperation = move (in id: String): void => {
    const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    match (windows.nativeWindow(in id)) { some(runtime) => runtime.window.orderFront(null); none => {} }
  };
  const hide: WindowOperation = move (in id: String): void => {
    const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    match (windows.nativeWindow(in id)) { some(runtime) => runtime.window.orderOut(null); none => {} }
  };
  const close: WindowOperation = move (in id: String): void => {
    if (id == "owner") { root.performClose(null); return; }
    const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    match (windows.nativeWindow(in id)) { some(runtime) => runtime.window.performClose(null); none => {} }
  };
  const setTitle: WindowTitleOperation = move (in id: String, in title: String): void => {
    const windows = match (attempt owner.upgrade()) { success(value) => value; failure(_) => return; };
    match (windows.nativeWindow(in id)) { some(runtime) => runtime.window.title = copy title; none => {} }
  };
  const state: (in id: String, value: boolean) => void on thread.main = (in id: String, value: boolean): void => {};
  return WindowBackend({ create, show, focus: show, hide, close, setTitle,
    minimize: hide, unminimize: show, setMaximized: state, setFullscreen: state });
}
function count(windows: WindowManager): usize on thread.main {
  const values = windows.all();
  return values.length;
}

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
  readonly windows: WindowManager;
  subscriptions: Array<WindowEventSubscription>;
  coordinator: Option<MacOSRelatedWindows>;
  reservation: Option<RelatedWindowReservation>;
  identity: Option<RelatedDocumentIdentity>;
  completionId: u64;
  completions: i32;
  failures: i32;
  echoes: i32;
  passed: boolean;
  failed: boolean;
  closes: i32;
  closeRequests: i32;
  allowClose: boolean;

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
        const id = "related-2";
        const window = match (this.windows.get(in id)) { some(value) => value; none => { this.failed = true; return; } };
        const weakState = weak this;
        const request = match (attempt window.events.closeRequested.subscribe(move (in event: WindowCloseRequestedEvent): void => {
          match (attempt weakState.upgrade()) {
            success(state) => {
              state.closeRequests = state.closeRequests + 1;
              if (!state.allowClose) event.cancel();
            }
            failure(_) => {}
          }
        })) { success(value) => value; failure(_) => { this.failed = true; return; } };
        this.subscriptions.push(request);
        const closed = match (attempt window.events.closed.subscribe(move (in event: WindowClosedEvent): void => {
          match (attempt weakState.upgrade()) {
            success(state) => {
              state.closes = state.closes + 1;
              const coordinator = match (state.current()) { some(value) => value; none => { state.failed = true; return; } };
              if (coordinator.count() != 0 || count(state.windows) != 1) state.failed = true;
              const reservation = match (copy state.reservation) { some(value) => value; none => { state.failed = true; return; } };
              if (coordinator.documents.isReady(in reservation.child)) state.failed = true;
              match (coordinator.nativeWindow(in event.windowId)) { some(_) => { state.failed = true; } none => {} }
            }
            failure(_) => {}
          }
        })) { success(value) => value; failure(_) => { this.failed = true; return; } };
        this.subscriptions.push(closed);
        const identity = match (copy this.identity) { some(value) => value; none => { this.failed = true; return; } };
        if (this.completionId == 0 || !this.owner.isCurrent(in identity)) { this.failed = true; return; }
        reply(this.view, in identity, this.completionId, "true");
      }
      failed(_) => {
        this.failures = this.failures + 1;
        const coordinator = match (this.current()) { some(value) => value; none => { this.failed = true; return; } };
        if (coordinator.count() != 0 || count(this.windows) != 1) this.failed = true;
        if (this.completionId != 0) {
          const identity = match (copy this.identity) { some(value) => value; none => { this.failed = true; return; } };
          if (!this.owner.isCurrent(in identity)) { this.failed = true; return; }
          reply(this.view, in identity, this.completionId, "false");
        }
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
        const ownerId = "owner";
        const logicalOwner = match (this.windows.get(in ownerId)) { some(value) => value; none => { this.failed = true; return; } };
        const reservation = match (coordinator.prepare(this.owner, this.view, logicalOwner, in identity, 2,
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
      if (request.m == "stopManager") { this.windows.stop(); reply(this.view, in identity, request.id, "true"); return; }
      if (request.m == "familyVeto") {
        const id = "owner";
        const root = match (this.windows.get(in id)) { some(value) => value; none => { this.failed = true; return; } };
        root.close();
        const child = match (copy this.reservation) { some(value) => value; none => { this.failed = true; return; } };
        if (this.closeRequests != 2 || this.closes != 0 || count(this.windows) != 2
          || !this.owner.isCurrent(in identity) || !coordinator.documents.isReady(in child.child)) { this.failed = true; return; }
        reply(this.view, in identity, request.id, "false");
        return;
      }
      if (request.m == "familyAccept") {
        this.allowClose = true;
        const id = "owner";
        const root = match (this.windows.get(in id)) { some(value) => value; none => { this.failed = true; return; } };
        root.close();
        if (this.closeRequests != 3 || this.closes != 1 || count(this.windows) != 0
          || this.owner.isCurrent(in identity) || coordinator.count() != 0) this.failed = true;
        this.passed = true;
        return;
      }
      if (request.m == "pass") { this.passed = true; return; }
    }
    if (request.m == "echo" && identity.windowId == 2 && this.completions == 1) {
      const runtime = match (coordinator.runtime(in identity)) { some(value) => value; none => { this.failed = true; return; } };
      if (!runtime.document.isActivated(in identity) || !runtime.document.capabilities.allowsService("notes.list")
        || runtime.document.capabilities.allowsService("admin.erase")) { this.failed = true; return; }
      this.echoes = this.echoes + 1;
      const id = "related-2";
      const window = match (this.windows.get(in id)) { some(value) => value; none => { this.failed = true; return; } };
      window.hide();
      if (runtime.window.visible) { this.failed = true; return; }
      window.show();
      window.setTitle("Adopted inspector");
      const title: String = runtime.window.title;
      if (!runtime.window.visible || title != "Adopted inspector") { this.failed = true; return; }
      window.close();
      if (this.closeRequests != 1 || this.closes != 0 || !runtime.document.isActivated(in identity)) { this.failed = true; return; }
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
  if (args.length < 2 || args.length > 4) return 2;
  const stopped = args.length == 4 && args[3] == "--stopped";
  const family = args.length == 4 && args[3] == "--family";
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
  const window = new MacOSWindow(WebKit.NSMakeRect(100, 100, 320, 200),
    WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable);
  window.contentView = view;
  const windows = createWindowManager();
  const state = new State({ owner, view, windows, subscriptions: Array<WindowEventSubscription>(), coordinator: Option<MacOSRelatedWindows>.none,
    reservation: Option<RelatedWindowReservation>.none, identity: Option<RelatedDocumentIdentity>.none,
    completionId: 0, completions: 0, failures: 0, echoes: 0, passed: false, failed: false, closes: 0, closeRequests: 0, allowClose: false });
  const weakState = weak state;
  const route: DesktopRouteMessageOperation = move (message: String, identity: RelatedDocumentIdentity): void => {
    match (attempt weakState.upgrade()) { success(state) => state.route(move message, identity); failure(_) => {} }
  };
  const retiring: (nativeId: i32) => void on thread.main = move (nativeId: i32): void => {
    // Model reentrant framework cleanup while native retirement still holds
    // the old record. It must not recursively retire or publish it again.
    match (attempt weakState.upgrade()) {
      success(state) => {
        const coordinator = match (state.current()) { some(value) => value; none => return; };
        const reservation = match (copy state.reservation) { some(value) => value; none => return; };
        if (reservation.child.windowId == nativeId) coordinator.fail(in reservation);
      }
      failure(_) => {}
    }
  };
  const related = new MacOSRelatedWindows(documents, creations, route, weak windows, retiring);
  match (attempt windows.start(backend(weak related, window), false)) { success => {} failure(_) => return 5; }
  match (windows.adoptNative("owner", WindowOptions())) { some(_) => {} none => return 6; }
  state.coordinator = Option.some(related);
  const handler = new DesktopMessageHandler({ document: owner, expectedView: view, expectedController: controller, routeMessage: route });
  const registration = objc.register({ add: controller.addScriptMessageHandler(handler, "zapp"), remove: controller.removeScriptMessageHandlerForName("zapp") });
  const navigationController = new RootNavigation({ document: owner, related });
  const navigation = objc.adapt<WebKit.WKNavigationDelegate>(navigationController);
  const ui = createRelatedWindowUIDelegate(related);
  view.navigationDelegate = navigation;
  view.UIDelegate = ui;
  const closed: NativeWindowClosedOperation = move (nativeId: i32): void => {
    owner.close(); related.pruneInvalidated();
  };
  const delegate = createDesktopWindowDelegate("owner", 1, window, view, weak windows, closed);
  window.delegate = delegate;
  window.makeKeyAndOrderFront(null);
  const suffix = stopped ? "?stopped=1" : (family ? "?family=1" : "");
  const url = WebKit.NSURL.URLWithString(`${args[0]}/owner.html${suffix}`);
  if (url == null) return 4;
  view.loadRequest(WebKit.NSURLRequest.requestWithURL(url));
  let ticks: i32 = 0;
  while (!state.failed && !(state.passed && related.count() == 0) && ticks < 200) {
    WebKit.NSRunLoop.currentRunLoop.runUntilDate(WebKit.NSDate.dateWithTimeIntervalSinceNow(0.05));
    ticks = ticks + 1;
  }
  const expected = stopped
    ? state.completions == 0 && state.failures == 2 && state.echoes == 0 && state.closes == 0 && state.closeRequests == 0
    : state.completions == 1 && state.failures == 1 && state.echoes == 1 && state.closes == 1 && state.closeRequests == (family ? 3 : 1);
  const remaining = usize(family ? 0 : 1);
  const pass = !state.failed && state.passed && expected
    && count(windows) == remaining && related.count() == 0 && creations.count() == 0 && documents.count() == remaining;
  related.closeAll();
  windows.stop();
  owner.close();
  view.stopLoading();
  window.close();
  console.log(`related production WebKit: pass=${pass} completed=${state.completions} failed=${state.failures} echoes=${state.echoes} closed=${state.closes} vetoed=${state.closeRequests}`);
  return pass ? 0 : 1;
}
