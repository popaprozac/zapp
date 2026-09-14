import WebKit from "WebKit/WebKit.h";
import clock from "QuartzCore/CABase.h";
import math from "std/math";
import objc from "std/objc";
import { Map } from "std/collections";
import { thread } from "std/thread";
import { BridgeDocument, BridgeDocumentActivated } from "../../bridge-document.zs";
import { RelatedDocuments, RelatedDocumentIdentity } from "../../related-documents.zs";
import { RelatedWindowCreations, RelatedWindowReservation, RelatedCreationCleanup,
  RelatedCreationReply, RelatedCreationResult } from "../../related-window-creations.zs";
import { Window, WindowManager, WindowOptions } from "../../window.zs";
import { MacOSWindowRuntime } from "./window-runtime.zs";
import { NativeWindowClosedOperation } from "./window-delegate.zs";
import { DesktopRouteMessageOperation } from "./document-transport.zs";
import { deliverRelatedDocumentInvalidated } from "./related-window-delivery.zs";
import { hasConfiguredFrontendOrigin, resolveLogicalURL } from "./navigation-policy.zs";
import { RelatedNativeFailure, RelatedNativeAllowsCreation, RelatedNativeCreateChild,
  createMacOSRelatedWindowRuntime } from "./related-window-native.zs";

function now(): u64 { return u64(math.trunc(clock.CACurrentMediaTime() * 1000)); }

class NativeCreation on thread.main {
  readonly reservation: RelatedWindowReservation;
  readonly owner: BridgeDocument;
  readonly ownerView: WebKit.WKWebView;
  readonly logicalOwner: Window;
  readonly address: String;
  readonly title: String;
  readonly width: u32;
  readonly height: u32;
  readonly deadline: u64;
  timer: WebKit.NSTimer | null;
  runtime: Option<MacOSWindowRuntime>;
  completed: boolean;
  deferPublication: boolean;
  published: boolean;
  retiring: boolean;

  function stopTimer(inout this): void {
    const timer = this.timer;
    this.timer = null;
    if (timer != null) timer.invalidate();
  }
  function close(inout this): void {
    this.stopTimer();
    match (in this.runtime) {
      some(value) => {
        const runtime: MacOSWindowRuntime = value;
        runtime.document.close();
        runtime.webView.stopLoading();
        runtime.window.close();
      }
      none => {}
    }
    this.runtime = Option.none;
  }

  deinit { this.close(); }
}

// Internal production coordinator. Only a native, document-authenticated
// prepare call can open the one-shot WebKit creation gate. Public factory
// integration is separate from these tested native lifecycle/authority gates.
internal class MacOSRelatedWindows on thread.main {
  readonly documents: RelatedDocuments;
  readonly creations: RelatedWindowCreations;
  readonly route: DesktopRouteMessageOperation;
  readonly windows: Weak<WindowManager>;
  readonly didCloseNativeWindow: NativeWindowClosedOperation;
  private records: Map<i32, NativeCreation>;
  private retired: Array<MacOSWindowRuntime>;
  private closed: boolean;

  constructor(documents: RelatedDocuments, creations: RelatedWindowCreations, route: DesktopRouteMessageOperation,
    windows: Weak<WindowManager>, didCloseNativeWindow: NativeWindowClosedOperation) {
    this.documents = documents;
    this.creations = creations;
    this.route = route;
    this.windows = windows;
    this.didCloseNativeWindow = didCloseNativeWindow;
    this.records = Map<i32, NativeCreation>();
    this.retired = Array<MacOSWindowRuntime>();
    this.closed = false;
  }

  function count(): usize { return this.records.length; }

  function runtime(in identity: RelatedDocumentIdentity): Option<MacOSWindowRuntime> {
    if (!this.documents.isReady(in identity)) return Option.none;
    const found = this.records.get(identity.windowId);
    return match (in found) {
      some(record) => {
        if (record.reservation.child.token != identity.token) return Option.none;
        select match (in record.runtime) {
          some(runtime) => { const retained: MacOSWindowRuntime = runtime; select Option.some(retained); }
          none => Option.none;
        };
      }
      none => Option.none;
    };
  }

  // Only completed, still-current children participate in logical controls.
  function nativeWindow(in id: String): Option<MacOSWindowRuntime> {
    for (const entry of this.records) {
      const record: NativeCreation = entry.value;
      if (record.completed && this.documents.isReady(in record.reservation.child)) {
        match (in record.runtime) {
          some(runtime) => { if (runtime.id == id) return Option.some(runtime); }
          none => {}
        }
      }
    }
    return Option.none;
  }

