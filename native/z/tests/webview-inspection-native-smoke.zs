import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";
import { Inspectable, resolveInspectable } from "../framework/window-inspection.zs";
import { MacOSWebView, filterMacOSWebViewMenu } from "../framework/platform/macos/webview.zs";
import { configureWebViewDeveloperExtras, configuredWebViewInspectable, configuredFrontendIsDevelopment } from "../framework/platform/macos/configured-webview.zs";

function main(): i32 on thread.main {
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyAccessory);
  const defaults = Array<boolean>(true, false);
  for (const defaultValue of defaults) {
    if (resolveInspectable(Inspectable.auto, defaultValue) != defaultValue) return 1;
    if (!resolveInspectable(Inspectable.enabled, defaultValue)) return 2;
    if (resolveInspectable(Inspectable.disabled, defaultValue)) return 3;
  }
  const policies = Array<Inspectable>(Inspectable.auto, Inspectable.enabled, Inspectable.disabled);
  for (const policy of policies) {
    const enabled = resolveInspectable(policy, configuredWebViewInspectable());
    const config = WebKit.WKWebViewConfiguration.alloc().init();
    configureWebViewDeveloperExtras(in config, enabled);
    const view = new MacOSWebView(WebKit.NSMakeRect(0, 0, 300, 200), config, configuredFrontendIsDevelopment());
    view.inspectable = enabled;
    if (view.inspectable != enabled) return 4;
    // The related path must explicitly apply its owner's effective policy,
    // even when WebKit supplies a fresh configuration with different defaults.
    const childConfig = WebKit.WKWebViewConfiguration.alloc().init();
    configureWebViewDeveloperExtras(in childConfig, view.inspectable);
    const child = new MacOSWebView(WebKit.NSMakeRect(0, 0, 200, 150), childConfig, configuredFrontendIsDevelopment());
    child.inspectable = view.inspectable;
    if (child.inspectable != enabled) return 5;
  }
  const menu = WebKit.NSMenu.alloc().initWithTitle("Native menu probe");
  const reload = WebKit.NSMenuItem.alloc().init();
  reload.title = "Neu laden";
  reload.identifier = "WKMenuItemIdentifierReload";
  menu.addItem(reload);
  const copy = WebKit.NSMenuItem.alloc().init();
  copy.title = "Copy";
  copy.identifier = "WKMenuItemIdentifierCopy";
  menu.addItem(copy);
  const custom = WebKit.NSMenuItem.alloc().init();
  custom.title = "Reload";
  custom.identifier = "app.custom.reload";
  menu.addItem(custom);
  filterMacOSWebViewMenu(in menu, true);
  if (menu.numberOfItems != 3) return 6;
  filterMacOSWebViewMenu(in menu, false);
  if (menu.numberOfItems != 2) return 7;
  if (menu.itemAtIndex(0) != copy || menu.itemAtIndex(1) != custom) return 8;
  filterMacOSWebViewMenu(in menu, false);
  if (menu.numberOfItems != 2) return 9;
  return 0;
}
