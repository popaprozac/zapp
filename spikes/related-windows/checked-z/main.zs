import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import console from "std/console";
import process from "std/process";
import { thread } from "std/thread";

function stopLoop(): void on thread.main {
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

class Observations on thread.main {
  created: i32;
  rejected: i32;
  replies: i32;
  closed: i32;
  finished: boolean;
  failed: boolean;

  function finish(inout this, failed: boolean): void {
    if (this.finished) return;
    this.finished = true;
    this.failed = failed;
    stopLoop();
  }

  function replied(inout this): void {
    this.replies = this.replies + 1;
    if (this.closed == 1) this.finish(false);
  }

  function createdChild(inout this): void {
    this.created = this.created + 1;
  }

  function rejectedChild(inout this): void {
    this.rejected = this.rejected + 1;
  }

  function didClose(inout this): void {
    this.closed = this.closed + 1;
    if (this.replies == 1) this.finish(false);
  }
}

class ChildMessages on thread.main implements WebKit.WKScriptMessageHandler {
  readonly state: Observations;
  readonly expectedView: WebKit.WKWebView;

  function receive(
    in controller: WebKit.WKUserContentController,
    in message: WebKit.WKScriptMessage
  ): void as "userContentController:didReceiveScriptMessage:" {
    const state = this.state;
    const actualView = message.webView;
    if (actualView == null || actualView != this.expectedView || !message.frameInfo.mainFrame) {
      state.finish(true);
      return;
    }
    const body = message.body;
    if (body instanceof WebKit.NSString) {
      const text: String = body;
      if (text == "ping") {
        // Reply to the native-identified child, never through owner JS.
        actualView.evaluateJavaScript("globalThis.__checkedReply(1)",
          completionHandler: move (value, error): void => {
            if (error != null) state.finish(true);
          });
        return;
      }
      if (text == "pass") {
        state.replied();
        return;
      }
    }
    state.finish(true);
  }
}

class ChildClosure on thread.main implements WebKit.WKUIDelegate {
  readonly state: Observations;
  readonly window: WebKit.NSWindow;

  function closed(inout this, in view: WebKit.WKWebView): void as "webViewDidClose:" {
    // DOM closure already succeeded: do not consult a cancellable close request.
    this.window.close();
    this.state.didClose();
  }
}

class ChildEndpoint on thread.main {
  readonly window: WebKit.NSWindow;
  readonly view: WebKit.WKWebView;
  readonly registration: objc.Registration;
  readonly delegate: objc.Adapter<WebKit.WKUIDelegate>;
}

// Isolated interop proof, not a public related-window API.
class RelatedWindowDelegate on thread.main implements WebKit.WKUIDelegate {
  readonly state: Observations;
  children: Array<ChildEndpoint>;

  function createChild(
    inout this,
    in owner: WebKit.WKWebView,
    in configuration: WebKit.WKWebViewConfiguration,
    in action: WebKit.WKNavigationAction,
    in features: WebKit.WKWindowFeatures
  ): WebKit.WKWebView | null as "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:" {
    if (action.targetFrame != null) return null;
    if (this.state.created != 0) {
      this.state.rejectedChild();
      return null;
    }
    const controller = WebKit.WKUserContentController.alloc().init();
    configuration.userContentController = controller;
    const child = WebKit.WKWebView.alloc().initWithFrame(
      WebKit.NSMakeRect(0, 0, 320, 240),
      configuration: configuration
    );
    const handler = new ChildMessages({ state: this.state, expectedView: child });
    const registration = objc.register({
      add: controller.addScriptMessageHandler(handler, "checked"),
      remove: controller.removeScriptMessageHandlerForName("checked"),
    });
    const script = WebKit.WKUserScript.alloc().initWithSource(
      "globalThis.__checkedRequest=()=>window.webkit.messageHandlers.checked.postMessage('ping');globalThis.__checkedReply=(id)=>{if(id!==1||!opener||opener.shared.value!==42||opener.denied!==null||opener.document===document||opener.Array===Array)throw Error('related child invariant');window.webkit.messageHandlers.checked.postMessage('pass');window.close();};",
      injectionTime: WebKit.WKUserScriptInjectionTimeAtDocumentStart,
      forMainFrameOnly: true
    );
    controller.addUserScript(script);
    const window = WebKit.NSWindow.alloc().initWithContentRect(
      WebKit.NSMakeRect(650, 250, 320, 240),
      styleMask: WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable,
      backing: WebKit.NSBackingStoreBuffered, defer: false
    );
    window.releasedWhenClosed = false;
    window.title = "Checked Z related child";
    window.contentView = child;
    const closure = new ChildClosure({ state: this.state, window });
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
  if (arguments.length != 1) return 2;
  const url = WebKit.NSURL.URLWithString(arguments[0]);
  if (url == null) return 2;
  const application = WebKit.NSApplication.sharedApplication;
  application.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  const state = new Observations({ created: 0, rejected: 0, replies: 0, closed: 0, finished: false, failed: false });
  const configuration = WebKit.WKWebViewConfiguration.alloc().init();
  configuration.websiteDataStore = WebKit.WKWebsiteDataStore.nonPersistentDataStore();
  configuration.preferences.javaScriptCanOpenWindowsAutomatically = true;
  const owner = WebKit.WKWebView.alloc().initWithFrame(
    WebKit.NSMakeRect(0, 0, 320, 240),
    configuration: configuration
  );
  const delegate = new RelatedWindowDelegate({ state, children: Array<ChildEndpoint>() });
  const adapter = objc.adapt<WebKit.WKUIDelegate>(delegate);
  owner.UIDelegate = adapter;
  const window = WebKit.NSWindow.alloc().initWithContentRect(
    WebKit.NSMakeRect(250, 250, 320, 240),
    styleMask: WebKit.NSWindowStyleMaskTitled,
    backing: WebKit.NSBackingStoreBuffered, defer: false
  );
  window.releasedWhenClosed = false;
  window.title = "Checked Z related owner";
  window.contentView = owner;
  window.makeKeyAndOrderFront(null);
  owner.loadRequest(WebKit.NSURLRequest.requestWithURL(url));
  const timeout = WebKit.NSTimer.timerWithTimeInterval(15, repeats: false,
    block: move (timer): void => { timer.invalidate(); state.finish(true); });
  WebKit.NSRunLoop.mainRunLoop.addTimer(timeout, forMode: WebKit.NSRunLoopCommonModes);
  application.activate();
  application.run();
  timeout.invalidate();
  owner.stopLoading();
  window.close();
  for (const endpoint of delegate.children) {
    endpoint.view.stopLoading();
    endpoint.window.close();
  }
  // Retain the adapters/registrations until NSApplication.run has unwound.
  const pass = !state.failed && state.finished && state.created == 1 && state.rejected == 1 && state.replies == 1 && state.closed == 1;
  console.log(`checked-z related child: pass=${pass} created=${state.created} rejected=${state.rejected} replies=${state.replies} closed=${state.closed}`);
  return pass ? 0 : 1;
}