  // Also used during retirement, after document routing has been revoked.
  function logicalWindowId(nativeId: i32): Option<String> {
    const found = this.records.get(nativeId);
    return match (in found) {
      some(record) => record.completed ? Option.some(`related-${nativeId}`) : Option.none;
      none => Option.none;
    };
  }

  function prepare(
    inout this,
    owner: BridgeDocument,
    ownerView: WebKit.WKWebView,
    logicalOwner: Window,
    in identity: RelatedDocumentIdentity,
    nativeId: i32,
    title: String,
    width: u32,
    height: u32,
    reply: RelatedCreationReply
  ): Option<RelatedWindowReservation> {
    if (this.closed || !owner.isCurrent(in identity) || this.records.has(nativeId) || width == 0 || height == 0) return Option.none;
    const weakOwner = weak this;
    const completion: RelatedCreationReply = move (result): void => {
      // Mark handoff only after the guard accepts readiness/deadline, but
      // before the caller can synchronously close the newly completed child.
      match (result) {
        ready(child) => {
          match (attempt weakOwner.upgrade()) {
            success(owner) => {
              if (owner.didComplete(in child)) reply(RelatedCreationResult.ready(child));
              else {
                // The manager may have stopped while the native child loaded.
                // Never report readiness for a child we could not publish.
                if (owner.failChild(in child)) {
                  reply(RelatedCreationResult.failed("related window manager is unavailable"));
                }
              }
            }
            failure(_) => {}
          }
        }
        failed(message) => reply(RelatedCreationResult.failed(move message));
      }
    };
    const started = now();
    const deadline = started + 10000;
    const reservation = match (this.creations.beginWithReply(in identity, nativeId, started, deadline, completion)) {
      some(value) => value; none => return Option.none;
    };
    const logical = `/.zapp/related.html?creation=${reservation.child.token}`;
    const url = resolveLogicalURL(in logical);
    if (url == null) { this.creations.fail(in reservation); return Option.none; }
    const absolute = url.absoluteString;
    if (absolute == null) { this.creations.fail(in reservation); return Option.none; }
    const address: String = absolute;
    const record = new NativeCreation({ reservation: copy reservation, owner, ownerView, logicalOwner, address,
      title, width, height, deadline, timer: null, runtime: Option<MacOSWindowRuntime>.none,
      completed: false, deferPublication: false, published: false, retiring: false });
    this.records.set(nativeId, record);
    record.timer = WebKit.NSTimer.scheduledTimerWithTimeInterval(10.0, repeats: false, block: move (timer): void => {
      timer.invalidate();
      match (attempt weakOwner.upgrade()) {
        success(owner) => owner.fail(in reservation);
        failure(_) => {}
      }
    });
    return Option.some(copy reservation);
  }

  private function lookup(in reservation: RelatedWindowReservation): Option<NativeCreation> {
    const found = this.records.get(reservation.child.windowId);
    return match (in found) {
      some(record) => {
        if (record.reservation.child.token != reservation.child.token
          || record.reservation.owner.token != reservation.owner.token
          || record.reservation.owner.windowId != reservation.owner.windowId) return Option.none;
        const retained: NativeCreation = record;
        select Option.some(retained);
      }
      none => Option.none;
    };
  }

  function address(in reservation: RelatedWindowReservation): Option<String> {
    return match (this.lookup(in reservation)) { some(record) => Option.some(copy record.address); none => Option.none; };
  }

  function deferPublication(inout this, in reservation: RelatedWindowReservation): void {
    match (this.lookup(in reservation)) {
      some(record) => { if (!record.completed) record.deferPublication = true; }
      none => {}
    }
  }

  // Renderer correlation is only accepted within its authenticated owner.
  // Keep the token a decimal String across JS; u64 identities are not Numbers.
  function abortPrepared(inout this, in owner: RelatedDocumentIdentity,
    nativeId: i32, in token: String): void {
    const found = this.records.get(nativeId);
    const reservation = match (in found) {
      some(record) => { if (record.published) return; select copy record.reservation; }
      none => return;
    };
    if (reservation.owner.windowId != owner.windowId || reservation.owner.token != owner.token
      || `${reservation.child.token}` != token) return;
    this.fail(in reservation);
  }

