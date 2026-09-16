import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";
import { BridgeDocument } from "../../bridge-document.zs";
import { RelatedDocumentIdentity } from "../../related-documents.zs";

// The runtime owns this observer. NSWindow and renderer completions keep weak
// Z handles, so a pending query cannot keep an otherwise closed window alive.
internal class MacOSWindowGestures on thread.main {
  readonly window: WebKit.NSWindow;
  readonly view: WebKit.WKWebView;
  readonly document: BridgeDocument;
  private generation: u64;
  private downNumber: isize;

  constructor(window: WebKit.NSWindow, view: WebKit.WKWebView, document: BridgeDocument) {
    this.window = window;
    this.view = view;
    this.document = document;
    this.generation = 0;
    this.downNumber = -1;
  }

  function before(inout this, in event: WebKit.NSEvent): void {
    if (event.type == WebKit.NSEventTypeLeftMouseDown || event.type == WebKit.NSEventTypeRightMouseDown
      || event.type == WebKit.NSEventTypeOtherMouseDown) {
      this.generation = this.generation + 1;
      this.downNumber = event.type == WebKit.NSEventTypeLeftMouseDown ? event.eventNumber : -1;
    }
  }

  function after(inout this, event: WebKit.NSEvent): void {
    if (event.type != WebKit.NSEventTypeLeftMouseDown || this.downNumber != event.eventNumber) return;
    if (usize(event.modifierFlags & WebKit.NSEventModifierFlagControl) != 0) return;
    const identity = match (this.document.readyIdentity()) { some(value) => value; none => return; };
    if (!this.window.visible || this.view.window != this.window) return;
    const point = this.view.convertPoint(event.locationInWindow, fromView: null);
    const bounds = this.view.bounds;
    if (point.x < bounds.origin.x || point.y < bounds.origin.y
      || point.x >= bounds.origin.x + bounds.size.width || point.y >= bounds.origin.y + bounds.size.height) return;
    const zoom = this.view.pageZoom;
    if (zoom <= 0) return;
    const x = (point.x - bounds.origin.x) / zoom;
    const y = (this.view.flipped ? point.y - bounds.origin.y : bounds.origin.y + bounds.size.height - point.y) / zoom;
    const generation = this.generation;
    this.query(event, identity, generation, x, y, 0);
  }

  private function query(inout this, event: WebKit.NSEvent, identity: RelatedDocumentIdentity,
    generation: u64, x: f64, y: f64, retry: i32): void {
    if (!this.current(in event, in identity, generation)) return;
    const owner = weak this;
    const script = `(()=>{const b=globalThis[Symbol.for('zapp.bridge')];return b&&typeof b._takeWindowDrag==='function'?b._takeWindowDrag('${identity.token}',${x},${y},${event.clickCount}):0})()`;
    this.view.evaluateJavaScript(move script, completionHandler: move (value, error): void => {
      if (error != null || !(value instanceof WebKit.NSNumber)) return;
      match (attempt owner.upgrade()) {
        success(active) => active.completed(event, identity, generation, x, y, retry, value.intValue);
        failure(_) => {}
      }
    });
  }

  private function current(in event: WebKit.NSEvent, in identity: RelatedDocumentIdentity, generation: u64): boolean {
    const age = WebKit.NSProcessInfo.processInfo.systemUptime - event.timestamp;
    return generation == this.generation && event.eventNumber == this.downNumber
      && this.window.visible && this.window.keyWindow && this.view.window == this.window
      && this.document.isCurrent(in identity)
      && age >= 0 && age < 0.5;
  }

  private function completed(inout this, event: WebKit.NSEvent, identity: RelatedDocumentIdentity,
    generation: u64, x: f64, y: f64, retry: i32, intent: i32): void {
    if (!this.current(in event, in identity, generation)) return;
    if (intent == -1 && retry < 2) { this.query(event, identity, generation, x, y, retry + 1); return; }
    this.downNumber = -1;
    if (intent == 2 && event.clickCount == 2) {
      performTitlebarDoubleClick(in this.window);
      return;
    }
    if ((intent == 1 || intent == 2) && (WebKit.NSEvent.pressedMouseButtons & 1) != 0) {
      this.window.performWindowDragWithEvent(event);
    }
  }
}

function performTitlebarDoubleClick(in window: WebKit.NSWindow): void on thread.main {
  const configured = WebKit.NSUserDefaults.standardUserDefaults.stringForKey("AppleActionOnDoubleClick");
  if (configured == null) { window.performZoom(null); return; }
  const action: String = configured;
  if (action == "Maximize") window.performZoom(null);
  else if (action == "Minimize") window.performMiniaturize(null);
  // None and unrecognized actions must not silently zoom. Fill needs a
  // public-API implementation; do not invoke private AppKit selectors.
}
