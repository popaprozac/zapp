// Checked-Z platform probe. Uses the production WebView bootstrap and owner-side
// lifetime helper, but does not expose a production related-window factory.
import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import console from "std/console";
import process from "std/process";
import fs from "std/fs";
import json from "std/json";
import { thread } from "std/thread";

readonly struct ProbeMessage {
  t: i32 = 0;
  id: u64 = 0;
  m: String = "";
}

class Observations on thread.main {
  created: i32;
  refused: i32;
  ready: i32;
  replies: i32;
  pending: i32;
  closed: i32;
  finished: boolean;
  failed: boolean;

  function createdChild(inout this): void { this.created = this.created + 1; }
  function refusedChild(inout this): void { this.refused = this.refused + 1; }
  function becameReady(inout this): void { this.ready = this.ready + 1; }
  function replied(inout this): void { this.replies = this.replies + 1; }
  function heldRequest(inout this): void { this.pending = this.pending + 1; }
  function closedChild(inout this): void { this.closed = this.closed + 1; }

  function finish(inout this, failed: boolean): void {
    if (this.finished) return;
    this.finished = true;
    this.failed = failed;
    const app = WebKit.NSApplication.sharedApplication;
    app.stop(null);
    const wake = WebKit.NSEvent.otherEventWithType(
      WebKit.NSEventTypeApplicationDefined,
      location: WebKit.NSMakePoint(0, 0), modifierFlags: 0,
      timestamp: 0, windowNumber: 0, context: null,
      subtype: 0, data1: 0, data2: 0
    );
    if (wake != null) app.postEvent(wake, atStart: true);
  }
}

class OwnerMessages on thread.main implements WebKit.WKScriptMessageHandler {
  readonly state: Observations;
  readonly expectedView: WebKit.WKWebView;

  function receive(
    inout this,
    in controller: WebKit.WKUserContentController,
    in message: WebKit.WKScriptMessage
  ): void as "userContentController:didReceiveScriptMessage:" {
    if (message.webView != this.expectedView || !message.frameInfo.mainFrame) {
      this.state.finish(true);
      return;
    }
    const body = message.body;
    if (body instanceof WebKit.NSString) {
      const text: String = body;
      if (text == "pass" && this.state.closed == 1) { this.state.finish(false); return; }
      console.error(text);
    }
    this.state.finish(true);
  }
}

class ChildMessages on thread.main implements WebKit.WKScriptMessageHandler {
  readonly state: Observations;
  readonly expectedView: WebKit.WKWebView;
  readonly owner: WebKit.WKWebView;
  readonly address: String;
  bridgeReady: boolean;
  documentReady: boolean;
  active: boolean;
  retired: boolean;

  function activate(inout this): void {
    if (this.retired || this.active || !this.bridgeReady || !this.documentReady) return;
    this.active = true;
    this.state.becameReady();
    const state = this.state;
    // The ID/token are native fixture identity, never taken from message data.
    this.owner.evaluateJavaScript(
      "globalThis.__checkedTrack('child-1','document-1')",
      completionHandler: move (value, error): void => { if (error != null) state.finish(true); }
    );
  }

  function retire(inout this): boolean {
    if (this.retired) return false;
    this.retired = true;
    this.active = false;
    return true;
  }

  function receive(
    inout this,
    in controller: WebKit.WKUserContentController,
    in message: WebKit.WKScriptMessage
  ): void as "userContentController:didReceiveScriptMessage:" {
    const actual = message.webView;
    const frame = message.frameInfo;
    const address = frame.request.URL;
    if (actual == null || actual != this.expectedView || !frame.mainFrame || address == null) {
      this.state.finish(true);
      return;
    }
    const absolute = address.absoluteString;
    if (absolute == null) { this.state.finish(true); return; }
    const source: String = absolute;
    if (source != this.address || this.retired) { this.state.finish(true); return; }
    const body = message.body;
    if (!(body instanceof WebKit.NSString)) { this.state.finish(true); return; }
    const text: String = body;
    const decoded = attempt json.decode<ProbeMessage>(text);
    match (decoded) {
      failure(_) => this.state.finish(true);
      success(request) => {
        if (request.t == 4 && request.m == "ready") {
          this.bridgeReady = true;
          this.activate();
          return;
        }
        if (request.t == 4 && request.m == "checked-document-ready") {
          this.documentReady = true;
          this.activate();
          return;
        }
        if (!this.active || request.t != 1) { this.state.finish(true); return; }
        if (request.m == "checked-pending") {
          this.state.heldRequest();
          return;
        }
        if (request.m == "checked-ping") {
          this.state.replied();
          const state = this.state;
          const script = `globalThis[Symbol.for('zapp.bridge')]._onInvokeResult(${request.id},true,'42')`;
          actual.evaluateJavaScript(move script,
            completionHandler: move (value, error): void => { if (error != null) state.finish(true); });
          return;
        }
        this.state.finish(true);
      }
    }
  }
}

class ChildClosure on thread.main implements WebKit.WKUIDelegate {
  readonly state: Observations;
  readonly window: WebKit.NSWindow;
  readonly owner: WebKit.WKWebView;
  readonly messages: ChildMessages;

  function closed(inout this, in view: WebKit.WKWebView): void as "webViewDidClose:" {
    if (!this.messages.retire()) return;
    // Commit native retirement/closure first. JS observes it afterward, never
    // acting as the acknowledgement needed to perform native teardown.
    this.window.close();
    this.state.closedChild();
    const state = this.state;
    this.owner.evaluateJavaScript("globalThis.__checkedInvalidated('child-1','document-1')",
      completionHandler: move (value, error): void => { if (error != null) state.finish(true); });
  }
}

