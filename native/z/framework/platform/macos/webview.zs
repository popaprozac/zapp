import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";
import objc from "std/objc";
import { MacOSFileDrops, isExternalFileDrag } from "./file-drops.zs";

internal function filterMacOSWebViewMenu(in menu: WebKit.NSMenu, development: boolean): void on thread.main {
  if (development) return;
  let index = menu.numberOfItems;
  while (index > 0) {
    index = index - 1;
    const item = menu.itemAtIndex(index);
    if (item != null) {
      const identifier = item.identifier;
      // WebKit's identifier is an implementation detail, checked by a native
      // compatibility probe. Never match a translated title or a numeric tag.
      if (identifier != null && identifier.isEqualToString("WKMenuItemIdentifierReload")) {
        menu.removeItemAtIndex(index);
      }
    }
  }
}

internal class MacOSWebView extends WebKit.WKWebView on thread.main {
  private readonly development: boolean;
  private drops: Option<Weak<MacOSFileDrops>>;
  private externalFiles: boolean;
  private inheritedDragOperation: WebKit.NSDragOperation;

  constructor(frame: WebKit.CGRect, configuration: WebKit.WKWebViewConfiguration, development: boolean) {
    super.initWithFrame(frame, configuration: configuration);
    this.development = development;
    this.drops = Option.none;
    this.externalFiles = false;
    this.inheritedDragOperation = WebKit.NSDragOperationNone;
  }

  internal function observeFileDrops(inout this, drops: Weak<MacOSFileDrops>): void {
    this.drops = Option.some(drops);
  }

  private function fileDrops(): Option<MacOSFileDrops> {
    return match (in this.drops) {
      some(owner) => { select match (attempt owner.upgrade()) { success(value) => Option.some(value); failure(_) => Option.none; }; }
      none => Option.none;
    };
  }

  override function draggingEntered(inout this, in sender: WebKit.NSDraggingInfo): WebKit.NSDragOperation as "draggingEntered:" {
    this.externalFiles = isExternalFileDrag(in sender);
    if (this.externalFiles) {
      return match (this.fileDrops()) { some(drops) => drops.enter(in sender); none => WebKit.NSDragOperationNone; };
    }
    const inherited = objc.optionalCall(super.draggingEntered(sender));
    this.inheritedDragOperation = match (in inherited) { some(value) => value; none => WebKit.NSDragOperationNone; };
    return this.inheritedDragOperation;
  }

  override function draggingUpdated(inout this, in sender: WebKit.NSDraggingInfo): WebKit.NSDragOperation as "draggingUpdated:" {
    if (this.externalFiles || isExternalFileDrag(in sender)) {
      return match (this.fileDrops()) { some(drops) => drops.update(in sender); none => WebKit.NSDragOperationNone; };
    }
    const inherited = objc.optionalCall(super.draggingUpdated(sender));
    return match (in inherited) { some(value) => value; none => this.inheritedDragOperation; };
  }

  override function draggingExited(inout this, in sender: objc.Object | null): void as "draggingExited:" {
    if (this.externalFiles) {
      match (this.fileDrops()) { some(drops) => drops.exit(); none => {} }
      this.externalFiles = false;
      return;
    }
    objc.optionalCall(super.draggingExited(sender));
  }

  override function prepareForDragOperation(inout this, in sender: WebKit.NSDraggingInfo): boolean as "prepareForDragOperation:" {
    if (this.externalFiles || isExternalFileDrag(in sender)) {
      return match (this.fileDrops()) { some(drops) => drops.prepare(in sender); none => false; };
    }
    const inherited = objc.optionalCall(super.prepareForDragOperation(sender));
    return match (in inherited) { some(value) => value; none => true; };
  }

  override function performDragOperation(inout this, in sender: WebKit.NSDraggingInfo): boolean as "performDragOperation:" {
    if (this.externalFiles || isExternalFileDrag(in sender)) {
      return match (this.fileDrops()) { some(drops) => drops.perform(in sender); none => false; };
    }
    const inherited = objc.optionalCall(super.performDragOperation(sender));
    return match (in inherited) { some(value) => value; none => false; };
  }

  override function concludeDragOperation(inout this, in sender: objc.Object | null): void as "concludeDragOperation:" {
    if (this.externalFiles) {
      match (this.fileDrops()) { some(drops) => drops.exit(); none => {} }
      return;
    }
    objc.optionalCall(super.concludeDragOperation(sender));
  }

  override function draggingEnded(inout this, in sender: WebKit.NSDraggingInfo): void as "draggingEnded:" {
    if (this.externalFiles || isExternalFileDrag(in sender)) {
      match (this.fileDrops()) { some(drops) => drops.exit(); none => {} }
      this.externalFiles = false;
      return;
    }
    objc.optionalCall(super.draggingEnded(sender));
  }

  override function willOpenMenu(in menu: WebKit.NSMenu, in event: WebKit.NSEvent): void as "willOpenMenu:withEvent:" {
    super.willOpenMenu(menu, withEvent: event);
    filterMacOSWebViewMenu(in menu, this.development);
  }
}
