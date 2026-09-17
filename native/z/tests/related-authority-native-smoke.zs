// Real registry/allocator/delegates; only the private test message routes differ
// from application routes. Factory scenarios reuse the production bridge router;
// neither path accepts renderer-selected authority.
import WebKit from "WebKit/WebKit.h";
import process from "std/process";
import console from "std/console";
import json from "std/json";
import { Map, Set } from "std/collections";
import { thread } from "std/thread";
import { ApplicationCapabilities, CapabilityProfile } from "../framework/application-capabilities.zs";
import { createApplicationEvents } from "../framework/application-events.zs";
import { initializeMacOSApplicationHost } from "../framework/platform/macos/application-host.zs";
import { RelatedDocumentIdentity, createRelatedDocuments } from "../framework/related-documents.zs";
import { RelatedWindowCreations, RelatedCreationReply, RelatedCreationResult } from "../framework/related-window-creations.zs";
import { MacOSRelatedWindows } from "../framework/platform/macos/related-window-creations.zs";
import { MacOSWindowRegistry } from "../framework/platform/macos/window-registry.zs";
import { WindowStateStore, WindowStateInbox } from "../framework/window-state.zs";
import { Channel } from "std/channel";
import { MacOSWindowRuntime } from "../framework/platform/macos/window-runtime.zs";
import { DesktopRouteMessageOperation } from "../framework/platform/macos/document-transport.zs";
import { NativeWindowClosedOperation } from "../framework/platform/macos/window-delegate.zs";
import { createApplicationMenu } from "../framework/application-menu.zs";
import { createContextMenuSessions } from "../framework/context-menu.zs";
import { WindowManager, WindowOptions, WindowBackend, WindowCreateOperation, WindowOperation, WindowTitleOperation, createWindowManager } from "../framework/window.zs";
import { WindowError } from "../framework/application-error.zs";
import { WindowCloseRequestedEvent } from "../framework/events.zs";
import { WindowEventSubscription } from "../framework/window-events.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { decodeBridgeMessage } from "../framework/bridge.zs";
import { routeRelatedWindowBridgeMessage } from "../framework/platform/macos/related-window-bridge.zs";
import { routeWindowBridgeMessage } from "../framework/window-bridge.zs";

readonly struct RequestArgs { child: i32 = 0; }
readonly struct Request { t: i32 = 0; id: u64 = 0; m: String = ""; a: RequestArgs = RequestArgs(); }
readonly struct Waiter { owner: RelatedDocumentIdentity; id: u64; }
readonly struct Prepared {
  address: String; windowId: String; documentToken: String; ownerToken: String; nativeId: i32;
}