  function publishPrepared(inout this, in owner: RelatedDocumentIdentity,
    nativeId: i32, in token: String): boolean {
    const found = this.records.get(nativeId);
    const record: NativeCreation = match (in found) { some(value) => value; none => return false; };
    const reservation = record.reservation;
    if (!record.completed || !record.deferPublication
      || reservation.owner.windowId != owner.windowId || reservation.owner.token != owner.token
      || `${reservation.child.token}` != token || !this.documents.isReady(in reservation.child)
      || !this.documents.isReady(in owner)) return false;
    if (record.published) return true;
    if (now() >= record.deadline) { this.fail(in reservation); return false; }
    record.published = true;
    record.stopTimer();
    match (in record.runtime) { some(runtime) => runtime.window.makeKeyAndOrderFront(null); none => return false; }
    return true;
  }

  private function candidate(in view: WebKit.WKWebView, in action: WebKit.WKNavigationAction): Option<NativeCreation> {
    if (this.closed || action.targetFrame != null || !action.sourceFrame.mainFrame) return Option.none;
    const source = action.sourceFrame.request.URL;
    const url = action.request.URL;
    if (source == null || url == null || !hasConfiguredFrontendOrigin(in source) || !hasConfiguredFrontendOrigin(in url)) return Option.none;
    const absolute = url.absoluteString;
    if (absolute == null) return Option.none;
    const address: String = absolute;
    for (const entry of this.records) {
      const record: NativeCreation = entry.value;
      if (!record.completed && record.ownerView == view && record.address == address
        && record.owner.isCurrent(in record.reservation.owner)) return Option.some(record);
    }
    return Option.none;
  }

  function allows(in view: WebKit.WKWebView, in action: WebKit.WKNavigationAction): boolean {
    return match (this.candidate(in view, in action)) { some(_) => true; none => false; };
  }

  function create(inout this, in view: WebKit.WKWebView, configuration: WebKit.WKWebViewConfiguration,
    in action: WebKit.WKNavigationAction): WebKit.WKWebView | null {
    const record = match (this.candidate(in view, in action)) { some(value) => value; none => return null; };
    const reservation = record.reservation;
    const document = match (this.creations.claim(in reservation.owner, in reservation, now())) {
      some(value) => value; none => { this.fail(in reservation); return null; }
    };
    const weakOwner = weak this;
    const failed: RelatedNativeFailure = move (): void => {
      match (attempt weakOwner.upgrade()) { success(owner) => owner.fail(in reservation); failure(_) => {} }
    };
    const closed: NativeWindowClosedOperation = move (nativeId: i32): void => {
      match (attempt weakOwner.upgrade()) { success(owner) => owner.fail(in reservation); failure(_) => {} }
    };
    const activated: BridgeDocumentActivated = move (identity: RelatedDocumentIdentity): void => {
      match (attempt weakOwner.upgrade()) { success(owner) => owner.complete(in reservation); failure(_) => {} }
    };
    document.whenActivated(activated);
    const allowsCreation: RelatedNativeAllowsCreation = move (in view, in action): boolean => {
      return match (attempt weakOwner.upgrade()) {
        success(owner) => owner.allows(in view, in action); failure(_) => false;
      };
    };
    const createChild: RelatedNativeCreateChild = move (in view, configuration, in action): WebKit.WKWebView | null => {
      return match (attempt weakOwner.upgrade()) {
        success(owner) => owner.create(in view, configuration, in action); failure(_) => null;
      };
    };
    const runtime = match (attempt createMacOSRelatedWindowRuntime(configuration, document,
      `related-${reservation.child.windowId}`, copy record.address, copy record.title,
      record.width, record.height, this.route, failed, closed, allowsCreation, createChild, this.windows)) {
      success(value) => value;
      failure(_) => { this.fail(in reservation); return null; }
    };
    record.runtime = Option.some(runtime);
    const cleanup: RelatedCreationCleanup = move (): void => {
      match (attempt weakOwner.upgrade()) { success(owner) => owner.rollback(in reservation); failure(_) => {} }
    };
    if (!this.creations.attach(in reservation, cleanup, now())) return null;
    return runtime.webView;
  }

  private function complete(inout this, in reservation: RelatedWindowReservation): void {
    const record = match (this.lookup(in reservation)) { some(value) => value; none => return; };
    if (record.completed) return;
    if (!record.deferPublication) record.stopTimer();
    if (!this.creations.complete(in reservation, now())) { this.fail(in reservation); return; }
    // The reply can synchronously close the child/owner. Never present it again
    // after that reentrancy, even though this stack retains the former record.
    if (!this.documents.isReady(in reservation.child)) return;
    if (!record.deferPublication) {
      record.published = true;
      match (in record.runtime) { some(runtime) => runtime.window.makeKeyAndOrderFront(null); none => {} }
    }
  }

