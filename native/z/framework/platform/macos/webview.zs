import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";

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

  constructor(frame: WebKit.CGRect, configuration: WebKit.WKWebViewConfiguration, development: boolean) {
    super.initWithFrame(frame, configuration: configuration);
    this.development = development;
  }

  override function willOpenMenu(in menu: WebKit.NSMenu, in event: WebKit.NSEvent): void as "willOpenMenu:withEvent:" {
    super.willOpenMenu(menu, withEvent: event);
    filterMacOSWebViewMenu(in menu, this.development);
  }
}