// Probe-only weak native observations; neither these nor Weak<T> keep the
// window graph alive. Model the per-turn autorelease pools of NSApplication.
function createNativeObservations(): WebKit.NSObject = raw objc {
  return [[NSHashTable alloc] initWithOptions:NSPointerFunctionsWeakMemory capacity:0];
}
function observeNative(in tracker: WebKit.NSObject, in window: WebKit.NSWindow, in view: WebKit.WKWebView): void = raw objc {
  [(NSHashTable *)tracker addObject:window];
  [(NSHashTable *)tracker addObject:view];
}
function nativeObservationCount(in tracker: WebKit.NSObject): usize = raw objc {
  return [(NSHashTable *)tracker allObjects].count;
}
function pulseRunLoop(): void = raw objc {
  @autoreleasepool {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
}

class State on thread.main {
  readonly windows: WindowManager;
  registry: Option<MacOSWindowRegistry>;
  waiting: Map<i32, Waiter>;
  ready: Set<i32>;
  subscriptions: Array<WindowEventSubscription>;
  observed: Array<Weak<MacOSWindowRuntime>>;
  readonly nativeObserved: WebKit.NSObject;
  completed: i32;
  closed: i32;
  vetoes: i32;
  veto: boolean;
  passed: boolean;
  failed: boolean;

  function current(): Option<MacOSWindowRegistry> {
    return match (in this.registry) { some(value) => Option.some(value); none => Option.none; };
  }

  function runtime(in identity: RelatedDocumentIdentity): Option<MacOSWindowRuntime> {
    const registry = match (this.current()) { some(value) => value; none => return Option.none; };
    const root = registry.nativeWindows.get(identity.windowId);
    return match (in root) {
      some(value) => value.document.isCurrent(in identity) ? Option.some(value) : Option.none;
      none => registry.related.runtime(in identity);
    };
  }

  function reply(inout this, in identity: RelatedDocumentIdentity, id: u64, payload: String): void {
    const runtime = match (this.runtime(in identity)) { some(value) => value; none => { this.failed = true; return; } };
    const value = json.JsonValue.string(move payload);
    const encoded = json.stringify(in value);
    runtime.webView.evaluateJavaScript(`globalThis[Symbol.for('zapp.bridge')]._onDocumentInvokeResult('${identity.token}',${id},true,${encoded})`,
      completionHandler: move (value, error): void => {});
  }

  function completion(inout this, result: RelatedCreationResult): void {
    const child = match (result) { ready(value) => value; failed(_) => { this.failed = true; return; } };
    const runtime = match (this.runtime(in child)) { some(value) => value; none => { this.failed = true; return; } };
    // Every generation inherits the same immutable authority, without gaining
    // unrelated native/service/worker permissions.
    if (!runtime.capabilitySelection.allowsPermission("window:create")
      || !runtime.capabilitySelection.allowsService("notes.list")
      || runtime.capabilitySelection.allowsService("notes.delete")
      || runtime.capabilitySelection.allowsWorker("private")) { this.failed = true; return; }
    this.completed = this.completed + 1;
    this.ready.add(child.windowId);
    if (child.windowId == 4) {
      const window = match (this.windows.get(in runtime.id)) { some(value) => value; none => { this.failed = true; return; } };
      const weakState = weak this;
      const subscription = match (attempt window.events.closeRequested.subscribe(move (in event: WindowCloseRequestedEvent): void => {
        match (attempt weakState.upgrade()) {
          success(state) => { if (state.veto) { state.vetoes = state.vetoes + 1; event.cancel(); } }
          failure(_) => {}
        }
      })) { success(value) => value; failure(_) => { this.failed = true; return; } };
      this.subscriptions.push(subscription);
    }
    match (this.waiting.remove(child.windowId)) {
      some(waiter) => this.reply(in waiter.owner, waiter.id, "true");
      none => {}
    }
  }

  function route(inout this, message: String, identity: RelatedDocumentIdentity): void {
    const request = match (attempt json.decode<Request>(message)) { success(value) => value; failure(_) => { this.failed = true; return; } };
    if (request.t == 4 && request.m == "ready") return;
    const registry = match (this.current()) { some(value) => value; none => { this.failed = true; return; } };
    if (request.m == "watchRuntime") {
      const runtime = match (this.runtime(in identity)) { some(value) => value; none => { this.failed = true; return; } };
      const observed: Weak<MacOSWindowRuntime> = weak runtime;
      this.observed.push(observed);
      observeNative(this.nativeObserved, runtime.window, runtime.webView);
      this.reply(in identity, request.id, "true"); return;
    }
    if (request.m == "sampleRuntime" || request.m == "sampleOwnedRuntime" || request.m == "countRuntime") {
      let alive = 0;
      for (const observed of this.observed) {
        match (attempt observed.upgrade()) { success(_) => { alive = alive + 1; } failure(_) => {} }
      }
      const nativeAlive = nativeObservationCount(this.nativeObserved);
      if (request.m != "countRuntime") console.log(`related churn: observed=${this.observed.length} alive=${alive} native=${nativeAlive}`);
      const counted = request.m == "sampleOwnedRuntime" ? usize(alive) : usize(alive) + nativeAlive;
      this.reply(in identity, request.id, `${counted}`); return;
    }
    if (request.m == "__window:prepare-related" || request.m == "__window:abort-related" || request.m == "__window:publish-related") {
      const decoded = match (attempt decodeBridgeMessage(in message)) { success(value) => value; failure(_) => { this.failed = true; return; } };
      const permissions = ApplicationPermissions();
      match (routeRelatedWindowBridgeMessage(in decoded, in permissions, in identity, registry)) {
        response(value) => {
          if (value.ok && request.m == "__window:publish-related") this.completed = this.completed + 1;
          registry.deliverResponse(in value, identity);
        }
        _ => { this.failed = true; }
      }
      return;
    }
    if (request.m == "enableVeto") {
      const id = "related-2";
      const window = match (this.windows.get(in id)) { some(value) => value; none => { this.failed = true; return; } };
      const weakState = weak this;
      const subscription = match (attempt window.events.closeRequested.subscribe(move (in event: WindowCloseRequestedEvent): void => {
        match (attempt weakState.upgrade()) {
          success(state) => { if (state.veto) { state.vetoes = state.vetoes + 1; event.cancel(); } }
          failure(_) => {}
        }
      })) { success(value) => value; failure(_) => { this.failed = true; return; } };
      this.subscriptions.push(subscription);
      this.reply(in identity, request.id, "true"); return;
    }
    if (request.m == "disableVeto") { this.veto = false; this.reply(in identity, request.id, "true"); return; }
    if (request.t == 4) {
      const decoded = match (attempt decodeBridgeMessage(in message)) { success(value) => value; failure(_) => { this.failed = true; return; } };
      const capabilities = match (registry.documents.capabilitiesFor(in identity)) { some(value) => value; none => return; };
      const id = match (registry.logicalWindowId(identity.windowId)) { some(value) => value; none => return; };
      const permissions = ApplicationPermissions();
      let windows = this.windows;
      match (routeWindowBridgeMessage(in decoded, in permissions, in id, capabilities, inout windows)) {
        handled => {} _ => { this.failed = true; }
      }
      return;
    }
    if (request.m == "prepare") {
      const weakState = weak this;
      const complete: RelatedCreationReply = move (result): void => {
        match (attempt weakState.upgrade()) { success(state) => state.completion(move result); failure(_) => {} }
      };
      const prepared = registry.prepareRelatedWindow(in identity, "Related authority", 280, 180, complete);
      match (prepared) {
        some(reservation) => {
          const address = match (registry.related.address(in reservation)) { some(value) => value; none => { this.failed = true; return; } };
          const value = Prepared({ address, windowId: `related-${reservation.child.windowId}`,
            documentToken: `${reservation.child.token}`, ownerToken: `${identity.token}`, nativeId: reservation.child.windowId });
          const encoded = match (attempt json.encode(in value)) {
            success(text) => text; failure(_) => { this.failed = true; return; }
          };
          this.reply(in identity, request.id, move encoded);
        }
        none => this.reply(in identity, request.id, "false");
      }
      return;
    }
    if (request.m == "completion") {
      if (this.ready.has(request.a.child)) this.reply(in identity, request.id, "true");
      else this.waiting.set(request.a.child, Waiter({ owner: copy identity, id: request.id }));
      return;
    }
    if (request.m == "ping") { this.reply(in identity, request.id, "42"); return; }
    if (request.m == "forbidden" || request.m == "fail") { this.failed = true; return; }
    if (request.m == "familyVeto" || request.m == "closeBranch" || request.m == "closeOwner") {
      if (identity.windowId != 1 || this.completed != 3 || this.closed != 0) { this.failed = true; return; }
      const id = request.m == "closeBranch" ? "related-2" : "owner";
      const window = match (this.windows.get(in id)) { some(value) => value; none => { this.failed = true; return; } };
      this.veto = request.m == "familyVeto";
      window.close();
      if (this.veto) {
        if (this.closed != 0 || registry.documents.count() != 4 || registry.related.count() != 3 || this.vetoes != 1) this.failed = true;
        this.reply(in identity, request.id, "true");
      } else if (request.m == "closeBranch") {
        if (this.closed != 2 || registry.documents.count() != 2 || registry.related.count() != 1) this.failed = true;
        this.reply(in identity, request.id, "true");
      } else {
        this.passed = this.closed == 3 && registry.documents.count() == 0 && registry.related.count() == 0;
      }
      return;
    }
    if (request.m == "pass") { this.passed = true; return; }
    this.failed = true;
  }
}

function backend(owner: Weak<MacOSWindowRegistry>): WindowBackend on thread.main {
  const create: WindowCreateOperation = (in id, in options): void => {};
  const show: WindowOperation = move (in id): void => {
    match (attempt owner.upgrade()) { success(registry) => registry.showWindow(in id); failure(_) => {} }
  };
  const close: WindowOperation = move (in id): void => {
    match (attempt owner.upgrade()) { success(registry) => registry.requestWindowClose(in id); failure(_) => {} }
  };
  const title: WindowTitleOperation = (in id, in title): void => {};
  const state: (in id: String, value: boolean) => void on thread.main = (in id, value): void => {};
  return WindowBackend({ create, show, focus: show, close, hide: show, minimize: show, unminimize: show,
    setTitle: title, setMaximized: state, setFullscreen: state });
}

function main(): i32 on thread.main {
  const args = process.args();
  if (args.length != 4) return 2;
  const denied = args[3] == "--denied";
  const subframe = args[3] == "--subframe";
  const ownerClose = args[3] == "--nested-owner-close";
  const factoryReady = args[3] == "--factory-ready";
  const factoryRollback = args[3] == "--factory-rollback";
  const factoryVeto = args[3] == "--factory-veto";
  const factoryDenied = args[3] == "--factory-denied";
  const factoryInvalid = args[3] == "--factory-invalid";
  const factoryChurn = args[3] == "--factory-churn" || args[3] == "--factory-animated-churn";
  const factory = factoryReady || factoryRollback || factoryVeto || factoryDenied || factoryInvalid || factoryChurn;
  const events = createApplicationEvents();
  const host = initializeMacOSApplicationHost(events);
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  app.finishLaunching();
  let permissions = Array<String>();
  if (!denied && !factoryDenied) permissions.push("window:create");
  const methods = Array<String>("notes.list");
  const workers = Array<String>();
  let profiles = Map<String, CapabilityProfile>();
  profiles.set("default", CapabilityProfile({ permissions: permissions.freeze(), serviceMethods: methods.freeze(), workerIds: workers.freeze() }));
  const capabilities = new ApplicationCapabilities({ profiles: profiles.freeze() });
  const windows = createWindowManager();
  const documents = createRelatedDocuments();
  const creations = new RelatedWindowCreations(documents);
  const state = new State({ windows, registry: Option<MacOSWindowRegistry>.none, waiting: Map<i32, Waiter>(),
    ready: Set<i32>(), subscriptions: Array<WindowEventSubscription>(), observed: Array<Weak<MacOSWindowRuntime>>(),
    nativeObserved: createNativeObservations(),
    completed: 0, closed: 0, vetoes: 0, veto: true, passed: false, failed: false });
  const weakState = weak state;
  const route: DesktopRouteMessageOperation = move (message, identity): void => {
    match (attempt weakState.upgrade()) { success(state) => state.route(move message, identity); failure(_) => {} }
  };
  const closed: NativeWindowClosedOperation = move (id): void => {
    match (attempt weakState.upgrade()) {
      success(state) => {
        if (id != 1) state.closed = state.closed + 1;
        match (state.current()) { some(registry) => registry.nativeWindowClosed(id); none => {} }
      }
      failure(_) => {}
    }
  };
  const related = new MacOSRelatedWindows(documents, creations, route, weak windows, closed);
  const { sender: stateSender, receiver: stateReceiver } = Channel<boolean>.bounded(1);
  const stateStore = new WindowStateStore("", new WindowStateInbox(), stateSender.sync());
  const registry = new MacOSWindowRegistry({ name: "Related authority", capabilities, windowManager: windows,
    stateStore,
    menu: createApplicationMenu(), contextMenus: createContextMenuSessions(), routeMessage: route,
    documents, creations, related, didCloseNativeWindow: closed,
    nativeWindows: Map<i32, MacOSWindowRuntime>(), retiredNativeWindows: Array<MacOSWindowRuntime>(), nextNativeWindowId: 1 });
  state.registry = Option.some(registry);
  match (attempt windows.start(backend(weak registry), false)) { success => {} failure(_) => return 3; }
  const id = "owner";
  const scenario = args[3].copyBytes(2, args[3].byteLength);
  const options = WindowOptions({ title: "Related authority", width: 320, height: 200, url: `/owner.html?${scenario}=1` });
  match (attempt registry.createWindow(in id, in options)) { success => {} failure(_) => return 5; }
  match (windows.adoptNative(copy id, move options)) { some(_) => {} none => return 4; }
  let ticks = 0;
  while (!state.failed && !(state.passed && related.count() == 0) && ticks < (factoryChurn ? 500 : 200)) {
    pulseRunLoop();
    ticks = ticks + 1;
  }
  const expected = factory ? (factoryChurn ? 16 : factoryReady ? 2 : factoryVeto ? 1 : 0) : denied ? 0 : (subframe ? 1 : 3);
  const expectedClosed = (factoryRollback || factoryInvalid) ? 1 : expected;
  const remaining = usize(ownerClose ? 0 : 1);
  const all = windows.all();
  const pass = !state.failed && state.passed && state.completed == expected && state.closed == expectedClosed
    && state.vetoes == ((expected == 3 || factoryVeto) ? 1 : 0) && state.waiting.length == 0
    && related.count() == 0 && creations.count() == 0 && documents.count() == remaining && all.length == remaining;
  registry.closeAllNativeWindows();
  windows.stop();
  console.log(`related authority WebKit: pass=${pass} completed=${state.completed} closed=${state.closed} vetoes=${state.vetoes}`);
  return pass ? 0 : 1;
}
