import WebKit from "WebKit/WebKit.h";
import console from "std/console";
import { thread } from "std/thread";
import { TitleBarOptions, TitleBarStyle } from "../framework/window-titlebar.zs";
import { applyMacOSTitleBar, macOSTitleBarStyleMask } from "../framework/platform/macos/window-titlebar.zs";
import { MacOSWindow } from "../framework/platform/macos/window-resize.zs";
import { measureWindowChrome } from "../framework/platform/macos/window-chrome.zs";
import { applyMacOSWindowPolicy } from "../framework/platform/macos/window-policy.zs";

struct Lifetime on thread.main {
  window: MacOSWindow;
  deinit { this.window.close(); }
}

function verify(style: TitleBarStyle, titleVisible: boolean): f64 throws i32 on thread.main {
  const options = TitleBarOptions({ style, titleVisible });
  const mask = WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable
    | WebKit.NSWindowStyleMaskMiniaturizable | WebKit.NSWindowStyleMaskResizable;
  const window = new MacOSWindow(WebKit.NSMakeRect(200, 200, 420, 260), macOSTitleBarStyleMask(mask, in options));
  const lifetime = Lifetime({ window });
  const view = WebKit.WKWebView.alloc().initWithFrame(WebKit.NSMakeRect(0, 0, 420, 260));
  window.contentView = view;
  window.title = "Zapp titlebar probe";
  applyMacOSTitleBar(in window, in options, "probe");
  if (window.visible) throw 1;
  if (window.titlebarAppearsTransparent != (style != TitleBarStyle.default)) throw 2;
  const fullSize = (window.styleMask & WebKit.NSWindowStyleMaskFullSizeContentView) == WebKit.NSWindowStyleMaskFullSizeContentView;
  if (fullSize != (style != TitleBarStyle.default)) throw 3;
  const visibility = window.titleVisibility;
  if ((visibility == WebKit.NSWindowTitleVisible) != titleVisible) throw 4;
  window.title = "Updated title";
  const title: String = window.title;
  const updatedVisibility = window.titleVisibility;
  if (title != "Updated title" || (updatedVisibility == WebKit.NSWindowTitleVisible) != titleVisible) throw 5;
  const toolbar = window.toolbar;
  if ((toolbar != null) != (style == TitleBarStyle.hiddenInset)) throw 6;
  window.orderFront(null);
  window.displayIfNeeded();
  const button = window.standardWindowButton(WebKit.NSWindowCloseButton);
  const minimize = window.standardWindowButton(WebKit.NSWindowMiniaturizeButton);
  const zoom = window.standardWindowButton(WebKit.NSWindowZoomButton);
  if (button == null || minimize == null || zoom == null) throw 7;
  if (button.hidden || minimize.hidden || zoom.hidden) throw 8;
  const rect = button.convertRect(button.bounds, toView: null);
  const inset = window.frame.size.height - rect.origin.y - rect.size.height;
  const metrics = measureWindowChrome(in window, in view);
  if (style == TitleBarStyle.default) {
    if (metrics.top != 0 || metrics.controlsLeft != 0) throw 11;
  } else {
    if (metrics.top <= 0 || metrics.controlsLeft <= 0) throw 12;
    view.pageZoom = 2.0;
    const scaled = measureWindowChrome(in window, in view);
    if (scaled.top != metrics.top / 2 || scaled.controlsLeft != metrics.controlsLeft / 2) throw 13;
    view.pageZoom = 1.0;
  }
  const label = match (style) { default => "default"; hidden => "hidden"; hiddenInset => "hiddenInset"; };
  console.log(`titlebar: style=${label} titleVisible=${titleVisible} controlsTop=${inset} overlap=${metrics.top} controlsLeft=${metrics.controlsLeft}`);
  window.orderOut(null);
  if (window.visible) throw 9;
  applyMacOSWindowPolicy(window, false, false);
  if (zoom.enabled || window.allowsFullscreen()) throw 14;
  if (usize(window.styleMask & WebKit.NSWindowStyleMaskResizable) == 0) throw 15;
  const before = window.frame;
  window.zoom(null);
  window.toggleFullScreen(null);
  const after = window.frame;
  if (before.origin.x != after.origin.x || before.origin.y != after.origin.y
    || before.size.width != after.size.width || before.size.height != after.size.height) throw 16;
  if (usize(window.styleMask & WebKit.NSWindowStyleMaskFullScreen) != 0) throw 17;
  applyMacOSWindowPolicy(window, true, false);
  if (!zoom.enabled || window.allowsFullscreen()) throw 18;
  applyMacOSWindowPolicy(window, false, true);
  if (!zoom.enabled || !window.allowsFullscreen()) throw 19;
  return inset;
}

function main(): i32 on thread.main {
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  const visibilityCases = Array<boolean>(true, false);
  for (const visible of visibilityCases) {
    const standard = match (attempt verify(TitleBarStyle.default, visible)) { success(value) => value; failure(code) => return code; };
    const hidden = match (attempt verify(TitleBarStyle.hidden, visible)) { success(value) => value; failure(code) => return code; };
    const inset = match (attempt verify(TitleBarStyle.hiddenInset, visible)) { success(value) => value; failure(code) => return code; };
    if (inset <= hidden || standard < 0) return 10;
  }
  return 0;
}