class ChildEndpoint on thread.main {
  readonly window: WebKit.NSWindow;
  readonly view: WebKit.WKWebView;
  readonly registration: objc.Registration;
  readonly delegate: objc.Adapter<WebKit.WKUIDelegate>;
}

class RelatedDelegate on thread.main implements WebKit.WKUIDelegate {
  readonly state: Observations;
  readonly bootstrap: String;
  readonly childAddress: String;
  children: Array<ChildEndpoint>;

  function createChild(
    inout this,
    in owner: WebKit.WKWebView,
    in configuration: WebKit.WKWebViewConfiguration,
    in action: WebKit.WKNavigationAction,
    in features: WebKit.WKWindowFeatures
  ): WebKit.WKWebView | null as "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:" {
    if (action.targetFrame != null) return null;
    if (this.state.created != 0) { this.state.refusedChild(); return null; }
    const controller = WebKit.WKUserContentController.alloc().init();
    configuration.userContentController = controller;
    controller.addUserScript(WebKit.WKUserScript.alloc().initWithSource(copy this.bootstrap,
      injectionTime: WebKit.WKUserScriptInjectionTimeAtDocumentStart, forMainFrameOnly: true));
    const child = WebKit.WKWebView.alloc().initWithFrame(
      WebKit.NSMakeRect(0, 0, 320, 240), configuration: configuration);
    const messages = new ChildMessages({ state: this.state, expectedView: child, owner, address: copy this.childAddress,
      bridgeReady: false, documentReady: false, active: false, retired: false });
    const registration = objc.register({
      add: controller.addScriptMessageHandler(messages, "zapp"),
      remove: controller.removeScriptMessageHandlerForName("zapp"),
    });
    const window = WebKit.NSWindow.alloc().initWithContentRect(WebKit.NSMakeRect(650, 250, 320, 240),
      styleMask: WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable,
      backing: WebKit.NSBackingStoreBuffered, defer: false);
    window.releasedWhenClosed = false;
    window.title = "Related document lifetime";
    window.contentView = child;
    const closure = new ChildClosure({ state: this.state, window, owner, messages });
    const adapter = objc.adapt<WebKit.WKUIDelegate>(closure);
    child.UIDelegate = adapter;
    this.children.push(new ChildEndpoint({ window, view: child, registration, delegate: adapter }));
    this.state.createdChild();
    window.makeKeyAndOrderFront(null);
    return child;
  }
}

function main(): i32 {
  const arguments = process.args();
  if (arguments.length != 3) return 2;
  const url = WebKit.NSURL.URLWithString(arguments[0]);
  if (url == null) return 2;
  const loaded = attempt fs.readText(arguments[2]);
  const bootstrap = match (loaded) { success(value) => move value; failure(_) => return 2; };
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  const state = new Observations({ created: 0, refused: 0, ready: 0, replies: 0, pending: 0, closed: 0, finished: false, failed: false });
  const configuration = WebKit.WKWebViewConfiguration.alloc().init();
  configuration.websiteDataStore = WebKit.WKWebsiteDataStore.nonPersistentDataStore();
  configuration.preferences.javaScriptCanOpenWindowsAutomatically = true;
  const owner = WebKit.WKWebView.alloc().initWithFrame(WebKit.NSMakeRect(0, 0, 320, 240), configuration: configuration);
  const messages = new OwnerMessages({ state, expectedView: owner });
  const controller = configuration.userContentController;
  const registration = objc.register({
    add: controller.addScriptMessageHandler(messages, "checked"),
    remove: controller.removeScriptMessageHandlerForName("checked"),
  });
  const delegate = new RelatedDelegate({ state, bootstrap: move bootstrap, childAddress: copy arguments[1], children: Array<ChildEndpoint>() });
  const adapter = objc.adapt<WebKit.WKUIDelegate>(delegate);
  owner.UIDelegate = adapter;
  const window = WebKit.NSWindow.alloc().initWithContentRect(WebKit.NSMakeRect(250, 250, 320, 240),
    styleMask: WebKit.NSWindowStyleMaskTitled, backing: WebKit.NSBackingStoreBuffered, defer: false);
  window.releasedWhenClosed = false;
  window.title = "Related lifetime owner";
  window.contentView = owner;
  window.makeKeyAndOrderFront(null);
  owner.loadRequest(WebKit.NSURLRequest.requestWithURL(url));
  const timeout = WebKit.NSTimer.timerWithTimeInterval(15, repeats: false,
    block: move (timer): void => { timer.invalidate(); state.finish(true); });
  WebKit.NSRunLoop.mainRunLoop.addTimer(timeout, forMode: WebKit.NSRunLoopCommonModes);
  app.activate();
  app.run();
  timeout.invalidate();
  owner.stopLoading();
  window.close();
  for (const endpoint of delegate.children) { endpoint.view.stopLoading(); endpoint.window.close(); }
  const pass = !state.failed && state.finished && state.created == 1 && state.refused == 1
    && state.ready == 1 && state.replies == 1 && state.pending == 1 && state.closed == 1;
  console.log(`checked-z lifetime: pass=${pass} created=${state.created} refused=${state.refused} ready=${state.ready} replies=${state.replies} pending=${state.pending} closed=${state.closed}`);
  return pass ? 0 : 1;
}