  private function didComplete(inout this, in identity: RelatedDocumentIdentity): boolean {
    const found = this.records.get(identity.windowId);
    match (in found) {
      some(value) => {
        const record: NativeCreation = value;
        if (record.reservation.child.token != identity.token || record.completed) return false;
        const runtime: MacOSWindowRuntime = match (in record.runtime) { some(value) => value; none => return false; };
        const windows = match (attempt this.windows.upgrade()) { success(value) => value; failure(_) => return false; };
        let capabilities = Array<String>();
        for (const name of runtime.capabilitySelection.names) { capabilities.push(copy name); }
        const options = WindowOptions({ title: copy record.title, width: record.width, height: record.height,
          url: copy record.address, capabilities: move capabilities });
        match (windows.adoptRelatedNative(record.logicalOwner, copy runtime.id, move options)) {
          some(_) => {
            record.completed = true;
            // Legacy native callers publish via their completion callback;
            // preserve their reentrant close/retention semantics as well.
            record.published = !record.deferPublication;
            return true;
          }
          none => return false;
        }
      }
      none => {}
    }
    return false;
  }

  private function failChild(inout this, in identity: RelatedDocumentIdentity): boolean {
    const found = this.records.get(identity.windowId);
    const reservation = match (in found) { some(record) => copy record.reservation; none => return false; };
    if (reservation.child.token != identity.token) return false;
    this.fail(in reservation);
    return this.documents.isReady(in reservation.owner);
  }

  private function rollback(inout this, in reservation: RelatedWindowReservation): void {
    const record = match (this.lookup(in reservation)) { some(value) => value; none => return; };
    if (record.retiring) return;
    record.retiring = true;
    // Revoke the complete document subtree before retiring native/logical
    // bookkeeping or invoking any user closed listener.
    match (in record.runtime) {
      some(value) => { const runtime: MacOSWindowRuntime = value; runtime.document.close(); }
      none => {}
    }
    this.didCloseNativeWindow(reservation.child.windowId);
    this.records.delete(reservation.child.windowId);
    // As with ordinary windows, retain the completed AppKit graph until the
    // application run loop unwinds. Failed unpublished allocations are released
    // before their failure reply instead of accumulating in this retirement list.
    if (record.published) {
      match (in record.runtime) {
        some(runtime) => { const retained: MacOSWindowRuntime = runtime; this.retired.push(retained); }
        none => {}
      }
    }
    record.close();
    if (record.completed) {
      const id = `related-${reservation.child.windowId}`;
      match (attempt this.windows.upgrade()) { success(windows) => windows.closedNative(in id); failure(_) => {} }
    }
    // Unpublished creation failures also retire an observing factory. Cleanup
    // has finished before this notice, exactly as for completed children.
    deliverRelatedDocumentInvalidated(record.ownerView, record.owner, in reservation.owner, in reservation.child);
  }

  function fail(inout this, in reservation: RelatedWindowReservation): void {
    this.creations.fail(in reservation);
    this.rollback(in reservation);
    this.pruneInvalidated();
  }

  function pruneInvalidated(inout this): void {
    this.creations.pruneInvalidated();
    let retired = Array<RelatedWindowReservation>();
    for (const entry of this.records) {
      const reservation = entry.value.reservation;
      if (!this.documents.isLive(in reservation.child)) retired.push(copy reservation);
    }
    for (const reservation of retired) { this.rollback(in reservation); }
  }

  function closeAll(inout this): void {
    this.closed = true;
    this.creations.cancelAll();
    let pending = Array<RelatedWindowReservation>();
    for (const entry of this.records) { pending.push(copy entry.value.reservation); }
    for (const reservation of pending) { this.rollback(in reservation); }
  }
}

class RelatedWindowUI on thread.main implements WebKit.WKUIDelegate {
  readonly windows: Weak<MacOSRelatedWindows>;
  function create(in view: WebKit.WKWebView, in configuration: WebKit.WKWebViewConfiguration,
    in action: WebKit.WKNavigationAction, in features: WebKit.WKWindowFeatures
  ): WebKit.WKWebView | null as "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:" {
    return match (attempt this.windows.upgrade()) {
      success(windows) => windows.create(in view, configuration, in action);
      failure(_) => null;
    };
  }
}

internal function createRelatedWindowUIDelegate(windows: MacOSRelatedWindows): objc.Adapter<WebKit.WKUIDelegate> on thread.main {
  const controller = new RelatedWindowUI({ windows: weak windows });
  return objc.adapt<WebKit.WKUIDelegate>(controller);
}
