import WebKit from "WebKit/WebKit.h";
import console from "std/console";
import { thread } from "std/thread";
import { Set } from "std/collections";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { BridgeDocument } from "../framework/bridge-document.zs";
import { createRelatedDocuments } from "../framework/related-documents.zs";
import { MacOSWindow } from "../framework/platform/macos/window-resize.zs";
import { MacOSWindowGestures } from "../framework/platform/macos/window-drag.zs";

function selection(): CapabilitySelection {
  let names = Array<String>();
  let permissions = Set<String>();
  let services = Set<String>();
  let workers = Set<String>();
  return new CapabilitySelection({
    names: names.freeze(), permissions: permissions.freeze(),
    serviceMethods: services.freeze(), workerIds: workers.freeze(),
  });
}

function install(window: MacOSWindow, view: WebKit.WKWebView): Weak<MacOSWindowGestures> throws i32 on thread.main {
  const document = new BridgeDocument(1, createRelatedDocuments(), selection());
  const observer = new MacOSWindowGestures(window, view, document);
  window.observeGestures(weak observer);
  const down = WebKit.NSEvent.mouseEventWithType(WebKit.NSEventTypeLeftMouseDown,
    location: WebKit.NSMakePoint(50, 50), modifierFlags: WebKit.NSEventModifierFlagControl,
    timestamp: WebKit.NSProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
    context: null, eventNumber: 1, clickCount: 1, pressure: 1.0);
  if (down == null) throw 3;
  // Control-click must use this event's flags; a native query is unnecessary.
  window.sendEvent(down);
  document.close();
  return weak observer;
}

function main(): i32 on thread.main {
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  const view = WebKit.WKWebView.alloc().initWithFrame(WebKit.NSMakeRect(0, 0, 300, 180));
  const window = new MacOSWindow(WebKit.NSMakeRect(200, 200, 300, 180), WebKit.NSWindowStyleMaskTitled);
  window.contentView = view;
  const expired = match (attempt install(window, view)) { success(value) => value; failure(code) => return code; };
  const alive = match (attempt expired.upgrade()) { success(value) => true; failure(_) => false; };
  if (alive) return 1;
  const up = WebKit.NSEvent.mouseEventWithType(WebKit.NSEventTypeLeftMouseUp,
    location: WebKit.NSMakePoint(50, 50), modifierFlags: WebKit.NSEventModifierFlagControl,
    timestamp: WebKit.NSProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
    context: null, eventNumber: 2, clickCount: 1, pressure: 0.0);
  if (up == null) return 2;
  // An expired observer must fall through to AppKit without dereferencing it.
  window.sendEvent(up);
  window.close();
  console.log("window gesture observer: native input and weak expiration passed");
  return 0;
}
