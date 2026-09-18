import WebKit from "WebKit/WebKit.h";
import json from "std/json";
import { thread } from "std/thread";
import { WindowFileDrops } from "../../window-file-drops.zs";
import { WindowDropPosition, WindowFileDragEnteredEvent, WindowFileDragEndedEvent } from "../../events.zs";
import { RelatedDocumentIdentity } from "../../related-documents.zs";
import { BridgeDocument } from "../../bridge-document.zs";
import { FilesystemAuthority } from "../../filesystem-authority.zs";
import { WindowManager } from "../../window.zs";
import { javascriptJSON } from "./response-delivery.zs";

// Inspect advertised types without reading promised data or publishing paths.
internal function isExternalFileDrag(in sender: WebKit.NSDraggingInfo): boolean on thread.main {
  if (sender.draggingSource != null) return false;
  const types = sender.draggingPasteboard.types;
  if (types == null) return false;
  const filenames: WebKit.NSString = "NSFilenamesPboardType";
  const promises: WebKit.NSString = "NSFilesPromisePboardType";
  const promisedURL: WebKit.NSString = "com.apple.pasteboard.promised-file-url";
  const promisedType: WebKit.NSString = "com.apple.pasteboard.promised-file-content-type";
  return types.containsObject(WebKit.NSPasteboardTypeFileURL)
    || types.containsObject(filenames) || types.containsObject(promises)
    || types.containsObject(promisedURL) || types.containsObject(promisedType);
}

internal function installMacOSFileDragTypes(in view: WebKit.WKWebView): void on thread.main {
  const types = WebKit.NSMutableArray.array();
  const filenames: WebKit.NSString = "NSFilenamesPboardType";
  const promises: WebKit.NSString = "NSFilesPromisePboardType";
  const promisedURL: WebKit.NSString = "com.apple.pasteboard.promised-file-url";
  const promisedType: WebKit.NSString = "com.apple.pasteboard.promised-file-content-type";
  types.addObject(WebKit.NSPasteboardTypeFileURL);
  types.addObject(filenames);
  types.addObject(promises);
  types.addObject(promisedURL);
  types.addObject(promisedType);
  // AppKit adds these to the existing registration; it does not replace the
  // text/HTML types registered by WebKit.
  view.registerForDraggedTypes(types);
}

internal function macOSDroppedFiles(in board: WebKit.NSPasteboard): Option<Array<String>> on thread.main {
  const items = board.pasteboardItems;
  if (items == null || items.count == 0) return Option.none;
  let paths = Array<String>();
  let index: usize = 0;
  while (index < usize(items.count)) {
    const item = items.objectAtIndex(index);
    if (!(item instanceof WebKit.NSPasteboardItem)) return Option.none;
    const source = item.stringForType(WebKit.NSPasteboardTypeFileURL);
    if (source == null) return Option.none;
    const url = WebKit.NSURL.URLWithString(source);
    if (url == null || !url.fileURL) return Option.none;
    const host = url.host;
    if (host != null && host.length != 0 && !host.isEqualToString("localhost")) return Option.none;
    const resolved = url.URLByResolvingSymlinksInPath;
    if (resolved == null) return Option.none;
    const path = resolved.path;
    if (path == null || path.length == 0) return Option.none;
    const attributes = WebKit.NSFileManager.defaultManager.attributesOfItemAtPath(path, error: null);
    if (attributes == null) return Option.none;
    const kind = attributes.objectForKey(WebKit.NSFileType);
    if (!(kind instanceof WebKit.NSString) || !kind.isEqualToString(WebKit.NSFileTypeRegular)) return Option.none;
    const owned: String = path;
    paths.push(move owned);
    index = index + 1;
  }
  return Option.some(move paths);
}

internal class MacOSFileDrops on thread.main {
  readonly view: WebKit.WKWebView;
  readonly id: String;
  readonly enabled: boolean;
  readonly document: BridgeDocument;
  readonly authority: FilesystemAuthority;
  readonly windows: Weak<WindowManager>;
  private session: Option<WindowFileDrops>;
  private identity: Option<RelatedDocumentIdentity>;
  private timer: WebKit.NSTimer | null;
  private sequence: isize;

  constructor(view: WebKit.WKWebView, id: String, enabled: boolean, document: BridgeDocument,
    authority: FilesystemAuthority, windows: Weak<WindowManager>) {
    this.view = view;
    this.id = move id;
    this.enabled = enabled;
    this.document = document;
    this.authority = authority;
    this.windows = windows;
    this.session = Option.none;
    this.identity = Option.none;
    this.timer = null;
    this.sequence = -1;
  }

  deinit {
    const timer = this.timer;
    if (timer != null) timer.invalidate();
  }

  private function active(): Option<WindowFileDrops> {
    return match (in this.session) { some(value) => Option.some(value); none => Option.none; };
  }

  private function position(in sender: WebKit.NSDraggingInfo): Option<WindowDropPosition> {
    const point = this.view.convertPoint(sender.draggingLocation, fromView: null);
    const bounds = this.view.bounds;
    const zoom = this.view.pageZoom;
    if (zoom <= 0) return Option.none;
    return Option.some(WindowDropPosition({ x: (point.x - bounds.origin.x) / zoom,
      y: (this.view.flipped ? point.y - bounds.origin.y : bounds.origin.y + bounds.size.height - point.y) / zoom }));
  }

  private function deliver(in identity: RelatedDocumentIdentity, in name: String, in encoded: String): void {
    if (!this.document.isCurrent(in identity)) return;
    const payload = javascriptJSON(in encoded);
    const script = `(()=>{const b=globalThis[Symbol.for('zapp.bridge')];if(b&&typeof b._onDocumentWindowEvent==='function')b._onDocumentWindowEvent('${identity.token}','${name}',${payload})})()`;
    this.view.evaluateJavaScript(move script, completionHandler: move (value, error): void => {});
  }

  private function scheduleMovement(inout this): void {
    if (this.timer != null) return;
    const owner = weak this;
    const timer = WebKit.NSTimer.timerWithTimeInterval(0.016, repeats: false, block: move (timer): void => {
      match (attempt owner.upgrade()) { success(current) => current.flushMovement(in timer); failure(_) => {} }
    });
    this.timer = timer;
    // Drag tracking runs outside the default run-loop mode. One weak, one-shot
    // timer retains only the latest position before any JSON/IPC work happens.
    WebKit.NSRunLoop.mainRunLoop.addTimer(timer, forMode: WebKit.NSRunLoopCommonModes);
  }

  private function flushMovement(inout this, in timer: WebKit.NSTimer): void {
    if (this.timer != timer) return;
    this.timer = null;
    const identity = match (this.identity) { some(value) => value; none => return; };
    let session = match (this.active()) { some(value) => value; none => return; };
    const sequence = this.sequence;
    const event = match (session.takeMovement()) { some(value) => value; none => { this.exit(); return; } };
    if (!session.current(sequence)) { this.exit(); return; }
    const encoded = match (attempt json.encode(in event)) { success(value) => value; failure(_) => return; };
    this.deliver(in identity, "file-drag-moved", in encoded);
  }

  function enter(inout this, in sender: WebKit.NSDraggingInfo): WebKit.NSDragOperation {
    this.exit();
    if (usize(sender.draggingSourceOperationMask & WebKit.NSDragOperationCopy) == 0) return WebKit.NSDragOperationNone;
    const position = match (this.position(in sender)) { some(value) => value; none => return WebKit.NSDragOperationNone; };
    const identity = match (this.document.readyIdentity()) { some(value) => value; none => return WebKit.NSDragOperationNone; };
    const manager = match (attempt this.windows.upgrade()) { success(value) => value; failure(_) => return WebKit.NSDragOperationNone; };
    const window = match (manager.get(in this.id)) { some(value) => value; none => return WebKit.NSDragOperationNone; };
    let session = new WindowFileDrops(copy this.id, this.enabled, this.document, this.authority, window.events);
    if (!session.begin(sender.draggingSequenceNumber, position)) return WebKit.NSDragOperationNone;
    this.session = Option.some(session);
    this.identity = Option.some(identity);
    this.sequence = sender.draggingSequenceNumber;
    const event = WindowFileDragEnteredEvent({ windowId: copy this.id, position });
    const encoded = match (attempt json.encode(in event)) { success(value) => value; failure(_) => { this.exit(); return WebKit.NSDragOperationNone; } };
    this.deliver(in identity, "file-drag-entered", in encoded);
    return WebKit.NSDragOperationCopy;
  }

  function update(inout this, in sender: WebKit.NSDraggingInfo): WebKit.NSDragOperation {
    let session = match (this.active()) { some(value) => value; none => return WebKit.NSDragOperationNone; };
    const position = match (this.position(in sender)) { some(value) => value; none => { this.exit(); return WebKit.NSDragOperationNone; } };
    if (usize(sender.draggingSourceOperationMask & WebKit.NSDragOperationCopy) == 0
      || !session.update(sender.draggingSequenceNumber, position)) { this.exit(); return WebKit.NSDragOperationNone; }
    if (session.hasMovement()) this.scheduleMovement();
    return WebKit.NSDragOperationCopy;
  }

  function exit(inout this): void {
    const timer = this.timer;
    this.timer = null;
    if (timer != null) timer.invalidate();
    const identity = this.identity;
    this.identity = Option.none;
    this.sequence = -1;
    const session = this.active();
    this.session = Option.none;
    match (session) { some(value) => value.clear(); none => {} }
    match (identity) {
      some(value) => {
        const event = WindowFileDragEndedEvent({ windowId: copy this.id });
        const encoded = match (attempt json.encode(in event)) { success(text) => text; failure(_) => return; };
        this.deliver(in value, "file-drag-ended", in encoded);
      }
      none => {}
    }
  }

  function prepare(inout this, in sender: WebKit.NSDraggingInfo): boolean {
    if (this.update(in sender) == WebKit.NSDragOperationNone) return false;
    return match (macOSDroppedFiles(sender.draggingPasteboard)) { some(_) => true; none => { this.exit(); select false; } };
  }

  function perform(inout this, in sender: WebKit.NSDraggingInfo): boolean {
    if (this.update(in sender) == WebKit.NSDragOperationNone) { this.exit(); return false; }
    let session = match (this.active()) { some(value) => value; none => return false; };
    const activeIdentity = this.identity;
    const identity = match (activeIdentity) { some(value) => value; none => { this.exit(); return false; } };
    const paths = match (macOSDroppedFiles(sender.draggingPasteboard)) {
      some(value) => value;
      none => { this.exit(); return false; }
    };
    const position = match (this.position(in sender)) { some(value) => value; none => { this.exit(); return false; } };
    const event = match (session.accept(sender.draggingSequenceNumber, in paths, position)) {
      some(value) => value;
      none => { this.exit(); return false; }
    };
    this.exit();
    // Native observers may close the window after accepting. The drop remains
    // accepted, but no queued script can disclose paths to a replacement page.
    if (!this.document.isCurrent(in identity)) return true;
    const encoded = match (attempt json.encode(in event)) { success(value) => value; failure(_) => return true; };
    this.deliver(in identity, "files-dropped", in encoded);
    return true;
  }
}
